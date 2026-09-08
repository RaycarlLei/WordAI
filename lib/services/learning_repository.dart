import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '/services/learning_distractor_source.dart';
import '/services/wordai_dossier.dart';

enum LearningStage { unlearned, contextPassed, learned }

enum ReviewTestType { context, independent }

extension LearningStageValue on LearningStage {
  int get value => index;

  static LearningStage fromInt(Object? value) {
    final number = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    return LearningStage.values[number.clamp(0, 2)];
  }
}

@immutable
class LearningTarget {
  const LearningTarget({
    required this.targetId,
    required this.lexemeId,
    required this.word,
    required this.query,
    required this.direction,
    required this.senseId,
    required this.partOfSpeech,
    required this.definitionEnglish,
    required this.meaningSimplified,
    required this.meaningTraditional,
    required this.exampleEnglish,
    required this.exampleSimplified,
    required this.exampleTraditional,
    required this.targetForm,
    required this.stage,
    required this.attemptCount,
    required this.lastTestedAt,
    required this.contentVersion,
  });

  final String targetId;
  final String lexemeId;
  final String word;
  final String query;
  final String direction;
  final String senseId;
  final String partOfSpeech;
  final String definitionEnglish;
  final String meaningSimplified;
  final String meaningTraditional;
  final String exampleEnglish;
  final String exampleSimplified;
  final String exampleTraditional;
  final String targetForm;
  final LearningStage stage;
  final int attemptCount;
  final int? lastTestedAt;
  final String contentVersion;

  ReviewTestType get requiredTest => stage == LearningStage.contextPassed
      ? ReviewTestType.independent
      : ReviewTestType.context;

  String meaningFor(String languageCode) {
    if (languageCode == 'zh_Hant') return meaningTraditional;
    if (languageCode.startsWith('zh')) return meaningSimplified;
    return definitionEnglish;
  }

  String exampleTranslationFor(String languageCode) {
    if (languageCode == 'zh_Hant') return exampleTraditional;
    if (languageCode.startsWith('zh')) return exampleSimplified;
    return '';
  }

  factory LearningTarget.fromMap(Map<String, Object?> map) => LearningTarget(
        targetId: map['target_id'] as String,
        lexemeId: map['lexeme_id'] as String,
        word: map['word'] as String,
        query: map['query'] as String,
        direction: map['direction'] as String,
        senseId: map['sense_id'] as String,
        partOfSpeech: map['part_of_speech'] as String,
        definitionEnglish: map['definition_en'] as String,
        meaningSimplified: map['meaning_zh_hans'] as String,
        meaningTraditional: map['meaning_zh_hant'] as String,
        exampleEnglish: map['example_en'] as String,
        exampleSimplified: map['example_zh_hans'] as String,
        exampleTraditional: map['example_zh_hant'] as String,
        targetForm: map['target_form'] as String,
        stage: LearningStageValue.fromInt(map['stage']),
        attemptCount: (map['attempt_count'] as num?)?.toInt() ?? 0,
        lastTestedAt: (map['last_tested_at'] as num?)?.toInt(),
        contentVersion: map['content_version'] as String,
      );
}

@immutable
class ReviewQuestion {
  const ReviewQuestion({
    required this.target,
    required this.options,
    required this.correctIndex,
    required this.languageCode,
  });

  final LearningTarget target;
  final List<String> options;
  final int correctIndex;
  final String languageCode;
  ReviewTestType get type => target.requiredTest;
}

/// The caller must prepare the current question again before submitting.
/// This is distinct from an operational database failure, which is retryable
/// without changing either the question or the session.
class ReviewQuestionChanged extends StateError {
  ReviewQuestionChanged()
      : super('The review question changed. Prepare it again.');
}

@immutable
class ReviewSessionState {
  const ReviewSessionState({
    required this.id,
    required this.targetIds,
    required this.currentIndex,
    required this.startedAt,
    required this.activeMs,
    required this.completedCount,
    required this.contextPassedCount,
    required this.newLearnedCount,
  });

  final String id;
  final List<String> targetIds;
  final int currentIndex;
  final int startedAt;
  final int activeMs;
  final int completedCount;
  final int contextPassedCount;
  final int newLearnedCount;

  bool get isComplete => currentIndex >= targetIds.length;
}

@immutable
class ReviewAnswerResult {
  const ReviewAnswerResult({
    required this.correct,
    required this.previousStage,
    required this.newStage,
    required this.wordPassedSenses,
    required this.wordTotalSenses,
  });

  final bool correct;
  final LearningStage previousStage;
  final LearningStage newStage;
  final int wordPassedSenses;
  final int wordTotalSenses;
}

@immutable
class ReviewSummary {
  const ReviewSummary({
    required this.completed,
    required this.contextPassed,
    required this.newLearned,
    required this.activeMs,
    required this.careerLearned,
  });

  final int completed;
  final int contextPassed;
  final int newLearned;
  final int activeMs;
  final int careerLearned;
}

class LearningRepository {
  LearningRepository._()
      : _selectionRandom = Random.secure(),
        _meaningLoader = _emptyMeaningLoader;

  @visibleForTesting
  LearningRepository.forTesting(
    Database database, {
    Random? selectionRandom,
    ReviewMeaningLoader? meaningLoader,
    bool syncEnabled = false,
  })  : _databaseOverride = database,
        _selectionRandom = selectionRandom ?? Random(0),
        _meaningLoader = meaningLoader ?? _emptyMeaningLoader;

  static final instance = LearningRepository._();
  static const _uuid = Uuid();
  static const _databaseName = 'wordai_learning.db';
  static const _databaseVersion = 4;
  static const _sessionStateFields = <String>[
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
  Database? _database;
  Future<Database>? _openingDatabase;
  Database? _databaseOverride;
  final Random _selectionRandom;
  final ReviewMeaningLoader _meaningLoader;
  final Map<String, Future<List<ReviewMeaningCandidate>>> _meaningPools = {};

  static Future<List<ReviewMeaningCandidate>> _emptyMeaningLoader({
    required String languageCode,
    required int seed,
    required int limit,
  }) async =>
      const <ReviewMeaningCandidate>[];

  Future<Database> get database async {
    if (_databaseOverride != null) return _databaseOverride!;
    if (_database != null) return _database!;
    return _openingDatabase ??= _openDatabase();
  }

  Future<Database> _openDatabase() async {
    try {
      final path = join(await getDatabasesPath(), _databaseName);
      _database = await openDatabase(
        path,
        version: _databaseVersion,
        onCreate: createSchema,
        onUpgrade: upgradeSchema,
        onOpen: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      );
      return _database!;
    } catch (_) {
      _openingDatabase = null;
      rethrow;
    }
  }

  @visibleForTesting
  static Future<void> createSchema(Database db, [int _ = 1]) async {
    await db.execute('''
      CREATE TABLE learning_progress (
        target_id TEXT PRIMARY KEY,
        uid TEXT NOT NULL,
        lexeme_id TEXT NOT NULL,
        word TEXT NOT NULL,
        query TEXT NOT NULL,
        direction TEXT NOT NULL,
        sense_id TEXT NOT NULL,
        part_of_speech TEXT NOT NULL,
        definition_en TEXT NOT NULL,
        meaning_zh_hans TEXT NOT NULL,
        meaning_zh_hant TEXT NOT NULL,
        example_en TEXT NOT NULL,
        example_zh_hans TEXT NOT NULL,
        example_zh_hant TEXT NOT NULL,
        target_form TEXT NOT NULL,
        stage INTEGER NOT NULL DEFAULT 0 CHECK(stage BETWEEN 0 AND 2),
        context_passed_at INTEGER,
        learned_at INTEGER,
        learned_once INTEGER NOT NULL DEFAULT 0,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_tested_at INTEGER,
        content_version TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        synced_at INTEGER,
        UNIQUE(uid, lexeme_id, sense_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX learning_progress_selection '
      'ON learning_progress(uid, stage, last_tested_at)',
    );
    await db.execute('''
      CREATE TABLE review_attempts (
        attempt_id TEXT PRIMARY KEY,
        uid TEXT NOT NULL,
        session_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        test_type TEXT NOT NULL CHECK(test_type IN ('context', 'independent')),
        correct INTEGER NOT NULL,
        latency_ms INTEGER NOT NULL,
        previous_stage INTEGER NOT NULL,
        new_stage INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        synced_at INTEGER,
        FOREIGN KEY(target_id) REFERENCES learning_progress(target_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE review_sessions (
        session_id TEXT PRIMARY KEY,
        uid TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        active_ms INTEGER NOT NULL DEFAULT 0,
        target_count INTEGER NOT NULL,
        completed_count INTEGER NOT NULL DEFAULT 0,
        context_passed_count INTEGER NOT NULL DEFAULT 0,
        new_learned_count INTEGER NOT NULL DEFAULT 0,
        current_index INTEGER NOT NULL DEFAULT 0,
        target_ids_json TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('active', 'completed', 'exited')),
        exit_reason TEXT,
        updated_at INTEGER NOT NULL,
        synced_at INTEGER
      )
    ''');
    await _createReviewQuestionsTable(db);
    await _createSyncStateTable(db);
  }

  @visibleForTesting
  static Future<void> upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) await _createSyncStateTable(db);
    if (oldVersion < 3) {
      await _createReviewQuestionsTable(db);
    } else if (oldVersion < 4) {
      // NULL identifies a legacy snapshot. Its original content cannot be
      // inferred from the current dictionary; rebuild it when next requested.
      await db.execute(
          'ALTER TABLE review_questions ADD COLUMN content_fingerprint TEXT');
    }
  }

  static Future<void> _createReviewQuestionsTable(DatabaseExecutor db) =>
      db.execute('''
        CREATE TABLE IF NOT EXISTS review_questions (
          session_id TEXT NOT NULL,
          target_id TEXT NOT NULL,
          language_code TEXT NOT NULL
            CHECK(language_code IN ('en', 'zh_Hans', 'zh_Hant')),
          options_json TEXT NOT NULL,
          correct_index INTEGER NOT NULL CHECK(correct_index BETWEEN 0 AND 3),
          content_fingerprint TEXT,
          created_at INTEGER NOT NULL,
          PRIMARY KEY(session_id, target_id, language_code),
          FOREIGN KEY(session_id) REFERENCES review_sessions(session_id)
            ON DELETE CASCADE,
          FOREIGN KEY(target_id) REFERENCES learning_progress(target_id)
            ON DELETE CASCADE
        )
      ''');

  static Future<void> _createSyncStateTable(DatabaseExecutor db) =>
      db.execute('''
        CREATE TABLE IF NOT EXISTS learning_sync_state (
          uid TEXT NOT NULL,
          collection_name TEXT NOT NULL,
          last_pull_ms INTEGER NOT NULL,
          PRIMARY KEY(uid, collection_name)
        )
      ''');

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _targetId(
    String uid,
    String lexemeId,
    String senseId,
  ) =>
      _hash('$uid::$lexemeId::$senseId');

  @visibleForTesting
  static Map<String, Object?> progressCloudIdentity(
    String uid,
    String targetId,
  ) =>
      <String, Object?>{
        'uid': uid,
        'target_id': targetId,
      };

  Future<int> registerDossier(String uid, WordAiDossier dossier,
          {bool syncToCloud = true}) =>
      _registerDossier(uid, dossier, updateExisting: true);

  /// Seeds missing meanings without changing existing content or progress.
  /// The existence check and insert share the same transaction.
  Future<int> registerMissingDossier(String uid, WordAiDossier dossier) =>
      _registerDossier(uid, dossier, updateExisting: false);

  Future<int> _registerDossier(String uid, WordAiDossier dossier,
      {required bool updateExisting}) async {
    if (uid.isEmpty || !dossier.isOk || dossier.senses.isEmpty) return 0;
    final db = await database;
    final direction = dossier.direction.wireValue;
    final normalizedQuery = dossier.query.trim();
    final lexemeId = _hash('$direction::${normalizedQuery.toLowerCase()}');
    final incomingWord = dossier.headword.english.trim();
    final word = incomingWord.isNotEmpty ? incomingWord : normalizedQuery;
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = 0;
    final changedTargetIds = <String>[];
    await db.transaction((txn) async {
      for (final sense in dossier.senses) {
        final example = sense.examples.isEmpty ? null : sense.examples.first;
        final targetId = _targetId(uid, lexemeId, sense.id);
        final content = <String, String>{
          'word': incomingWord,
          'query': normalizedQuery,
          'direction': direction,
          'sense_id': sense.id,
          'part_of_speech': sense.partOfSpeech,
          'definition_en': sense.definitionEnglish,
          'meaning_zh_hans': sense.meaningsSimplified.join('；'),
          'meaning_zh_hant': sense.meaningsTraditional.join('；'),
          'example_en': example?.english ?? '',
          'example_zh_hans': example?.simplified ?? '',
          'example_zh_hant': example?.traditional ?? '',
          'target_form': example?.targetForm ?? '',
        };
        final existingRows = await txn.query(
          'learning_progress',
          where: 'target_id = ? AND uid = ?',
          whereArgs: [targetId, uid],
          limit: 1,
        );
        if (existingRows.isEmpty) {
          await txn.insert('learning_progress', <String, Object?>{
            'target_id': targetId,
            'uid': uid,
            'lexeme_id': lexemeId,
            ...content,
            'word': word,
            'target_form': content['target_form']!.trim().isEmpty
                ? word
                : content['target_form'],
            'stage': 0,
            'learned_once': 0,
            'attempt_count': 0,
            'content_version': kWordAiDossierContentRevision,
            'updated_at': now,
          });
          changed++;
          changedTargetIds.add(targetId);
          continue;
        }

        if (!updateExisting) continue;

        // A regenerated dossier repairs stale text in place. Learning state
        // and timestamps are intentionally absent from this update. Empty
        // partial fields also cannot erase already usable local content.
        final existing = existingRows.first;
        final updates = <String, Object?>{};
        for (final entry in content.entries) {
          final incoming = entry.value.trim();
          if (incoming.isEmpty) continue;
          final current = (existing[entry.key] as String? ?? '').trim();
          if (incoming != current) updates[entry.key] = incoming;
        }
        if (existing['content_version'] != kWordAiDossierContentRevision) {
          updates['content_version'] = kWordAiDossierContentRevision;
        }
        if (updates.isEmpty) continue;
        updates['updated_at'] = now;
        updates['synced_at'] = null;
        await txn.update(
          'learning_progress',
          updates,
          where: 'target_id = ? AND uid = ?',
          whereArgs: [targetId, uid],
        );
        changed++;
        changedTargetIds.add(targetId);
      }
    });
    return changed;
  }

  Future<Set<String>> registeredQueries(String uid) async {
    final rows = await (await database).rawQuery('''
      SELECT LOWER(TRIM(query)) AS query
      FROM learning_progress
      WHERE uid = ?
      GROUP BY LOWER(TRIM(query))
      HAVING SUM(CASE WHEN stage < 2 AND (
        TRIM(definition_en) = ''
        OR TRIM(meaning_zh_hans) = ''
        OR TRIM(meaning_zh_hant) = ''
        OR (stage = 0 AND TRIM(example_en) = '')
      ) THEN 1 ELSE 0 END) = 0
    ''', [uid]);
    return rows
        .map((row) => (row['query'] as String).trim().toLowerCase())
        .toSet();
  }

  Future<int> reviewableWordCount(
    String uid, {
    List<String>? queries,
    bool requireUsableContent = false,
    String languageCode = 'en',
  }) async {
    final scope = _normalizedScope(queries);
    if (queries != null && scope!.isEmpty) return 0;
    final contentClause = requireUsableContent
        ? "AND TRIM(${_meaningColumn(languageCode)}) != '' "
            "AND (stage = 1 OR TRIM(example_en) != '')"
        : '';
    final rows = await (await database).rawQuery('''
      SELECT COUNT(DISTINCT lexeme_id) AS count FROM learning_progress
      WHERE uid = ? AND stage < 2
      $contentClause
      ${scope == null ? '' : 'AND LOWER(TRIM(query)) IN (SELECT value FROM json_each(?))'}
    ''', <Object?>[uid, if (scope != null) jsonEncode(scope.toList())]);
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<ReviewSessionState?> resumeActiveSession(String uid) =>
      _resumeActiveSession(uid, null);

  Future<ReviewSessionState?> resumeScopedSession(
    String uid,
    List<String> queries,
  ) =>
      _resumeActiveSession(uid, _normalizedScope(queries)!);

  Future<ReviewSessionState?> _resumeActiveSession(
    String uid,
    Set<String>? scope,
  ) async {
    final db = await database;
    final rows = await db.query(
      'review_sessions',
      where: 'uid = ? AND status = ?',
      whereArgs: [uid, 'active'],
      orderBy: 'updated_at DESC, started_at DESC, session_id DESC',
    );
    ReviewSessionState? selected;
    for (final row in rows) {
      late ReviewSessionState session;
      try {
        session = _sessionFromMap(row);
      } catch (error, stack) {
        // Preserve answers and original payload for diagnostics; retire only
        // this unusable session so Retry can create a healthy round.
        await _retireSession(
          db,
          uid,
          row['session_id'] as String,
          'invalid_session',
        );
        _reportSyncError('learning.invalidSession',
            const FormatException('Invalid saved review session'), stack);
        continue;
      }
      // Only decoding can establish that a payload is invalid. A failed read
      // or retirement write must propagate, leaving a valid round retryable.
      if (scope != null && !await _sessionMatchesScope(db, session, scope)) {
        await _retireSession(db, uid, session.id, 'scope_changed');
        continue;
      }
      if (selected == null) {
        selected = session;
      } else {
        await _retireSession(db, uid, session.id, 'superseded_session');
      }
    }
    return selected;
  }

  Future<bool> _sessionMatchesScope(
    DatabaseExecutor db,
    ReviewSessionState session,
    Set<String> scope,
  ) async {
    if (scope.isEmpty) return false;
    final rows = await db.query(
      'learning_progress',
      columns: const <String>['target_id', 'query'],
      where:
          'target_id IN (${List.filled(session.targetIds.length, '?').join(',')})',
      whereArgs: session.targetIds,
    );
    if (rows.length != session.targetIds.length) return false;
    final byId = <String, String>{
      for (final row in rows)
        row['target_id'] as String:
            (row['query'] as String).trim().toLowerCase(),
    };
    return session.targetIds.every((id) => scope.contains(byId[id]));
  }

  Future<void> _retireSession(
    DatabaseExecutor db,
    String uid,
    String sessionId,
    String reason,
  ) async {
    await db.update(
      'review_sessions',
      {
        'status': 'exited',
        'exit_reason': reason,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'synced_at': null,
      },
      where: 'session_id = ? AND uid = ? AND status = ?',
      whereArgs: [sessionId, uid, 'active'],
    );
    _meaningPools.removeWhere((key, _) => key.startsWith('$sessionId:'));
  }

  Future<ReviewSessionState?> createSession(
    String uid, {
    int maximum = 20,
    String languageCode = 'en',
    List<String>? queries,
  }) async {
    final scope = _normalizedScope(queries);
    if (queries != null && scope!.isEmpty) return null;
    final active = scope == null
        ? await resumeActiveSession(uid)
        : await _resumeActiveSession(uid, scope);
    if (active != null) return active;
    final selected = await _selectTargets(
      uid,
      maximum.clamp(1, 20),
      languageCode,
      scope,
    );
    if (selected.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    final targetIds = selected.map((target) => target.targetId).toList();
    final db = await database;
    await db.insert('review_sessions', {
      'session_id': id,
      'uid': uid,
      'started_at': now,
      'active_ms': 0,
      'target_count': targetIds.length,
      'completed_count': 0,
      'context_passed_count': 0,
      'new_learned_count': 0,
      'current_index': 0,
      'target_ids_json': jsonEncode(targetIds),
      'status': 'active',
      'updated_at': now,
    });
    final session = ReviewSessionState(
      id: id,
      targetIds: targetIds,
      currentIndex: 0,
      startedAt: now,
      activeMs: 0,
      completedCount: 0,
      contextPassedCount: 0,
      newLearnedCount: 0,
    );
    return session;
  }

  Future<List<LearningTarget>> _selectTargets(
    String uid,
    int maximum,
    String languageCode,
    Set<String>? scope,
  ) async {
    final db = await database;
    final column = _meaningColumn(languageCode);
    // Only IDs/stages cross the native bridge for the full collection, not
    // every definition and example. Hydrate at most 20 selected targets.
    final rows = await db.rawQuery('''
      WITH ranked AS (
        SELECT target_id, stage, ROW_NUMBER() OVER (
          PARTITION BY lexeme_id ORDER BY stage, COALESCE(last_tested_at, 0),
          updated_at, target_id
        ) AS position
        FROM learning_progress WHERE uid = ? AND stage < 2
          AND TRIM($column) != ''
          AND (stage = 1 OR TRIM(example_en) != '')
          ${scope == null ? '' : 'AND LOWER(TRIM(query)) IN (SELECT value FROM json_each(?))'}
      ) SELECT target_id, stage FROM ranked WHERE position = 1
    ''', <Object?>[uid, if (scope != null) jsonEncode(scope.toList())]);
    final unlearned = rows.where((row) => row['stage'] == 0).toList();
    final contextPassed = rows.where((row) => row['stage'] == 1).toList();

    // Randomize each stage pool for every new round while retaining the
    // product's 12 context-passed / 8 unlearned allocation. Active rounds are
    // not reshuffled because their selected target IDs are persisted.
    contextPassed.shuffle(_selectionRandom);
    unlearned.shuffle(_selectionRandom);

    final result = <Map<String, Object?>>[];
    final contextQuota = min(12, maximum);
    result.addAll(contextPassed.take(contextQuota));
    final unlearnedQuota = min(8, maximum - result.length);
    result.addAll(unlearned.take(unlearnedQuota));
    if (result.length < maximum) {
      result.addAll(
          contextPassed.skip(contextQuota).take(maximum - result.length));
    }
    if (result.length < maximum) {
      result
          .addAll(unlearned.skip(unlearnedQuota).take(maximum - result.length));
    }
    final targets = <LearningTarget>[];
    for (final row in result) {
      final target = await targetById(row['target_id'] as String);
      if (target != null) targets.add(target);
    }
    return targets;
  }

  static Set<String>? _normalizedScope(Iterable<String>? queries) {
    if (queries == null) return null;
    return queries
        .map((query) => query.trim().toLowerCase())
        .where((query) => query.isNotEmpty)
        .toSet();
  }

  static String _meaningColumn(String languageCode) => languageCode == 'zh_Hant'
      ? 'meaning_zh_hant'
      : languageCode.startsWith('zh')
          ? 'meaning_zh_hans'
          : 'definition_en';

  Future<LearningTarget?> targetById(String targetId) async {
    final rows = await (await database).query(
      'learning_progress',
      where: 'target_id = ?',
      whereArgs: [targetId],
      limit: 1,
    );
    return rows.isEmpty ? null : LearningTarget.fromMap(rows.first);
  }

  Future<ReviewQuestion?> buildQuestion(
    ReviewSessionState session,
    String languageCode,
  ) async {
    if (session.isComplete || session.currentIndex < 0) return null;
    final db = await database;
    final language = _reviewLanguage(languageCode);
    final prepared = await db
        .transaction<({LearningTarget? target, ReviewQuestion? saved})>(
            (txn) async {
      final target = await _currentQuestionTarget(txn, session);
      if (target == null ||
          target.stage == LearningStage.learned ||
          !_isMeaningValid(
              _cleanMeaning(target.meaningFor(language)), language) ||
          (target.requiredTest == ReviewTestType.context &&
              target.exampleEnglish.trim().isEmpty)) {
        return (target: null, saved: null);
      }
      // Read the target and its saved choices in one SQLite snapshot. Reopening
      // a round does not depend on the current distractor pool or a network call.
      final saved = await _readQuestionSnapshot(txn,
          sessionId: session.id, target: target, languageCode: language);
      return (target: target, saved: saved);
    });
    final target = prepared.target;
    if (target == null) return null;
    if (prepared.saved != null) return prepared.saved;
    final correct = _cleanMeaning(target.meaningFor(language));
    final seed = int.parse(
      _hash('${session.id}:${target.targetId}:$language').substring(0, 8),
      radix: 16,
    );
    final localCandidates = await _learningMeaningCandidates(
      target,
      language,
      seed,
    );
    final poolKey = '${session.id}:$language';
    final deviceCandidates =
        await (_meaningPools[poolKey] ??= _loadMeaningPool(language, seed));
    final distractors = _selectDistractors(
      target: target,
      correct: correct,
      languageCode: language,
      candidates: <ReviewMeaningCandidate>[
        ...localCandidates,
        ...deviceCandidates,
      ],
      seed: seed,
    );
    return db.transaction<ReviewQuestion?>((txn) async {
      final current = await _currentQuestionTarget(txn, session);
      if (current == null) return null;
      if (_questionContent(current, language) !=
          _questionContent(target, language)) {
        // Do not report an unavailable target: that would cause the caller to
        // skip it. Preparation may be retried using the newly imported content.
        throw ReviewQuestionChanged();
      }
      final saved = await _readQuestionSnapshot(txn,
          sessionId: session.id, target: current, languageCode: language);
      if (saved != null) return saved;
      if (distractors.length < 3) return null;
      final options = distractors.toList(growable: true);
      final correctIndex = Random(seed).nextInt(4);
      options.insert(correctIndex, correct);
      final question = ReviewQuestion(
        target: current,
        options: List<String>.unmodifiable(options),
        correctIndex: correctIndex,
        languageCode: language,
      );
      await txn.insert(
        'review_questions',
        {
          'session_id': session.id,
          'target_id': target.targetId,
          'language_code': language,
          'options_json': jsonEncode(options),
          'correct_index': correctIndex,
          'content_fingerprint': _questionFingerprint(question),
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
      );
      return question;
    });
  }

  Future<LearningTarget?> _currentQuestionTarget(
      DatabaseExecutor db, ReviewSessionState session) async {
    final rows = await db.query(
      'review_sessions',
      where: 'session_id = ? AND status = ?',
      whereArgs: [session.id, 'active'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final saved = _sessionFromMap(rows.first);
    if (saved.currentIndex != session.currentIndex ||
        !listEquals(saved.targetIds, session.targetIds) ||
        saved.isComplete) {
      return null;
    }
    final targets = await db.query(
      'learning_progress',
      where: 'target_id = ? AND uid = ?',
      whereArgs: [saved.targetIds[saved.currentIndex], rows.first['uid']],
      limit: 1,
    );
    return targets.isEmpty ? null : LearningTarget.fromMap(targets.first);
  }

  Future<List<ReviewMeaningCandidate>> _loadMeaningPool(
    String languageCode,
    int seed,
  ) async {
    try {
      return await _meaningLoader(
        languageCode: languageCode,
        seed: seed,
        limit: 80,
      );
    } catch (error, stack) {
      _reportSyncError('learning.loadDistractors', error, stack);
      return const <ReviewMeaningCandidate>[];
    }
  }

  Future<List<ReviewMeaningCandidate>> _learningMeaningCandidates(
    LearningTarget target,
    String languageCode,
    int seed,
  ) async {
    final db = await database;
    final column = _meaningColumn(languageCode);
    final pivot = _hash('review-meaning:$seed');
    Future<List<Map<String, Object?>>> read(String comparison, int limit) =>
        db.rawQuery('''
          SELECT word, TRIM($column) AS meaning, part_of_speech
          FROM learning_progress
          WHERE target_id $comparison ? AND target_id != ? AND lexeme_id != ?
            AND TRIM($column) != ''
          ORDER BY target_id
          LIMIT ?
        ''', <Object?>[pivot, target.targetId, target.lexemeId, limit]);
    final first = await read('>=', 64);
    final rows = first.length >= 64
        ? first
        : <Map<String, Object?>>[
            ...first,
            ...await read('<', 64 - first.length),
          ];
    return rows
        .map((row) => ReviewMeaningCandidate(
              word: row['word'] as String,
              meaning: row['meaning'] as String,
              partOfSpeech: row['part_of_speech'] as String? ?? '',
            ))
        .toList(growable: false);
  }

  List<String> _selectDistractors({
    required LearningTarget target,
    required String correct,
    required String languageCode,
    required List<ReviewMeaningCandidate> candidates,
    required int seed,
  }) {
    final random = Random(seed ^ 0x5f3759df);
    final preferred = candidates
        .where((item) => item.partOfSpeech == target.partOfSpeech)
        .toList()
      ..shuffle(random);
    final remaining = candidates
        .where((item) => item.partOfSpeech != target.partOfSpeech)
        .toList()
      ..shuffle(random);
    final excludedWords = <String>{
      _normalizeWord(target.word),
      _normalizeWord(target.query),
    };
    final usedWords = <String>{};
    final usedAnswers = _answerParts(correct);
    final result = <String>[];
    for (final candidate in <ReviewMeaningCandidate>[
      ...preferred,
      ...remaining,
    ]) {
      final word = _normalizeWord(candidate.word);
      final meaning = _cleanMeaning(candidate.meaning);
      if (word.isEmpty ||
          excludedWords.contains(word) ||
          usedWords.contains(word) ||
          !_isMeaningValid(meaning, languageCode)) {
        continue;
      }
      final parts = _answerParts(meaning);
      if (parts.isEmpty || parts.any(usedAnswers.contains)) continue;
      usedWords.add(word);
      usedAnswers.addAll(parts);
      result.add(meaning);
      if (result.length == 3) break;
    }
    return result;
  }

  Future<ReviewQuestion?> _readQuestionSnapshot(
    DatabaseExecutor db, {
    required String sessionId,
    required LearningTarget target,
    required String languageCode,
  }) async {
    final rows = await db.query(
      'review_questions',
      where: 'session_id = ? AND target_id = ? AND language_code = ?',
      whereArgs: [sessionId, target.targetId, languageCode],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final decoded = jsonDecode(rows.first['options_json'] as String);
      final correctIndex = (rows.first['correct_index'] as num).toInt();
      if (decoded is! List ||
          decoded.length != 4 ||
          decoded.any((item) => item is! String) ||
          correctIndex < 0 ||
          correctIndex >= decoded.length) {
        throw const FormatException('Invalid saved review question');
      }
      final options = decoded.cast<String>();
      if (options.toSet().length != 4 ||
          options.map(_answerSignature).toSet().length != 4 ||
          _cleanMeaning(options[correctIndex]) !=
              _cleanMeaning(target.meaningFor(languageCode))) {
        throw const FormatException('Stale saved review question');
      }
      final question = ReviewQuestion(
        target: target,
        options: List<String>.unmodifiable(options),
        correctIndex: correctIndex,
        languageCode: languageCode,
      );
      if (rows.first['content_fingerprint'] != _questionFingerprint(question)) {
        throw const FormatException('Unbound or stale saved review question');
      }
      return question;
    } on Object {
      await db.delete(
        'review_questions',
        where: 'session_id = ? AND target_id = ? AND language_code = ?',
        whereArgs: [sessionId, target.targetId, languageCode],
      );
      return null;
    }
  }

  // Versioned, finite dependencies of the displayed question and its answer.
  // Other locales, unused translations, progress counters, global revisions,
  // and the live distractor pool are deliberately not part of this identity.
  static String _questionContent(LearningTarget target, String languageCode) =>
      jsonEncode([
        'review-content-v1',
        target.targetId,
        target.stage.value,
        languageCode,
        target.word,
        target.partOfSpeech,
        _cleanMeaning(target.meaningFor(languageCode)),
        if (target.requiredTest == ReviewTestType.context) ...[
          target.exampleEnglish,
          target.targetForm,
        ],
      ]);

  static String _questionFingerprint(ReviewQuestion question,
          {LearningTarget? target}) =>
      _hash(jsonEncode([
        _questionContent(target ?? question.target, question.languageCode),
        question.options,
        question.correctIndex,
      ]));

  static String _reviewLanguage(String languageCode) {
    if (languageCode == 'zh_Hant') return 'zh_Hant';
    if (languageCode.startsWith('zh')) return 'zh_Hans';
    return 'en';
  }

  static String _cleanMeaning(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _normalizeWord(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static Set<String> _answerParts(String value) {
    final normalized = _cleanMeaning(value).toLowerCase();
    if (normalized.isEmpty) return <String>{};
    return <String>{
      for (final part in <String>[
        normalized,
        ...normalized.split(RegExp(r'[；;、/|]+')),
      ])
        if (_answerSignature(part).isNotEmpty) _answerSignature(part),
    };
  }

  static String _answerSignature(String value) => _cleanMeaning(value)
      .toLowerCase()
      .replaceAll(RegExp(r'''^[\s"“”‘’'()（）\[\]]+'''), '')
      .replaceAll(RegExp(r'''[\s"“”‘’'()（）\[\].,!?:;。！？：；，]+$'''), '');

  static bool _isMeaningValid(String value, String languageCode) {
    if (value.isEmpty ||
        value.length > 420 ||
        value.startsWith('{') ||
        value.startsWith('[') ||
        value.toUpperCase().startsWith('ERROR:') ||
        RegExp(r'```|https?://|</?[a-z][^>]*>', caseSensitive: false)
            .hasMatch(value) ||
        RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]')
            .hasMatch(value)) {
      return false;
    }
    final hasHan = RegExp(r'[\u3400-\u9FFF]').hasMatch(value);
    return languageCode.startsWith('zh')
        ? hasHan
        : !hasHan && RegExp(r'[A-Za-z]').hasMatch(value);
  }

  Future<ReviewAnswerResult> recordAnswer({
    required String uid,
    required ReviewSessionState session,
    required ReviewQuestion question,
    required int selectedIndex,
    required int latencyMs,
    required int activeMs,
  }) async {
    if (selectedIndex < -1 || selectedIndex >= question.options.length) {
      throw ArgumentError.value(selectedIndex, 'selectedIndex');
    }
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final attemptId = _uuid.v4();
    late LearningStage previous;
    late LearningStage next;
    late int passed;
    late int total;
    late bool correct;

    await db.transaction((txn) async {
      final sessionRows = await txn.query(
        'review_sessions',
        where: 'session_id = ? AND uid = ? AND status = ?',
        whereArgs: [session.id, uid, 'active'],
        limit: 1,
      );
      if (sessionRows.isEmpty) {
        throw StateError('Review session is no longer active.');
      }
      final persistedSession = sessionRows.first;
      final persistedIndex =
          (persistedSession['current_index'] as num?)?.toInt() ?? 0;
      final persistedTargets =
          jsonDecode(persistedSession['target_ids_json'] as String);
      if (persistedIndex != session.currentIndex ||
          persistedTargets is! List ||
          persistedIndex >= persistedTargets.length ||
          persistedTargets[persistedIndex].toString() !=
              question.target.targetId) {
        throw StateError('This review answer was already handled.');
      }
      final questionRows = await txn.query(
        'review_questions',
        columns: const <String>[
          'options_json',
          'correct_index',
          'content_fingerprint'
        ],
        where: 'session_id = ? AND target_id = ? AND language_code = ?',
        whereArgs: [
          session.id,
          question.target.targetId,
          question.languageCode,
        ],
        limit: 1,
      );
      if (questionRows.isEmpty) {
        throw ReviewQuestionChanged();
      }
      final Object? persistedOptions;
      try {
        persistedOptions =
            jsonDecode(questionRows.first['options_json'] as String);
      } on FormatException {
        throw ReviewQuestionChanged();
      }
      final persistedCorrect =
          (questionRows.first['correct_index'] as num?)?.toInt() ?? -1;
      if (persistedOptions is! List ||
          persistedOptions.length != 4 ||
          persistedOptions.any((item) => item is! String) ||
          !listEquals(persistedOptions.cast<String>(), question.options) ||
          persistedCorrect != question.correctIndex ||
          persistedCorrect < 0 ||
          persistedCorrect >= persistedOptions.length) {
        throw ReviewQuestionChanged();
      }
      correct = selectedIndex == persistedCorrect;
      final progressRows = await txn.query(
        'learning_progress',
        where: 'target_id = ? AND uid = ?',
        whereArgs: [question.target.targetId, uid],
        limit: 1,
      );
      if (progressRows.isEmpty) throw StateError('Learning target is missing.');
      final current = LearningTarget.fromMap(progressRows.first);
      final fingerprint = questionRows.first['content_fingerprint'];
      if (fingerprint != _questionFingerprint(question) ||
          fingerprint != _questionFingerprint(question, target: current)) {
        // Validation and the answer's writes share one transaction. Reimports
        // preserve earned progress but cannot credit this obsolete question.
        throw ReviewQuestionChanged();
      }
      previous = LearningStageValue.fromInt(progressRows.first['stage']);
      if (previous == LearningStage.learned) {
        throw StateError(
            'A learned target cannot be tested in a normal round.');
      }
      final expected = previous == LearningStage.unlearned
          ? ReviewTestType.context
          : ReviewTestType.independent;
      if (expected != question.type) {
        throw StateError('Learning stages cannot be skipped.');
      }
      next =
          correct ? LearningStage.values[min(previous.value + 1, 2)] : previous;
      await txn.update(
        'learning_progress',
        {
          'stage': next.value,
          'context_passed_at': correct && next == LearningStage.contextPassed
              ? now
              : progressRows.first['context_passed_at'],
          'learned_at': correct && next == LearningStage.learned
              ? now
              : progressRows.first['learned_at'],
          'learned_once': next == LearningStage.learned
              ? 1
              : progressRows.first['learned_once'],
          'attempt_count':
              ((progressRows.first['attempt_count'] as num?)?.toInt() ?? 0) + 1,
          'last_tested_at': now,
          'updated_at': now,
          'synced_at': null,
        },
        where: 'target_id = ?',
        whereArgs: [question.target.targetId],
      );
      await txn.insert('review_attempts', {
        'attempt_id': attemptId,
        'uid': uid,
        'session_id': session.id,
        'target_id': question.target.targetId,
        'test_type': expected.name,
        'correct': correct ? 1 : 0,
        'latency_ms': latencyMs.clamp(0, 3600000),
        'previous_stage': previous.value,
        'new_stage': next.value,
        'created_at': now,
      });
      final completed =
          ((persistedSession['completed_count'] as num?)?.toInt() ?? 0) + 1;
      final contextPasses =
          ((persistedSession['context_passed_count'] as num?)?.toInt() ?? 0) +
              (correct && next == LearningStage.contextPassed ? 1 : 0);
      final learned =
          ((persistedSession['new_learned_count'] as num?)?.toInt() ?? 0) +
              (correct && next == LearningStage.learned ? 1 : 0);
      await txn.update(
        'review_sessions',
        {
          'active_ms': activeMs.clamp(0, 24 * 60 * 60 * 1000),
          'completed_count': completed,
          'context_passed_count': contextPasses,
          'new_learned_count': learned,
          'current_index': persistedIndex + 1,
          'updated_at': now,
          'synced_at': null,
        },
        where: 'session_id = ? AND uid = ? AND status = ?',
        whereArgs: [session.id, uid, 'active'],
      );
      final senseRows = await txn.query(
        'learning_progress',
        columns: ['stage'],
        where: 'uid = ? AND lexeme_id = ?',
        whereArgs: [uid, progressRows.first['lexeme_id']],
      );
      total = senseRows.length;
      final threshold = min(previous.value + 1, LearningStage.learned.value);
      passed = senseRows
          .where((row) =>
              LearningStageValue.fromInt(row['stage']).value >= threshold)
          .length;
    });

    return ReviewAnswerResult(
      correct: correct,
      previousStage: previous,
      newStage: next,
      wordPassedSenses: passed,
      wordTotalSenses: total,
    );
  }

  Future<ReviewSessionState> sessionById(String sessionId) async {
    final rows = await (await database).query(
      'review_sessions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Review session is missing.');
    return _sessionFromMap(rows.first);
  }

  /// Advances past a target that cannot form a trustworthy four-option
  /// question. It is not counted as an attempt and never changes progress.
  Future<ReviewSessionState> skipUnavailableTarget(
    String uid,
    ReviewSessionState session,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await database;
    await db.transaction((txn) async {
      final changed = await txn.update(
        'review_sessions',
        {
          'current_index': session.currentIndex + 1,
          'updated_at': now,
          'synced_at': null,
        },
        where:
            'session_id = ? AND uid = ? AND status = ? AND current_index = ?',
        whereArgs: [session.id, uid, 'active', session.currentIndex],
      );
      if (changed != 1) {
        throw StateError('Review target was already advanced.');
      }
      if (session.currentIndex < session.targetIds.length) {
        await txn.update(
          'learning_progress',
          {'last_tested_at': now, 'updated_at': now, 'synced_at': null},
          where: 'target_id = ? AND uid = ?',
          whereArgs: [session.targetIds[session.currentIndex], uid],
        );
      }
    });
    return sessionById(session.id);
  }

  ReviewSessionState _sessionFromMap(Map<String, Object?> map) {
    final decoded = jsonDecode(map['target_ids_json'] as String);
    final index = (map['current_index'] as num?)?.toInt() ?? 0;
    if (decoded is! List ||
        decoded.isEmpty ||
        decoded.length > 20 ||
        decoded.any((item) => item is! String || item.trim().isEmpty) ||
        decoded.toSet().length != decoded.length ||
        index < 0 ||
        index > decoded.length) {
      throw const FormatException('Invalid saved review session');
    }
    return ReviewSessionState(
      id: map['session_id'] as String,
      targetIds: decoded.cast<String>(),
      currentIndex: index,
      startedAt: (map['started_at'] as num).toInt(),
      activeMs: (map['active_ms'] as num?)?.toInt() ?? 0,
      completedCount: (map['completed_count'] as num?)?.toInt() ?? 0,
      contextPassedCount: (map['context_passed_count'] as num?)?.toInt() ?? 0,
      newLearnedCount: (map['new_learned_count'] as num?)?.toInt() ?? 0,
    );
  }

  Future<ReviewSummary> finishSession({
    required String uid,
    required String sessionId,
    required bool completed,
    required int activeMs,
    String exitReason = 'user_exit',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await database;
    await db.update(
      'review_sessions',
      {
        'ended_at': now,
        'active_ms': activeMs,
        'status': completed ? 'completed' : 'exited',
        'exit_reason': completed ? 'round_complete' : exitReason,
        'updated_at': now,
        'synced_at': null,
      },
      where: 'session_id = ? AND uid = ?',
      whereArgs: [sessionId, uid],
    );
    final session = await sessionById(sessionId);
    final career = await careerLearnedCount(uid);
    _meaningPools.removeWhere((key, _) => key.startsWith('$sessionId:'));
    return ReviewSummary(
      completed: session.completedCount,
      contextPassed: session.contextPassedCount,
      newLearned: session.newLearnedCount,
      activeMs: activeMs,
      careerLearned: career,
    );
  }

  Future<int> careerLearnedCount(String uid) async {
    final rows = await (await database).rawQuery(
      'SELECT COUNT(DISTINCT lexeme_id) AS count FROM learning_progress '
      'WHERE uid = ? AND learned_once = 1',
      [uid],
    );
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> syncFromCloud(String uid) async {}
  void _reportSyncError(String operation, Object error, StackTrace stack) {
    debugPrint('$operation: ${error.runtimeType}');
  }

  @visibleForTesting
  static Map<String, Object?> mergeProgressState(
    Map<String, Object?> local,
    Map<String, dynamic> remote,
  ) {
    int integer(Object? value) => value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    int? latestTime(String key) {
      final localValue = _firestoreMillis(local[key]);
      final remoteValue = _firestoreMillis(remote[key]);
      if (localValue == null) return remoteValue;
      if (remoteValue == null) return localValue;
      return max(localValue, remoteValue);
    }

    final stage = max(
      LearningStageValue.fromInt(local['stage']).value,
      LearningStageValue.fromInt(remote['stage']).value,
    );
    final learnedOnce = stage == LearningStage.learned.value ||
        local['learned_once'] == 1 ||
        local['learned_once'] == true ||
        remote['learned_once'] == 1 ||
        remote['learned_once'] == true;
    return <String, Object?>{
      'stage': stage,
      'learned_once': learnedOnce ? 1 : 0,
      'attempt_count': max(
          integer(local['attempt_count']), integer(remote['attempt_count'])),
      'context_passed_at': latestTime('context_passed_at'),
      'learned_at': latestTime('learned_at'),
      'last_tested_at': latestTime('last_tested_at'),
      'updated_at': max(
        _firestoreMillis(local['updated_at']) ?? 0,
        _firestoreMillis(remote['updated_at']) ?? 0,
      ),
    };
  }

  @visibleForTesting
  static Map<String, Object?> mergeSessionState(
    Map<String, Object?> local,
    Map<String, Object?> remote,
  ) {
    int integer(Object? value) => value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
    int? latestTime(String key) {
      final localValue = _firestoreMillis(local[key]);
      final remoteValue = _firestoreMillis(remote[key]);
      if (localValue == null) return remoteValue;
      if (remoteValue == null) return localValue;
      return max(localValue, remoteValue);
    }

    int earliestStart() {
      final localValue = _firestoreMillis(local['started_at']) ?? 0;
      final remoteValue = _firestoreMillis(remote['started_at']) ?? 0;
      if (localValue == 0) return remoteValue;
      if (remoteValue == 0) return localValue;
      return min(localValue, remoteValue);
    }

    String status(Object? value, String fallback) =>
        const {'active', 'exited', 'completed'}.contains(value)
            ? value! as String
            : value == null
                ? fallback
                : 'exited';
    const statusRank = {'active': 0, 'exited': 1, 'completed': 2};
    final localStatus = status(local['status'], 'active');
    final remoteStatus = status(remote['status'], localStatus);
    final remoteWins =
        (statusRank[remoteStatus] ?? 0) > (statusRank[localStatus] ?? 0) ||
            (remoteStatus == localStatus &&
                (_firestoreMillis(remote['updated_at']) ?? 0) >
                    (_firestoreMillis(local['updated_at']) ?? 0));
    final mergedStatus = remoteWins ? remoteStatus : localStatus;
    final localTargets = (local['target_ids_json'] ?? '').toString().trim();
    final remoteTargets = (remote['target_ids_json'] ?? '').toString().trim();

    return <String, Object?>{
      'started_at': earliestStart(),
      'ended_at': latestTime('ended_at'),
      for (final key in const [
        'active_ms',
        'target_count',
        'completed_count',
        'context_passed_count',
        'new_learned_count',
        'current_index',
      ])
        key: max(integer(local[key]), integer(remote[key])),
      // A session's selected targets are immutable. Prefer the local copy so
      // a stale or malformed cloud payload cannot replace the active round.
      'target_ids_json': localTargets.isNotEmpty && localTargets != '[]'
          ? localTargets
          : remoteTargets,
      'status': mergedStatus,
      'exit_reason': mergedStatus == 'active'
          ? null
          : (remoteWins ? remote['exit_reason'] : local['exit_reason']),
      'updated_at': max(
        _firestoreMillis(local['updated_at']) ?? 0,
        _firestoreMillis(remote['updated_at']) ?? 0,
      ),
    };
  }

  static int? _firestoreMillis(Object? value) => switch (value) {
        DateTime timestamp => timestamp.millisecondsSinceEpoch,
        num number => number.toInt(),
        _ => null,
      };

  Future<void> _reconcileSessionUpload({
    required Database db,
    required String uid,
    required String sessionId,
    required Map<String, Object?> uploaded,
    required Map<String, Object?> cloudMerged,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'review_sessions',
        where: 'session_id = ? AND uid = ?',
        whereArgs: [sessionId, uid],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final current = rows.first;
      final reconciled = mergeSessionState(current, cloudMerged);
      final unchangedSinceUpload = _sessionStateFields.every(
        (key) => current[key] == uploaded[key],
      );
      await txn.update(
        'review_sessions',
        {
          ...reconciled,
          'synced_at': unchangedSinceUpload
              ? DateTime.now().millisecondsSinceEpoch
              : null,
        },
        where: 'session_id = ? AND uid = ?',
        whereArgs: [sessionId, uid],
      );
    });
  }

  @visibleForTesting
  Future<void> reconcileSessionUploadForTesting({
    required String uid,
    required String sessionId,
    required Map<String, Object?> uploaded,
    required Map<String, Object?> cloudMerged,
  }) async =>
      _reconcileSessionUpload(
        db: await database,
        uid: uid,
        sessionId: sessionId,
        uploaded: uploaded,
        cloudMerged: cloudMerged,
      );
}
