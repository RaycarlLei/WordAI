import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/sample_words.dart';
import 'package:word_a_i/services/wordai_dossier.dart';
import 'package:word_a_i/services/community_gateway.dart';
import 'package:word_a_i/services/learning_repository.dart';

void main() {
  sqfliteFfiInit();
  test('all bundled words validate as importable S6', () {
    for (final word in sampleWords()) {
      final result =
          WordAiDossier.fromJson(word.toJson(), expectedQuery: word.query);
      expect(result.query, word.query);
    }
  });
  test('documented example validates as S6', () {
    for (final row
        in jsonDecode(File('examples/words.json').readAsStringSync()) as List) {
      expect(
          WordAiDossier.fromJson(Map<String, dynamic>.from(row),
                  expectedQuery: row['query'])
              .isOk,
          isTrue);
    }
  });
  for (final language in ['en', 'zh', 'zh_Hant']) {
    test('first launch can review every sample in $language without network',
        () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await LearningRepository.createSchema(db);
      final repo = LearningRepository.forTesting(db);
      for (final word in sampleWords()) {
        await repo.registerDossier('local', word);
      }
      expect(await repo.reviewableWordCount('local'), 12);
      final session = await repo.createSession('local');
      expect(session, isNotNull);
      expect(await repo.buildQuestion(session!, language), isNotNull);
    });
  }
  test('unconfigured and unsafe gateways fail before opening a client',
      () async {
    for (final url in [
      '',
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com/?token=x',
      'https://example.com/#x'
    ]) {
      await expectLater(CommunityGateway(baseUrl: url).synthesizeSpeech('cat'),
          throwsA(isA<CommunityGatewayException>()));
    }
    expect(
        CommunityGateway(baseUrl: 'https://example.com/api/')
            .speechEndpoint
            .toString(),
        'https://example.com/api/tts');
  });
}
