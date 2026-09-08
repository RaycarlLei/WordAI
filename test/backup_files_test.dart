import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_a_i/services/backup_files.dart';

const _channel = MethodChannel('org.wordai.community/backup_files');
const _name = 'wordai-backup-2026-09-08.json';
final _payload = Uint8List.fromList('{"format":"test"}'.codeUnits);

Matcher _failure(String code) => isA<BackupFileException>().having(
      (error) => error.code,
      'code',
      code,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform sends bounded bytes and distinguishes save from cancel',
        () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return calls.length == 1;
      });
      final files = PlatformBackupFiles(platform: platform);
      expect(files.canSave, isTrue);
      expect(await files.save(_payload, suggestedName: _name), isTrue);
      expect(await files.save(_payload, suggestedName: _name), isFalse);
      expect(calls, hasLength(2));
      expect(calls.first.method, 'save');
      expect(calls.first.arguments, {
        'bytes': _payload,
        'suggestedName': _name,
      });
    });
  }

  test('provider errors never expose native messages, details or a chosen URI',
      () async {
    messenger.setMockMethodCallHandler(_channel, (_) async {
      throw PlatformException(
        code: 'provider_private_error',
        message: 'content://synthetic-private-document/test',
        details: 'synthetic private content',
      );
    });
    final files = PlatformBackupFiles(platform: TargetPlatform.android);
    try {
      await files.save(_payload, suggestedName: _name);
      fail('A provider error must not resolve as saved or cancelled');
    } on BackupFileException catch (error) {
      expect(error.code, 'save_failed');
      expect(error.message, contains('partial file'));
      expect(error.toString(), isNot(contains('synthetic')));
      expect(error.toString(), isNot(contains('content://')));
    }
    messenger.setMockMethodCallHandler(_channel, (_) async => true);
    expect(await files.save(_payload, suggestedName: _name), isTrue);
  });

  test('missing or malformed native response is failure, never cancellation',
      () async {
    final files = PlatformBackupFiles(platform: TargetPlatform.android);
    for (final response in [null, 'saved', 1]) {
      messenger.setMockMethodCallHandler(_channel, (_) async => response);
      await expectLater(files.save(_payload, suggestedName: _name),
          throwsA(_failure('save_failed')));
    }
    messenger.setMockMethodCallHandler(_channel, null);
    await expectLater(files.save(_payload, suggestedName: _name),
        throwsA(_failure('save_failed')));
  });

  test('native busy and detached states remain safe retryable failures',
      () async {
    final files = PlatformBackupFiles(platform: TargetPlatform.iOS);
    for (final code in ['busy', 'unavailable']) {
      messenger.setMockMethodCallHandler(_channel, (_) async {
        throw PlatformException(
            code: code, message: 'synthetic private detail');
      });
      await expectLater(
          files.save(_payload, suggestedName: _name), throwsA(_failure(code)));
    }
  });

  test('one pending operation rejects another save or select without a picker',
      () async {
    final pending = Completer<bool>();
    var calls = 0;
    var selections = 0;
    messenger.setMockMethodCallHandler(_channel, (_) {
      calls++;
      return pending.future;
    });
    final files = PlatformBackupFiles(
      platform: TargetPlatform.android,
      selectFile: () async {
        selections++;
        return null;
      },
    );
    final saving = files.save(_payload, suggestedName: _name);
    await expectLater(
        files.save(_payload, suggestedName: _name), throwsA(_failure('busy')));
    await expectLater(files.select(), throwsA(_failure('busy')));
    expect(calls, 1);
    expect(selections, 0);
    pending.complete(false);
    expect(await saving, isFalse);
    expect(await files.select(), isNull);
    expect(selections, 1);
  });

  test('payload and basename validation runs before opening any picker',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(_channel, (_) async {
      calls++;
      return true;
    });
    final files = PlatformBackupFiles(platform: TargetPlatform.android);
    for (final bytes in [Uint8List(0), Uint8List(maxBackupFileBytes + 1)]) {
      await expectLater(files.save(bytes, suggestedName: _name),
          throwsA(_failure('invalid_data')));
    }
    for (final name in [
      '',
      '../backup.json',
      r'C:\backup.json',
      '/backup.json',
      'folder/backup.json',
      r'folder\backup.json',
      'backup\u0000.json',
      'backup\n.json',
      'backup.json\n',
      'CON.json',
      'nul.more.json',
      'backup.txt',
      '${'a' * 124}.json',
    ]) {
      await expectLater(files.save(_payload, suggestedName: name),
          throwsA(_failure('invalid_name')));
    }
    expect(calls, 0);
    expect(
        await files.save(Uint8List(maxBackupFileBytes), suggestedName: _name),
        isTrue);
    expect(calls, 1);
  });

  test(
      'desktop save writes a snapshot of the bytes after destination selection',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('wordai-backup-files-');
    addTearDown(() async {
      // Only this test's freshly created child of the system temp directory.
      expect(directory.parent.resolveSymbolicLinksSync(),
          Directory.systemTemp.resolveSymbolicLinksSync());
      expect(directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
          startsWith('wordai-backup-files-'));
      await directory.delete(recursive: true);
    });
    final destination = Completer<FileSaveLocation?>();
    final files = PlatformBackupFiles(
      platform: TargetPlatform.windows,
      chooseDestination: (suggestedName) {
        expect(suggestedName, _name);
        return destination.future;
      },
    );
    final bytes = Uint8List.fromList(_payload);
    final saving = files.save(bytes, suggestedName: _name);
    bytes.fillRange(0, bytes.length, 0);
    final saved = File('${directory.path}${Platform.pathSeparator}backup.json');
    destination.complete(FileSaveLocation(saved.path));
    expect(await saving, isTrue);
    expect(await saved.readAsBytes(), _payload);

    final restored = PlatformBackupFiles(
      platform: TargetPlatform.windows,
      selectFile: () async => XFile(saved.path),
    );
    final selected = await restored.select();
    expect(
        await selected!.openRead().expand((chunk) => chunk).toList(), _payload);
  });

  test('desktop cancellation and write failure are different outcomes',
      () async {
    final cancelled = PlatformBackupFiles(
      platform: TargetPlatform.macOS,
      chooseDestination: (_) async => null,
    );
    expect(await cancelled.save(_payload, suggestedName: _name), isFalse);
    final directory =
        await Directory.systemTemp.createTemp('wordai-backup-files-');
    addTearDown(() async {
      expect(directory.parent.resolveSymbolicLinksSync(),
          Directory.systemTemp.resolveSymbolicLinksSync());
      expect(directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
          startsWith('wordai-backup-files-'));
      await directory.delete(recursive: true);
    });
    final failed = PlatformBackupFiles(
      platform: TargetPlatform.linux,
      // A directory is not a writable backup file on any supported desktop OS.
      chooseDestination: (_) async => FileSaveLocation(directory.path),
    );
    await expectLater(failed.save(_payload, suggestedName: _name),
        throwsA(_failure('save_failed')));
  });

  test('select shares busy protection and releases it after cancellation/error',
      () async {
    final pending = Completer<XFile?>();
    var calls = 0;
    final files = PlatformBackupFiles(selectFile: () {
      calls++;
      if (calls == 1) return pending.future;
      throw const FileSystemException('synthetic private path');
    });
    final selecting = files.select();
    await expectLater(files.select(), throwsA(_failure('busy')));
    await expectLater(
        files.save(_payload, suggestedName: _name), throwsA(_failure('busy')));
    pending.complete(null);
    expect(await selecting, isNull);
    await expectLater(files.select(), throwsA(_failure('select_failed')));
    await expectLater(files.select(), throwsA(_failure('select_failed')));
    expect(calls, 3);
  });

  test('unsupported save capability fails without opening a destination',
      () async {
    var called = false;
    final files = PlatformBackupFiles(
      platform: TargetPlatform.fuchsia,
      chooseDestination: (_) async {
        called = true;
        return null;
      },
    );
    expect(files.canSave, isFalse);
    await expectLater(files.save(_payload, suggestedName: _name),
        throwsA(_failure('unsupported')));
    expect(called, isFalse);
  });
}
