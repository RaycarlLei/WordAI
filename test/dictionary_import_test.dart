import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/dictionary_import.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/wordai_dossier.dart';

Stream<List<int>> encoded(Object? value) =>
    Stream.value(utf8.encode(jsonEncode(value)));

void main() {
  sqfliteFfiInit();
  late Database db;
  late LearningRepository repository;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await LearningRepository.createSchema(db);
    repository = LearningRepository.forTesting(db);
  });
  tearDown(() => db.close());

  test('single S6 object and arrays import through the same validated path',
      () async {
    final samples = sampleWords();
    expect(
        await importDictionary(encoded(samples.first.toJson()),
            repository: repository, uid: 'local'),
        1);
    expect(
        await importDictionary(
            encoded(
                samples.skip(1).take(2).map((word) => word.toJson()).toList()),
            repository: repository,
            uid: 'local'),
        2);
    expect(
        await repository.registeredQueries('local'), {'cat', 'river', 'book'});
  });

  test('the whole file validates before the first database write', () async {
    final sample = sampleWords().first.toJson();
    for (final input in <Object?>[
      [],
      null,
      7,
      {},
      [true],
      [sample, {}],
      [
        sample,
        {...sample, 'schema_version': 'unsupported'}
      ],
      [
        sample,
        {...sample, 'senses': []}
      ],
      [
        sample,
        {...sample, 'query': ''}
      ],
      [
        sample,
        {...sample, 'query': 'cat\n'}
      ],
      [
        sample,
        {...sample, 'query': 'c' * 121}
      ],
    ]) {
      final completed = <int>[];
      await expectLater(
          importDictionary(encoded(input),
              repository: repository, uid: 'local', onImported: completed.add),
          throwsA(isA<DictionaryImportException>()));
      expect(completed, isEmpty);
      expect(await db.query('learning_progress'), isEmpty);
    }
  });

  test(
      'empty text, malformed JSON and invalid UTF-8 are rejected without writes',
      () async {
    for (final bytes in <List<int>>[
      [],
      utf8.encode('['),
      [0xff, 0xfe]
    ]) {
      await expectLater(
          importDictionary(Stream.value(bytes),
              repository: repository, uid: 'local'),
          throwsA(isA<DictionaryImportException>()));
      expect(await db.query('learning_progress'), isEmpty);
    }
  });

  test('valid lookup abstentions cannot be counted as imported words',
      () async {
    const abstention = WordAiDossier(
        status: 'invalid',
        query: 'unrecognized',
        direction: WordAiQueryDirection.englishToChinese,
        suggestion: '',
        headword: WordAiHeadword.empty,
        senses: [],
        lexical: WordAiLexicalInfo.empty,
        analysis: []);
    expect(
        WordAiDossier.fromJson(abstention.toJson(),
                expectedQuery: abstention.query)
            .isOk,
        isFalse);
    await expectLater(
        importDictionary(encoded(abstention.toJson()),
            repository: repository, uid: 'local'),
        throwsA(isA<DictionaryImportException>()));
    expect(await db.query('learning_progress'), isEmpty);
  });

  test('entry count is checked before decoding individual S6 objects',
      () async {
    await expectLater(
        readDictionary(encoded(List.filled(maxDictionaryEntries + 1, {}))),
        throwsA(isA<DictionaryImportException>()
            .having((error) => error.message, 'message', contains('20,000'))));
  });

  test('actual stream size is bounded and an oversized source is cancelled',
      () async {
    var cancelled = false;
    var reachedTail = false;
    Stream<List<int>> source() async* {
      try {
        yield Uint8List(maxDictionaryBytes);
        yield [32];
        reachedTail = true;
        throw StateError('must not keep reading');
      } finally {
        cancelled = true;
      }
    }

    await expectLater(
        importDictionary(source(), repository: repository, uid: 'local'),
        throwsA(isA<DictionaryImportException>()
            .having((error) => error.message, 'message', contains('10 MB'))));
    expect(cancelled, isTrue);
    expect(reachedTail, isFalse);
    expect(await db.query('learning_progress'), isEmpty);
  });

  test('a valid UTF-8 file exactly at the byte limit is accepted', () async {
    final sample = utf8.encode(jsonEncode(sampleWords().first.toJson()));
    final padding = Uint8List(maxDictionaryBytes - sample.length)
      ..fillRange(0, maxDictionaryBytes - sample.length, 32);
    final entries =
        await readDictionary(Stream.fromIterable([sample, padding]));
    expect(entries.single.query, 'cat');
  });

  test('a source read failure cannot leave a validated prefix imported',
      () async {
    Stream<List<int>> source() async* {
      yield utf8.encode(jsonEncode(sampleWords().first.toJson()));
      throw StateError('synthetic read failure');
    }

    await expectLater(
        importDictionary(source(), repository: repository, uid: 'local'),
        throwsStateError);
    expect(await db.query('learning_progress'), isEmpty);
  });

  test(
      'a storage failure reports only committed entries and retry preserves progress',
      () async {
    final samples = sampleWords().take(3).toList();
    await db.execute(
        "CREATE TRIGGER fail_second BEFORE INSERT ON learning_progress WHEN NEW.query = 'river' BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END");
    final completed = <int>[];
    final payload = samples.map((word) => word.toJson()).toList();
    await expectLater(
        importDictionary(encoded(payload),
            repository: repository, uid: 'local', onImported: completed.add),
        throwsA(isA<DatabaseException>()));
    expect(completed, [1]);
    expect(await repository.registeredQueries('local'), {'cat'});
    await db.update('learning_progress',
        {'stage': 1, 'attempt_count': 4, 'last_tested_at': 1234});
    await db.execute('DROP TRIGGER fail_second');
    expect(
        await importDictionary(encoded(payload),
            repository: repository, uid: 'local'),
        3);
    final cat = (await db
            .query('learning_progress', where: 'query = ?', whereArgs: ['cat']))
        .single;
    expect(cat['stage'], 1);
    expect(cat['attempt_count'], 4);
    expect(cat['last_tested_at'], 1234);
    expect(
        await repository.registeredQueries('local'), {'cat', 'river', 'book'});
  });

  test(
      'sample initialization only inserts missing meanings and never repairs existing rows',
      () async {
    final sample = sampleWords().first;
    expect(await repository.registerMissingDossier('local', sample), 1);
    await db.update('learning_progress', {
      'definition_en': 'my imported definition',
      'example_en': '',
      'stage': 1,
      'attempt_count': 7,
      'last_tested_at': 1234,
      'content_version': 'user-import',
      'updated_at': 5678,
    });
    final before = (await db.query('learning_progress')).single;
    expect(await repository.registerMissingDossier('local', sample), 0);
    expect((await db.query('learning_progress')).single, before);
    expect(await repository.registerMissingDossier('other', sample), 1);
    expect(
        await repository.registerMissingDossier('local', sampleWords()[1]), 1);
    final expanded = sample.toJson();
    final senses = expanded['senses'] as List;
    senses.add({...senses.first as Map<String, dynamic>, 'id': 'noun-2'});
    expect(
        await repository.registerMissingDossier('local',
            WordAiDossier.fromJson(expanded, expectedQuery: sample.query)),
        1);
    final original = (await db.query('learning_progress',
            where: 'target_id = ?', whereArgs: [before['target_id']]))
        .single;
    expect(original, before);
  });

  test(
      'concurrent initializers insert one copy without replacing imported content',
      () async {
    final sample = sampleWords().first;
    final added = await Future.wait(List.generate(
        4, (_) => repository.registerMissingDossier('local', sample)));
    expect(added.reduce((a, b) => a + b), 1);
    final edited = sample.toJson();
    (edited['senses'] as List).first['definition_en'] =
        'a domesticated feline kept as a companion';
    await importDictionary(encoded(edited),
        repository: repository, uid: 'local');
    await Future.wait(List.generate(
        4, (_) => repository.registerMissingDossier('local', sample)));
    final rows = await db.query('learning_progress');
    expect(rows, hasLength(1));
    expect(rows.single['definition_en'],
        'a domesticated feline kept as a companion');
  });
}
