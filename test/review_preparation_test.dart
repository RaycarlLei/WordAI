import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:word_a_i/services/learning_repository.dart';
import 'package:word_a_i/services/review_preparation.dart';
import 'package:word_a_i/services/wordai_dossier.dart';
import 'fixtures/review_dossier.dart';

void progress(
    {required bool cloud,
    required int checked,
    required int total,
    required int ready}) {}
WordAiDossierUpdate update(String word, int index) => WordAiDossierUpdate(
    dossier: reviewDossier(word, index),
    stage: 'complete',
    isFinal: true,
    provider: 'test',
    model: '');

void main() {
  sqfliteFfiInit();
  late Database db;
  late LearningRepository repository;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await LearningRepository.createSchema(db);
    repository = LearningRepository.forTesting(db);
  });
  tearDown(() => db.close());

  test('cancel interrupts a stuck wait and observes its later error', () async {
    final run = ReviewPreparationRun();
    final gate = Completer<int>();
    final pending = run.wait(gate.future);
    final expectation =
        expectLater(pending, throwsA(isA<ReviewPreparationCancelled>()));
    run.cancel();
    await expectation;
    gate.completeError(StateError('late native failure'));
    await Future<void>.delayed(Duration.zero);
    final late = Completer<int>();
    await expectLater(
        run.wait(late.future), throwsA(isA<ReviewPreparationCancelled>()));
    late.completeError(StateError('after cancel'));
    await Future<void>.delayed(Duration.zero);
  });

  test('continuous partial tokens cannot reset absolute final-result timeout',
      () async {
    var cancelled = false;
    final stream = StreamController<WordAiDossierUpdate>(onCancel: () {
      cancelled = true;
    });
    final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (!cancelled) {
        stream.add(WordAiDossierUpdate(
            dossier: reviewDossier('word', 1),
            stage: 'partial',
            isFinal: false,
            provider: 'test',
            model: ''));
      }
    });
    addTearDown(() async {
      timer.cancel();
      await stream.close();
    });
    await expectLater(
        ReviewPreparationRun().readFinal(stream.stream,
            timeout: const Duration(milliseconds: 25)),
        throwsA(isA<TimeoutException>()));
    expect(cancelled, isTrue);
  });

  test('twenty ready words need no dossier lookups or cloud calls', () async {
    for (var i = 0; i < 20; i++) {
      await repository.registerDossier('u', reviewDossier('word$i', i));
    }
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (_, __) => throw StateError('must not load'));
    expect(
        await preparer.prepare(
            uid: 'u',
            words: ['newword'],
            run: ReviewPreparationRun(),
            onProgress: progress),
        20);
  });

  test('local round stops at twenty and batches progress uploads', () async {
    var calls = 0;
    final repo = _TrackedRepository(db);
    final preparer = ReviewWordPreparer(
        repository: repo,
        load: (word, cloud) {
          expect(cloud, isFalse);
          calls++;
          return Stream.value(update(word, int.parse(word.substring(4))));
        });
    expect(
        await preparer.prepare(
            uid: 'u',
            words: List.generate(300, (i) => 'word$i'),
            run: ReviewPreparationRun(),
            onProgress: progress),
        20);
    expect(calls, 20);
    expect(repo.immediateUploads, 0);
    expect(await repository.createSession('u'), isNotNull);
  });

  test('one ready local word starts a short round without cloud top-up',
      () async {
    await repository.registerDossier('u', reviewDossier('word0', 0));
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (_, cloud) {
          expect(cloud, isFalse);
          return const Stream.empty();
        });
    expect(
        await preparer.prepare(
            uid: 'u',
            words: ['missing'],
            run: ReviewPreparationRun(),
            onProgress: progress),
        1);
  });

  test('5000 misses cannot trigger 5000 cloud requests', () async {
    var local = 0, cloud = 0;
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (_, online) {
          if (online) {
            cloud++;
          } else {
            local++;
          }
          return const Stream.empty();
        });
    await preparer.prepare(
        uid: 'u',
        words: List.generate(5000, (i) => 'word$i'),
        run: ReviewPreparationRun(),
        onProgress: progress);
    expect(local, 80);
    expect(cloud, 4);
    expect(preparer.needsMoreContent, isTrue);
  });

  test('another book cannot make the selected uncached book look prepared',
      () async {
    for (var index = 0; index < 20; index++) {
      await repository.registerDossier(
          'u', reviewDossier('other$index', index));
    }
    var calls = 0;
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (word, cloud) {
          expect(word, 'selected');
          expect(cloud, isFalse);
          calls++;
          return Stream.value(update(word, 99));
        });
    expect(
        await preparer.prepare(
            uid: 'u',
            words: ['selected'],
            limitToWords: true,
            run: ReviewPreparationRun(),
            onProgress: progress),
        1);
    expect(calls, 1);
    final session =
        (await repository.createSession('u', queries: ['selected']))!;
    expect(session.targetIds, hasLength(1));
    expect((await repository.targetById(session.targetIds.single))!.query,
        'selected');
  });

  test('unusable registered content can recover without resetting attempts',
      () async {
    await repository.registerDossier('u', reviewDossier('damaged', 1));
    await db
        .update('learning_progress', {'example_en': '', 'attempt_count': 3});
    var cloud = 0;
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (word, online) {
          if (!online) return const Stream.empty();
          cloud++;
          return Stream.value(update(word, 1));
        });
    expect(
        await preparer.prepare(
            uid: 'u',
            words: ['damaged'],
            limitToWords: true,
            run: ReviewPreparationRun(),
            onProgress: progress),
        1);
    expect(cloud, 1);
    final target = (await db.query('learning_progress')).single;
    expect(target['example_en'], isNotEmpty);
    expect(target['attempt_count'], 3);
    expect(target['stage'], 0);
  });

  test('cloud prepares one target without generating extra distractor targets',
      () async {
    var cloud = 0;
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (word, online) {
          if (!online) return const Stream.empty();
          return Stream.value(update(word, cloud++));
        });
    expect(
        await preparer.prepare(
            uid: 'u',
            words: ['one', 'two', 'three', 'four', 'five'],
            run: ReviewPreparationRun(),
            onProgress: progress),
        1);
    expect(cloud, 1);
    final session = (await repository.createSession('u'))!;
    expect(session.targetIds, hasLength(1));
    expect(await repository.reviewableWordCount('u'), 1);
  });

  test('stalled cloud request times out without launching replacements',
      () async {
    var cloud = 0;
    var cancelled = false;
    final stream = StreamController<WordAiDossierUpdate>(onCancel: () {
      cancelled = true;
    });
    addTearDown(stream.close);
    final preparer = ReviewWordPreparer(
        repository: repository,
        cloudItemTimeout: const Duration(milliseconds: 20),
        load: (_, online) {
          if (!online) return const Stream.empty();
          cloud++;
          return stream.stream;
        });
    expect(
        await preparer.prepare(
            uid: 'u',
            words: ['one', 'two', 'three'],
            run: ReviewPreparationRun(),
            onProgress: progress),
        0);
    expect(cloud, 1);
    expect(cancelled, isTrue);
  });

  test('exit during lookup cancels stream and cannot register late content',
      () async {
    final run = ReviewPreparationRun();
    final started = Completer<void>();
    var cancelled = false;
    final stream = StreamController<WordAiDossierUpdate>(onCancel: () {
      cancelled = true;
    });
    addTearDown(stream.close);
    final preparer = ReviewWordPreparer(
        repository: repository,
        load: (_, __) {
          started.complete();
          return stream.stream;
        });
    final pending = preparer.prepare(
        uid: 'u', words: ['one', 'two'], run: run, onProgress: progress);
    final result =
        expectLater(pending, throwsA(isA<ReviewPreparationCancelled>()));
    await started.future;
    run.cancel();
    await result;
    stream.add(update('one', 1));
    expect(cancelled, isTrue);
    expect(await repository.reviewableWordCount('u'), 0);
  });

  test(
      'damaged session is retired without deleting progress or original payload',
      () async {
    for (var i = 0; i < 4; i++) {
      await repository.registerDossier('u', reviewDossier('word$i', i));
    }
    final session = (await repository.createSession('u'))!;
    await db.update('review_sessions', {'target_ids_json': 'broken JSON'},
        where: 'session_id = ?', whereArgs: [session.id]);
    expect(await repository.resumeActiveSession('u'), isNull);
    final old = (await db.query('review_sessions')).single;
    expect(old['status'], 'exited');
    expect(old['target_ids_json'], 'broken JSON');
    expect(await repository.reviewableWordCount('u'), 4);
    expect((await repository.createSession('u'))!.id, isNot(session.id));
  });

  test('20000 saved words build a random round with bounded question payloads',
      () async {
    await repository.registerDossier('large', reviewDossier('seed', 0));
    final template = (await db.query('learning_progress')).single;
    final batch = db.batch();
    for (var i = 1; i < 20000; i++) {
      batch.insert('learning_progress', {
        ...template,
        'target_id': 'target-$i',
        'lexeme_id': 'lexeme-$i',
        'query': 'word$i',
        'word': 'word$i',
        'definition_en': 'Meaning $i: ${'example ' * 40}',
        'meaning_zh_hans': '释义$i',
        'meaning_zh_hant': '釋義$i',
      });
    }
    await batch.commit(noResult: true);
    final clock = Stopwatch()..start();
    final session = (await repository.createSession('large'))!;
    final selectionMs = clock.elapsedMilliseconds;
    expect(session.targetIds.toSet(), hasLength(20));
    final question = (await repository.buildQuestion(session, 'en'))!;
    final firstQuestionMs = clock.elapsedMilliseconds;
    expect(question.options.toSet(), hasLength(4));
    var current = session;
    while (!current.isComplete) {
      expect(await repository.buildQuestion(current, 'zh_Hant'), isNotNull);
      current = await repository.skipUnavailableTarget('large', current);
    }
    // Measurement, not a flaky hardware-dependent wall-time assertion.
    // ignore: avoid_print
    print(
        'REVIEW_20000 selection_ms=$selectionMs first_question_ms=$firstQuestionMs round_ms=${clock.elapsedMilliseconds}');
  });
}

class _TrackedRepository extends LearningRepository {
  _TrackedRepository(super.database) : super.forTesting();
  int immediateUploads = 0;
  @override
  Future<int> registerDossier(String uid, WordAiDossier dossier,
      {bool syncToCloud = true}) {
    if (syncToCloud) immediateUploads++;
    return super.registerDossier(uid, dossier, syncToCloud: syncToCloud);
  }
}
