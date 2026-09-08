import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'learning_repository.dart';

const maxLearningBackupBytes = 32 * 1024 * 1024;
const _profile = 'local';
const _maxSafeInteger = 9007199254740991;
const _maxTimestampMs = 8640000000000000;
const _maxRows = <String, int>{
  'learning_progress': 100000,
  'review_sessions': 100000,
  'review_attempts': 500000,
};
const _progressFields = <String>[
  'target_id',
  'uid',
  'lexeme_id',
  'word',
  'query',
  'direction',
  'sense_id',
  'part_of_speech',
  'definition_en',
  'meaning_zh_hans',
  'meaning_zh_hant',
  'example_en',
  'example_zh_hans',
  'example_zh_hant',
  'target_form',
  'stage',
  'context_passed_at',
  'learned_at',
  'learned_once',
  'attempt_count',
  'last_tested_at',
  'content_version',
  'updated_at',
];
const _sessionFields = <String>[
  'session_id',
  'uid',
  'started_at',
  'ended_at',
  'active_ms',
  'target_count',
  'completed_count',
  'context_passed_count',
  'new_learned_count',
  'current_index',
  'target_ids_json',
  'status',
  'exit_reason',
  'updated_at',
];
const _attemptFields = <String>[
  'attempt_id',
  'uid',
  'session_id',
  'target_id',
  'test_type',
  'correct',
  'latency_ms',
  'previous_stage',
  'new_stage',
  'created_at',
];
const _fields = <String, List<String>>{
  'learning_progress': _progressFields,
  'review_sessions': _sessionFields,
  'review_attempts': _attemptFields,
};
const _primaryKeys = <String, String>{
  'learning_progress': 'target_id',
  'review_sessions': 'session_id',
  'review_attempts': 'attempt_id',
};
const _rootFields = <String>[
  'format',
  'version',
  'profile',
  'created_at_ms',
  'learning_progress',
  'review_sessions',
  'review_attempts',
];
const _invalid = LearningBackupException(
    'This is not a supported, complete WordAI learning backup.');
const _tooLarge =
    LearningBackupException('The learning backup exceeds 32 MiB.');

class LearningBackupException implements Exception {
  const LearningBackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A fully validated local-profile snapshot. Returned bytes are a copy.
final class LearningBackup {
  LearningBackup._(this.createdAtMs, this._rows, this._bytes);

  final int createdAtMs;
  final Map<String, List<Map<String, Object?>>> _rows;
  final Uint8List _bytes;

  int get progressCount => _rows['learning_progress']!.length;
  int get sessionCount => _rows['review_sessions']!.length;
  int get attemptCount => _rows['review_attempts']!.length;

  Uint8List toBytes() => Uint8List.fromList(_bytes);
}

/// Counts actual stream bytes before decoding. No database is opened here.
Future<LearningBackup> readLearningBackup(Stream<List<int>> input) async {
  final bytes = BytesBuilder();
  try {
    await for (final chunk in input) {
      if (chunk.length > maxLearningBackupBytes - bytes.length) throw _tooLarge;
      bytes.add(chunk);
    }
    final text = utf8.decode(bytes.takeBytes());
    _checkJsonStructure(text);
    return _validate(jsonDecode(text));
  } on LearningBackupException {
    rethrow;
  } on FormatException {
    throw _invalid;
  } catch (_) {
    throw const LearningBackupException(
        'The backup could not be read. Choose the file again.');
  }
}

class LearningBackupService {
  LearningBackupService(this.repository);
  final LearningRepository repository;

  /// Every table is read in one transaction, including the profile check.
  Future<LearningBackup> capture() async {
    try {
      final db = await repository.database;
      return await db.transaction((txn) async {
        await _requireLocalDatabase(txn);
        final document = <String, Object?>{
          'format': 'wordai-learning-backup',
          'version': 1,
          'profile': _profile,
          'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        };
        // Incremental row accounting stops collection before an oversized
        // export can accumulate every row. Final encoding checks framing too.
        var rowBytes = 0;
        for (final table in _fields.keys) {
          final rows = <Map<String, Object?>>[];
          final primaryKey = _primaryKeys[table]!;
          String? cursor;
          while (true) {
            final page = await txn.query(table,
                columns: _fields[table],
                where: cursor == null ? null : '$primaryKey > ?',
                whereArgs: cursor == null ? null : [cursor],
                orderBy: '$primaryKey COLLATE BINARY',
                limit: 128);
            for (final row in page) {
              _validateRow(table, row);
              rowBytes += _encode(row).length;
              if (rowBytes > maxLearningBackupBytes) throw _tooLarge;
              rows.add(row);
              if (rows.length > _maxRows[table]!) throw _invalid;
            }
            if (page.length < 128) break;
            cursor = page.last[primaryKey] as String;
          }
          document[table] = rows;
        }
        return _validate(document);
      }, exclusive: false);
    } on LearningBackupException {
      rethrow;
    } catch (_) {
      throw const LearningBackupException(
          'The learning backup could not be created. Try again.');
    }
  }

  /// Replaces local learning data in one transaction. The caller must first
  /// confirm replacement and keep learning/import screens inactive until done.
  Future<void> restore(LearningBackup backup) async {
    try {
      final db = await repository.database;
      await db.transaction((txn) async {
        // Check inside the same transaction as deletion: a non-local profile
        // must never be silently erased, even if the preview preceded it.
        await _requireLocalDatabase(txn);
        await txn.delete('review_questions');
        await txn.delete('review_attempts');
        await txn.delete('review_sessions');
        await txn.delete('learning_progress');
        await txn.delete('learning_sync_state',
            where: 'uid = ?', whereArgs: [_profile]);
        for (final table in _fields.keys) {
          final rows = backup._rows[table]!;
          for (var offset = 0; offset < rows.length; offset += 128) {
            // Bound extra bridge buffers without a platform round trip for
            // every historical attempt. All batches share this transaction.
            final batch = txn.batch();
            for (final row in rows.skip(offset).take(128)) {
              final values = Map<String, Object?>.of(row);
              if (table == 'review_sessions' && values['status'] == 'active') {
                values['status'] = 'exited';
                values['exit_reason'] = 'restored_backup';
                values['ended_at'] = backup.createdAtMs;
                values['updated_at'] = backup.createdAtMs;
              }
              batch.insert(table, values,
                  conflictAlgorithm: ConflictAlgorithm.abort);
            }
            await batch.commit(noResult: true);
          }
        }
      });
    } on LearningBackupException {
      rethrow;
    } catch (_) {
      // Do not expose SQLite diagnostics, file paths or learning content. A
      // commit/IO failure can be ambiguous, so do not promise a specific state.
      throw const LearningBackupException(
          'The backup could not be restored. Reopen the app and check your '
          'learning data before retrying.');
    }
  }
}

Future<void> _requireLocalDatabase(DatabaseExecutor db) async {
  for (final table in [..._fields.keys, 'learning_sync_state']) {
    final foreign = await db.query(table,
        columns: const ['uid'],
        where: "typeof(uid) != 'text' OR uid != ?",
        whereArgs: [_profile],
        limit: 1);
    if (foreign.isNotEmpty) {
      throw const LearningBackupException(
          'This database contains another profile. Its data cannot be replaced '
          'or included in a local learning backup.');
    }
  }
}

LearningBackup _validate(Object? input) {
  final root = _exactMap(input, _rootFields);
  if (root['format'] != 'wordai-learning-backup' ||
      root['version'] is! int ||
      root['version'] != 1 ||
      root['profile'] != _profile) {
    throw _invalid;
  }
  final created = _timestamp(root['created_at_ms']);
  final tables = <String, List<Map<String, Object?>>>{};
  for (final table in _fields.keys) {
    final inputRows = root[table];
    if (inputRows is! List || inputRows.length > _maxRows[table]!) {
      throw _invalid;
    }
    final ids = <String>{};
    final rows = <Map<String, Object?>>[];
    for (final raw in inputRows) {
      final row = _exactMap(raw, _fields[table]!);
      _validateRow(table, row);
      if (!ids.add(row[_primaryKeys[table]!] as String)) throw _invalid;
      rows.add(Map.unmodifiable(row));
    }
    tables[table] = List.unmodifiable(rows);
  }
  // Even a dictionary-only snapshot is useful; an empty snapshot is not a
  // supported way to clear a device accidentally.
  if (tables['learning_progress']!.isEmpty) throw _invalid;
  final targets = {
    for (final row in tables['learning_progress']!) row['target_id'] as String,
  };
  final sessions = <String, Set<String>>{};
  for (final row in tables['review_sessions']!) {
    final ids = _sessionTargets(row);
    if (ids.any((id) => !targets.contains(id))) throw _invalid;
    sessions[row['session_id'] as String] = ids.toSet();
  }
  for (final row in tables['review_attempts']!) {
    if (!targets.contains(row['target_id']) ||
        !(sessions[row['session_id']]?.contains(row['target_id']) ?? false)) {
      throw _invalid;
    }
  }
  final bytes = _encode({
    'format': root['format'],
    'version': 1,
    'profile': _profile,
    'created_at_ms': created,
    ...tables,
  });
  return LearningBackup._(created, Map.unmodifiable(tables), bytes);
}

Map<String, Object?> _exactMap(Object? input, List<String> fields) {
  if (input is! Map ||
      input.length != fields.length ||
      input.keys.any((key) => key is! String || !fields.contains(key))) {
    throw _invalid;
  }
  return Map<String, Object?>.from(input);
}

void _validateRow(String table, Map<String, Object?> row) {
  if (row['uid'] != _profile) throw _invalid;
  if (table == 'learning_progress') {
    final target = _hashId(row['target_id']);
    final lexeme = _hashId(row['lexeme_id']);
    final query = _string(row['query'], maximum: 2048, nonempty: true);
    final sense = _string(row['sense_id'], maximum: 256, nonempty: true);
    final direction = row['direction'];
    if (direction != 'en_to_zh' && direction != 'zh_to_en') throw _invalid;
    if (lexeme != _hash('$direction::${query.trim().toLowerCase()}') ||
        target != _hash('$_profile::$lexeme::$sense')) {
      throw _invalid;
    }
    for (final field in const [
      'word',
      'part_of_speech',
      'definition_en',
      'meaning_zh_hans',
      'meaning_zh_hant',
      'example_en',
      'example_zh_hans',
      'example_zh_hant',
      'target_form',
    ]) {
      _string(row[field]);
    }
    _string(row['content_version'], maximum: 128, nonempty: true);
    _integer(row['stage'], maximum: 2);
    _integer(row['learned_once'], maximum: 1);
    _integer(row['attempt_count'], maximum: 2147483647);
    for (final field in const [
      'context_passed_at',
      'learned_at',
      'last_tested_at'
    ]) {
      _nullableInteger(row[field]);
    }
    _timestamp(row['updated_at']);
  } else if (table == 'review_sessions') {
    _identifier(row['session_id']);
    _timestamp(row['started_at']);
    _nullableInteger(row['ended_at']);
    _timestamp(row['updated_at']);
    _integer(row['active_ms']);
    for (final field in const [
      'target_count',
      'completed_count',
      'context_passed_count',
      'new_learned_count',
      'current_index'
    ]) {
      _integer(row[field], maximum: 2147483647);
    }
    if (!const {'active', 'completed', 'exited'}.contains(row['status'])) {
      throw _invalid;
    }
    if (row['exit_reason'] != null) _string(row['exit_reason'], maximum: 1024);
    _sessionTargets(row);
  } else {
    _identifier(row['attempt_id']);
    _identifier(row['session_id']);
    _hashId(row['target_id']);
    final type = row['test_type'];
    final correct = _integer(row['correct'], maximum: 1);
    final previous = _integer(row['previous_stage'], maximum: 1);
    final next = _integer(row['new_stage'], maximum: 2);
    if (type != (previous == 0 ? 'context' : 'independent') ||
        next != previous + correct) {
      throw _invalid;
    }
    _integer(row['latency_ms'], maximum: 3600000);
    _timestamp(row['created_at']);
  }
}

List<String> _sessionTargets(Map<String, Object?> row) {
  final encoded = _string(row['target_ids_json'], maximum: 4096);
  final Object? decoded;
  try {
    _checkJsonStructure(encoded);
    decoded = jsonDecode(encoded);
  } on FormatException {
    throw _invalid;
  }
  if (decoded is! List || decoded.isEmpty || decoded.length > 20) {
    throw _invalid;
  }
  final ids = decoded.map(_hashId).toList();
  if (ids.toSet().length != ids.length ||
      (row['current_index'] as int) > ids.length) {
    throw _invalid;
  }
  return ids;
}

int _integer(Object? value, {int maximum = _maxSafeInteger}) {
  if (value is! int || value < 0 || value > maximum) throw _invalid;
  return value;
}

void _nullableInteger(Object? value) {
  if (value != null) _timestamp(value);
}

int _timestamp(Object? value) => _integer(value, maximum: _maxTimestampMs);

String _identifier(Object? value) =>
    _string(value, maximum: 128, nonempty: true);

String _hashId(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw _invalid;
  }
  return value;
}

String _string(Object? value, {int maximum = 65536, bool nonempty = false}) {
  if (value is! String ||
      value.length > maximum ||
      (nonempty && value.trim().isEmpty)) {
    throw _invalid;
  }
  // JSON permits escaped unpaired UTF-16 surrogates. Reject them before UTF-8
  // hashing/encoding can replace them and collapse distinct identities.
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) throw _invalid;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) throw _invalid;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw _invalid;
    }
  }
  if (utf8.encode(value).length > maximum) throw _invalid;
  return value;
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

Uint8List _encode(Object value) {
  final output = _BoundedBytes();
  final encoder = JsonUtf8Encoder().startChunkedConversion(output);
  encoder.add(value);
  encoder.close();
  return output.bytes.takeBytes();
}

class _BoundedBytes implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (data.length > maxLearningBackupBytes - bytes.length) throw _tooLarge;
    bytes.add(data);
  }

  @override
  void close() {}
}

/// JSON decoding alone discards duplicate object keys. This lexical preflight
/// rejects ambiguous keys and caps nesting; jsonDecode still owns JSON grammar.
void _checkJsonStructure(String text) {
  final stack = <Set<String>?>[];
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x7b || unit == 0x5b) {
      stack.add(unit == 0x7b ? <String>{} : null);
      if (stack.length > 8) throw _invalid;
    } else if (unit == 0x7d || unit == 0x5d) {
      if (stack.isEmpty || (stack.last == null) != (unit == 0x5d)) {
        throw _invalid;
      }
      stack.removeLast();
    } else if (unit == 0x22) {
      final start = i++;
      while (i < text.length && text.codeUnitAt(i) != 0x22) {
        if (text.codeUnitAt(i) == 0x5c) i++;
        i++;
      }
      if (i >= text.length) throw _invalid;
      var next = i + 1;
      while (next < text.length &&
          const [0x20, 0x0a, 0x0d, 0x09].contains(text.codeUnitAt(next))) {
        next++;
      }
      if (next < text.length && text.codeUnitAt(next) == 0x3a) {
        if (stack.isEmpty ||
            stack.last == null ||
            !stack.last!
                .add(jsonDecode(text.substring(start, i + 1)) as String)) {
          throw _invalid;
        }
      }
    }
  }
  if (stack.isNotEmpty) throw _invalid;
}
