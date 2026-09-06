import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/flutter_flow/internationalization.dart';
import 'package:word_a_i/pages/flash_cards/flash_cards_widget.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/wordai_dossier.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('correct answer stays minimal, then advances in 1s',
      (tester) async {
    late Database db;
    late LearningRepository repository;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LearningRepository.createSchema(db);
      repository = LearningRepository.forTesting(db);
      for (var index = 0; index < 4; index++) {
        await repository.registerDossier(
          'widget-user',
          _dossier('word$index', index),
        );
      }
    });
    addTearDown(db.close);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          FFLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: FlashCardsWidget(
          repository: repository,
          testUid: 'widget-user',
          initialWords: const ['word0', 'word1', 'word2', 'word3'],
        ),
      ),
    );
    for (var i = 0;
        i < 30 && find.text('Read it in context').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Read it in context'), findsOneWidget);
    expect(find.text('Not sure'), findsOneWidget);
    final session = (await tester.runAsync(
      () => repository.resumeActiveSession('widget-user'),
    ))!;
    final target = (await tester.runAsync(
      () => repository.targetById(session.targetIds.first),
    ))!;
    final nextTarget = (await tester.runAsync(
      () => repository.targetById(session.targetIds[1]),
    ))!;
    expect(target.stage, LearningStage.unlearned);

    await tester.tap(find.text(target.definitionEnglish));
    LearningStage? updatedStage;
    for (var i = 0; i < 20; i++) {
      updatedStage = await tester.runAsync(
        () async =>
            (await repository.targetById(target.targetId))?.stage ??
            LearningStage.unlearned,
      );
      if (updatedStage == LearningStage.contextPassed) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(updatedStage, LearningStage.contextPassed);
    final persisted = (await tester.runAsync(
      () => repository.resumeActiveSession('widget-user'),
    ))!;
    expect(persisted.completedCount, 1);
    for (var i = 0;
        i < 20 && find.byIcon(Icons.check_circle_rounded).evaluate().isEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text('Correct'), findsNothing);
    expect(find.text('Continue'), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(
      find.text(target.exampleEnglish, findRichText: true),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 900));
    expect(
      find.text(target.exampleEnglish, findRichText: true),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0;
        i < 20 &&
            find
                .text(nextTarget.exampleEnglish, findRichText: true)
                .evaluate()
                .isEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(
      find.text(nextTarget.exampleEnglish, findRichText: true),
      findsOneWidget,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('answer feedback keeps layout stable in ${brightness.name}',
        (tester) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late Database db;
      late _PausedAnswerLearningRepository repository;
      await tester.runAsync(() async {
        db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await LearningRepository.createSchema(db);
        repository = _PausedAnswerLearningRepository(db);
        for (var index = 0; index < 4; index++) {
          await repository.registerDossier(
            'feedback-user',
            _dossier('word$index', index),
          );
        }
      });
      addTearDown(db.close);

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        locale: const Locale('en'),
        localizationsDelegates: const [
          FFLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: FlashCardsWidget(
          repository: repository,
          testUid: 'feedback-user',
          initialWords: const [],
        ),
      ));
      for (var i = 0;
          i < 30 && find.text('Read it in context').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      final session = (await tester.runAsync(
        () => repository.resumeActiveSession('feedback-user'),
      ))!;
      final target = (await tester.runAsync(
        () => repository.targetById(session.targetIds.first),
      ))!;
      final sentence = find.text(target.exampleEnglish, findRichText: true);
      final option = find.text(target.definitionEnglish);
      final unsure = find.text('Not sure');
      final sentenceRect = tester.getRect(sentence);
      final optionRect = tester.getRect(option);
      final unsureRect = tester.getRect(unsure);

      void expectStableFeedback() {
        expect(tester.getRect(sentence), sentenceRect);
        expect(tester.getRect(option), optionRect);
        expect(tester.getRect(unsure), unsureRect);
        // Only the round progress bar belongs on this screen. A transient
        // indeterminate bar below the answers starts as a stray blue dot.
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      await tester.tap(option);
      await tester.pump();
      expectStableFeedback();
      await tester.pump(const Duration(milliseconds: 100));
      expectStableFeedback();
      await tester.tap(option);
      expect(repository.recordCalls, 1);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);

      repository.answerGate.complete();
      for (var i = 0;
          i < 30 && find.byIcon(Icons.check_circle_rounded).evaluate().isEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expectStableFeedback();
      await tester.pump(const Duration(milliseconds: 180));
      expectStableFeedback();
      expect(find.text('Continue'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('local review does not wait for cloud synchronization',
      (tester) async {
    late Database db;
    late Completer<void> syncGate;
    late LearningRepository repository;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LearningRepository.createSchema(db);
      syncGate = Completer<void>();
      repository = _PausedSyncLearningRepository(db, syncGate);
      for (var index = 0; index < 4; index++) {
        await repository.registerDossier(
          'loading-user',
          _dossier('local$index', index),
        );
      }
    });
    addTearDown(db.close);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          FFLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: FlashCardsWidget(
          repository: repository,
          testUid: 'loading-user',
          initialWords: const [],
        ),
      ),
    );
    for (var index = 0;
        index < 20 && find.text('Read it in context').evaluate().isEmpty;
        index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Read it in context'), findsOneWidget);
    expect(syncGate.isCompleted, isFalse);
    expect(
      find.text('Syncing progress across your devices…'),
      findsNothing,
    );
    syncGate.complete();
  });

  testWidgets('a full round shows animated celebration statistics',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Database db;
    late LearningRepository repository;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LearningRepository.createSchema(db);
      repository = LearningRepository.forTesting(db);
      for (var index = 0; index < 20; index++) {
        await repository.registerDossier(
          'celebration-user',
          _dossier('celebration$index', index),
        );
      }
    });
    addTearDown(db.close);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          FFLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: FlashCardsWidget(
          repository: repository,
          testUid: 'celebration-user',
          initialWords: const [],
        ),
      ),
    );

    for (var index = 0; index < 20; index++) {
      if (index > 0) {
        for (var attempt = 0;
            attempt < 30 &&
                find.byIcon(Icons.check_circle_rounded).evaluate().isNotEmpty;
            attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }
      for (var attempt = 0;
          attempt < 30 && find.text('Read it in context').evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final session = (await tester.runAsync(
        () => repository.resumeActiveSession('celebration-user'),
      ))!;
      final target = (await tester.runAsync(
        () => repository.targetById(session.targetIds[session.currentIndex]),
      ))!;
      await tester.tap(find.text(target.definitionEnglish));
      for (var attempt = 0;
          attempt < 30 &&
              find.byIcon(Icons.check_circle_rounded).evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      // The completion surface intentionally contains looping celebration
      // animation, so waiting for the entire tree to settle can never be a
      // reliable completion signal. Advance only the transition frame here.
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (var attempt = 0;
        attempt < 40 && find.text('Round complete').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Round complete'), findsOneWidget);
    expect(find.text('20 words moved forward'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Lifetime'), findsOneWidget);
    expect(find.text('Another round'), findsOneWidget);
  });
}

class _PausedAnswerLearningRepository extends LearningRepository {
  _PausedAnswerLearningRepository(super.database) : super.forTesting();

  final answerGate = Completer<void>();
  var recordCalls = 0;

  @override
  Future<ReviewAnswerResult> recordAnswer({
    required String uid,
    required ReviewSessionState session,
    required ReviewQuestion question,
    required int selectedIndex,
    required int latencyMs,
    required int activeMs,
  }) async {
    recordCalls++;
    await answerGate.future;
    return super.recordAnswer(
      uid: uid,
      session: session,
      question: question,
      selectedIndex: selectedIndex,
      latencyMs: latencyMs,
      activeMs: activeMs,
    );
  }
}

class _PausedSyncLearningRepository extends LearningRepository {
  _PausedSyncLearningRepository(super.database, this.syncGate)
      : super.forTesting();

  final Completer<void> syncGate;

  @override
  Future<void> syncFromCloud(String uid) => syncGate.future;
}

WordAiDossier _dossier(String word, int index) => WordAiDossier(
      status: 'ok',
      query: word,
      direction: WordAiQueryDirection.englishToChinese,
      suggestion: '',
      headword: WordAiHeadword(
        english: word,
        simplified: '词$index',
        traditional: '詞$index',
        ipaUs: '',
        ipaUk: '',
      ),
      senses: [
        WordAiSense(
          id: 'noun-1',
          partOfSpeech: 'noun',
          equivalentsEnglish: [word],
          definitionEnglish: 'definition $index',
          meaningsSimplified: ['释义$index'],
          meaningsTraditional: ['釋義$index'],
          labels: const [],
          examples: [
            WordAiExample(
              english: 'This sentence contains $word in context.',
              simplified: '这个句子包含词$index。',
              traditional: '這個句子包含詞$index。',
              targetForm: word,
              register: 'neutral',
            ),
          ],
          synonyms: const [],
          antonyms: const [],
          collocations: const [],
        ),
      ],
      lexical: WordAiLexicalInfo.empty,
      analysis: const [],
    );
