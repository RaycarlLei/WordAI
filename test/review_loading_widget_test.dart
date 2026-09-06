import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/flutter_flow/internationalization.dart';
import 'package:word_a_i/pages/flash_cards/flash_cards_widget.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/widgets/review_loading_view.dart';
import 'fixtures/review_dossier.dart';

const delegates = <LocalizationsDelegate<dynamic>>[
  FFLocalizationsDelegate(),
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate
];

Widget app(Widget child) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: delegates,
    supportedLocales: const [Locale('en')],
    home: child);

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  sqfliteFfiInit();

  testWidgets(
      'stalled preparation offers retry, ignores late run, and sync error is contained',
      (tester) async {
    late Database db;
    late _PendingRepository repo;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LearningRepository.createSchema(db);
      repo = _PendingRepository(db, failSync: true);
      for (var i = 0; i < 4; i++) {
        await repo.registerDossier('u', reviewDossier('word$i', i));
      }
    });
    addTearDown(db.close);
    await tester.pumpWidget(app(FlashCardsWidget(
        repository: repo,
        testUid: 'u',
        initialWords: const [],
        preparationBudget: const Duration(seconds: 2))));
    expect(find.byType(ReviewLoadingView), findsOneWidget);
    expect(find.text('Restoring learning progress…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Unable to prepare review'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Retry'));
    // SQLite FFI uses real asynchronous I/O. Wait for the visible result
    // instead of racing it against a fixed 100ms host-time sleep or advancing
    // the fake preparation deadline while the host is under load.
    for (var index = 0;
        index < 200 && find.text('Read it in context').evaluate().isEmpty;
        index++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Read it in context'), findsOneWidget);
    repo.gate.complete(null);
    await flush(tester);
    expect(find.text('Read it in context'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'close remains usable during loading and late completion cannot revive page',
      (tester) async {
    late Database db;
    late _PendingRepository repo;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LearningRepository.createSchema(db);
      repo = _PendingRepository(db);
    });
    addTearDown(db.close);
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
              repository: repo, testUid: 'u', initialWords: const [])),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        locale: const Locale('en'),
        localizationsDelegates: delegates,
        supportedLocales: const [Locale('en')]));
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ReviewLoadingView), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Start'), findsOneWidget);
    repo.gate.complete(null);
    await flush(tester);
    expect(find.byType(FlashCardsWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final label in ['Preparing your review…', '正在准备复习…', '正在準備複習…']) {
      testWidgets(
          'loading layout: dark=$dark / $label / small screen and large text',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: MediaQuery(
                data: const MediaQueryData(
                    size: Size(320, 568),
                    textScaler: TextScaler.linear(1.8),
                    disableAnimations: true),
                child: Scaffold(
                    body: SafeArea(
                        child: ReviewLoadingView(
                            text: label,
                            detail: '正在检查本地资源 · 12/80',
                            hint: '可随时退出，已完成的进度会保留。'))))));
        await tester.pump(const Duration(seconds: 2));
        expect(find.text(label), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.drag(find.byKey(const ValueKey('review-loading-scroll')),
            const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _PendingRepository extends LearningRepository {
  _PendingRepository(super.database, {this.failSync = false})
      : super.forTesting();
  final bool failSync;
  final gate = Completer<ReviewSessionState?>();
  int calls = 0;
  @override
  Future<ReviewSessionState?> resumeActiveSession(String uid) {
    if (calls++ == 0) return gate.future;
    return super.resumeActiveSession(uid);
  }

  @override
  Future<void> syncFromCloud(String uid) async {
    if (failSync) throw StateError('mock sync failure');
  }
}
