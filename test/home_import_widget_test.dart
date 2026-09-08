import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/main.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/learning_repository.dart';

Future<void> waitForHome(WidgetTester tester) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Home did not finish its database operation');
}

class _FailingRefreshRepository extends LearningRepository {
  _FailingRefreshRepository(super.database) : super.forTesting();
  bool failRefresh = false;

  @override
  Future<Set<String>> registeredQueries(String uid) {
    if (failRefresh) throw StateError('synthetic refresh read failure');
    return super.registeredQueries(uid);
  }
}

Future<({Database db, _FailingRefreshRepository repository})>
    prepareRefreshTest(WidgetTester tester) async {
  final state = (await tester.runAsync(() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await LearningRepository.createSchema(db);
    return (db: db, repository: _FailingRefreshRepository(db));
  }))!;
  addTearDown(state.db.close);
  return state;
}

void main() {
  sqfliteFfiInit();

  testWidgets(
      'importing a sample word survives automatic refresh and a later reload',
      (tester) async {
    final state = (await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      await LearningRepository.createSchema(db);
      return (db: db, repository: LearningRepository.forTesting(db));
    }))!;
    addTearDown(state.db.close);
    final edited = sampleWords().first.toJson();
    const definition = 'a domesticated feline kept as a companion';
    (edited['senses'] as List).first['definition_en'] = definition;
    await tester.pumpWidget(CommunityApp(
      homeRepository: state.repository,
      selectDictionary: () async => XFile.fromData(
          Uint8List.fromList(utf8.encode(jsonEncode(edited))),
          name: 'cat.json'),
    ));
    await waitForHome(tester);
    await tester.runAsync(() => state.db.update('learning_progress',
        {'stage': 1, 'attempt_count': 4, 'last_tested_at': 1234},
        where: 'query = ?', whereArgs: ['cat']));

    await tester.tap(find.text('Import dictionary'));
    await waitForHome(tester);
    expect(find.text('Imported 1 entry.'), findsOneWidget);
    Future<void> expectImportRetained() async {
      final cat = (await tester.runAsync(() async => (await state.db.query(
              'learning_progress',
              where: 'query = ?',
              whereArgs: ['cat']))
          .single))!;
      expect(cat['definition_en'], definition);
      expect(cat['stage'], 1);
      expect(cat['attempt_count'], 4);
      expect(cat['last_tested_at'], 1234);
    }

    await expectImportRetained();
    await tester.tap(find.byTooltip('Retry'));
    await waitForHome(tester);
    await expectImportRetained();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a mixed invalid file reports zero imported entries and retains existing content',
      (tester) async {
    final state = (await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      await LearningRepository.createSchema(db);
      return (db: db, repository: LearningRepository.forTesting(db));
    }))!;
    addTearDown(state.db.close);
    final edited = sampleWords().first.toJson();
    (edited['senses'] as List).first['definition_en'] =
        'this edit must never be written';
    await tester.pumpWidget(CommunityApp(
      homeRepository: state.repository,
      selectDictionary: () async => XFile.fromData(
          Uint8List.fromList(utf8.encode(jsonEncode([edited, {}]))),
          name: 'mixed.json'),
    ));
    await waitForHome(tester);
    final before = await tester.runAsync(
        () => state.db.query('learning_progress', orderBy: 'target_id'));
    await tester.tap(find.text('Import dictionary'));
    await waitForHome(tester);
    expect(
        find.text('Entry 2 is not a valid S6 word. No entries were imported.'),
        findsOneWidget);
    expect(
        await tester.runAsync(
            () => state.db.query('learning_progress', orderBy: 'target_id')),
        before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Retry clears a previous refresh error after storage recovers',
      (tester) async {
    final state = await prepareRefreshTest(tester);
    state.repository.failRefresh = true;
    await tester.pumpWidget(CommunityApp(homeRepository: state.repository));
    await waitForHome(tester);
    expect(find.text('Local storage is unavailable. Please retry.'),
        findsOneWidget);

    state.repository.failRefresh = false;
    await tester.tap(find.byTooltip('Retry'));
    await waitForHome(tester);
    expect(
        find.text('Local storage is unavailable. Please retry.'), findsNothing);
    expect(find.text('12 words · 12 left to learn'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a committed import remains visible when its refresh fails',
      (tester) async {
    final state = await prepareRefreshTest(tester);
    final edited = sampleWords().first.toJson();
    const definition = 'a domesticated feline kept as a companion';
    (edited['senses'] as List).first['definition_en'] = definition;
    await tester.pumpWidget(CommunityApp(
      homeRepository: state.repository,
      selectDictionary: () async {
        state.repository.failRefresh = true;
        return XFile.fromData(
            Uint8List.fromList(utf8.encode(jsonEncode(edited))),
            name: 'cat.json');
      },
    ));
    await waitForHome(tester);
    await tester.tap(find.text('Import dictionary'));
    await waitForHome(tester);
    expect(find.text('Imported 1 entry.'), findsOneWidget);
    expect(find.text('Local storage is unavailable. Please retry.'),
        findsOneWidget);
    final cat = (await tester.runAsync(() async => (await state.db
            .query('learning_progress', where: 'query = ?', whereArgs: ['cat']))
        .single))!;
    expect(cat['definition_en'], definition);

    state.repository.failRefresh = false;
    await tester.tap(find.byTooltip('Retry'));
    await waitForHome(tester);
    expect(find.text('Imported 1 entry.'), findsOneWidget);
    expect(
        find.text('Local storage is unavailable. Please retry.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a partial import keeps its committed count when refresh also fails',
      (tester) async {
    final state = await prepareRefreshTest(tester);
    final entries = sampleWords().take(2).map((word) => word.toJson()).toList();
    (entries[0]['senses'] as List).first['definition_en'] =
        'a domesticated feline kept as a companion';
    (entries[1]['senses'] as List).first['definition_en'] =
        'a flowing body of fresh water';
    await tester.pumpWidget(CommunityApp(
      homeRepository: state.repository,
      selectDictionary: () async {
        state.repository.failRefresh = true;
        return XFile.fromData(
            Uint8List.fromList(utf8.encode(jsonEncode(entries))),
            name: 'two-words.json');
      },
    ));
    await waitForHome(tester);
    await tester.runAsync(() => state.db.execute(
        "CREATE TRIGGER fail_river BEFORE UPDATE ON learning_progress WHEN NEW.query = 'river' BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END"));
    await tester.tap(find.text('Import dictionary'));
    await waitForHome(tester);
    expect(
        find.textContaining('Import stopped after 1 entry.'), findsOneWidget);
    expect(find.text('Local storage is unavailable. Please retry.'),
        findsOneWidget);
    final rows = (await tester.runAsync(() => state.db.query(
        'learning_progress',
        where: 'query IN (?, ?)',
        whereArgs: ['cat', 'river'],
        orderBy: 'query')))!;
    expect(
        rows[0]['definition_en'], 'a domesticated feline kept as a companion');
    expect(rows[1]['definition_en'],
        sampleWords()[1].senses.single.definitionEnglish);

    state.repository.failRefresh = false;
    await tester.tap(find.byTooltip('Retry'));
    await waitForHome(tester);
    expect(
        find.textContaining('Import stopped after 1 entry.'), findsOneWidget);
    expect(
        find.text('Local storage is unavailable. Please retry.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
