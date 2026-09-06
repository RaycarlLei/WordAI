import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/services/learning_distractor_source.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/wordai_dossier.dart';

void main() {
  sqfliteFfiInit();

  test('progress cloud identity satisfies owner-scoped Firestore rules', () {
    expect(
      LearningRepository.progressCloudIdentity('formal-user', 'target-1'),
      const <String, Object?>{
        'uid': 'formal-user',
        'target_id': 'target-1',
      },
    );
  });

  test(
      'version 2 upgrade preserves progress and sessions while adding questions',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await LearningRepository.createSchema(db);
    final repo = LearningRepository.forTesting(db);
    for (var i = 0; i < 4; i++) {
      await repo.registerDossier('u1', dossier('word$i', i));
    }
    await db.update(
      'learning_progress',
      {
        'stage': LearningStage.contextPassed.value,
        'attempt_count': 7,
        'last_tested_at': 123,
      },
      where: "word = 'word0'",
    );
    final session = (await repo.createSession('u1'))!;
    await db.execute('DROP TABLE review_questions');

    await LearningRepository.upgradeSchema(db, 2, 3);

    final preserved = (await db.query(
      'learning_progress',
      where: "word = 'word0'",
    ))
        .single;
    expect(preserved['stage'], LearningStage.contextPassed.value);
    expect(preserved['attempt_count'], 7);
    expect(preserved['last_tested_at'], 123);
    expect((await repo.sessionById(session.id)).id, session.id);
    expect(await repo.buildQuestion(session, 'en'), isNotNull);
    expect(await db.query('review_questions'), hasLength(1));
  });

  Future<(Database, LearningRepository)> repository({
    Random? random,
    ReviewMeaningLoader? meaningLoader,
  }) async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LearningRepository.createSchema(db);
    return (
      db,
      LearningRepository.forTesting(
        db,
        selectionRandom: random,
        meaningLoader: meaningLoader,
      ),
    );
  }

  test('correct answers advance exactly one stage and wrong answers do not',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    for (var i = 0; i < 4; i++) {
      await repo.registerDossier('u1', dossier('word$i', i));
    }
    var session = (await repo.createSession('u1'))!;
    var question = (await repo.buildQuestion(session, 'en'))!;
    final targetId = question.target.targetId;
    final first = await repo.recordAnswer(
      uid: 'u1',
      session: session,
      question: question,
      selectedIndex: question.correctIndex,
      latencyMs: 200,
      activeMs: 200,
    );
    expect(first.previousStage, LearningStage.unlearned);
    expect(first.newStage, LearningStage.contextPassed);
    expect(
        (await repo.targetById(targetId))!.stage, LearningStage.contextPassed);

    await repo.finishSession(
      uid: 'u1',
      sessionId: session.id,
      completed: false,
      activeMs: 200,
    );
    session = (await repo.createSession('u1'))!;
    question = (await repo.buildQuestion(session, 'en'))!;
    expect(question.target.targetId, targetId);
    expect(question.type, ReviewTestType.independent);
    final wrong = await repo.recordAnswer(
      uid: 'u1',
      session: session,
      question: question,
      selectedIndex: -1,
      latencyMs: 100,
      activeMs: 100,
    );
    expect(wrong.newStage, LearningStage.contextPassed);
  });

  test('a round has at most 20 distinct words with 12 plus 8 allocation',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    for (var i = 0; i < 30; i++) {
      await repo.registerDossier('u1', dossier('word$i', i));
    }
    final rows = await db.query('learning_progress', orderBy: 'word ASC');
    for (final row in rows.take(15)) {
      await db.update(
        'learning_progress',
        {'stage': 1},
        where: 'target_id = ?',
        whereArgs: [row['target_id']],
      );
    }
    final session = (await repo.createSession('u1'))!;
    expect(session.targetIds, hasLength(20));
    final targets = <LearningTarget>[];
    for (final id in session.targetIds) {
      targets.add((await repo.targetById(id))!);
    }
    expect(targets.map((target) => target.lexemeId).toSet(), hasLength(20));
    expect(
      targets.where((target) => target.stage == LearningStage.contextPassed),
      hasLength(12),
    );
    expect(
      targets.where((target) => target.stage == LearningStage.unlearned),
      hasLength(8),
    );
  });

  test('each new round randomly samples from the eligible word pool', () async {
    final (db, repo) = await repository(random: Random(20260827));
    addTearDown(db.close);
    for (var i = 0; i < 60; i++) {
      await repo.registerDossier('u1', dossier('word$i', i));
    }

    final selections = <Set<String>>[];
    for (var round = 0; round < 4; round++) {
      final session = (await repo.createSession('u1'))!;
      final words = <String>{};
      for (final id in session.targetIds) {
        words.add((await repo.targetById(id))!.word);
      }
      selections.add(words);
      await repo.finishSession(
        uid: 'u1',
        sessionId: session.id,
        completed: false,
        activeMs: 0,
      );
    }

    expect(selections.every((selection) => selection.length == 20), isTrue);
    expect(selections.skip(1), everyElement(isNot(equals(selections.first))));
    expect(selections.expand((selection) => selection).toSet().length,
        greaterThan(20));
  });

  test('an answer is durable and the same session position cannot submit twice',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    for (var i = 0; i < 4; i++) {
      await repo.registerDossier('u1', dossier('word$i', i));
    }
    final session = (await repo.createSession('u1'))!;
    final question = (await repo.buildQuestion(session, 'en'))!;
    await repo.recordAnswer(
      uid: 'u1',
      session: session,
      question: question,
      selectedIndex: question.correctIndex,
      latencyMs: 50,
      activeMs: 50,
    );

    final reopened = LearningRepository.forTesting(db);
    final resumed = (await reopened.resumeActiveSession('u1'))!;
    expect(resumed.currentIndex, 1);
    expect(resumed.completedCount, 1);
    await expectLater(
      repo.recordAnswer(
        uid: 'u1',
        session: session,
        question: question,
        selectedIndex: question.correctIndex,
        latencyMs: 50,
        activeMs: 50,
      ),
      throwsStateError,
    );
    final attempts = await db.query('review_attempts');
    expect(attempts, hasLength(1));
  });

  test('word progress reflects every target sense and never skips a stage',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    await repo.registerDossier('u1', dossierWithTwoSenses('lead'));
    for (var i = 0; i < 3; i++) {
      await repo.registerDossier('u1', dossier('distractor$i', i));
    }
    await db.update(
      'learning_progress',
      {'stage': LearningStage.learned.value},
      where: 'word LIKE ?',
      whereArgs: ['distractor%'],
    );

    var session = (await repo.createSession('u1'))!;
    var question = (await repo.buildQuestion(session, 'en'))!;
    final first = await repo.recordAnswer(
      uid: 'u1',
      session: session,
      question: question,
      selectedIndex: question.correctIndex,
      latencyMs: 40,
      activeMs: 40,
    );
    expect(first.wordPassedSenses, 1);
    expect(first.wordTotalSenses, 2);
    await repo.finishSession(
      uid: 'u1',
      sessionId: session.id,
      completed: false,
      activeMs: 40,
    );

    session = (await repo.createSession('u1'))!;
    question = (await repo.buildQuestion(session, 'en'))!;
    expect(question.target.word, 'lead');
    expect(question.type, ReviewTestType.context);
    final second = await repo.recordAnswer(
      uid: 'u1',
      session: session,
      question: question,
      selectedIndex: question.correctIndex,
      latencyMs: 40,
      activeMs: 40,
    );
    expect(second.wordPassedSenses, 2);
    expect(second.wordTotalSenses, 2);
  });

  test('one pending word uses learned device meanings without new progress',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('focus', 0));
    for (var i = 1; i <= 3; i++) {
      await repo.registerDossier('u1', dossier('learned$i', i));
    }
    await db.update(
      'learning_progress',
      {'stage': LearningStage.learned.value, 'learned_once': 1},
      where: "word LIKE 'learned%'",
    );

    final session = (await repo.createSession(
      'u1',
      queries: const <String>['focus'],
    ))!;
    final question = (await repo.buildQuestion(session, 'en'))!;
    expect(question.target.word, 'focus');
    expect(question.options, hasLength(4));
    expect(question.options.toSet(), hasLength(4));
    expect(await db.query('learning_progress'), hasLength(4));
    expect(
      await db.query('learning_progress', where: 'stage = 2'),
      hasLength(3),
    );
  });

  test('device pool rejects same-word, equivalent, empty and wrong-language',
      () async {
    final candidates = <ReviewMeaningCandidate>[
      const ReviewMeaningCandidate(word: 'target', meaning: '其他同词义'),
      const ReviewMeaningCandidate(word: 'equivalent1', meaning: '你好'),
      const ReviewMeaningCandidate(word: 'equivalent2', meaning: '喂；问候'),
      const ReviewMeaningCandidate(word: 'empty', meaning: '   '),
      const ReviewMeaningCandidate(word: 'english', meaning: 'English only'),
      const ReviewMeaningCandidate(word: 'farewell', meaning: '再见'),
      const ReviewMeaningCandidate(word: 'thanks', meaning: '感谢'),
      const ReviewMeaningCandidate(word: 'morning', meaning: '早晨'),
    ];
    final (db, repo) = await repository(
      meaningLoader: ({
        required languageCode,
        required seed,
        required limit,
      }) async =>
          candidates,
    );
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('target', 0));
    await db.update(
      'learning_progress',
      {'meaning_zh_hans': '你好；喂'},
      where: "word = 'target'",
    );

    final session = (await repo.createSession(
      'u1',
      languageCode: 'zh_Hans',
      queries: const <String>['target'],
    ))!;
    final question = (await repo.buildQuestion(session, 'zh_Hans'))!;
    expect(question.options.toSet(),
        containsAll(const <String>{'你好；喂', '再见', '感谢', '早晨'}));
    expect(question.options, isNot(contains('你好')));
    expect(question.options, isNot(contains('喂；问候')));
    expect(await db.query('learning_progress'), hasLength(1));
  });

  test('saved options survive repository restart and source changes', () async {
    var loads = 0;
    final (db, repo) = await repository(
      meaningLoader: ({
        required languageCode,
        required seed,
        required limit,
      }) async {
        loads++;
        return const <ReviewMeaningCandidate>[
          ReviewMeaningCandidate(word: 'one', meaning: 'first meaning'),
          ReviewMeaningCandidate(word: 'two', meaning: 'second meaning'),
          ReviewMeaningCandidate(word: 'three', meaning: 'third meaning'),
        ];
      },
    );
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('focus', 0));
    final session = (await repo.createSession('u1'))!;
    final first = (await repo.buildQuestion(session, 'en'))!;
    expect(loads, 1);

    final reopened = LearningRepository.forTesting(
      db,
      meaningLoader: ({
        required languageCode,
        required seed,
        required limit,
      }) async =>
          const <ReviewMeaningCandidate>[],
    );
    final resumed = (await reopened.resumeActiveSession('u1'))!;
    final restored = (await reopened.buildQuestion(resumed, 'en'))!;
    expect(restored.options, first.options);
    expect(restored.correctIndex, first.correctIndex);
  });

  test('recordAnswer rejects a forged question without changing progress',
      () async {
    final (db, repo) = await repository(
      meaningLoader: ({
        required languageCode,
        required seed,
        required limit,
      }) async =>
          const <ReviewMeaningCandidate>[
        ReviewMeaningCandidate(word: 'one', meaning: 'first meaning'),
        ReviewMeaningCandidate(word: 'two', meaning: 'second meaning'),
        ReviewMeaningCandidate(word: 'three', meaning: 'third meaning'),
      ],
    );
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('focus', 0));
    final session = (await repo.createSession('u1'))!;
    final question = (await repo.buildQuestion(session, 'en'))!;
    final forged = ReviewQuestion(
      target: question.target,
      options: question.options,
      correctIndex: (question.correctIndex + 1) % 4,
      languageCode: question.languageCode,
    );

    await expectLater(
      repo.recordAnswer(
        uid: 'u1',
        session: session,
        question: forged,
        selectedIndex: forged.correctIndex,
        latencyMs: 10,
        activeMs: 10,
      ),
      throwsStateError,
    );
    expect(await db.query('review_attempts'), isEmpty);
    expect((await repo.targetById(question.target.targetId))!.stage,
        LearningStage.unlearned);
  });

  test('regenerated content repairs a target without resetting learning state',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('repair', 0));
    await db.update(
      'learning_progress',
      {
        'stage': LearningStage.contextPassed.value,
        'learned_once': 1,
        'attempt_count': 7,
        'last_tested_at': 12345,
        'definition_en': '',
      },
      where: "word = 'repair'",
    );
    expect(await repo.registeredQueries('u1'), isEmpty);

    expect(await repo.registerDossier('u1', dossier('repair', 9)), 1);
    var row = (await db.query('learning_progress')).single;
    expect(row['stage'], LearningStage.contextPassed.value);
    expect(row['learned_once'], 1);
    expect(row['attempt_count'], 7);
    expect(row['last_tested_at'], 12345);
    expect(row['definition_en'], 'definition number 9');
    expect(await repo.registeredQueries('u1'), contains('repair'));

    await repo.registerDossier(
      'u1',
      dossier(
        'repair',
        10,
        definition: '',
        simplified: const <String>[],
        traditional: const <String>[],
        includeExample: false,
      ),
    );
    row = (await db.query('learning_progress')).single;
    expect(row['definition_en'], 'definition number 9');
    expect(row['meaning_zh_hans'], '释义9');
    expect(row['example_en'], contains('repair'));
    expect(row['attempt_count'], 7);
  });

  test('a damaged pending sense makes the whole query eligible for repair',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('polyseme', 1));
    final complete = (await db.query('learning_progress')).single;
    await db.insert('learning_progress', <String, Object?>{
      ...complete,
      'target_id': 'damaged-second-sense',
      'sense_id': 'verb-2',
      'definition_en': '',
    });

    expect(await repo.registeredQueries('u1'), isEmpty);
    await db.update(
      'learning_progress',
      {'definition_en': 'a repaired second definition'},
      where: 'target_id = ?',
      whereArgs: const <Object?>['damaged-second-sense'],
    );
    expect(await repo.registeredQueries('u1'), contains('polyseme'));
  });

  test('selection skips damaged targets and respects a large query scope',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    for (var i = 0; i < 30; i++) {
      await repo.registerDossier('u1', dossier('bad$i', i));
    }
    await repo.registerDossier('u1', dossier('usable', 99));
    await db.update(
      'learning_progress',
      {'definition_en': ''},
      where: "word LIKE 'bad%'",
    );
    final scope = <String>[
      for (var i = 0; i < 1200; i++) 'missing$i',
      'usable',
    ];

    expect(
      await repo.reviewableWordCount(
        'u1',
        queries: scope,
        requireUsableContent: true,
      ),
      1,
    );
    final session = (await repo.createSession('u1', queries: scope))!;
    expect(session.targetIds, hasLength(1));
    expect((await repo.targetById(session.targetIds.single))!.word, 'usable');
  });

  test('scoped sessions never leak words from another collection', () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('bookA', 1));
    await repo.registerDossier('u1', dossier('bookB', 2));

    final first = (await repo.createSession(
      'u1',
      queries: const <String>['bookA'],
    ))!;
    expect((await repo.targetById(first.targetIds.single))!.word, 'bookA');
    expect(
      await repo.resumeScopedSession('u1', const <String>['bookB']),
      isNull,
    );
    final retired = (await db.query(
      'review_sessions',
      where: 'session_id = ?',
      whereArgs: [first.id],
    ))
        .single;
    expect(retired['exit_reason'], 'scope_changed');
    final second = (await repo.createSession(
      'u1',
      queries: const <String>['bookB'],
    ))!;
    expect((await repo.targetById(second.targetIds.single))!.word, 'bookB');
    expect(await repo.reviewableWordCount('u1', queries: const []), 0);
    await repo.finishSession(
      uid: 'u1',
      sessionId: second.id,
      completed: false,
      activeMs: 0,
    );
    expect(await repo.createSession('u1', queries: const []), isNull);
  });

  test('resume keeps only the newest of concurrent active sessions', () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    await repo.registerDossier('u1', dossier('focus', 0));
    final first = (await repo.createSession('u1'))!;
    final firstRow = (await db.query(
      'review_sessions',
      where: 'session_id = ?',
      whereArgs: [first.id],
    ))
        .single;
    await db.insert('review_sessions', {
      ...firstRow,
      'session_id': 'newer-session',
      'started_at': first.startedAt + 1,
      'updated_at': (firstRow['updated_at'] as int) + 1,
    });

    final resumed = (await repo.resumeActiveSession('u1'))!;
    expect(resumed.id, 'newer-session');
    final old = (await db.query(
      'review_sessions',
      where: 'session_id = ?',
      whereArgs: [first.id],
    ))
        .single;
    expect(old['status'], 'exited');
    expect(old['exit_reason'], 'superseded_session');
  });

  test('same-stage progress merge keeps remote attempts and latest times', () {
    final merged = LearningRepository.mergeProgressState(
      const <String, Object?>{
        'stage': 0,
        'learned_once': 0,
        'attempt_count': 1,
        'context_passed_at': null,
        'learned_at': null,
        'last_tested_at': 100,
        'updated_at': 120,
      },
      const <String, dynamic>{
        'stage': 0,
        'learned_once': false,
        'attempt_count': 3,
        'context_passed_at': null,
        'learned_at': null,
        'last_tested_at': 200,
        'updated_at': 220,
      },
    );
    expect(merged['stage'], 0);
    expect(merged['attempt_count'], 3);
    expect(merged['last_tested_at'], 200);
    expect(merged['updated_at'], 220);
  });

  test('stale session upload cannot roll back a locally recorded answer',
      () async {
    final (db, repo) = await repository();
    addTearDown(db.close);
    for (var i = 0; i < 4; i++) {
      await repo.registerDossier('u1', dossier('word$i', i));
    }
    final session = (await repo.createSession('u1'))!;
    final uploaded = Map<String, Object?>.from((await db.query(
      'review_sessions',
      where: 'session_id = ? AND uid = ?',
      whereArgs: [session.id, 'u1'],
    ))
        .single)
      ..remove('synced_at');
    final question = (await repo.buildQuestion(session, 'en'))!;
    await repo.recordAnswer(
      uid: 'u1',
      session: session,
      question: question,
      selectedIndex: question.correctIndex,
      latencyMs: 10,
      activeMs: 10,
    );

    // Models the create-session upload completing after recordAnswer already
    // advanced the same local row.
    await repo.reconcileSessionUploadForTesting(
      uid: 'u1',
      sessionId: session.id,
      uploaded: uploaded,
      cloudMerged: uploaded,
    );

    final saved = (await db.query(
      'review_sessions',
      where: 'session_id = ? AND uid = ?',
      whereArgs: [session.id, 'u1'],
    ))
        .single;
    expect(saved['current_index'], 1);
    expect(saved['completed_count'], 1);
    expect(saved['synced_at'], isNull);
    final advanced = await repo.sessionById(session.id);
    expect(await repo.buildQuestion(advanced, 'en'), isNotNull);
  });

  test('session merge never revives terminal state or regresses counters', () {
    final merged = LearningRepository.mergeSessionState(
      const <String, Object?>{
        'started_at': 100,
        'ended_at': 300,
        'active_ms': 200,
        'target_count': 4,
        'completed_count': 2,
        'context_passed_count': 1,
        'new_learned_count': 1,
        'current_index': 2,
        'target_ids_json': '["local"]',
        'status': 'completed',
        'exit_reason': 'round_complete',
        'updated_at': 300,
      },
      const <String, Object?>{
        'started_at': 110,
        'active_ms': 50,
        'target_count': 4,
        'completed_count': 0,
        'context_passed_count': 0,
        'new_learned_count': 0,
        'current_index': 0,
        'target_ids_json': '["remote"]',
        'status': 'active',
        'updated_at': 400,
      },
    );
    expect(merged['status'], 'completed');
    expect(merged['exit_reason'], 'round_complete');
    expect(merged['current_index'], 2);
    expect(merged['completed_count'], 2);
    expect(merged['target_ids_json'], '["local"]');
    expect(merged['updated_at'], 400);
  });
}

WordAiDossier dossier(
  String word,
  int index, {
  String? definition,
  List<String>? simplified,
  List<String>? traditional,
  bool includeExample = true,
}) =>
    WordAiDossier(
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
          definitionEnglish: definition ?? 'definition number $index',
          meaningsSimplified: simplified ?? ['释义$index'],
          meaningsTraditional: traditional ?? ['釋義$index'],
          labels: const [],
          examples: includeExample
              ? [
                  WordAiExample(
                    english: 'This sentence contains $word clearly.',
                    simplified: '这个句子包含词$index。',
                    traditional: '這個句子包含詞$index。',
                    targetForm: word,
                    register: 'neutral',
                  ),
                ]
              : const [],
          synonyms: const [],
          antonyms: const [],
          collocations: const [],
        ),
      ],
      lexical: WordAiLexicalInfo.empty,
      analysis: const [],
    );

WordAiDossier dossierWithTwoSenses(String word) => WordAiDossier(
      status: 'ok',
      query: word,
      direction: WordAiQueryDirection.englishToChinese,
      suggestion: '',
      headword: WordAiHeadword(
        english: word,
        simplified: '引导；铅',
        traditional: '引導；鉛',
        ipaUs: '',
        ipaUk: '',
      ),
      senses: const [
        WordAiSense(
          id: 'verb-1',
          partOfSpeech: 'verb',
          equivalentsEnglish: ['lead'],
          definitionEnglish: 'to guide a person or group',
          meaningsSimplified: ['引导'],
          meaningsTraditional: ['引導'],
          labels: [],
          examples: [
            WordAiExample(
              english: 'She will lead the group home.',
              simplified: '她会带领大家回家。',
              traditional: '她會帶領大家回家。',
              targetForm: 'lead',
              register: 'neutral',
            ),
          ],
          synonyms: [],
          antonyms: [],
          collocations: [],
        ),
        WordAiSense(
          id: 'noun-1',
          partOfSpeech: 'noun',
          equivalentsEnglish: ['lead'],
          definitionEnglish: 'a heavy soft metal',
          meaningsSimplified: ['铅'],
          meaningsTraditional: ['鉛'],
          labels: [],
          examples: [
            WordAiExample(
              english: 'The old pipe was made of lead.',
              simplified: '旧管道是铅制的。',
              traditional: '舊管道是鉛製的。',
              targetForm: 'lead',
              register: 'neutral',
            ),
          ],
          synonyms: [],
          antonyms: [],
          collocations: [],
        ),
      ],
      lexical: WordAiLexicalInfo.empty,
      analysis: const [],
    );
