import 'services/wordai_dossier.dart';

/// Original small example dataset. Large dictionaries and synthesized audio
/// packs are not bundled; import your own licensed S6 dictionaries instead.
List<WordAiDossier> sampleWords() {
  const rows = [
    [
      'cat',
      'a small animal often kept as a pet',
      '猫',
      '貓',
      'The cat slept on the chair.'
    ],
    [
      'river',
      'a large natural stream of water',
      '河流',
      '河流',
      'The river flows through the town.'
    ],
    [
      'book',
      'a set of pages containing written information',
      '书籍',
      '書籍',
      'She opened a book about birds.'
    ],
    [
      'garden',
      'an area where flowers or vegetables grow',
      '花园',
      '花園',
      'We planted roses in the garden.'
    ],
    [
      'window',
      'an opening with glass that admits light',
      '窗户',
      '窗戶',
      'Please open the window.'
    ],
    [
      'mountain',
      'a very high natural rise in the land',
      '山岳',
      '山岳',
      'Snow covered the mountain.'
    ],
    [
      'friend',
      'a person you know well and like',
      '朋友',
      '朋友',
      'My friend lives nearby.'
    ],
    [
      'journey',
      'an act of travelling from one place to another',
      '旅程',
      '旅程',
      'Our journey began at sunrise.'
    ],
    [
      'bridge',
      'a structure carrying a road over an obstacle',
      '桥梁',
      '橋樑',
      'We crossed the bridge together.'
    ],
    [
      'forest',
      'a large area covered with trees',
      '森林',
      '森林',
      'Birds sang in the forest.'
    ],
    [
      'pencil',
      'an instrument used for writing or drawing',
      '铅笔',
      '鉛筆',
      'He drew a circle with a pencil.'
    ],
    [
      'cloud',
      'a visible mass of tiny water drops in the sky',
      '云朵',
      '雲朵',
      'A white cloud moved across the sky.'
    ],
  ];
  const translations = {
    'cat': ['猫在椅子上睡着了。', '貓在椅子上睡著了。'],
    'river': ['河流穿过小镇。', '河流穿過小鎮。'],
    'book': ['她打开了一本关于鸟的书。', '她打開了一本關於鳥的書。'],
    'garden': ['我们在花园里种了玫瑰。', '我們在花園裡種了玫瑰。'],
    'window': ['请打开窗户。', '請打開窗戶。'],
    'mountain': ['积雪覆盖着山。', '積雪覆蓋著山。'],
    'friend': ['我的朋友住在附近。', '我的朋友住在附近。'],
    'journey': ['我们的旅程从日出时开始。', '我們的旅程從日出時開始。'],
    'bridge': ['我们一起过了桥。', '我們一起過了橋。'],
    'forest': ['鸟儿在森林里歌唱。', '鳥兒在森林裡歌唱。'],
    'pencil': ['他用铅笔画了一个圆。', '他用鉛筆畫了一個圓。'],
    'cloud': ['一朵白云飘过天空。', '一朵白雲飄過天空。'],
  };
  return rows
      .map((r) => WordAiDossier(
            status: 'ok',
            query: r[0],
            direction: WordAiQueryDirection.englishToChinese,
            suggestion: '',
            headword: WordAiHeadword(
                english: r[0],
                simplified: r[2],
                traditional: r[3],
                ipaUs: '',
                ipaUk: ''),
            senses: [
              WordAiSense(
                  id: 'noun-1',
                  partOfSpeech: 'noun',
                  equivalentsEnglish: [r[0]],
                  definitionEnglish: r[1],
                  meaningsSimplified: [r[2]],
                  meaningsTraditional: [r[3]],
                  labels: const [],
                  examples: [
                    WordAiExample(
                        english: r[4],
                        simplified: translations[r[0]]![0],
                        traditional: translations[r[0]]![1],
                        targetForm: r[0],
                        register: 'neutral')
                  ],
                  synonyms: const [],
                  antonyms: const [],
                  collocations: const [])
            ],
            lexical: WordAiLexicalInfo(
                lemma: r[0],
                forms: const [],
                wordFamily: const [],
                phrases: const [],
                confusables: const [],
                etymologyEnglish: '',
                etymologySimplified: '',
                etymologyTraditional: ''),
            analysis: const [],
          ))
      .toList();
}
