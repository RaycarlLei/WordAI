import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_cache_manager.dart';
import 'community_gateway.dart';
import 'speech_audio.dart';
import 'speech_error_reporter.dart';

enum TtsPlaybackPhase { idle, loading, playing }

@immutable
class TtsPlaybackSnapshot {
  const TtsPlaybackSnapshot._({
    required this.phase,
    this.sourceId,
  });

  const TtsPlaybackSnapshot.idle() : this._(phase: TtsPlaybackPhase.idle);

  const TtsPlaybackSnapshot.loading(String sourceId)
      : this._(phase: TtsPlaybackPhase.loading, sourceId: sourceId);

  const TtsPlaybackSnapshot.playing(String sourceId)
      : this._(phase: TtsPlaybackPhase.playing, sourceId: sourceId);

  final TtsPlaybackPhase phase;
  final String? sourceId;

  bool isActiveFor(String id) =>
      sourceId == id && phase != TtsPlaybackPhase.idle;
  bool isLoadingFor(String id) =>
      sourceId == id && phase == TtsPlaybackPhase.loading;
  bool isPlayingFor(String id) =>
      sourceId == id && phase == TtsPlaybackPhase.playing;
}

/// Pure state arbiter for the app-wide single TTS player.
///
/// Keeping request ordering independent from the audio plugin makes stale
/// response and interruption behavior deterministic and testable.
class TtsPlaybackArbiter {
  final ValueNotifier<TtsPlaybackSnapshot> state =
      ValueNotifier<TtsPlaybackSnapshot>(const TtsPlaybackSnapshot.idle());

  int _generation = 0;

  int claim(String sourceId) {
    final token = ++_generation;
    state.value = TtsPlaybackSnapshot.loading(sourceId);
    return token;
  }

  bool isCurrent(int token, String sourceId) =>
      token == _generation && state.value.sourceId == sourceId;

  bool isGenerationCurrent(int token) => token == _generation;

  bool markPlaying(int token, String sourceId) {
    if (!isCurrent(token, sourceId)) return false;
    state.value = TtsPlaybackSnapshot.playing(sourceId);
    return true;
  }

  void abandon(int token, String sourceId) {
    if (!isCurrent(token, sourceId)) return;
    state.value = const TtsPlaybackSnapshot.idle();
  }

  void complete() {
    if (state.value.phase == TtsPlaybackPhase.playing) {
      state.value = const TtsPlaybackSnapshot.idle();
    }
  }

  void stop() {
    ++_generation;
    state.value = const TtsPlaybackSnapshot.idle();
  }

  void dispose() => state.dispose();
}

/// Text-to-Speech Service.
/// Live speech is generated only through authenticated WordAI Cloud.
class TTSService {
  static final TTSService instance = TTSService._internal();

  TTSService._internal() : this._(AudioPlayer(), FlutterTts(), null);

  @visibleForTesting
  TTSService.forTesting({
    Future<String> Function(String)? audioLoader,
    TTSCacheManager? cacheManager,
    Future<List<int>> Function(String)? cloudSpeechLoader,
    Future<List<int>?> Function(String)? offlineSpeechLoader,
    AudioPlayer? audioPlayer,
    FlutterTts? systemTts,
  }) : this._(audioPlayer ?? AudioPlayer(), systemTts ?? FlutterTts(),
            audioLoader,
            cacheManager: cacheManager,
            cloudSpeechLoader: cloudSpeechLoader,
            offlineSpeechLoader: offlineSpeechLoader);

  TTSService._(
    this._audioPlayer,
    this._systemTts,
    this._audioLoader, {
    TTSCacheManager? cacheManager,
    Future<List<int>> Function(String)? cloudSpeechLoader,
    Future<List<int>?> Function(String)? offlineSpeechLoader,
  })  : _cacheManager = cacheManager,
        _cloudSpeechLoader = cloudSpeechLoader,
        _offlineSpeechLoader = offlineSpeechLoader {
    // The plugin's default logger includes source URLs/data URIs in errors.
    // Our listeners below report only sanitized stage/code metadata instead.
    AudioLogger.logLevel = AudioLogLevel.none;
    _playerCompleteSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (_playbackArbiter.state.value.phase == TtsPlaybackPhase.playing) {
        _currentPlayingUrl = null;
        _playbackArbiter.complete();
      }
    }, onError: (Object error, StackTrace stack) {
      reportSpeechFailure('playback', 'speech-native-player-error');
      if (_playbackArbiter.state.value.phase == TtsPlaybackPhase.playing) {
        unawaited(_recoverNativePlayback());
      }
    });
    _systemTts.setCompletionHandler(() {
      if (_currentPlayingUrl == _systemSpeechMarker &&
          _playbackArbiter.state.value.phase == TtsPlaybackPhase.playing) {
        _currentPlayingUrl = null;
        _playbackArbiter.complete();
      }
    });
    _systemTts.setCancelHandler(() {
      if (_currentPlayingUrl == _systemSpeechMarker) {
        _currentPlayingUrl = null;
        _playbackArbiter.complete();
      }
    });
    _systemTts.setErrorHandler((_) {
      if (_currentPlayingUrl == _systemSpeechMarker) {
        reportSpeechFailure('system', 'speech-system-player-error');
        _currentPlayingUrl = null;
        _playbackArbiter.stop();
      }
    });
  }

  final AudioPlayer _audioPlayer;
  final FlutterTts _systemTts;
  final Future<String> Function(String)? _audioLoader;
  final TTSCacheManager? _cacheManager;
  final Future<List<int>> Function(String)? _cloudSpeechLoader;
  final Future<List<int>?> Function(String)? _offlineSpeechLoader;
  String? _activeSpeechText;
  int? _activeToken;
  bool _recoveringNative = false;
  late final StreamSubscription<void> _playerCompleteSubscription;
  final TtsPlaybackArbiter _playbackArbiter = TtsPlaybackArbiter();
  String? _currentPlayingUrl;
  int _sourceSequence = 0;
  Future<void> _audioOperation = Future<void>.value();
  static const String _systemSpeechMarker = 'wordai-system-speech';

  ValueNotifier<TtsPlaybackSnapshot> get playbackState =>
      _playbackArbiter.state;

  /// Normalize text for consistent hashing and API results
  String _normalizeText(String text) {
    return text
        .replaceAll(RegExp(r'\r\n'), '\n') // Normalize line endings
        .replaceAll(RegExp(r'\s+'),
            ' ') // Collapse multiple spaces/newlines to a single space
        .trim();
  }

  /// Generate speech audio using the offline pack or WordAI Cloud.
  /// Returns the local file path (mobile) or data URL (web) of the audio file
  Future<String> generateSpeech({
    required String text,
  }) async {
    final normalizedText = _normalizeText(text);

    if (normalizedText.isEmpty) {
      throw Exception('Text cannot be empty');
    }
    if (_audioLoader != null) return _audioLoader(normalizedText);

    final cacheManager = _cacheManager ?? TTSCacheManager.instance;
    final cacheText = _providerCacheText(normalizedText);

    // Check cache first
    if (kIsWeb) {
      final cachedAudio = await cacheManager.getCachedAudioWeb(cacheText);
      if (cachedAudio != null) {
        debugPrint('Using cached audio (web)');
        return 'data:audio/mpeg;base64,$cachedAudio';
      }
    } else {
      final cachedPath = await cacheManager.getCachedAudioPath(cacheText);
      if (cachedPath != null) {
        debugPrint('Using cached audio (mobile)');
        return cachedPath;
      }

      final offlinePath = await cacheManager.getCachedAudioPath(
          'audio-pack::$normalizedText',
          namespace: 'offline');
      if (offlinePath != null) return offlinePath;
      final offline = await _offlineSpeechLoader?.call(normalizedText);
      if (offline != null) {
        return cacheManager.saveAudioFile(
            'audio-pack::$normalizedText', offline,
            namespace: 'offline');
      }
    }

    // Make API request
    debugPrint('Generating new audio');
    final List<int> audioBytes;
    try {
      audioBytes = await (_cloudSpeechLoader?.call(normalizedText) ??
          CommunityGateway.instance.synthesizeSpeech(normalizedText));
      if (!isValidMp3(audioBytes)) {
        throw const SpeechAudioException('speech-invalid-mp3');
      }
    } catch (error) {
      _reportGenerationFailure(error);
      rethrow;
    }

    // Save audio file based on platform
    if (kIsWeb) {
      // Web: create data URL and cache
      final base64Audio = base64Encode(audioBytes);
      final audioUrl = 'data:audio/mpeg;base64,$base64Audio';
      await cacheManager.cacheAudioWeb(cacheText, base64Audio);
      return audioUrl;
    } else {
      // Mobile: save to file system
      final audioPath = await cacheManager.saveAudioFile(cacheText, audioBytes);
      return audioPath;
    }
  }

  /// Force-refresh cached speech for the given text.
  ///
  /// - Always calls the TTS API, ignoring any existing cache.
  /// - Only overwrites the cached audio if the API call succeeds.
  /// - Returns true when the cache was refreshed successfully, false otherwise.
  Future<bool> refreshCachedSpeech({
    required String text,
  }) async {
    final normalizedText = _normalizeText(text);

    if (normalizedText.isEmpty) {
      debugPrint('refreshCachedSpeech skipped: text is empty');
      return false;
    }

    debugPrint('Refreshing cached audio');

    try {
      final cacheText = _providerCacheText(normalizedText);
      final audioBytes =
          await CommunityGateway.instance.synthesizeSpeech(normalizedText);

      final cacheManager = TTSCacheManager.instance;

      if (kIsWeb) {
        final base64Audio = base64Encode(audioBytes);
        await cacheManager.cacheAudioWeb(cacheText, base64Audio);
      } else {
        // Uses deterministic filename; this overwrites the previous file for this text
        await cacheManager.saveAudioFile(cacheText, audioBytes);
      }

      return true;
    } catch (e) {
      _reportGenerationFailure(e);
      return false;
    }
  }

  String createPlaybackSourceId([String prefix = 'tts']) =>
      '$prefix:${++_sourceSequence}';

  /// Claims the single global player for [sourceId] and interrupts any
  /// previous playback. The returned token prevents stale network requests
  /// from starting after a newer button has been tapped.
  Future<int> beginPlayback(String sourceId) async {
    final token = _playbackArbiter.claim(sourceId);
    _activeSpeechText = null;
    _activeToken = null;
    await _serializeAudioOperation(() async {
      await _stopPlayers();
      _currentPlayingUrl = null;
    });
    return token;
  }

  bool isPlaybackRequestCurrent(int token, String sourceId) =>
      _playbackArbiter.isCurrent(token, sourceId);

  bool isPlaybackGenerationCurrent(int token) =>
      _playbackArbiter.isGenerationCurrent(token);

  void abandonPlaybackRequest(int token, String sourceId) {
    if (!isPlaybackRequestCurrent(token, sourceId)) return;
    _currentPlayingUrl = null;
    _playbackArbiter.abandon(token, sourceId);
  }

  /// Generates and plays one utterance using the global single-player policy.
  Future<bool> generateAndPlay({
    required String text,
    required String sourceId,
  }) async {
    final token = await beginPlayback(sourceId);
    try {
      final audioPath = await generateSpeech(text: text);
      if (!isPlaybackRequestCurrent(token, sourceId)) return false;
      return await playAudio(
        audioPath,
        sourceId: sourceId,
        requestToken: token,
        fallbackText: text,
      );
    } catch (error) {
      if (!_playbackArbiter.isGenerationCurrent(token)) return false;
      _reportGenerationFailure(error);
      if (shouldUseSystemSpeech(error)) {
        return playSystemSpeech(
          text,
          sourceId: sourceId,
          requestToken: token,
        );
      }
      abandonPlaybackRequest(token, sourceId);
      rethrow;
    }
  }

  bool shouldUseSystemSpeech(Object error) {
    if (kIsWeb) return false;
    if (error is SpeechAudioException &&
        error.code.startsWith('speech-system-')) {
      return false;
    }
    // System speech is local and free. Input mistakes/cancellation still stop.
    return error is! CommunityGatewayException ||
        !const {'invalid-argument', 'cancelled', 'canceled'}
            .contains(error.code);
  }

  void _reportGenerationFailure(Object error) {
    if (error is CommunityGatewayException) {
      final code = (error.code ?? '').toLowerCase();
      if (code.contains('budget') ||
          code.contains('cooling') ||
          code.contains('resource') ||
          code.contains('network') ||
          code == 'deadline-exceeded' ||
          code == 'invalid-argument') {
        return;
      }
      reportSpeechFailure(
          'generation', code.isEmpty ? 'speech-cloud-failed' : code);
    } else {
      reportSpeechFailure(
          error is SpeechAudioException ? 'decode' : 'generation',
          error is SpeechAudioException ? error.code : 'speech-cloud-failed');
    }
  }

  Future<void> _recoverNativePlayback() async {
    if (_recoveringNative || _currentPlayingUrl == _systemSpeechMarker) return;
    final text = _activeSpeechText;
    final token = _activeToken;
    final source = _playbackArbiter.state.value.sourceId;
    final path = _currentPlayingUrl;
    if (text == null || token == null || source == null) {
      _playbackArbiter.stop();
      return;
    }
    _recoveringNative = true;
    try {
      if (path != null) await _evictFailedAudio(path);
      await playSystemSpeech(text, sourceId: source, requestToken: token);
    } catch (_) {
      reportSpeechFailure('system', 'speech-system-player-error');
    } finally {
      _recoveringNative = false;
    }
  }

  Future<void> _evictFailedAudio(String path) async {
    try {
      await TTSCacheManager.instance.evictPlaybackSource(path);
    } catch (_) {
      reportSpeechFailure('cache', 'speech-cache-remove-failed');
    }
  }

  Future<bool> playSystemSpeech(
    String text, {
    required String sourceId,
    required int requestToken,
  }) async {
    if (!isPlaybackRequestCurrent(requestToken, sourceId)) return false;
    final normalized = _normalizeText(text);
    if (normalized.isEmpty) return false;
    try {
      await _serializeAudioOperation(() async {
        await _stopPlayers();
        if (!isPlaybackRequestCurrent(requestToken, sourceId)) return;
        final hanCount =
            RegExp(r'[\u3400-\u9fff]').allMatches(normalized).length;
        await _systemTts.setLanguage(
          hanCount * 2 >= normalized.runes.length ? 'zh-CN' : 'en-US',
        );
        await _systemTts.setSpeechRate(0.48);
        await _systemTts.setPitch(1.0);
        await _systemTts.setVolume(1.0);
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          await _systemTts.setIosAudioCategory(
            IosTextToSpeechAudioCategory.playback,
            <IosTextToSpeechAudioCategoryOptions>[],
            IosTextToSpeechAudioMode.defaultMode,
          );
          await _systemTts.setSharedInstance(true);
        }
        _currentPlayingUrl = _systemSpeechMarker;
        if (!_playbackArbiter.markPlaying(requestToken, sourceId)) return;
        final started = await _systemTts.speak(normalized);
        if (started != 1) {
          throw const SpeechAudioException('speech-system-unavailable');
        }
      });
      return isPlaybackRequestCurrent(requestToken, sourceId);
    } catch (error) {
      abandonPlaybackRequest(requestToken, sourceId);
      reportSpeechFailure('system', 'speech-system-player-error');
      throw const SpeechAudioException('speech-system-player-error');
    }
  }

  /// Play audio from file path or URL. Only the most recently claimed source
  /// may start playback.
  Future<bool> playAudio(
    String audioPath, {
    String? sourceId,
    int? requestToken,
    String? fallbackText,
  }) async {
    final resolvedSourceId =
        sourceId ?? createPlaybackSourceId('direct-playback');
    final resolvedToken = requestToken ?? await beginPlayback(resolvedSourceId);

    if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
      return false;
    }

    try {
      return await _serializeAudioOperation(() async {
        if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
          return false;
        }

        await _stopPlayers();
        if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
          return false;
        }

        _currentPlayingUrl = audioPath;
        _activeSpeechText = fallbackText;
        _activeToken = resolvedToken;
        await _audioPlayer.setAudioContext(const AudioContext(
          iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
        ));
        await _audioPlayer.setVolume(1.0);

        await _audioPlayer
            .setSource(
                kIsWeb ? UrlSource(audioPath) : DeviceFileSource(audioPath))
            .timeout(const Duration(seconds: 8));
        if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
          return false;
        }
        await _audioPlayer.resume();
        if (!_playbackArbiter.markPlaying(resolvedToken, resolvedSourceId)) {
          await _audioPlayer.stop();
          return false;
        }

        if (_currentPlaybackRate != 1.0 &&
            isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
          await _audioPlayer.setPlaybackRate(_currentPlaybackRate);
        }
        return isPlaybackRequestCurrent(resolvedToken, resolvedSourceId);
      });
    } catch (e) {
      if (!_playbackArbiter.isGenerationCurrent(resolvedToken)) return false;
      reportSpeechFailure('playback', 'speech-native-player-error');
      await _evictFailedAudio(audioPath);
      if (fallbackText != null &&
          shouldUseSystemSpeech(e) &&
          isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
        return playSystemSpeech(fallbackText,
            sourceId: resolvedSourceId, requestToken: resolvedToken);
      }
      abandonPlaybackRequest(resolvedToken, resolvedSourceId);
      throw const SpeechAudioException('speech-native-player-error');
    }
  }

  /// Cancel only this owner's playback, including a pending download.
  Future<void> stopSource(String sourceId) async {
    if (_playbackArbiter.state.value.sourceId != sourceId) return;
    await stop();
  }

  /// Stop current playback
  Future<void> stop() async {
    _playbackArbiter.stop();
    _currentPlayingUrl = null;
    _currentPlaybackRate = 1.0;
    try {
      await _serializeAudioOperation(_stopPlayers);
    } catch (e) {
      // Ignore errors when stopping
    }
  }

  Future<T> _serializeAudioOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _audioOperation = _audioOperation.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _stopPlayers() async {
    // A broken cloud-audio player must not prevent local system recovery.
    try {
      await _audioPlayer.stop();
    } catch (_) {
      reportSpeechFailure('playback', 'speech-native-stop-failed');
    }
    try {
      await _systemTts.stop();
    } catch (_) {
      reportSpeechFailure('system', 'speech-system-stop-failed');
    }
  }

  double _currentPlaybackRate = 1.0;

  /// Set playback rate (speed)
  /// Can be called during playback to adjust speed in real-time
  /// Rate: 0.25 to 4.0 (1.0 = normal speed)
  Future<void> setPlaybackRate(double rate) async {
    try {
      if (_currentPlayingUrl != null) {
        await _audioPlayer.setPlaybackRate(rate);
        _currentPlaybackRate = rate;
      }
    } catch (e) {
      debugPrint('Error setting playback rate: $e');
    }
  }

  /// Get current playback rate
  double getPlaybackRate() {
    return _currentPlaybackRate;
  }

  /// Check if audio is currently playing
  bool get isPlaying =>
      _playbackArbiter.state.value.phase == TtsPlaybackPhase.playing;

  /// Get audio player state stream
  Stream<dynamic> get playerStateStream => _audioPlayer.onPlayerStateChanged;

  /// Dispose resources
  Future<void> dispose() async {
    await stop();
    await _playerCompleteSubscription.cancel();
    await _audioPlayer.dispose();
    _playbackArbiter.dispose();
  }

  /// Clear all cached audio
  Future<void> clearCache() async {
    await TTSCacheManager.instance.clearCache();
  }

  /// Get cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    return await TTSCacheManager.instance.getCacheStats();
  }

  /// Check if audio is cached
  Future<bool> isCached(String text) async {
    final normalizedText = _normalizeText(text);
    final providerCached = await TTSCacheManager.instance.isCached(
      _providerCacheText(normalizedText),
    );
    if (providerCached || kIsWeb) return providerCached;
    final offlineCached = await TTSCacheManager.instance.getCachedAudioPath(
      'audio-pack::$normalizedText',
      namespace: 'offline',
    );
    if (offlineCached != null) return true;
    return false;
  }

  String _providerCacheText(String text) => 'wordai_cloud::$text';
}
