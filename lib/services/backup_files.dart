import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const maxBackupFileBytes = 32 * 1024 * 1024;

class BackupFileException implements Exception {
  const BackupFileException(this.message, {required this.code});

  final String message;
  final String code;

  @override
  String toString() => message;
}

abstract class BackupFiles {
  bool get canSave;

  /// False means the user cancelled. A failed write always throws; the chosen
  /// document may then be incomplete and is never deleted by this service.
  Future<bool> save(Uint8List bytes, {required String suggestedName});

  /// The caller must bound and validate the actual stream from [XFile.openRead].
  Future<XFile?> select();
}

const _jsonFiles = XTypeGroup(
  label: 'WordAI backup',
  extensions: ['json'],
  mimeTypes: ['application/json'],
  uniformTypeIdentifiers: ['public.json'],
);

class PlatformBackupFiles implements BackupFiles {
  PlatformBackupFiles({
    TargetPlatform? platform,
    MethodChannel channel =
        const MethodChannel('org.wordai.community/backup_files'),
    @visibleForTesting Future<XFile?> Function()? selectFile,
    @visibleForTesting
    Future<FileSaveLocation?> Function(String suggestedName)? chooseDestination,
  })  : _platform = platform ?? defaultTargetPlatform,
        _channel = channel,
        _selectFile = selectFile ?? _open,
        _chooseDestination = chooseDestination ?? _destination;

  final TargetPlatform _platform;
  final MethodChannel _channel;
  final Future<XFile?> Function() _selectFile;
  final Future<FileSaveLocation?> Function(String) _chooseDestination;
  bool _busy = false;

  static Future<XFile?> _open() =>
      openFile(acceptedTypeGroups: const [_jsonFiles]);

  static Future<FileSaveLocation?> _destination(String suggestedName) =>
      getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: const [_jsonFiles],
      );

  @override
  bool get canSave =>
      !kIsWeb &&
      switch (_platform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows =>
          true,
        TargetPlatform.fuchsia => false,
      };

  void _acquire() {
    if (_busy) {
      throw const BackupFileException(
        'Finish the current file operation first.',
        code: 'busy',
      );
    }
    _busy = true;
  }

  @override
  Future<bool> save(Uint8List bytes, {required String suggestedName}) async {
    _acquire();
    try {
      if (!canSave) {
        throw const BackupFileException(
          'Saving backups is not supported on this platform.',
          code: 'unsupported',
        );
      }
      if (bytes.isEmpty || bytes.length > maxBackupFileBytes) {
        throw const BackupFileException(
          'A backup must contain 1 byte to 32 MiB.',
          code: 'invalid_data',
        );
      }
      if (!_validName(suggestedName)) {
        throw const BackupFileException(
          'Use a simple JSON filename for the backup.',
          code: 'invalid_name',
        );
      }
      // The caller may reuse its buffer while the system picker is open.
      final snapshot = Uint8List.fromList(bytes);
      if (_platform == TargetPlatform.android ||
          _platform == TargetPlatform.iOS) {
        final saved = await _channel.invokeMethod<bool>('save', {
          'bytes': snapshot,
          'suggestedName': suggestedName,
        });
        if (saved == null) throw const FormatException();
        return saved;
      }
      final location = await _chooseDestination(suggestedName);
      if (location == null) return false;
      await XFile.fromData(snapshot, mimeType: 'application/json')
          .saveTo(location.path);
      return true;
    } on BackupFileException {
      rethrow;
    } on PlatformException catch (error) {
      // Native messages/details and provider errors may contain a private URI.
      throw _nativeFailure(error.code);
    } catch (_) {
      throw _nativeFailure('save_failed');
    } finally {
      _busy = false;
    }
  }

  @override
  Future<XFile?> select() async {
    _acquire();
    try {
      return await _selectFile();
    } catch (_) {
      throw const BackupFileException(
        'Could not open the file picker. Try again.',
        code: 'select_failed',
      );
    } finally {
      _busy = false;
    }
  }

  static bool _validName(String name) =>
      name.length <= 128 &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.json$').hasMatch(name) &&
      !name.contains('..') &&
      !RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', caseSensitive: false)
          .hasMatch(name.split('.').first);

  static BackupFileException _nativeFailure(String code) => switch (code) {
        'busy' => const BackupFileException(
            'Finish the current file operation first.',
            code: 'busy',
          ),
        'unavailable' => const BackupFileException(
            'The file operation was interrupted. Try again.',
            code: 'unavailable',
          ),
        _ => const BackupFileException(
            'The backup could not be saved. A partial file may remain; '
            'choose a new file and try again.',
            code: 'save_failed',
          ),
      };
}
