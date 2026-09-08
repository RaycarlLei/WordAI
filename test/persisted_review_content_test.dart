import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/dictionary_import.dart';
import 'package:word_a_i/services/learning_distractor_source.dart';
import 'package:word_a_i/services/learning_repository.dart';

const _replacement = 'a domesticated feline companion with retractable claws';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('a failed scope read leaves a durable round resumable with its answers',
      () async {
    final disk = await _Disk.create();
    final session =
        (await disk.repo.createSession('local', queries: ['cat', 'river']))!;
    final question = (await disk.repo.buildQuestion(session, 'en'))!;
    await _answer(disk.repo, session, question);
    await disk.reopen();

    final fault = _FailOnceDatabase(disk.db, scopeRead: true);
    final retrying = LearningRepository.forTesting(fault);
    await expectLater(retrying.resumeScopedSession('local', ['cat', 'river']),
        throwsA(isA<_Busy>()));
    expect(fault.failures, 1);
    final row = (await disk.db.query('review_sessions')).single;
    expect(row['status'], 'active');
    expect(row['exit_reason'], isNull);
    expect(row['completed_count'], 1);

    await disk.reopen();
    final restored =
        (await disk.repo.resumeScopedSession('local', ['cat', 'river']))!;
    expect(restored.id, session.id);
    expect(restored.currentIndex, 1);
    expect(restored.completedCount, 1);
    await expectLater(_answer(disk.repo, session, question), throwsStateError);
    final next = (await disk.repo.buildQuestion(restored, 'en'))!;
    expect(next.target.targetId, session.targetIds[1]);
    await _answer(disk.repo, restored, next);
    await disk.reopen();
    expect((await disk.repo.sessionById(session.id)).completedCount, 2);
    expect(await disk.db.query('review_attempts'), hasLength(2));
  });

  test('a failed retirement write is not reclassified as an invalid payload',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    final fault = _FailOnceDatabase(disk.db, scopeRead: false);
    final retrying = LearningRepository.forTesting(fault);
    await expectLater(retrying.resumeScopedSession('local', ['river']),
        throwsA(isA<_Busy>()));
    expect(fault.retirementReasons, ['scope_changed']);
    await disk.reopen();
    expect((await disk.db.query('review_sessions')).single['status'], 'active');
    expect((await disk.repo.resumeScopedSession('local', ['cat']))!.id,
        session.id);
  });

  test('a proven corrupt session is retired and preparation can recover',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    await disk.db.update('review_sessions', {'target_ids_json': '[broken'},
        where: 'session_id = ?', whereArgs: [session.id]);
    await disk.reopen();
    final fresh = (await disk.repo.createSession('local', queries: ['cat']))!;
    expect(fresh.id, isNot(session.id));
    expect(await disk.repo.buildQuestion(fresh, 'en'), isNotNull);
    final retired = (await disk.db.query('review_sessions',
            where: 'session_id = ?', whereArgs: [session.id]))
        .single;
    expect(retired['exit_reason'], 'invalid_session');
    expect(retired['target_ids_json'], '[broken');
    expect(await disk.db.query('review_attempts'), isEmpty);
  });

  test('an imported definition cannot earn progress from the old saved answer',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    final old = (await disk.repo.buildQuestion(session, 'en'))!;
    await _importCat(disk.repo, definition: _replacement);
    await expectLater(_answer(disk.repo, session, old),
        throwsA(isA<ReviewQuestionChanged>()));
    await disk.reopen();
    final target = (await disk.repo.targetById(old.target.targetId))!;
    expect(target.definitionEnglish, _replacement);
    expect(target.stage, LearningStage.unlearned);
    expect(target.attemptCount, 0);
    expect(await disk.db.query('review_attempts'), isEmpty);
    final restored = (await disk.repo.resumeScopedSession('local', ['cat']))!;
    expect(restored.currentIndex, 0);
    final fresh = (await disk.repo.buildQuestion(restored, 'en'))!;
    expect(fresh.options[fresh.correctIndex], _replacement);
    await _answer(disk.repo, restored, fresh);
    await disk.reopen();
    expect((await disk.repo.targetById(old.target.targetId))!.stage,
        LearningStage.contextPassed);
    expect((await disk.repo.sessionById(session.id)).completedCount, 1);
    expect(await disk.db.query('review_attempts'), hasLength(1));
    await _importCat(disk.repo,
        definition: 'a tame feline that shares a home with people');
    await disk.reopen();
    // The position check remains first even if both stage and content changed
    // after commit. The UI recovers this acknowledgement from the saved index.
    await expectLater(
        _answer(disk.repo, restored, fresh),
        throwsA(isA<StateError>()
            .having((error) => error is ReviewQuestionChanged,
                'content conflict', isFalse)
            .having((error) => error.message, 'message',
                'This review answer was already handled.')));
    expect(await disk.db.query('review_attempts'), hasLength(1));
  });

  test(
      'reimport preserves earned progress while refreshing an independent test',
      () async {
    final disk = await _Disk.create();
    final first = (await disk.repo.createSession('local', queries: ['cat']))!;
    final context = (await disk.repo.buildQuestion(first, 'en'))!;
    await _answer(disk.repo, first, context);
    await disk.repo.finishSession(
        uid: 'local', sessionId: first.id, completed: true, activeMs: 10);
    final second = (await disk.repo.createSession('local', queries: ['cat']))!;
    final old = (await disk.repo.buildQuestion(second, 'en'))!;
    expect(old.type, ReviewTestType.independent);
    final before = (await disk.db.query('learning_progress',
            where: 'target_id = ?', whereArgs: [old.target.targetId]))
        .single;
    await _importCat(disk.repo, definition: _replacement);
    await expectLater(
        _answer(disk.repo, second, old), throwsA(isA<ReviewQuestionChanged>()));
    await disk.reopen();
    final preserved = (await disk.db.query('learning_progress',
            where: 'target_id = ?', whereArgs: [old.target.targetId]))
        .single;
    for (final column in [
      'stage',
      'attempt_count',
      'last_tested_at',
      'context_passed_at',
      'learned_at',
      'learned_once'
    ]) {
      expect(preserved[column], before[column], reason: column);
    }
    final restored = (await disk.repo.resumeScopedSession('local', ['cat']))!;
    final fresh = (await disk.repo.buildQuestion(restored, 'en'))!;
    // Independent questions display a word, not an example. This unused field
    // can change without replacing their already validated answer snapshot.
    await disk.db.update('learning_progress',
        {'example_en': 'A different example about the same cat.'},
        where: 'target_id = ?', whereArgs: [old.target.targetId]);
    await _answer(disk.repo, restored, fresh);
    await disk.reopen();
    expect((await disk.repo.targetById(old.target.targetId))!.stage,
        LearningStage.learned);
    expect(await disk.db.query('review_attempts'), hasLength(2));
  });

  test(
      'context prompt and highlighted form changes invalidate its saved answer',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    // Keep the correct meaning unchanged: matching option text is insufficient.
    for (final change in [
      {'example_en': 'A cat waited beside the door.'},
      {'target_form': 'A cat'},
      {'word': 'domestic cat'},
      {'part_of_speech': 'countable noun'},
    ]) {
      final old = (await disk.repo.buildQuestion(session, 'en'))!;
      await disk.db.update('learning_progress', change,
          where: 'target_id = ?', whereArgs: [old.target.targetId]);
      await expectLater(_answer(disk.repo, session, old),
          throwsA(isA<ReviewQuestionChanged>()),
          reason: change.keys.single);
      await disk.reopen();
      expect(await disk.repo.buildQuestion(session, 'en'), isNotNull);
    }
    expect((await disk.repo.sessionById(session.id)).currentIndex, 0);
    expect(await disk.db.query('review_attempts'), isEmpty);
  });

  test('frozen distractors and unused target translations remain stable',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    final question = (await disk.repo.buildQuestion(session, 'en'))!;
    // The saved choices are literal text, not live references to these rows.
    await disk.db.update(
        'learning_progress', {'definition_en': 'new pool text'},
        where: 'query != ?', whereArgs: ['cat']);
    await disk.db.update(
        'learning_progress',
        {
          'meaning_zh_hans': '家猫',
          'example_zh_hans': '一只家猫正在休息。',
          'content_version': 'an-unrelated-global-revision',
        },
        where: 'query = ?',
        whereArgs: ['cat']);
    await disk.reopen();
    final resumed = (await disk.repo.buildQuestion(session, 'en'))!;
    expect(resumed.options, question.options);
    expect(resumed.correctIndex, question.correctIndex);
    await _answer(disk.repo, session, question);
    expect(await disk.db.query('review_attempts'), hasLength(1));
  });

  test('a changed localized answer invalidates only that language snapshot',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    final english = (await disk.repo.buildQuestion(session, 'en'))!;
    final chinese = (await disk.repo.buildQuestion(session, 'zh_Hans'))!;
    await disk.db.update('learning_progress', {'meaning_zh_hans': '家猫'},
        where: 'query = ?', whereArgs: ['cat']);
    await expectLater(_answer(disk.repo, session, chinese),
        throwsA(isA<ReviewQuestionChanged>()));
    await disk.reopen();
    expect((await disk.repo.buildQuestion(session, 'en'))!.options,
        english.options);
    final refreshed = (await disk.repo.buildQuestion(session, 'zh_Hans'))!;
    expect(refreshed.options[refreshed.correctIndex], '家猫');
    await _answer(disk.repo, session, refreshed);
  });

  test('an import during distractor loading cannot insert an obsolete question',
      () async {
    final disk = await _Disk.create();
    final loading = Completer<void>();
    final release = Completer<List<ReviewMeaningCandidate>>();
    final repo = LearningRepository.forTesting(disk.db, meaningLoader: (
        {required languageCode, required seed, required limit}) {
      loading.complete();
      return release.future;
    });
    final session = (await repo.createSession('local', queries: ['cat']))!;
    final pending = repo.buildQuestion(session, 'en');
    final rejected =
        expectLater(pending, throwsA(isA<ReviewQuestionChanged>()));
    await loading.future;
    await _importCat(disk.repo, definition: _replacement);
    release.complete(const []);
    await rejected;
    expect(await disk.db.query('review_questions'), isEmpty);
    await disk.reopen();
    final restored = (await disk.repo.resumeScopedSession('local', ['cat']))!;
    expect(restored.currentIndex, 0);
    final fresh = (await disk.repo.buildQuestion(restored, 'en'))!;
    expect(fresh.options[fresh.correctIndex], _replacement);
    await _answer(disk.repo, restored, fresh);
  });

  test('version 3 disk snapshots are rebuilt without inventing legacy identity',
      () async {
    final disk = await _Disk.create();
    final first = (await disk.repo.createSession('local', queries: ['cat']))!;
    final context = (await disk.repo.buildQuestion(first, 'en'))!;
    await _answer(disk.repo, first, context);
    await disk.repo.finishSession(
        uid: 'local', sessionId: first.id, completed: true, activeMs: 10);
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    final old = (await disk.repo.buildQuestion(session, 'en'))!;
    expect(old.type, ReviewTestType.independent);
    // Recreate the actual v3 table shape and user_version before reopening it.
    await disk.db.execute(
        'ALTER TABLE review_questions DROP COLUMN content_fingerprint');
    await disk.db.setVersion(3);
    await _importCat(disk.repo, definition: _replacement);
    await disk.reopen();
    expect(await disk.db.getVersion(), 4);
    final legacy = (await disk.db.query('review_questions',
            where: 'session_id = ?', whereArgs: [session.id]))
        .single;
    expect(legacy['content_fingerprint'], isNull);
    await expectLater(_answer(disk.repo, session, old),
        throwsA(isA<ReviewQuestionChanged>()));
    final fresh = (await disk.repo.buildQuestion(session, 'en'))!;
    expect(fresh.options[fresh.correctIndex], _replacement);
    expect(
        (await disk.db.query('review_questions',
                where: 'session_id = ?', whereArgs: [session.id]))
            .single['content_fingerprint'],
        matches(RegExp(r'^[0-9a-f]{64}$')));
    expect((await disk.repo.targetById(old.target.targetId))!.attemptCount, 1);
    expect((await disk.repo.targetById(old.target.targetId))!.stage,
        LearningStage.contextPassed);
    expect((await disk.repo.resumeScopedSession('local', ['cat']))!.id,
        session.id);
    expect((await disk.repo.sessionById(session.id)).currentIndex, 0);
    expect(await disk.db.query('review_attempts'), hasLength(1));
    await disk.reopen();
    expect(
        (await disk.repo.buildQuestion(session, 'en'))!.options, fresh.options);
    await _answer(disk.repo, session, fresh);
  });

  test('an aborted attempt insert rolls back progress and retries after reopen',
      () async {
    final disk = await _Disk.create();
    final session = (await disk.repo.createSession('local', queries: ['cat']))!;
    final question = (await disk.repo.buildQuestion(session, 'en'))!;
    await disk.db.execute('''
      CREATE TRIGGER fail_attempt BEFORE INSERT ON review_attempts
      BEGIN SELECT RAISE(ABORT, 'injected attempt write failure'); END
    ''');
    await expectLater(_answer(disk.repo, session, question),
        throwsA(isA<DatabaseException>()));
    await disk.reopen();
    final untouched = (await disk.repo.targetById(question.target.targetId))!;
    expect(untouched.stage, LearningStage.unlearned);
    expect(untouched.attemptCount, 0);
    expect(untouched.lastTestedAt, isNull);
    expect((await disk.repo.sessionById(session.id)).currentIndex, 0);
    expect(await disk.db.query('review_attempts'), isEmpty);
    expect(await disk.db.query('review_questions'), hasLength(1));
    await disk.db.execute('DROP TRIGGER fail_attempt');
    await _answer(disk.repo, session, question);
    await disk.reopen();
    expect((await disk.repo.targetById(question.target.targetId))!.attemptCount,
        1);
    expect((await disk.repo.sessionById(session.id)).currentIndex, 1);
  });
}

Future<ReviewAnswerResult> _answer(LearningRepository repo,
        ReviewSessionState session, ReviewQuestion question) =>
    repo.recordAnswer(
        uid: 'local',
        session: session,
        question: question,
        selectedIndex: question.correctIndex,
        latencyMs: 10,
        activeMs: 10);

Future<void> _importCat(LearningRepository repo,
    {required String definition}) async {
  final replacement = sampleWords().first.toJson();
  (replacement['senses'] as List).first['definition_en'] = definition;
  await importDictionary(Stream.value(utf8.encode(jsonEncode(replacement))),
      repository: repo, uid: 'local');
}

class _Disk {
  _Disk(this.directory, this.canonicalDirectory, this.path, this.db);
  final Directory directory;
  final String canonicalDirectory;
  final String path;
  Database db;
  LearningRepository get repo => LearningRepository.forTesting(db);

  static Future<_Disk> create() async {
    final directory = await Directory.systemTemp.createTemp('wordai-review-');
    final canonical = await directory.resolveSymbolicLinks();
    final path = p.join(canonical, 'learning.db');
    final disk = _Disk(directory, canonical, path, await _open(path));
    addTearDown(() async {
      if (disk.db.isOpen) await disk.db.close();
      // Only this freshly created fixture directory may be removed. Do not
      // follow a replaced symlink or operate on any existing application data.
      if (await directory.resolveSymbolicLinks() != canonical ||
          !p.isWithin(canonical, path)) {
        throw StateError('The fixture directory identity changed');
      }
      await directory.delete(recursive: true);
    });
    for (final sample in sampleWords().take(4)) {
      await disk.repo.registerDossier('local', sample);
    }
    return disk;
  }

  static Future<Database> _open(String path) =>
      databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 4,
              singleInstance: false,
              onCreate: LearningRepository.createSchema,
              onUpgrade: LearningRepository.upgradeSchema,
              onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));

  Future<void> reopen() async {
    await db.close();
    db = await _open(path);
  }
}

/// Injects one operational failure while all successful reads/writes still use
/// the real file-backed SQLite database. No payload is altered by this proxy.
class _FailOnceDatabase implements Database {
  _FailOnceDatabase(this.inner, {required this.scopeRead});
  final Database inner;
  final bool scopeRead;
  int failures = 0;
  final retirementReasons = <String>[];

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
  }) {
    if (scopeRead &&
        failures == 0 &&
        table == 'learning_progress' &&
        columns?.join(',') == 'target_id,query') {
      failures++;
      return Future.error(_Busy());
    }
    return inner.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    if (table == 'review_sessions') {
      retirementReasons.add(values['exit_reason'] as String);
      if (!scopeRead && failures == 0) {
        failures++;
        return Future.error(_Busy());
      }
    }
    return inner.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Busy extends DatabaseException {
  _Busy() : super('database is locked: one-shot test fault');
  @override
  int getResultCode() => 5;
  @override
  Object? get result => null;
}
