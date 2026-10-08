import 'dart:async';
import 'dart:math';

import 'learning_repository.dart';
import 'wordai_dossier.dart';

class ReviewPreparationCancelled implements Exception {
  const ReviewPreparationCancelled();
}

/// One page-owned run. Timeouts invalidate late results; exiting cancels the
/// consumer immediately even if a native/network future cannot be interrupted.
class ReviewPreparationRun {
  ReviewPreparationRun({this.budget = const Duration(seconds: 35)});

  final Duration budget;
  final Stopwatch _clock = Stopwatch()..start();
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const ReviewPreparationCancelled();
    if (_clock.elapsed >= budget) {
      throw TimeoutException('review.preparation.deadline');
    }
  }

  Future<T> wait<T>(Future<T> future, {Duration? timeout}) async {
    try {
      check();
    } catch (_) {
      future.ignore(); // Observe late native failures even after cancellation.
      rethrow;
    }
    final remaining = budget - _clock.elapsed;
    final limit = timeout == null || timeout > remaining ? remaining : timeout;
    final value = await Future.any<T>([
      future,
      _cancelled.future
          .then<T>((_) => throw const ReviewPreparationCancelled()),
    ]).timeout(limit);
    check();
    return value;
  }

  Future<WordAiDossier?> readFinal(Stream<WordAiDossierUpdate> stream,
      {required Duration timeout}) async {
    check();
    final result = Completer<WordAiDossier?>();
    final subscription = stream.listen((update) {
      if (!result.isCompleted && update.isFinal) {
        result.complete(update.dossier);
      }
    }, onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    }, onDone: () {
      if (!result.isCompleted) result.complete(null);
    });
    try {
      return await wait(result.future, timeout: timeout);
    } finally {
      // A blocked producer must not keep the page alive while cancelling.
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }
}

typedef ReviewDossierLoader = Stream<WordAiDossierUpdate> Function(
    String word, bool allowCloud);
typedef ReviewPreparationProgress = void Function(
    {required bool cloud,
    required int checked,
    required int total,
    required int ready});

class ReviewWordPreparer {
  ReviewWordPreparer({
    required this.repository,
    required this.load,
    this.localBudget = const Duration(seconds: 6),
    this.cloudBudget = const Duration(seconds: 18),
    this.localItemTimeout = const Duration(seconds: 2),
    this.cloudItemTimeout = const Duration(seconds: 8),
    this.maxCloudRequests = 4,
    this.onFailure,
  });

  final LearningRepository repository;
  final ReviewDossierLoader load;
  final Duration localBudget, cloudBudget, localItemTimeout, cloudItemTimeout;
  final int maxCloudRequests;
  bool needsMoreContent = false;
  final void Function(String stage, Object error, StackTrace stack)? onFailure;

  Future<int> prepare(
      {required String uid,
      required List<String> words,
      bool limitToWords = false,
      String languageCode = 'en',
      required ReviewPreparationRun run,
      required ReviewPreparationProgress onProgress}) async {
    needsMoreContent = false;
    Future<int> countReady() => repository.reviewableWordCount(uid,
        queries: limitToWords ? words : null,
        requireUsableContent: true,
        languageCode: languageCode);
    var ready = await run.wait(countReady());
    if (words.isEmpty || ready >= 20) return ready;
    final registered = await run.wait(repository.registeredQueries(uid));
    final unique = <String, String>{};
    for (final word in words) {
      final value = word.trim();
      if (value.isNotEmpty && !registered.contains(value.toLowerCase())) {
        unique.putIfAbsent(value.toLowerCase(), () => value);
      }
    }
    final missing = unique.values.toList()..shuffle(Random.secure());
    final count = min(missing.length, 80);
    final misses = <String>[];
    final reported = <String>{};
    void report(String stage, Object error, StackTrace stack) {
      if (reported.add(stage)) onFailure?.call(stage, error, stack);
    }

    final localClock = Stopwatch()..start();
    var scanned = 0;
    for (; scanned < count && ready < 20; scanned++) {
      run.check();
      if (localClock.elapsed >= localBudget) break;
      onProgress(
          cloud: false, checked: scanned + 1, total: count, ready: ready);
      final word = missing[scanned];
      WordAiDossier? dossier;
      try {
        final remaining = localBudget - localClock.elapsed;
        dossier = await run.readFinal(load(word, false),
            timeout:
                remaining < localItemTimeout ? remaining : localItemTimeout);
      } on ReviewPreparationCancelled {
        rethrow;
      } catch (error, stack) {
        report('localLookup', error, stack);
      }
      run.check();
      if (dossier?.isOk == true) {
        await run.wait(repository.registerDossier(uid, dossier!));
        ready = await run.wait(countReady());
      } else {
        misses.add(word);
      }
      // Yield between entries so gestures and skeletons keep rendering.
      await run.wait(Future<void>.delayed(Duration.zero));
    }
    // Question choices come from the device-wide dictionary cache, not from
    // the number of words still being learned. Even one target is a useful
    // round; never generate extra study targets just to supply distractors.
    if (ready >= 1) return ready;
    final candidates = [...misses, ...missing.skip(scanned)];
    final cloudClock = Stopwatch()..start();
    var calls = 0;
    for (final word in candidates) {
      run.check();
      if (calls >= maxCloudRequests ||
          cloudClock.elapsed >= cloudBudget ||
          ready >= 1) {
        break;
      }
      calls++;
      onProgress(
          cloud: true,
          checked: calls,
          total: min(maxCloudRequests, candidates.length),
          ready: ready);
      try {
        final remaining = cloudBudget - cloudClock.elapsed;
        final dossier = await run.readFinal(load(word, true),
            timeout:
                remaining < cloudItemTimeout ? remaining : cloudItemTimeout);
        run.check();
        if (dossier?.isOk == true) {
          await run.wait(repository.registerDossier(uid, dossier!));
          ready = await run.wait(countReady());
        }
      } on ReviewPreparationCancelled {
        rethrow;
      } on TimeoutException catch (error, stack) {
        report('cloudTimeout', error, stack);
        // Do not overlap more requests with a producer that may still be
        // completing its transport cancellation in the background.
        break;
      } catch (error, stack) {
        report('cloudLookup', error, stack);
      }
    }
    needsMoreContent = ready == 0 && candidates.isNotEmpty;
    return ready;
  }
}
