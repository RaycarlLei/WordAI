import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/pages/flash_cards/flash_cards_widget.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/review_pronunciation.dart';
import 'package:word_a_i/services/wordai_dossier.dart';

import 'fixtures/review_dossier.dart';
import 'review_loading_widget_test.dart' show app, delegates;

Future<void> waitForReview(WidgetTester tester) async {
  for (var index = 0; index < 100; index++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('Read it in context').evaluate().isNotEmpty ||
        find.text('Retry').evaluate().isNotEmpty ||
        find.text('Done').evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
  }
}

void main() {
  sqfliteFfiInit();

  Future<({Database db, LearningRepository repository})> prepare(
      WidgetTester tester, int count) async {
    final result = (await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      await LearningRepository.createSchema(db);
      final repository = LearningRepository.forTesting(db);
      for (var index = 0; index < count; index++) {
        await repository.registerDossier(
            'u', reviewDossier('word$index', index));
      }
      return (db: db, repository: repository);
    }))!;
    addTearDown(result.db.close);
    return result;
  }

  testWidgets(
      'a remaining target without choices never claims learning is done',
      (tester) async {
    final state = await prepare(tester, 1);
    await tester.pumpWidget(app(FlashCardsWidget(
      repository: state.repository,
      testUid: 'u',
      initialWords: const ['word0'],
      dossierLoader: (_, __) => const Stream<WordAiDossierUpdate>.empty(),
    )));
    await waitForReview(tester);
    expect(find.text('A few entries still need preparing'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Nothing to review'), findsNothing);
    expect(find.text('Done'), findsNothing);
    expect(
        await tester.runAsync(() => state.repository.reviewableWordCount('u')),
        1);
    expect(
        await tester.runAsync(() => state.repository.careerLearnedCount('u')),
        0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pronounces each visible question once and stops on leaving',
      (tester) async {
    final state = await prepare(tester, 4);
    final spoken = <String>[];
    var stops = 0;
    final pronunciation = ReviewPronunciation(
      play: (word) async {
        spoken.add(word);
      },
      stop: () async {
        stops++;
      },
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.detached));
    await tester.pumpWidget(app(FlashCardsWidget(
      repository: state.repository,
      testUid: 'u',
      initialWords: const [],
      pronunciation: pronunciation,
    )));
    await waitForReview(tester);
    final session = (await tester
        .runAsync(() => state.repository.resumeActiveSession('u')))!;
    final first = (await tester
        .runAsync(() => state.repository.targetById(session.targetIds.first)))!;
    expect(spoken, [first.word]);
    await tester.pumpAndSettle();
    expect(spoken, hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(spoken, hasLength(1));
    await tester.tap(find.text('Not sure'));
    for (var i = 0; i < 100 && find.text('Continue').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(spoken, hasLength(1));
    await tester.ensureVisible(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    for (var i = 0; i < 100 && spoken.length < 2; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    final second = (await tester
        .runAsync(() => state.repository.targetById(session.targetIds[1])))!;
    expect(spoken, [first.word, second.word]);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(stops, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing uncached words remain retryable while offline',
      (tester) async {
    final state = await prepare(tester, 0);
    await tester.pumpWidget(app(FlashCardsWidget(
      repository: state.repository,
      testUid: 'u',
      initialWords: const ['uncached'],
      dossierLoader: (_, __) => const Stream<WordAiDossierUpdate>.empty(),
    )));
    await waitForReview(tester);
    expect(find.text('A few entries still need preparing'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('have learned the meanings'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('learned recorded words can report completion accurately',
      (tester) async {
    final state = await prepare(tester, 1);
    await tester
        .runAsync(() => state.db.update('learning_progress', {'stage': 2}));
    await tester.pumpWidget(app(FlashCardsWidget(
      repository: state.repository,
      testUid: 'u',
      initialWords: const ['word0'],
      dossierLoader: (_, __) => throw StateError('no lookup needed'),
    )));
    await waitForReview(tester);
    expect(find.textContaining('have learned the meanings'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a retired saved round cannot hide remaining available words',
      (tester) async {
    final state = await prepare(tester, 1);
    await tester.runAsync(() async {
      await state.repository.createSession('u');
      await state.db.update('learning_progress', {'stage': 2});
      for (var index = 1; index <= 4; index++) {
        await state.repository
            .registerDossier('u', reviewDossier('word$index', index));
      }
    });
    await tester.pumpWidget(app(FlashCardsWidget(
      repository: state.repository,
      testUid: 'u',
      initialWords: const ['word0', 'word1', 'word2', 'word3', 'word4'],
      dossierLoader: (_, __) => const Stream<WordAiDossierUpdate>.empty(),
    )));
    await waitForReview(tester);
    expect(find.text('Read it in context'), findsOneWidget);
    expect(find.text('Nothing to review'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single unlearned word uses learned words as choices offline',
      (tester) async {
    final state = await prepare(tester, 4);
    await tester.runAsync(() => state.db.update(
        'learning_progress', {'stage': 2},
        where: 'query != ?', whereArgs: ['word0']));
    await tester.pumpWidget(app(FlashCardsWidget(
      repository: state.repository,
      testUid: 'u',
      initialWords: const ['word0'],
      dossierLoader: (_, cloud) {
        expect(cloud, isFalse);
        return const Stream<WordAiDossierUpdate>.empty();
      },
    )));
    await waitForReview(tester);
    expect(find.text('Read it in context'), findsOneWidget);
    expect(find.text('Nothing to review'), findsNothing);
    expect(
        await tester.runAsync(() => state.repository.reviewableWordCount('u')),
        1);
  });

  testWidgets('an account switch invalidates the old review before answering',
      (tester) async {
    final state = await prepare(tester, 4);
    var activeUid = 'u';
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
              body: TextButton(
                  onPressed: () => context.push('/review'),
                  child: const Text('Start')))),
      GoRoute(
          path: '/review',
          builder: (_, __) => FlashCardsWidget(
              repository: state.repository,
              testUid: 'u',
              activeUid: () => activeUid,
              initialWords: const [],
              dossierLoader: (_, __) =>
                  const Stream<WordAiDossierUpdate>.empty())),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        locale: const Locale('en'),
        localizationsDelegates: delegates,
        supportedLocales: const [Locale('en')]));
    await tester.tap(find.text('Start'));
    await tester.pump();
    await waitForReview(tester);
    expect(find.text('Read it in context'), findsOneWidget);
    activeUid = 'another-account';
    await tester.tap(find.text('Not sure'));
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    expect(await tester.runAsync(() => state.db.query('review_attempts')),
        isEmpty);
    expect(
        await tester
            .runAsync(() => state.repository.registeredQueries(activeUid)),
        isEmpty);
  });

  testWidgets('long cached meanings remain usable on a small large-text screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await prepare(tester, 4);
    const descriptions = [
      'An extended explanation of an everyday action, describing how a person '
          'carefully completes a task and understands the result in context.',
      'A scientific account of a natural process involving changes in matter, '
          'the transfer of energy, and observations recorded over time.',
      'A social arrangement in which different communities exchange ideas, '
          'share responsibilities, and agree on practical rules for cooperation.',
      'An artistic technique for combining visual patterns, contrasting colors, '
          'and repeated shapes to express a feeling or represent an experience.',
    ];
    await tester.runAsync(() async {
      for (var index = 0; index < descriptions.length; index++) {
        await state.db.update('learning_progress',
            {'definition_en': descriptions[index], 'stage': index == 0 ? 0 : 2},
            where: 'query = ?', whereArgs: ['word$index']);
      }
    });
    await tester.pumpWidget(app(MediaQuery(
      data: const MediaQueryData(
          size: Size(320, 568), textScaler: TextScaler.linear(1.8)),
      child: FlashCardsWidget(
        repository: state.repository,
        testUid: 'u',
        initialWords: const ['word0'],
        dossierLoader: (_, __) => const Stream<WordAiDossierUpdate>.empty(),
      ),
    )));
    await waitForReview(tester);
    expect(find.text('Read it in context'), findsOneWidget);
    for (final description in descriptions) {
      expect(find.text(description), findsOneWidget);
      await tester.ensureVisible(find.text(description));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    final session = (await tester
        .runAsync(() => state.repository.resumeActiveSession('u')))!;
    expect(session.currentIndex, 0);
    expect(session.completedCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an acknowledged-late answer resumes its committed position',
      (tester) async {
    final state = await prepare(tester, 4);
    final repository = _LostAcknowledgementRepository(state.db);
    await tester.pumpWidget(app(FlashCardsWidget(
        repository: repository,
        testUid: 'u',
        initialWords: const [],
        dossierLoader: (_, __) => const Stream<WordAiDossierUpdate>.empty())));
    await waitForReview(tester);
    final original =
        (await tester.runAsync(() => repository.resumeActiveSession('u')))!;
    final nextQuestion = find.byKey(ValueKey(original.targetIds[1]));
    await tester.tap(find.text('Not sure'));
    for (var index = 0;
        index < 200 && nextQuestion.evaluate().isEmpty;
        index++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    // The outgoing question remains mounted during AnimatedSwitcher. Once
    // the new target appears, settle that transition before checking the
    // stable interface or disposing the page.
    await tester.pumpAndSettle();
    expect(nextQuestion, findsOneWidget);
    final restored =
        (await tester.runAsync(() => repository.resumeActiveSession('u')))!;
    expect(restored.id, original.id);
    expect(restored.currentIndex, 1);
    expect(restored.completedCount, 1);
    expect(await tester.runAsync(() => state.db.query('review_attempts')),
        hasLength(1));
    expect(
        find.text('Progress was not saved. Please try again.'), findsNothing);
    expect(find.text('Read it in context'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _LostAcknowledgementRepository extends LearningRepository {
  _LostAcknowledgementRepository(super.database) : super.forTesting();

  @override
  Future<ReviewAnswerResult> recordAnswer({
    required String uid,
    required ReviewSessionState session,
    required ReviewQuestion question,
    required int selectedIndex,
    required int latencyMs,
    required int activeMs,
  }) async {
    await super.recordAnswer(
        uid: uid,
        session: session,
        question: question,
        selectedIndex: selectedIndex,
        latencyMs: latencyMs,
        activeMs: activeMs);
    throw StateError(
        'The local write committed before acknowledgement failed.');
  }
}
