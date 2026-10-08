import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/learning_backup.dart';
import 'package:word_a_i/services/learning_repository.dart';

const _tables = [
  'learning_progress',
  'review_sessions',
  'review_attempts',
  'review_questions',
  'learning_sync_state',
];
const _order = [
  'target_id',
  'session_id',
  'attempt_id',
  'session_id, target_id, language_code',
  'uid, collection_name',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('disk round trip preserves earned progress and answered history',
      () async {
    final source = await _Disk.create(history: true);
    final before = await source.snapshot();
    final backup = await source.service.capture();
    final decoded = _decode(backup);
    expect(backup.progressCount, 4);
    expect(backup.sessionCount, 3);
    expect(backup.attemptCount, 3);
    expect(decoded.keys, isNot(contains('review_questions')));
    expect(decoded.keys, isNot(contains('learning_sync_state')));
    expect(utf8.decode(backup.toBytes()), isNot(contains('synced_at')));
    expect(await source.snapshot(), before);

    final target = await _Disk.create();
    // Restore is supported on a populated installation, including starter data.
    for (final word in sampleWords().skip(4)) {
      await target.repo.registerDossier('local', word);
    }
    expect((await target.db.query('learning_progress')).length, 12);
    final read = await _read(decoded);
    await target.service.restore(read);
    await target.reopen();
    final restored = await target.snapshot();
    expect(_withoutSync(restored['learning_progress']!),
        decoded['learning_progress']);
    expect(
        _withoutSync(restored['review_attempts']!), decoded['review_attempts']);
    expect(restored['review_questions'], isEmpty);
    expect(restored['learning_sync_state'], isEmpty);
    expect(await target.repo.careerLearnedCount('local'), 1);
    expect(await target.repo.resumeActiveSession('local'), isNull);
    for (final session in restored['review_sessions']!) {
      final original = (decoded['review_sessions'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((row) => row['session_id'] == session['session_id']);
      final expected = Map<String, Object?>.of(original);
      if (original['status'] == 'active') {
        expected.addAll({
          'status': 'exited',
          'exit_reason': 'restored_backup',
          'ended_at': backup.createdAtMs,
          'updated_at': backup.createdAtMs,
        });
      }
      expect(_withoutSync([session]).single, expected);
    }
    for (final table in _tables.take(3)) {
      expect(restored[table]!.every((row) => row['synced_at'] == null), isTrue);
    }
    final fresh = (await target.repo.createSession('local'))!;
    expect(
        (decoded['review_sessions'] as List)
            .any((row) => row['session_id'] == fresh.id),
        isFalse);
    expect(await target.repo.buildQuestion(fresh, 'en'), isNotNull);
  });

  test('capture transaction keeps a queued writer outside the entire snapshot',
      () async {
    final disk = await _Disk.create(history: true);
    final before = await disk.snapshot();
    final wrapped = _SnapshotDatabase(disk.db);
    final backup =
        await LearningBackupService(LearningRepository.forTesting(wrapped))
            .capture();
    expect(wrapped.queuedWrite, isNotNull);
    await wrapped.queuedWrite;
    final decoded = _decode(backup);
    expect(decoded['learning_progress'],
        _withoutSync(before['learning_progress']!));
    expect(
        decoded['review_sessions'], _withoutSync(before['review_sessions']!));
    final changed = await disk.snapshot();
    expect(changed['learning_progress']!.every((r) => r['attempt_count'] == 99),
        isTrue);
    expect(changed['review_sessions']!.every((r) => r['completed_count'] == 17),
        isTrue);
    expect(_decode(backup), decoded);
  });

  test('mid-restore SQLite failure rolls back deleted and inserted disk rows',
      () async {
    final source = await _Disk.create(history: true);
    final backup = await source.service.capture();
    final target = await _Disk.create(history: true);
    final before = await target.snapshot();
    // Insertion order has already replaced progress and sessions by the time
    // this real SQLite trigger aborts the first restored attempt.
    await target.db.execute('''
      CREATE TRIGGER fail_restored_attempt BEFORE INSERT ON review_attempts
      BEGIN SELECT RAISE(ABORT, 'synthetic payload must not reach the UI'); END
    ''');
    await expectLater(
        target.service.restore(backup),
        throwsA(isA<LearningBackupException>().having((e) => e.message,
            'safe message', isNot(contains('synthetic payload')))));
    await target.reopen();
    expect(await target.snapshot(), before);
    expect(await target.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await target.db.execute('DROP TRIGGER fail_restored_attempt');
    await target.service.restore(backup);
    await target.reopen();
    expect((await target.db.query('review_attempts')).length, 3);
  });

  test('the same backup restores deterministically without mutating its bytes',
      () async {
    final disk = await _Disk.create(history: true);
    final backup = await disk.service.capture();
    final bytes = backup.toBytes();
    final callerCopy = backup.toBytes();
    callerCopy.fillRange(0, callerCopy.length, 0);
    expect(backup.toBytes(), bytes);
    await disk.service.restore(backup);
    final first = await disk.snapshot();
    await disk.service.restore(backup);
    await disk.reopen();
    expect(await disk.snapshot(), first);
    expect(backup.toBytes(), bytes);
  });

  test('another profile in any owned table prevents capture and replacement',
      () async {
    final disk = await _Disk.create(history: true);
    final backup = await disk.service.capture();
    for (final table in [..._tables.take(3), 'learning_sync_state']) {
      await disk.db.update(table, {'uid': 'another-profile'});
      final before = await disk.snapshot();
      await expectLater(
          disk.service.capture(), throwsA(isA<LearningBackupException>()));
      await expectLater(disk.service.restore(backup),
          throwsA(isA<LearningBackupException>()));
      await disk.reopen();
      expect(await disk.snapshot(), before, reason: table);
      await disk.db.update(table, {'uid': 'local'});
    }
  });

  test('dictionary-only data is useful; an empty backup cannot clear a device',
      () async {
    final disk = await _Disk.create();
    final backup = await disk.service.capture();
    expect(backup.progressCount, 4);
    expect(backup.sessionCount, 0);
    expect(backup.attemptCount, 0);
    final empty = _decode(backup)..['learning_progress'] = [];
    await expectLater(_read(empty), throwsA(isA<LearningBackupException>()));
    final before = await disk.snapshot();
    expect(await disk.snapshot(), before);
    final newInstall = await _Disk.create(seed: false);
    await expectLater(
        newInstall.service.capture(), throwsA(isA<LearningBackupException>()));
    await newInstall.service.restore(backup);
    await newInstall.reopen();
    expect((await newInstall.db.query('learning_progress')).length, 4);
  });

  test(
      'historical summaries and wall-clock adjustments need not match attempts',
      () async {
    final disk = await _Disk.create(history: true);
    final document = _decode(await disk.service.capture());
    final progress = (document['learning_progress'] as List).first;
    progress['attempt_count'] = 500;
    progress['context_passed_at'] = null;
    progress['learned_at'] = null;
    progress['last_tested_at'] = null;
    final session = (document['review_sessions'] as List)
        .firstWhere((row) => row['status'] == 'completed');
    session['started_at'] = 10000;
    session['ended_at'] = 20;
    session['updated_at'] = 1;
    session['target_count'] = 40;
    session['completed_count'] = 30;
    session['context_passed_count'] = 25;
    session['new_learned_count'] = 20;
    session['active_ms'] = 90000000;
    final backup = await _read(document);
    await disk.service.restore(backup);
    await disk.reopen();
    final restored = (await disk.db.query('review_sessions',
            where: 'session_id = ?', whereArgs: [session['session_id']]))
        .single;
    expect(_withoutSync([restored]).single, session);
    expect(
        (await disk.db.query('learning_progress',
                where: 'target_id = ?', whereArgs: [progress['target_id']]))
            .single['attempt_count'],
        500);
  });

  test(
      'schema, strict scalar types, stages, identity and references fail closed',
      () async {
    final disk = await _Disk.create(history: true);
    final original = _decode(await disk.service.capture());
    final mutations = <String, void Function(Map<String, dynamic>)>{
      'version': (d) => d['version'] = 3,
      'numeric version type': (d) => d['version'] = 2.0,
      'unknown root field': (d) => d['extra'] = true,
      'missing root field': (d) => d.remove('created_at_ms'),
      'foreign profile': (d) => d['profile'] = 'another-profile',
      'foreign row': (d) =>
          d['learning_progress'][0]['uid'] = 'another-profile',
      'unknown row field': (d) => d['learning_progress'][0]['synced_at'] = 1,
      'missing row field': (d) =>
          d['learning_progress'][0].remove('updated_at'),
      'nullable required': (d) => d['learning_progress'][0]['word'] = null,
      'string counter': (d) => d['learning_progress'][0]['attempt_count'] = '1',
      'float counter': (d) => d['learning_progress'][0]['attempt_count'] = 1.0,
      'negative count': (d) => d['learning_progress'][0]['attempt_count'] = -1,
      'counter bound': (d) =>
          d['learning_progress'][0]['attempt_count'] = 2147483648,
      'integer precision': (d) => d['created_at_ms'] = 9007199254740992,
      'DateTime range': (d) => d['created_at_ms'] = 8640000000000001,
      'stored DateTime range': (d) =>
          d['review_sessions'][0]['started_at'] = 8640000000000001,
      'boolean flag': (d) => d['learning_progress'][0]['learned_once'] = true,
      'stage bound': (d) => d['learning_progress'][0]['stage'] = 3,
      'changed query': (d) => d['learning_progress'][0]['query'] = 'changed',
      'changed sense': (d) => d['learning_progress'][0]['sense_id'] = 'changed',
      'lexeme hash': (d) => d['learning_progress'][0]['lexeme_id'] = 'a' * 64,
      'target hash': (d) => d['learning_progress'][0]['target_id'] = 'a' * 64,
      'invalid surrogate': (d) => d['learning_progress'][0]['word'] = '\ud800',
      'field byte limit': (d) =>
          d['learning_progress'][0]['definition_en'] = '字' * 21846,
      'missing session': (d) =>
          d['review_attempts'][0]['session_id'] = 'absent',
      'missing target': (d) => d['review_attempts'][0]['target_id'] = 'b' * 64,
      'missing selected target': (d) =>
          d['review_sessions'][0]['target_ids_json'] = jsonEncode(['b' * 64]),
      'session index': (d) => d['review_sessions'][0]['current_index'] = 21,
      'duplicate selected target': (d) {
        final id = jsonDecode(d['review_sessions'][0]['target_ids_json'])[0];
        d['review_sessions'][0]['target_ids_json'] = jsonEncode([id, id]);
      },
      'attempt outside selection': (d) {
        final attempt = d['review_attempts'][0];
        final session = (d['review_sessions'] as List)
            .firstWhere((s) => s['session_id'] == attempt['session_id']);
        final other = (d['learning_progress'] as List)
            .firstWhere((r) => r['target_id'] != attempt['target_id']);
        session['target_ids_json'] = jsonEncode([other['target_id']]);
      },
      'incorrect stage transition': (d) =>
          d['review_attempts'][0]['new_stage'] = 0,
      'incorrect test type': (d) =>
          d['review_attempts'][0]['test_type'] = 'other',
      'latency bound': (d) => d['review_attempts'][0]['latency_ms'] = 3600001,
      for (final table in _tables.take(3))
        'duplicate $table id': (d) => d[table].add(d[table][0]),
    };
    final before = await disk.snapshot();
    for (final entry in mutations.entries) {
      final changed = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      entry.value(changed);
      await expectLater(_read(changed), throwsA(isA<LearningBackupException>()),
          reason: entry.key);
    }
    await disk.reopen();
    expect(await disk.snapshot(), before);
  });

  test(
      'truncation, duplicate JSON keys, excessive depth and invalid UTF-8 reject',
      () async {
    final disk = await _Disk.create();
    final json = utf8.decode((await disk.service.capture()).toBytes());
    final malformed = <List<int>>[
      [],
      [0xff],
      utf8.encode(json.substring(0, json.length - 1)),
      utf8.encode(json.replaceFirst('"version":2', '"version":2,"version":1')),
      utf8.encode(
          json.replaceFirst('"version":2', '"vers\\u0069on":2,"version":1')),
      utf8.encode(json.replaceFirst('"stage":0', '"stage":2,"stage":0')),
      utf8.encode('${'[' * 9}0${']' * 9}'),
      utf8.encode('{"bad": [}'),
    ];
    for (final bytes in malformed) {
      await expectLater(readLearningBackup(Stream.value(bytes)),
          throwsA(isA<LearningBackupException>()));
    }
    await expectLater(
        readLearningBackup(
            Stream.error(StateError('private diagnostic must not escape'))),
        throwsA(isA<LearningBackupException>().having((e) => e.message,
            'message', isNot(contains('private diagnostic')))));
  });

  test('32 MiB applies to actual bytes and stops consuming an oversized stream',
      () async {
    var cancelled = false;
    var afterOverflow = false;
    Stream<List<int>> oversized() async* {
      try {
        final chunk = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 0x20);
        for (var i = 0; i < 32; i++) {
          yield chunk;
        }
        yield [0x20];
        afterOverflow = true;
        yield [0x20];
      } finally {
        cancelled = true;
      }
    }

    await expectLater(
        readLearningBackup(oversized()),
        throwsA(isA<LearningBackupException>()
            .having((e) => e.message, 'size error', contains('32 MiB'))));
    expect(cancelled, isTrue);
    expect(afterOverflow, isFalse);
  });

  test('a valid UTF-8 backup at the exact byte limit remains readable',
      () async {
    final disk = await _Disk.create();
    final document = _decode(await disk.service.capture());
    document['created_at_ms'] = 8640000000000000;
    document['learning_progress'][0]['definition_en'] = '字' * 21845 + 'a';
    document['learning_progress'][0]['word'] = '😀';
    final content = utf8.encode(jsonEncode(document));
    Stream<List<int>> padded() async* {
      yield content;
      var remaining = maxLearningBackupBytes - content.length;
      while (remaining > 0) {
        final size = remaining > 65536 ? 65536 : remaining;
        yield Uint8List(size)..fillRange(0, size, 0x20);
        remaining -= size;
      }
    }

    final read = await readLearningBackup(padded());
    expect(read.progressCount, 4);
    expect(DateTime.fromMillisecondsSinceEpoch(read.createdAtMs).year, 275760);
    expect(_decode(read)['learning_progress'], document['learning_progress']);
  });

  test('oversized export fails without changing source data or history',
      () async {
    final disk = await _Disk.create(history: true);
    final base = Map<String, Object?>.of(
        (await disk.db.query('learning_progress')).first);
    final text = 'x' * 65536;
    await disk.db.transaction((txn) async {
      for (var i = 0; i < 60; i++) {
        final query = 'large-word-$i';
        final lexeme = _hash('en_to_zh::$query');
        final row = <String, Object?>{
          ...base,
          'query': query,
          'direction': 'en_to_zh',
          'lexeme_id': lexeme,
          'target_id': _hash('local::$lexeme::${base['sense_id']}'),
          for (final field in const [
            'word',
            'part_of_speech',
            'definition_en',
            'meaning_zh_hans',
            'meaning_zh_hant',
            'example_en',
            'example_zh_hans',
            'example_zh_hant',
            'target_form'
          ])
            field: text,
        };
        await txn.insert('learning_progress', row);
      }
    });
    final before = await _databaseDigest(disk.db);
    await expectLater(
        disk.service.capture(),
        throwsA(isA<LearningBackupException>()
            .having((e) => e.message, 'size error', contains('32 MiB'))));
    await disk.reopen();
    expect(await _databaseDigest(disk.db), before);
  }, timeout: const Timeout(Duration(seconds: 90)));
}

Map<String, dynamic> _decode(LearningBackup backup) =>
    jsonDecode(utf8.decode(backup.toBytes())) as Map<String, dynamic>;

Future<LearningBackup> _read(Map<String, dynamic> document) =>
    readLearningBackup(Stream.value(utf8.encode(jsonEncode(document))));

List<Map<String, Object?>> _withoutSync(List<Map<String, Object?>> rows) => rows
    .map((row) => Map<String, Object?>.of(row)..remove('synced_at'))
    .toList();

String _hash(String input) => sha256.convert(utf8.encode(input)).toString();

Future<List<String>> _databaseDigest(Database db) async {
  final hashes = <String>[];
  for (var i = 0; i < _tables.length; i++) {
    hashes
        .add(_hash(jsonEncode(await db.query(_tables[i], orderBy: _order[i]))));
  }
  return hashes;
}

class _Disk {
  _Disk(this.directory, this.canonicalDirectory, this.path, this.db);
  final Directory directory;
  final String canonicalDirectory;
  final String path;
  Database db;
  LearningRepository get repo => LearningRepository.forTesting(db);
  LearningBackupService get service => LearningBackupService(repo);

  static Future<_Disk> create({bool seed = true, bool history = false}) async {
    final directory = await Directory.systemTemp.createTemp('wordai-backup-');
    final canonical = await directory.resolveSymbolicLinks();
    final path = p.join(canonical, 'learning.db');
    final disk = _Disk(directory, canonical, path, await _open(path));
    addTearDown(() async {
      if (disk.db.isOpen) await disk.db.close();
      if (await directory.resolveSymbolicLinks() != canonical ||
          !p.isWithin(canonical, path)) {
        throw StateError('The fixture directory identity changed');
      }
      await directory.delete(recursive: true);
    });
    if (seed) {
      for (final word in sampleWords().take(4)) {
        await disk.repo.registerDossier('local', word);
      }
    }
    if (history) await disk.seedHistory();
    return disk;
  }

  static Future<Database> _open(String path) =>
      databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 4,
            singleInstance: false,
            onCreate: LearningRepository.createSchema,
            onUpgrade: LearningRepository.upgradeSchema,
            onDowngrade: LearningRepository.rejectSchemaDowngrade,
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ));

  Future<void> reopen() async {
    await db.close();
    db = await _open(path);
  }

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async => {
        for (var i = 0; i < _tables.length; i++)
          _tables[i]: await db.query(_tables[i], orderBy: _order[i]),
      };

  Future<void> seedHistory() async {
    final repository = repo;
    for (var round = 0; round < 3; round++) {
      final session = (await repository.createSession('local',
          queries: round < 2 ? ['cat'] : ['river', 'book'], maximum: 2))!;
      final question = (await repository.buildQuestion(session, 'en'))!;
      await repository.recordAnswer(
          uid: 'local',
          session: session,
          question: question,
          selectedIndex: question.correctIndex,
          latencyMs: 15,
          activeMs: 31);
      if (round < 2) {
        await repository.finishSession(
            uid: 'local', sessionId: session.id, completed: true, activeMs: 45);
      } else {
        final next = await repository.sessionById(session.id);
        expect(await repository.buildQuestion(next, 'en'), isNotNull);
      }
    }
    for (final table in _tables.take(3)) {
      await db.update(table, {'synced_at': 123});
    }
    await db.insert('learning_sync_state', {
      'uid': 'local',
      'collection_name': 'synthetic-history',
      'last_pull_ms': 100,
    });
  }
}

/// The competing writer uses the same real disk database, outside the capture
/// transaction. It is queued after its first data read, not emulated in memory.
class _SnapshotDatabase implements Database {
  _SnapshotDatabase(this.inner);
  final Database inner;
  Future<void>? queuedWrite;

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      inner.transaction(
          (txn) => action(_SnapshotTransaction(txn, () {
                queuedWrite ??= inner.transaction((writer) async {
                  await writer
                      .update('learning_progress', {'attempt_count': 99});
                  await writer
                      .update('review_sessions', {'completed_count': 17});
                });
              })),
          exclusive: exclusive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SnapshotTransaction implements Transaction {
  _SnapshotTransaction(this.inner, this.onRead);
  final Transaction inner;
  final void Function() onRead;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final rows = await inner.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    if (table == 'learning_progress' && columns!.contains('target_id')) {
      onRead();
    }
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
