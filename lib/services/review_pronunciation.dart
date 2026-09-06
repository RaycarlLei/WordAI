import 'dart:async';

import 'tts_service.dart';

/// Owns only this review's pronunciation; downloads may finish caching after
/// cancellation, but the TTS request token prevents them from playing later.
class ReviewPronunciation {
  ReviewPronunciation({
    required Future<void> Function(String word) play,
    required Future<void> Function() stop,
  })  : _play = play,
        _stop = stop;

  factory ReviewPronunciation.cached() {
    final source = 'flash-card:${++_sequence}';
    return ReviewPronunciation(
      play: (word) async {
        await TTSService.instance.generateAndPlay(text: word, sourceId: source);
      },
      stop: () => TTSService.instance.stopSource(source),
    );
  }

  static int _sequence = 0;
  final Future<void> Function(String) _play;
  final Future<void> Function() _stop;
  String? _lastQuestion;
  bool _started = false;
  bool _disposed = false;

  void show(String questionId, String word) {
    if (_disposed || _lastQuestion == questionId || word.trim().isEmpty) return;
    _lastQuestion = questionId;
    _started = true;
    unawaited(_quietly(() => _play(word.trim())));
  }

  void stop() {
    if (!_started) return;
    _started = false;
    unawaited(_quietly(_stop));
  }

  void dispose() {
    _disposed = true;
    stop();
  }

  Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Audio failure must never block answering. TTS handles local fallback
      // and sanitized diagnostics; this page does not display an error dialog.
    }
  }
}
