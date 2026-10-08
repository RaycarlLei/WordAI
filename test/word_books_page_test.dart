import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/main.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/word_book_repository.dart';

import 'fixtures/offline_http.dart';

Future<void> ready(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  for (var i = 0; i < 200; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Local operation did not finish');
}

void main() {
  sqfliteFfiInit();
  testWidgets(
      'offline create, add, rename, remove, restore and localized dark UI',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final captureFont = Platform.environment['WORD_AI_CAPTURE_FONT'];
    if (captureFont != null) {
      await tester.runAsync(() async {
        final font = FontLoader('Roboto')
          ..addFont(File(captureFont).readAsBytes().then(ByteData.sublistView));
        await font.load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
    }
    final previous = HttpOverrides.current;
    final offline = OfflineHttp();
    HttpOverrides.global = offline;
    addTearDown(() => expect(offline.attempts, 0));
    addTearDown(() => HttpOverrides.global = previous);
    tester.view.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    tester.view.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
        tester.view.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(
        tester.view.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = (await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      await LearningRepository.createSchema(db);
      return (db: db, repo: LearningRepository.forTesting(db));
    }))!;
    addTearDown(state.db.close);
    final captureKey = GlobalKey();
    Future<void> capture(String name) async {
      final directory = Platform.environment['WORD_AI_CAPTURE_DIR'];
      if (directory == null) return;
      final boundary = captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$directory/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pumpWidget(RepaintBoundary(
        key: captureKey, child: CommunityApp(homeRepository: state.repo)));
    await ready(tester);
    await tester.tap(find.text('Word books'));
    await ready(tester);
    await tester.tap(find.byTooltip('New word book'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Offline book');
    await tester.tap(find.text('Save'));
    await ready(tester);
    expect(find.text('Offline book'), findsOneWidget);
    await tester.tap(find.text('Add words'));
    await ready(tester);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'cat'));
    await tester.tap(find.text('Add'));
    await ready(tester);
    expect(find.text('cat'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Renamed');
    await tester.tap(find.text('Save'));
    await ready(tester);
    expect(find.text('Renamed'), findsOneWidget);
    await capture('wordbook-dark');
    await tester.tap(find.byTooltip('Remove word'));
    await ready(tester);
    expect(find.text('This book is empty.'), findsOneWidget);
    await tester.tap(find.byTooltip('Recently Deleted'));
    await ready(tester);
    await tester.tap(find.byTooltip('Restore'));
    await ready(tester);
    final saved =
        await tester.runAsync(() => WordBookRepository(state.repo).books());
    expect(saved!.singleWhere((b) => b.name == 'Renamed').words, ['cat']);
    await tester.tap(find.byTooltip('Back'));
    await ready(tester);
    await tester.tap(find.byTooltip('Language'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('繁體中文'));
    await ready(tester);
    await tester.tap(find.text('單字本'));
    await ready(tester);
    expect(find.text('預設單字本'), findsOneWidget);
    expect(find.text('已學會'), findsOneWidget);
    await capture('wordbooks-traditional-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
