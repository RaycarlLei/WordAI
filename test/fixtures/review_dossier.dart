import 'package:word_a_i/services/wordai_dossier.dart';

WordAiDossier reviewDossier(String word, int index) => WordAiDossier(
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
