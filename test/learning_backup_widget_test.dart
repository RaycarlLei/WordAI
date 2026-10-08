import 'dart:io';
import 'fixtures/offline_http.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/main.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/backup_files.dart';
import 'package:word_a_i/services/learning_backup.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/widgets/learning_backup_dialog.dart';

class _Files implements BackupFiles {
  @override
  bool get canSave => true;
  XFile? selected;
  Uint8List? saved;
  Future<bool> Function()? onSave;
  Future<XFile?> Function()? onSelect;

  @override
  Future<XFile?> select() async =>
      onSelect == null ? selected : await onSelect!();

  @override
  Future<bool> save(Uint8List bytes, {required String suggestedName}) async {
    saved = Uint8List.fromList(bytes);
    return await onSave?.call() ?? true;
  }
}

class _HeldCapture extends LearningBackupService {
  _HeldCapture(super.repository);
  final completion = Completer<LearningBackup>();
  @override
  Future<LearningBackup> capture() => completion.future;
}

class _ObservedFile extends XFile {
  _ObservedFile() : super('synthetic-unused-path');
  bool opened = false;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    opened = true;
    return const Stream.empty();
  }
}

Future<void> _idle(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('The backup operation did not finish.');
}

Future<({Database db, LearningRepository repository, _Files files})> _setup(
    WidgetTester tester) async {
  final db = (await tester.runAsync(() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await LearningRepository.createSchema(db);
    return db;
  }))!;
  addTearDown(db.close);
  return (
    db: db,
    repository: LearningRepository.forTesting(db),
    files: _Files()
  );
}

Future<void> _dialog(
    WidgetTester tester, LearningRepository repository, _Files files,
    {bool largeText = false,
    bool dark = false,
    LearningBackupService? service}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(
          textScaler: TextScaler.linear(largeText ? 2 : 1),
          disableAnimations: true),
      child: Scaffold(
          body: LearningBackupDialog(
              service: service ?? LearningBackupService(repository),
              files: files)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  late OfflineHttp offline;
  HttpOverrides? previousNetwork;
  setUp(() {
    previousNetwork = HttpOverrides.current;
    offline = OfflineHttp();
    HttpOverrides.global = offline;
  });
  tearDown(() {
    HttpOverrides.global = previousNetwork;
    expect(offline.attempts, 0,
        reason: 'Local import and backup must not contact a service');
  });
  sqfliteFfiInit();

  testWidgets(
      'disposing during capture does not open a late system save picker',
      (tester) async {
    final state = await _setup(tester);
    final backup = (await tester.runAsync(() async {
      await state.repository.registerDossier('local', sampleWords().first);
      return LearningBackupService(state.repository).capture();
    }))!;
    final held = _HeldCapture(state.repository);
    await _dialog(tester, state.repository, state.files, service: held);
    await tester.tap(find.text('Save backup'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    held.completion.complete(backup);
    await tester.pump();
    expect(state.files.saved, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing during selection does not read a late selected file',
      (tester) async {
    final state = await _setup(tester);
    final selection = Completer<XFile?>();
    state.files.onSelect = () => selection.future;
    final file = _ObservedFile();
    await _dialog(tester, state.repository, state.files);
    await tester.tap(find.text('Restore from file'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    selection.complete(file);
    await tester.pump();
    expect(file.opened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'save only reports success after completion and blocks overlapping actions',
      (tester) async {
    final state = await _setup(tester);
    await tester.runAsync(
        () => state.repository.registerDossier('local', sampleWords().first));
    final completion = Completer<bool>();
    state.files.onSave = () => completion.future;
    await _dialog(tester, state.repository, state.files);
    await tester.tap(find.text('Save backup'));
    for (var i = 0; i < 100 && state.files.saved == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(state.files.saved, isNotNull);
    expect(find.text('Backup saved.'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Restore from file'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNull);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    completion.complete(true);
    await _idle(tester);
    expect(find.text('Backup saved.'), findsOneWidget);
    final backup = await readLearningBackup(Stream.value(state.files.saved!));
    expect(backup.progressCount, 1);
  });

  testWidgets('cancel and write failure are distinct from successful save',
      (tester) async {
    final state = await _setup(tester);
    await tester.runAsync(
        () => state.repository.registerDossier('local', sampleWords().first));
    state.files.onSave = () async => false;
    await _dialog(tester, state.repository, state.files);
    await tester.tap(find.text('Save backup'));
    await _idle(tester);
    expect(find.text('Save cancelled.'), findsOneWidget);
    expect(find.text('Backup saved.'), findsNothing);
    state.files.onSave =
        () async => throw StateError('synthetic-private-provider-uri');
    await tester.tap(find.text('Save backup'));
    await _idle(tester);
    expect(find.textContaining('A partial file may remain'), findsOneWidget);
    expect(find.textContaining('synthetic-private-provider-uri'), findsNothing);
    expect(find.text('Backup saved.'), findsNothing);
  });

  testWidgets(
      'restore previews without writing and replaces only after explicit confirmation',
      (tester) async {
    final state = await _setup(tester);
    final backup = (await tester.runAsync(() async {
      await state.repository.registerDossier('local', sampleWords().first);
      final backup = await LearningBackupService(state.repository).capture();
      await state.repository.registerDossier('local', sampleWords()[1]);
      return backup;
    }))!;
    state.files.selected =
        XFile.fromData(backup.toBytes(), name: 'backup.json');
    await tester.pumpWidget(CommunityApp(
        homeRepository: state.repository, backupFiles: state.files));
    await _idle(tester);
    expect(find.text('2 words · 2 left to learn'), findsOneWidget);
    await tester.tap(find.text('Learning backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore from file'));
    // Home remains busy beneath the modal; wait for the preview itself.
    await tester.pumpAndSettle();
    expect(find.text('Review backup'), findsOneWidget);
    expect(find.text('1 meaning · 0 answers · 0 sessions'), findsOneWidget);
    expect(
        await tester
            .runAsync(() => state.repository.registeredQueries('local')),
        {'cat', 'river'});
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        await tester
            .runAsync(() => state.repository.registeredQueries('local')),
        {'cat', 'river'});
    await tester.tap(find.text('Restore from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace local learning data'));
    for (var i = 0;
        i < 200 &&
            find.textContaining('Learning data restored.').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.textContaining('Learning data restored.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await _idle(tester);
    expect(find.text('1 word · 1 left to learn'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    await _idle(tester);
    expect(
        await tester
            .runAsync(() => state.repository.registeredQueries('local')),
        {'cat'});
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(CommunityApp(
        homeRepository: state.repository, backupFiles: state.files));
    await _idle(tester);
    expect(find.text('1 word · 1 left to learn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid backup never offers replacement or exposes file content',
      (tester) async {
    final state = await _setup(tester);
    await tester.runAsync(
        () => state.repository.registerDossier('local', sampleWords().first));
    state.files.selected = XFile.fromData(
        Uint8List.fromList(utf8.encode('{"secret":"synthetic-private-text"')));
    await _dialog(tester, state.repository, state.files);
    await tester.tap(find.text('Restore from file'));
    await _idle(tester);
    expect(find.textContaining('Local data has not changed.'), findsOneWidget);
    expect(find.text('Replace local learning data'), findsNothing);
    expect(find.textContaining('synthetic-private-text'), findsNothing);
    expect(
        await tester
            .runAsync(() => state.repository.registeredQueries('local')),
        {'cat'});
  });

  testWidgets(
      'restore failure preserves data and keeps preview available to retry',
      (tester) async {
    final state = await _setup(tester);
    state.files.selected = (await tester.runAsync(() async {
      await state.repository.registerDossier('local', sampleWords().first);
      final backup = await LearningBackupService(state.repository).capture();
      await state.repository.registerDossier('local', sampleWords()[1]);
      await state.db.execute(
          "CREATE TRIGGER reject_restore BEFORE DELETE ON learning_progress BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
      return XFile.fromData(backup.toBytes());
    }))!;
    await _dialog(tester, state.repository, state.files);
    await tester.tap(find.text('Restore from file'));
    await _idle(tester);
    await tester.tap(find.text('Replace local learning data'));
    await _idle(tester);
    expect(
        find.text(
            'Restore could not be confirmed. Reopen the app and check your learning data before retrying.'),
        findsOneWidget);
    expect(find.text('Review backup'), findsOneWidget);
    expect(
        await tester
            .runAsync(() => state.repository.registeredQueries('local')),
        {'cat', 'river'});
  });

  testWidgets(
      'backup controls stay reachable at 200 percent text on a small dark screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await _setup(tester);
    state.files.selected = (await tester.runAsync(() async {
      await state.repository.registerDossier('local', sampleWords().first);
      return XFile.fromData(
          (await LearningBackupService(state.repository).capture()).toBytes());
    }))!;
    await _dialog(tester, state.repository, state.files,
        largeText: true, dark: true);
    await tester.ensureVisible(find.text('Restore from file'));
    await tester.tap(find.text('Restore from file'));
    await _idle(tester);
    expect(find.text('Review backup').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Replace local learning data'));
    expect(
        find.text('Replace local learning data').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
