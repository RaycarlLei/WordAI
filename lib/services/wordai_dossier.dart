import 'dart:convert';

import '/services/wordai_llm_contract.dart';

const String kWordAiStructuredContractVersion = 'wordai_dossier_s6';
const String kWordAiDossierContentRevision = 'lexical_graph_v1';

class WordAiDossierException implements Exception {
  const WordAiDossierException(this.message, {this.code = 'invalid-dossier'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

enum WordAiQueryDirection { englishToChinese, chineseToEnglish }

extension WordAiQueryDirectionWire on WordAiQueryDirection {
  String get wireValue => switch (this) {
        WordAiQueryDirection.englishToChinese => 'en_to_zh',
        WordAiQueryDirection.chineseToEnglish => 'zh_to_en',
      };
}

WordAiQueryDirection detectWordAiQueryDirection(String value) {
  final query = WordAiLlmContract.normalizeTarget(value);
  final han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]')
      .allMatches(query)
      .length;
  final latin = RegExp(r'[A-Za-z]').allMatches(query).length;
  return han > 0 && han >= (latin / 2).ceil().clamp(1, 1 << 30)
      ? WordAiQueryDirection.chineseToEnglish
      : WordAiQueryDirection.englishToChinese;
}

bool isSafeBilingualLookup(String value) {
  final query = WordAiLlmContract.normalizeTarget(value);
  if (query.isEmpty ||
      query.runes.length > 120 ||
      value.contains('\n') ||
      value.contains('\r') ||
      _hasControl(query) ||
      _hasUnpairedSurrogate(query)) {
    return false;
  }
  return RegExp(r'[A-Za-z\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]')
      .hasMatch(query);
}

class WordAiDossierUpdate {
  const WordAiDossierUpdate({
    required this.dossier,
    required this.stage,
    required this.isFinal,
    required this.provider,
    required this.model,
  });

  final WordAiDossier dossier;
  final String stage;
  final bool isFinal;
  final String provider;
  final String model;
}

class WordAiDossier {
  const WordAiDossier({
    required this.status,
    required this.query,
    required this.direction,
    required this.suggestion,
    required this.headword,
    required this.senses,
    required this.lexical,
    required this.analysis,
  });

  final String status;
  final String query;
  final WordAiQueryDirection direction;
  final String suggestion;
  final WordAiHeadword headword;
  final List<WordAiSense> senses;
  final WordAiLexicalInfo lexical;
  final List<WordAiInsight> analysis;

  bool get isOk => status == 'ok';

  static WordAiDossier fromJson(
    Map<String, dynamic> json, {
    required String expectedQuery,
    bool allowPartial = false,
  }) {
    _expectExactKeys(
        json,
        const {
          'schema_version',
          'status',
          'query',
          'direction',
          'suggestion',
          'headword',
          'senses',
          'lexical',
          'analysis',
        },
        'dossier');
    if (_requiredString(json, 'schema_version') !=
        kWordAiStructuredContractVersion) {
      throw const WordAiDossierException(
        'WordAI returned an incompatible structured response.',
        code: 'dossier.version',
      );
    }
    final query = WordAiLlmContract.normalizeTarget(
      _requiredString(json, 'query'),
    );
    final expected = WordAiLlmContract.normalizeTarget(expectedQuery);
    if (query != expected) {
      throw const WordAiDossierException(
        'WordAI answered a different lookup query.',
        code: 'dossier.query',
      );
    }
    final status = _requiredString(json, 'status');
    if (!const {'ok', 'uncertain', 'invalid'}.contains(status)) {
      throw const WordAiDossierException(
        'WordAI returned an invalid lookup status.',
        code: 'dossier.status',
      );
    }
    final directionValue = _requiredString(json, 'direction');
    final expectedDirection = detectWordAiQueryDirection(query);
    if (directionValue != expectedDirection.wireValue) {
      throw const WordAiDossierException(
        'WordAI returned the wrong bilingual direction.',
        code: 'dossier.direction',
      );
    }
    final suggestion = _validateIntegrity(
      _requiredString(json, 'suggestion'),
      label: 'Suggestion',
      maximum: 120,
      allowEmpty: true,
    );
    final headword = WordAiHeadword.fromJson(
      _requiredMap(json, 'headword'),
      allowEmpty: status != 'ok' || allowPartial,
    );
    final senses = _requiredList(json, 'senses')
        .map((item) => WordAiSense.fromJson(_asMap(item, 'sense')))
        .toList(growable: false);
    final senseIds = <String>{};
    for (final sense in senses) {
      if (!senseIds.add(sense.id)) {
        throw const WordAiDossierException(
          'WordAI repeated a sense identifier.',
          code: 'sense.duplicate',
        );
      }
    }
    final lexical = WordAiLexicalInfo.fromJson(
      _requiredMap(json, 'lexical'),
      allowEmpty: status != 'ok' || allowPartial,
    );
    final rawAnalysis = _requiredList(json, 'analysis');
    if (rawAnalysis.length > 5) {
      throw const WordAiDossierException(
        'WordAI returned too many insights.',
        code: 'dossier.analysis',
      );
    }
    final analysis = <WordAiInsight>[];
    for (final item in rawAnalysis) {
      try {
        analysis.add(WordAiInsight.fromJson(
          _asMap(item, 'analysis'),
          senseIds: senseIds,
        ));
      } on WordAiDossierException {
        // Insights are optional. Invalid items are never displayed, while the
        // validated senses and examples remain available to the learner.
      }
    }

    if (status != 'ok') {
      if (!headword.isEmpty ||
          senses.isNotEmpty ||
          !lexical.isEmpty ||
          analysis.isNotEmpty) {
        throw const WordAiDossierException(
          'An abstaining WordAI response contained generated content.',
          code: 'dossier.abstention',
        );
      }
    } else {
      if ((!allowPartial && senses.isEmpty) || senses.length > 4) {
        throw const WordAiDossierException(
          'WordAI returned an invalid number of senses or insights.',
          code: 'dossier.count',
        );
      }
      final exampleCount = senses.fold<int>(
        0,
        (total, sense) => total + sense.examples.length,
      );
      if (exampleCount > 8) {
        throw const WordAiDossierException(
          'WordAI returned too many examples.',
          code: 'dossier.examples',
        );
      }
      if (!allowPartial &&
          senses.any((sense) =>
              sense.partOfSpeech == 'proper noun' ||
              (sense.labels.contains('technical') &&
                  const {'noun', 'abbreviation', 'phrase'}
                      .contains(sense.partOfSpeech)))) {
        final encyclopedia = analysis
            .where((insight) => insight.isEncyclopedic)
            .toList(growable: false);
        if (encyclopedia.length != 1 ||
            !_hasEncyclopedicDepth(encyclopedia.single)) {
          throw const WordAiDossierException(
            'WordAI omitted the required encyclopedic overview.',
            code: 'analysis.encyclopedia',
          );
        }
      }
    }

    return WordAiDossier(
      status: status,
      query: query,
      direction: expectedDirection,
      suggestion: suggestion,
      headword: headword,
      senses: senses,
      lexical: lexical,
      analysis: analysis,
    );
  }

  static WordAiDossier fromLegacy(
    Map<String, dynamic> legacy, {
    required String expectedQuery,
  }) {
    final validated = WordAiLlmContract.validateDossier(
      expectedTarget: expectedQuery,
      dossier: legacy,
      normalizeOfflineSource: true,
    );
    final status = _requiredString(validated, 'status');
    if (status != 'ok') {
      return WordAiDossier(
        status: status,
        query: WordAiLlmContract.normalizeTarget(expectedQuery),
        direction: WordAiQueryDirection.englishToChinese,
        suggestion: _requiredString(validated, 'suggestion'),
        headword: WordAiHeadword.empty,
        senses: const [],
        lexical: WordAiLexicalInfo.empty,
        analysis: const [],
      );
    }
    final query = WordAiLlmContract.normalizeTarget(expectedQuery);
    final definition = _requiredString(validated, 'definition');
    final senses = <WordAiSense>[];
    for (final raw in _requiredList(validated, 'entries')) {
      final entry = _asMap(raw, 'legacy entry');
      final index = senses.length + 1;
      final part = _requiredString(entry, 'part');
      senses.add(WordAiSense(
        id: '${part.replaceAll(' ', '-')}-$index',
        partOfSpeech: part,
        equivalentsEnglish: [query],
        definitionEnglish: definition,
        meaningsSimplified: _stringList(entry, 'meanings_zh_hans'),
        meaningsTraditional: _stringList(entry, 'meanings_zh_hant'),
        labels: const [],
        synonyms: const [],
        antonyms: const [],
        collocations: const [],
        examples: [
          WordAiExample(
            english: _requiredString(entry, 'example_en'),
            simplified: _requiredString(entry, 'example_zh_hans'),
            traditional: _requiredString(entry, 'example_zh_hant'),
            targetForm: query,
            register: 'neutral',
          ),
        ],
      ));
    }
    final insights = _requiredList(validated, 'analysis').take(5).map((raw) {
      final item = _asMap(raw, 'legacy analysis');
      return WordAiInsight(
        category: _requiredString(item, 'category'),
        senseId: 'term',
        textEnglish: _requiredString(item, 'text_en'),
        textSimplified: _requiredString(item, 'text_zh_hans'),
        textTraditional: _requiredString(item, 'text_zh_hant'),
      );
    }).toList(growable: false);
    return WordAiDossier(
      status: 'ok',
      query: query,
      direction: WordAiQueryDirection.englishToChinese,
      suggestion: _requiredString(validated, 'suggestion'),
      headword: WordAiHeadword(
        english: query,
        simplified: senses.first.meaningsSimplified.first,
        traditional: senses.first.meaningsTraditional.first,
        ipaUs: '',
        ipaUk: '',
      ),
      senses: senses,
      lexical: WordAiLexicalInfo(
        lemma: query,
        forms: const [],
        wordFamily: const [],
        phrases: const [],
        confusables: const [],
        etymologyEnglish: '',
        etymologySimplified: '',
        etymologyTraditional: '',
      ),
      analysis: insights,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': kWordAiStructuredContractVersion,
        'status': status,
        'query': query,
        'direction': direction.wireValue,
        'suggestion': suggestion,
        'headword': headword.toJson(),
        'senses': senses.map((sense) => sense.toJson()).toList(),
        'lexical': lexical.toJson(),
        'analysis': analysis.map((item) => item.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());
}

class WordAiHeadword {
  const WordAiHeadword({
    required this.english,
    required this.simplified,
    required this.traditional,
    required this.ipaUs,
    required this.ipaUk,
  });

  static const empty = WordAiHeadword(
    english: '',
    simplified: '',
    traditional: '',
    ipaUs: '',
    ipaUk: '',
  );

  final String english;
  final String simplified;
  final String traditional;
  final String ipaUs;
  final String ipaUk;

  bool get isEmpty =>
      [english, simplified, traditional, ipaUs, ipaUk].every((v) => v.isEmpty);

  static WordAiHeadword fromJson(
    Map<String, dynamic> json, {
    required bool allowEmpty,
  }) {
    _expectExactKeys(
        json,
        const {
          'english',
          'zh_hans',
          'zh_hant',
          'ipa_us',
          'ipa_uk',
        },
        'headword');
    final english = _requiredString(json, 'english');
    final simplified = _requiredString(json, 'zh_hans');
    final traditional = _requiredString(json, 'zh_hant');
    final ipaUs = _requiredString(json, 'ipa_us');
    final ipaUk = _requiredString(json, 'ipa_uk');
    if (allowEmpty &&
        [english, simplified, traditional, ipaUs, ipaUk]
            .every((v) => v.isEmpty)) {
      return empty;
    }
    return WordAiHeadword(
      english: _validateEnglish(english, 'English headword', 120),
      simplified: _validateChinese(simplified, 'Simplified headword', 120),
      traditional: _validateChinese(traditional, 'Traditional headword', 120),
      ipaUs: _validateIntegrity(
        ipaUs,
        label: 'US IPA',
        maximum: 80,
        allowEmpty: true,
      ),
      ipaUk: _validateIntegrity(
        ipaUk,
        label: 'UK IPA',
        maximum: 80,
        allowEmpty: true,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'english': english,
        'zh_hans': simplified,
        'zh_hant': traditional,
        'ipa_us': ipaUs,
        'ipa_uk': ipaUk,
      };
}

class WordAiSense {
  const WordAiSense({
    required this.id,
    required this.partOfSpeech,
    required this.equivalentsEnglish,
    required this.definitionEnglish,
    required this.meaningsSimplified,
    required this.meaningsTraditional,
    required this.labels,
    required this.examples,
    required this.synonyms,
    required this.antonyms,
    required this.collocations,
  });

  static const parts = {
    'noun',
    'verb',
    'adjective',
    'adverb',
    'pronoun',
    'preposition',
    'conjunction',
    'interjection',
    'determiner',
    'auxiliary',
    'particle',
    'phrasal verb',
    'phrase',
    'idiom',
    'abbreviation',
    'proper noun',
  };
  static const allowedLabels = {
    'common',
    'formal',
    'informal',
    'literary',
    'technical',
    'regional',
    'dated',
    'figurative',
  };

  final String id;
  final String partOfSpeech;
  final List<String> equivalentsEnglish;
  final String definitionEnglish;
  final List<String> meaningsSimplified;
  final List<String> meaningsTraditional;
  final List<String> labels;
  final List<WordAiExample> examples;
  final List<String> synonyms;
  final List<String> antonyms;
  final List<String> collocations;

  static WordAiSense fromJson(Map<String, dynamic> json) {
    _expectExactKeys(
        json,
        const {
          'id',
          'part_of_speech',
          'equivalents_en',
          'definition_en',
          'meanings_zh_hans',
          'meanings_zh_hant',
          'labels',
          'examples',
          'synonyms',
          'antonyms',
          'collocations',
        },
        'sense');
    final id = _validateIntegrity(
      _requiredString(json, 'id'),
      label: 'Sense id',
      maximum: 40,
    );
    if (!RegExp(r'^[a-z]+(?:-[a-z]+)*-[1-9][0-9]*$').hasMatch(id)) {
      throw const WordAiDossierException(
        'WordAI returned an invalid sense identifier.',
        code: 'sense.id',
      );
    }
    final part = _requiredString(json, 'part_of_speech');
    if (!parts.contains(part)) {
      throw const WordAiDossierException(
        'WordAI returned an invalid part of speech.',
        code: 'sense.part',
      );
    }
    final equivalents = _validatedStringList(
      json,
      'equivalents_en',
      maximum: 4,
      validator: (value) => _validateEnglish(value, 'English equivalent', 100),
    );
    final simplified = _validatedStringList(
      json,
      'meanings_zh_hans',
      maximum: 4,
      validator: (value) => _validateChinese(value, 'Simplified meaning', 100),
    );
    final traditional = _validatedStringList(
      json,
      'meanings_zh_hant',
      maximum: 4,
      validator: (value) => _validateChinese(value, 'Traditional meaning', 100),
    );
    final labels = _stringList(json, 'labels');
    if (labels.length > 3 ||
        labels.any((label) => !allowedLabels.contains(label)) ||
        labels.toSet().length != labels.length) {
      throw const WordAiDossierException(
        'WordAI returned invalid sense labels.',
        code: 'sense.labels',
      );
    }
    final examples = _requiredList(json, 'examples')
        .map((item) => WordAiExample.fromJson(_asMap(item, 'example')))
        .toList(growable: false);
    if (examples.length > 3 ||
        examples.map((e) => e.english.toLowerCase()).toSet().length !=
            examples.length) {
      throw const WordAiDossierException(
        'WordAI returned invalid or duplicate examples.',
        code: 'sense.examples',
      );
    }
    return WordAiSense(
      id: id,
      partOfSpeech: part,
      equivalentsEnglish: equivalents,
      definitionEnglish: _validateEnglish(
        _requiredString(json, 'definition_en'),
        'English definition',
        320,
      ),
      meaningsSimplified: simplified,
      meaningsTraditional: traditional,
      labels: labels,
      examples: examples,
      synonyms: _validatedOptionalStringList(
        json,
        'synonyms',
        maximum: 6,
        validator: (value) => _validateEnglish(value, 'Sense synonym', 100),
      ),
      antonyms: _validatedOptionalStringList(
        json,
        'antonyms',
        maximum: 4,
        validator: (value) => _validateEnglish(value, 'Sense antonym', 100),
      ),
      collocations: _validatedOptionalStringList(
        json,
        'collocations',
        maximum: 6,
        validator: (value) => _validateEnglish(value, 'Sense collocation', 140),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'part_of_speech': partOfSpeech,
        'equivalents_en': equivalentsEnglish,
        'definition_en': definitionEnglish,
        'meanings_zh_hans': meaningsSimplified,
        'meanings_zh_hant': meaningsTraditional,
        'labels': labels,
        'examples': examples.map((example) => example.toJson()).toList(),
        'synonyms': synonyms,
        'antonyms': antonyms,
        'collocations': collocations,
      };
}

class WordAiLexicalInfo {
  const WordAiLexicalInfo({
    required this.lemma,
    required this.forms,
    required this.wordFamily,
    required this.phrases,
    required this.confusables,
    required this.etymologyEnglish,
    required this.etymologySimplified,
    required this.etymologyTraditional,
  });

  static const empty = WordAiLexicalInfo(
    lemma: '',
    forms: [],
    wordFamily: [],
    phrases: [],
    confusables: [],
    etymologyEnglish: '',
    etymologySimplified: '',
    etymologyTraditional: '',
  );

  final String lemma;
  final List<WordAiForm> forms;
  final List<String> wordFamily;
  final List<String> phrases;
  final List<String> confusables;
  final String etymologyEnglish;
  final String etymologySimplified;
  final String etymologyTraditional;

  bool get isEmpty =>
      lemma.isEmpty &&
      forms.isEmpty &&
      wordFamily.isEmpty &&
      phrases.isEmpty &&
      confusables.isEmpty &&
      etymologyEnglish.isEmpty &&
      etymologySimplified.isEmpty &&
      etymologyTraditional.isEmpty;

  static WordAiLexicalInfo fromJson(
    Map<String, dynamic> json, {
    required bool allowEmpty,
  }) {
    _expectExactKeys(
      json,
      const {
        'lemma',
        'forms',
        'word_family',
        'phrases',
        'confusables',
        'etymology',
      },
      'lexical information',
    );
    final lemmaValue = _requiredString(json, 'lemma');
    final forms = _requiredList(json, 'forms')
        .map((item) => WordAiForm.fromJson(_asMap(item, 'word form')))
        .toList(growable: false);
    if (forms.length > 12 ||
        forms.map((form) => form.term.toLowerCase()).toSet().length !=
            forms.length) {
      throw const WordAiDossierException(
        'WordAI returned invalid word forms.',
        code: 'lexical.forms',
      );
    }
    final etymology = _requiredMap(json, 'etymology');
    _expectExactKeys(
      etymology,
      const {'text_en', 'text_zh_hans', 'text_zh_hant'},
      'etymology',
    );
    final etymologyEnglish = _requiredString(etymology, 'text_en').trim();
    final etymologySimplified =
        _requiredString(etymology, 'text_zh_hans').trim();
    final etymologyTraditional =
        _requiredString(etymology, 'text_zh_hant').trim();
    final hasAnyEtymology = etymologyEnglish.isNotEmpty ||
        etymologySimplified.isNotEmpty ||
        etymologyTraditional.isNotEmpty;
    if (hasAnyEtymology &&
        (etymologyEnglish.isEmpty ||
            etymologySimplified.isEmpty ||
            etymologyTraditional.isEmpty)) {
      throw const WordAiDossierException(
        'WordAI returned an incomplete etymology.',
        code: 'lexical.etymology',
      );
    }
    final lemma = lemmaValue.isEmpty && allowEmpty
        ? ''
        : _validateEnglish(lemmaValue, 'Canonical lemma', 120);
    final result = WordAiLexicalInfo(
      lemma: lemma,
      forms: forms,
      wordFamily: _validatedOptionalStringList(
        json,
        'word_family',
        maximum: 8,
        validator: (value) => _validateEnglish(value, 'Word-family term', 100),
      ),
      phrases: _validatedOptionalStringList(
        json,
        'phrases',
        maximum: 8,
        validator: (value) => _validateEnglish(value, 'Related phrase', 140),
      ),
      confusables: _validatedOptionalStringList(
        json,
        'confusables',
        maximum: 6,
        validator: (value) => _validateEnglish(value, 'Confusable term', 100),
      ),
      etymologyEnglish: hasAnyEtymology
          ? _validateEnglish(etymologyEnglish, 'English etymology', 700)
          : '',
      etymologySimplified: hasAnyEtymology
          ? _validateChinese(
              etymologySimplified,
              'Simplified Chinese etymology',
              700,
            )
          : '',
      etymologyTraditional: hasAnyEtymology
          ? _validateChinese(
              etymologyTraditional,
              'Traditional Chinese etymology',
              700,
            )
          : '',
    );
    if (!allowEmpty && result.lemma.isEmpty) {
      throw const WordAiDossierException(
        'WordAI omitted the canonical lemma.',
        code: 'lexical.lemma',
      );
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'lemma': lemma,
        'forms': forms.map((form) => form.toJson()).toList(),
        'word_family': wordFamily,
        'phrases': phrases,
        'confusables': confusables,
        'etymology': {
          'text_en': etymologyEnglish,
          'text_zh_hans': etymologySimplified,
          'text_zh_hant': etymologyTraditional,
        },
      };
}

class WordAiForm {
  const WordAiForm({required this.term, required this.type});

  static const types = {
    'lemma',
    'plural',
    'past',
    'past_participle',
    'present_participle',
    'third_person',
    'comparative',
    'superlative',
    'alternative',
  };

  final String term;
  final String type;

  static WordAiForm fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const {'term', 'type'}, 'word form');
    final type = _requiredString(json, 'type');
    if (!types.contains(type)) {
      throw const WordAiDossierException(
        'WordAI returned an invalid word-form type.',
        code: 'lexical.form_type',
      );
    }
    return WordAiForm(
      term: _validateEnglish(
        _requiredString(json, 'term'),
        'Word form',
        100,
      ),
      type: type,
    );
  }

  Map<String, dynamic> toJson() => {'term': term, 'type': type};
}

class WordAiExample {
  const WordAiExample({
    required this.english,
    required this.simplified,
    required this.traditional,
    required this.targetForm,
    required this.register,
  });

  final String english;
  final String simplified;
  final String traditional;
  final String targetForm;
  final String register;

  static WordAiExample fromJson(Map<String, dynamic> json) {
    _expectExactKeys(
        json,
        const {
          'english',
          'zh_hans',
          'zh_hant',
          'target_form',
          'register',
        },
        'example');
    final english = _validateEnglish(
      _requiredString(json, 'english'),
      'English example',
      280,
    );
    final targetForm = _validateEnglish(
      _requiredString(json, 'target_form'),
      'Example target form',
      100,
    );
    if (!english.toLowerCase().contains(targetForm.toLowerCase())) {
      throw const WordAiDossierException(
        'The example did not contain its target form.',
        code: 'example.target',
      );
    }
    final register = _requiredString(json, 'register');
    if (!const {'neutral', 'formal', 'informal', 'literary'}
        .contains(register)) {
      throw const WordAiDossierException(
        'WordAI returned an invalid example register.',
        code: 'example.register',
      );
    }
    return WordAiExample(
      english: english,
      simplified: _validateChinese(
        _requiredString(json, 'zh_hans'),
        'Simplified example',
        280,
      ),
      traditional: _validateChinese(
        _requiredString(json, 'zh_hant'),
        'Traditional example',
        280,
      ),
      targetForm: targetForm,
      register: register,
    );
  }

  Map<String, dynamic> toJson() => {
        'english': english,
        'zh_hans': simplified,
        'zh_hant': traditional,
        'target_form': targetForm,
        'register': register,
      };
}

class WordAiInsight {
  const WordAiInsight({
    required this.category,
    required this.senseId,
    required this.textEnglish,
    required this.textSimplified,
    required this.textTraditional,
  });

  static const categories = {
    'meaning',
    'register',
    'context',
    'collocation',
    'confusion',
    'regional',
    'memory',
    'word_formation',
  };

  final String category;
  final String senseId;
  final String textEnglish;
  final String textSimplified;
  final String textTraditional;

  bool get isEncyclopedic => category == 'context' && senseId == 'term';

  static WordAiInsight fromJson(
    Map<String, dynamic> json, {
    required Set<String> senseIds,
  }) {
    _expectExactKeys(
        json,
        const {
          'category',
          'sense_id',
          'text_en',
          'text_zh_hans',
          'text_zh_hant',
        },
        'analysis');
    final category = _requiredString(json, 'category');
    final senseId = _requiredString(json, 'sense_id');
    if (!categories.contains(category) ||
        (senseId != 'term' && !senseIds.contains(senseId))) {
      throw const WordAiDossierException(
        'WordAI returned invalid insight metadata.',
        code: 'analysis.metadata',
      );
    }
    return WordAiInsight(
      category: category,
      senseId: senseId,
      textEnglish: _validateEnglish(
        _requiredString(json, 'text_en'),
        'English insight',
        1200,
      ),
      textSimplified: _validateChinese(
        _requiredString(json, 'text_zh_hans'),
        'Simplified insight',
        1200,
      ),
      textTraditional: _validateChinese(
        _requiredString(json, 'text_zh_hant'),
        'Traditional insight',
        1200,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'category': category,
        'sense_id': senseId,
        'text_en': textEnglish,
        'text_zh_hans': textSimplified,
        'text_zh_hant': textTraditional,
      };
}

bool _hasEncyclopedicDepth(WordAiInsight insight) {
  final englishSentences =
      RegExp(r'[.!?](?:\s|$)').allMatches(insight.textEnglish).length;
  final simplifiedSentences =
      RegExp(r'[。！？]').allMatches(insight.textSimplified).length;
  final traditionalSentences =
      RegExp(r'[。！？]').allMatches(insight.textTraditional).length;
  return insight.textEnglish.length >= 240 &&
      insight.textSimplified.length >= 120 &&
      insight.textTraditional.length >= 120 &&
      englishSentences >= 2 &&
      simplifiedSentences >= 2 &&
      traditionalSentences >= 2;
}

void _expectExactKeys(
  Map<String, dynamic> value,
  Set<String> expected,
  String label,
) {
  if (value.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(value.keys.toSet()).isNotEmpty) {
    throw WordAiDossierException(
      'The $label did not match the strict schema.',
      code: 'schema.keys',
    );
  }
}

String _requiredString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw WordAiDossierException('The $key field was not text.',
        code: 'schema.type');
  }
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> map, String key) =>
    _asMap(map[key], key);

Map<String, dynamic> _asMap(dynamic value, String label) {
  if (value is! Map) {
    throw WordAiDossierException('The $label field was not an object.',
        code: 'schema.type');
  }
  return Map<String, dynamic>.from(value);
}

List<dynamic> _requiredList(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! List) {
    throw WordAiDossierException('The $key field was not an array.',
        code: 'schema.type');
  }
  return value;
}

List<String> _stringList(Map<String, dynamic> map, String key) {
  final values = _requiredList(map, key);
  if (values.any((value) => value is! String)) {
    throw WordAiDossierException('The $key array contained non-text values.');
  }
  return values.cast<String>().toList(growable: false);
}

List<String> _validatedStringList(
  Map<String, dynamic> map,
  String key, {
  required int maximum,
  required String Function(String) validator,
}) {
  final values = _stringList(map, key);
  if (values.isEmpty || values.length > maximum) {
    throw WordAiDossierException('The $key array had an invalid size.');
  }
  final normalized = values.map(validator).toList(growable: false);
  if (normalized.map((value) => value.toLowerCase()).toSet().length !=
      normalized.length) {
    throw WordAiDossierException('The $key array contained duplicates.');
  }
  return normalized;
}

List<String> _validatedOptionalStringList(
  Map<String, dynamic> map,
  String key, {
  required int maximum,
  required String Function(String) validator,
}) {
  final values = _stringList(map, key);
  if (values.length > maximum) {
    throw WordAiDossierException('The $key array had an invalid size.');
  }
  final validated = values.map(validator).toList(growable: false);
  if (validated.map((value) => value.toLowerCase()).toSet().length !=
      validated.length) {
    throw WordAiDossierException('The $key array contained duplicates.');
  }
  return validated;
}

String _validateIntegrity(
  String value, {
  required String label,
  required int maximum,
  bool allowEmpty = false,
}) {
  final text = _decodeDisplayEscapes(value).trim();
  if ((!allowEmpty && text.isEmpty) ||
      text.length > maximum ||
      _hasControl(text) ||
      _hasUnpairedSurrogate(text) ||
      text.contains('\uFFFD') ||
      RegExp(r'Ã[\u0080-\u00BF]|â(?:€|€™|€œ|€“|€”|€¦)|ðŸ|ï¿½').hasMatch(text) ||
      RegExp(r'```|https?://|</?[a-z][^>]*>', caseSensitive: false)
          .hasMatch(text) ||
      _containsEmoji(text)) {
    throw WordAiDossierException(
      '$label contained invalid or damaged text.',
      code: 'text.integrity',
    );
  }
  return text;
}

String _decodeDisplayEscapes(String value) {
  var decoded = value
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\n')
      .replaceAll(r'\t', ' ')
      .replaceAll(r'\f', '\n')
      .replaceAll(r'\b', ' ');
  decoded = decoded.replaceAllMapped(
    RegExp(r'\\u([0-9a-fA-F]{4})'),
    (match) {
      final codePoint = int.parse(match.group(1)!, radix: 16);
      if (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
        return match.group(0)!;
      }
      return String.fromCharCode(codePoint);
    },
  );
  return decoded;
}

String _validateEnglish(String value, String label, int maximum) {
  final text = _validateIntegrity(value, label: label, maximum: maximum);
  if (RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]').hasMatch(text) ||
      !RegExp(r'[A-Za-z]').hasMatch(text)) {
    throw WordAiDossierException('$label was not valid English text.');
  }
  return text;
}

String _validateChinese(String value, String label, int maximum) {
  final text = _validateIntegrity(value, label: label, maximum: maximum);
  final han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]')
      .allMatches(text)
      .length;
  final latin = RegExp(r'[A-Za-z]').allMatches(text).length;
  if (han < 1 || latin > (han * 2).clamp(16, 1 << 30)) {
    throw WordAiDossierException('$label was not valid Chinese text.');
  }
  return text;
}

bool _hasControl(String value) =>
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]')
        .hasMatch(value);

bool _hasUnpairedSurrogate(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (index + 1 >= units.length ||
          units[index + 1] < 0xDC00 ||
          units[index + 1] > 0xDFFF) {
        return true;
      }
      index++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

bool _containsEmoji(String value) => value.runes.any((rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) || (rune >= 0x2600 && rune <= 0x27BF));
