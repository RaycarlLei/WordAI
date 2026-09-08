import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/wordai_dossier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
      'a failed second seed insert rolls back and a retry inserts every sample',
      () async {
    final disk = await _Disk.create();
    await disk.db.execute('''
      CREATE TRIGGER fail_second_seed BEFORE INSERT ON learning_progress
      WHEN NEW.uid = 'local' AND
        (SELECT COUNT(*) FROM learning_progress WHERE uid = 'local') = 1
      BEGIN SELECT RAISE(ABORT, 'synthetic second-insert failure'); END
    ''');
    final samples = sampleWords();
    await expectLater(disk.repo.seedEmptyProfile('local', samples),
        throwsA(isA<DatabaseException>()));
    await disk.reopen();
    expect(await disk.rows(), isEmpty);

    await disk.db.execute('DROP TRIGGER fail_second_seed');
    expect(await disk.repo.seedEmptyProfile('local', samples), 12);
    await disk.reopen();
    final rows = await disk.rows();
    expect(rows, hasLength(12));
    expect(rows.map((row) => row['query']).toSet(),
        samples.map((dossier) => dossier.query).toSet());
    expect(rows.every((row) => row['stage'] == 0 && row['attempt_count'] == 0),
        isTrue);
    expect(await disk.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('any existing progress blocks seeding even when no query is reviewable',
      () async {
    final disk = await _Disk.create();
    await disk.repo.registerDossier('local', sampleWords().first);
    await disk.db.update('learning_progress', {
      'definition_en': '',
      'meaning_zh_hans': '',
      'meaning_zh_hant': '',
      'example_en': '',
      'stage': 1,
      'learned_once': 1,
      'attempt_count': 42,
      'context_passed_at': 100,
      'learned_at': 90,
      'updated_at': 80,
    });
    expect(await disk.repo.registeredQueries('local'), isEmpty);
    final before = await disk.rows();
    expect(await disk.repo.seedEmptyProfile('local', sampleWords()), 0);
    await disk.reopen();
    expect(await disk.rows(), before);
  });

  test(
      'concurrent seed calls cannot combine two initial sets or overwrite them',
      () async {
    final disk = await _Disk.create();
    final samples = sampleWords();
    final first = samples.take(6).toList();
    final second = samples.skip(6).toList();
    // Separate repository callers share the real SQLite connection, as app
    // callers do. A check outside the transaction could admit both disjoint sets.
    final counts = await Future.wait([
      disk.repo.seedEmptyProfile('local', first),
      disk.repo.seedEmptyProfile('local', second),
    ]);
    expect(counts, unorderedEquals([6, 0]));
    await disk.reopen();
    final rows = await disk.rows();
    final winner = counts.first == 6 ? first : second;
    expect(rows.map((row) => row['query']).toSet(),
        winner.map((dossier) => dossier.query).toSet());
    expect(await disk.repo.seedEmptyProfile('local', samples), 0);
    expect(await disk.rows(), rows);
  });

  test('a different profile is preserved and does not block seeding this one',
      () async {
    final disk = await _Disk.create();
    await disk.repo.registerDossier('another-profile', sampleWords().first);
    final other = await disk.rows(uid: 'another-profile');
    expect(await disk.repo.seedEmptyProfile('local', sampleWords()), 12);
    await disk.reopen();
    expect(await disk.rows(uid: 'another-profile'), other);
    expect(await disk.rows(), hasLength(12));
  });

  test(
      'a seed list containing a content-free dossier is rejected before writes',
      () async {
    final disk = await _Disk.create();
    final valid = sampleWords().first;
    final empty = WordAiDossier(
      status: 'ok',
      query: valid.query,
      direction: valid.direction,
      suggestion: valid.suggestion,
      headword: valid.headword,
      senses: const [],
      lexical: valid.lexical,
      analysis: valid.analysis,
    );
    await expectLater(disk.repo.seedEmptyProfile('local', [valid, empty]),
        throwsArgumentError);
    await disk.reopen();
    expect(await disk.rows(), isEmpty);
    expect(await disk.repo.seedEmptyProfile('local', sampleWords()), 12);
  });
}

class _Disk {
  _Disk(this.directory, this.canonicalDirectory, this.path, this.db);
  final Directory directory;
  final String canonicalDirectory;
  final String path;
  Database db;
  LearningRepository get repo => LearningRepository.forTesting(db);

  static Future<_Disk> create() async {
    final directory = await Directory.systemTemp.createTemp('wordai-seed-');
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

  Future<List<Map<String, Object?>>> rows({String uid = 'local'}) =>
      db.query('learning_progress',
          where: 'uid = ?', whereArgs: [uid], orderBy: 'target_id');
}
