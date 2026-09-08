import 'dart:convert';
import 'dart:typed_data';

import 'learning_repository.dart';
import 'wordai_dossier.dart';

const maxDictionaryBytes = 10 * 1024 * 1024;
const maxDictionaryEntries = 20000;

class DictionaryImportException implements Exception {
  const DictionaryImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Bounds the bytes actually read, rather than trusting file-picker metadata.
/// No caller may start writing entries until this entire file has validated.
Future<List<WordAiDossier>> readDictionary(Stream<List<int>> source) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source) {
    if (chunk.length > maxDictionaryBytes - bytes.length) {
      throw const DictionaryImportException('The file exceeds 10 MB.');
    }
    bytes.add(chunk);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
  } on FormatException {
    throw const DictionaryImportException('Choose a valid UTF-8 JSON file.');
  }
  final List<dynamic> rows;
  if (decoded is Map<String, dynamic>) {
    rows = [decoded];
  } else if (decoded is List) {
    rows = decoded;
  } else {
    throw const DictionaryImportException(
        'Expected an S6 entry or an array of S6 entries.');
  }
  if (rows.isEmpty || rows.length > maxDictionaryEntries) {
    throw const DictionaryImportException('Expected 1 to 20,000 S6 entries.');
  }
  final entries = <WordAiDossier>[];
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    try {
      if (row is! Map<String, dynamic> ||
          row['query'] is! String ||
          !isSafeBilingualLookup(row['query'] as String)) {
        throw const WordAiDossierException('Invalid entry');
      }
      final entry = WordAiDossier.fromJson(row, expectedQuery: row['query']);
      // Abstentions are valid lookup responses, but contain nothing to import.
      if (!entry.isOk || entry.senses.isEmpty) {
        throw const WordAiDossierException('Entry has no learning content');
      }
      entries.add(entry);
    } on WordAiDossierException {
      throw DictionaryImportException(
          'Entry ${index + 1} is not a valid S6 word.');
    }
  }
  return List.unmodifiable(entries);
}

/// Validation is all-or-nothing; storage remains a retryable per-entry import.
/// Progress advances only after the entry's database transaction commits.
Future<int> importDictionary(
  Stream<List<int>> source, {
  required LearningRepository repository,
  required String uid,
  void Function(int count)? onImported,
}) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid');
  final entries = await readDictionary(source);
  var imported = 0;
  for (final entry in entries) {
    await repository.registerDossier(uid, entry);
    imported++;
    onImported?.call(imported);
  }
  return imported;
}
