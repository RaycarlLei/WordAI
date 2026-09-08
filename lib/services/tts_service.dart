import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_cache_manager.dart';
import 'community_gateway.dart';
import 'speech_audio.dart';
import 'speech_error_reporter.dart';

enum TtsPlaybackPhase { idle, loading, playing, unavailable }

@immutable
class TtsPlaybackSnapshot {
  const TtsPlaybackSnapshot._({
    required this.phase,
    this.sourceId,
  });

  const TtsPlaybackSnapshot.idle() : this._(phase: TtsPlaybackPhase.idle);

  const TtsPlaybackSnapshot.unavailable()
      : this._(phase: TtsPlaybackPhase.unavailable);

  const TtsPlaybackSnapshot.loading(String sourceId)
      : this._(phase: TtsPlaybackPhase.loading, sourceId: sourceId);

  const TtsPlaybackSnapshot.playing(String sourceId)
      : this._(phase: TtsPlaybackPhase.playing, sourceId: sourceId);

  final TtsPlaybackPhase phase;
  final String? sourceId;

  bool isActiveFor(String id) => isLoadingFor(id) || isPlayingFor(id);
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

  void makeUnavailable() {
    ++_generation;
    state.value = const TtsPlaybackSnapshot.unavailable();
  }

  void dispose() => state.dispose();
}

/// Native ownership survives a UI completion notification. In particular,
/// flutter_tts does not identify the utterance in completion/cancel callbacks.
class _PlaybackOwner {
  _PlaybackOwner(this.token, this.sourceId,
      {this.player, this.path, this.text});

  final int token;
  final String sourceId;
  final AudioPlayer? player;
  final String? path;
  final String? text;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  bool acceptsEvents = true;
  bool started = false;
  bool nativeError = false;
  bool recovering = false;
  int pendingCalls = 0;
}

/// Coordinates cached/gateway audio and local device speech fallback.
class TTSService {
  static final TTSService instance = TTSService._internal();

  TTSService._internal() : this._(AudioPlayer.new, FlutterTts(), null);

  @visibleForTesting
  TTSService.forTesting({
    Future<String> Function(String)? audioLoader,
    TTSCacheManager? cacheManager,
    Future<List<int>> Function(String)? cloudSpeechLoader,
    Future<List<int>?> Function(String)? offlineSpeechLoader,
    AudioPlayer Function()? audioPlayerFactory,
    FlutterTts? systemTts,
    Duration nativeCallTimeout = const Duration(seconds: 8),
  }) : this._(audioPlayerFactory ?? AudioPlayer.new, systemTts ?? FlutterTts(),
            audioLoader,
            cacheManager: cacheManager,
            cloudSpeechLoader: cloudSpeechLoader,
            offlineSpeechLoader: offlineSpeechLoader,
            nativeCallTimeout: nativeCallTimeout);

  TTSService._(
    this._audioPlayerFactory,
    this._systemTts,
    this._audioLoader, {
    TTSCacheManager? cacheManager,
    Future<List<int>> Function(String)? cloudSpeechLoader,
    Future<List<int>?> Function(String)? offlineSpeechLoader,
    Duration nativeCallTimeout = const Duration(seconds: 8),
  })  : _cacheManager = cacheManager,
        _cloudSpeechLoader = cloudSpeechLoader,
        _offlineSpeechLoader = offlineSpeechLoader,
        _nativeCallTimeout = nativeCallTimeout {
    if (nativeCallTimeout <= Duration.zero) {
      throw ArgumentError.value(nativeCallTimeout, 'nativeCallTimeout');
    }
    // The plugin's default logger includes source URLs/data URIs in errors.
    // Our listeners below report only sanitized stage/code metadata instead.
    AudioLogger.logLevel = AudioLogLevel.none;
    _systemTts.setCompletionHandler(_systemFinished);
    _systemTts.setCancelHandler(_systemFinished);
    _systemTts.setErrorHandler((_) {
      final owner = _owner;
      if (owner != null && owner.player == null && _acceptsEvents(owner)) {
        reportSpeechFailure('system', 'speech-system-player-error');
        _systemFinished();
      }
    });
  }

  final AudioPlayer Function() _audioPlayerFactory;
  final FlutterTts _systemTts;
  final Future<String> Function(String)? _audioLoader;
  final TTSCacheManager? _cacheManager;
  final Future<List<int>> Function(String)? _cloudSpeechLoader;
  final Future<List<int>?> Function(String)? _offlineSpeechLoader;
  final Duration _nativeCallTimeout;
  final TtsPlaybackArbiter _playbackArbiter = TtsPlaybackArbiter();
  final StreamController<PlayerState> _playerStates =
      StreamController<PlayerState>.broadcast();
  _PlaybackOwner? _owner;
  bool _unavailable = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void>? _disposeOperation;
  int _sourceSequence = 0;
  Future<void> _audioOperation = Future<void>.value();

  ValueNotifier<TtsPlaybackSnapshot> get playbackState =>
      _playbackArbiter.state;

  /// False after ambiguous native failure or disposal. Recreating FlutterTts
  /// cannot recover this safely: that plugin shares one native engine.
  bool get isAudioAvailable => !_unavailable && !_disposed;

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
    _requireAvailable();
    final token = _playbackArbiter.claim(sourceId);
    await _serializeAudioOperation(() async {
      _requireAvailable();
      await _retireCurrentOwner();
    });
    return token;
  }

  bool isPlaybackRequestCurrent(int token, String sourceId) =>
      isAudioAvailable && _playbackArbiter.isCurrent(token, sourceId);

  bool isPlaybackGenerationCurrent(int token) =>
      isAudioAvailable && _playbackArbiter.isGenerationCurrent(token);

  void abandonPlaybackRequest(int token, String sourceId) {
    if (!isPlaybackRequestCurrent(token, sourceId)) return;
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
      if (!isAudioAvailable) _requireAvailable();
      if (!isPlaybackGenerationCurrent(token)) return false;
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
        (error.code.startsWith('speech-system-') ||
            error.code == 'speech-audio-unavailable' ||
            error.code == 'speech-audio-disposed')) {
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

  bool _acceptsEvents(_PlaybackOwner owner) =>
      isAudioAvailable &&
      identical(_owner, owner) &&
      owner.acceptsEvents &&
      _playbackArbiter.isGenerationCurrent(owner.token);

  void _systemFinished() {
    final owner = _owner;
    if (owner == null || owner.player != null || !_acceptsEvents(owner)) return;
    // flutter_tts events have no utterance ID. They can update the indicator,
    // but cannot release ownership or prove that this utterance has stopped.
    _playbackArbiter.complete();
  }

  void _listenToPlayer(_PlaybackOwner owner) {
    final player = owner.player!;
    owner.subscriptions.add(player.onPlayerComplete.listen((_) {
      if (_acceptsEvents(owner)) _playbackArbiter.complete();
    }, onError: (Object _, StackTrace __) {
      if (!_acceptsEvents(owner) || owner.recovering) return;
      owner.nativeError = true;
      // Preparation/resume failures are handled by their awaited request.
      // Only an already accepted playback needs asynchronous recovery.
      if (!owner.started) return;
      owner.recovering = true;
      owner.acceptsEvents = false;
      reportSpeechFailure('playback', 'speech-native-player-error');
      unawaited(_recoverNativePlayback(owner));
    }));
    owner.subscriptions.add(player.onPlayerStateChanged.listen((state) {
      if (_acceptsEvents(owner)) _playerStates.add(state);
    }));
  }

  Future<void> _recoverNativePlayback(_PlaybackOwner owner) async {
    try {
      final retired = await _serializeAudioOperation(() async {
        if (!identical(_owner, owner)) return false;
        _requireAvailable();
        await _retireCurrentOwner();
        return true;
      });
      if (!retired) return;
      if (owner.path != null) unawaited(_evictFailedAudio(owner.path!));
      if (!isPlaybackRequestCurrent(owner.token, owner.sourceId)) return;
      if (owner.text != null) {
        await playSystemSpeech(owner.text!,
            sourceId: owner.sourceId, requestToken: owner.token);
      } else {
        abandonPlaybackRequest(owner.token, owner.sourceId);
      }
    } catch (_) {
      // A failed/timed-out stop leaves audio unavailable. Never fall back
      // while the previous source could still be audible.
      reportSpeechFailure('playback', 'speech-native-recovery-failed');
    }
  }

  Future<void> _evictFailedAudio(String path) async {
    try {
      await (_cacheManager ?? TTSCacheManager.instance)
          .evictPlaybackSource(path);
    } catch (_) {
      reportSpeechFailure('cache', 'speech-cache-remove-failed');
    }
  }

  Future<bool> playSystemSpeech(
    String text, {
    required String sourceId,
    required int requestToken,
  }) async {
    _requireAvailable();
    if (!isPlaybackRequestCurrent(requestToken, sourceId)) return false;
    final normalized = _normalizeText(text);
    if (normalized.isEmpty) return false;
    try {
      return await _serializeAudioOperation(() async {
        _requireAvailable();
        if (!isPlaybackRequestCurrent(requestToken, sourceId)) return false;
        await _retireCurrentOwner();
        if (!isPlaybackRequestCurrent(requestToken, sourceId)) return false;
        final owner = _PlaybackOwner(requestToken, sourceId);
        _owner = owner;
        final hanCount =
            RegExp(r'[\u3400-\u9fff]').allMatches(normalized).length;
        final configuration = <Future<dynamic> Function()>[
          () => _systemTts.setLanguage(
              hanCount * 2 >= normalized.runes.length ? 'zh-CN' : 'en-US'),
          () => _systemTts.setSpeechRate(0.48),
          () => _systemTts.setPitch(1.0),
          () => _systemTts.setVolume(1.0),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) ...[
            () => _systemTts.setIosAudioCategory(
                  IosTextToSpeechAudioCategory.playback,
                  <IosTextToSpeechAudioCategoryOptions>[],
                  IosTextToSpeechAudioMode.defaultMode,
                ),
            () => _systemTts.setSharedInstance(true),
          ],
        ];
        for (final configure in configuration) {
          await _nativeCall(owner, configure);
          if (!isPlaybackRequestCurrent(requestToken, sourceId)) return false;
        }
        owner.started = true;
        _playbackArbiter.markPlaying(requestToken, sourceId);
        final started =
            await _nativeCall(owner, () => _systemTts.speak(normalized));
        if (started != 1) {
          throw const SpeechAudioException('speech-system-unavailable');
        }
        return isPlaybackGenerationCurrent(requestToken);
      });
    } catch (error) {
      if (!isAudioAvailable) _requireAvailable();
      // A rejected call is not evidence that nothing started. Confirm stop
      // before freeing this owner, including failed system speak requests.
      await _stopFailedRequest(requestToken);
      if (!isPlaybackGenerationCurrent(requestToken)) return false;
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
    _requireAvailable();
    final resolvedSourceId =
        sourceId ?? createPlaybackSourceId('direct-playback');
    final resolvedToken = requestToken ?? await beginPlayback(resolvedSourceId);

    if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
      return false;
    }

    try {
      return await _serializeAudioOperation(() async {
        _requireAvailable();
        if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
          return false;
        }

        await _retireCurrentOwner();
        if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
          return false;
        }

        // A fresh player gives native events an instance boundary. Reusing
        // one player cannot distinguish late completion of its old source.
        final player = _audioPlayerFactory();
        // Speech has no position/progress UI. The plugin's default updater
        // starts unobserved native position Futures on resume/completion;
        // disable it before this fresh player can issue any playback call.
        player.positionUpdater = null;
        final owner = _PlaybackOwner(resolvedToken, resolvedSourceId,
            player: player, path: audioPath, text: fallbackText);
        _owner = owner;
        _listenToPlayer(owner);
        final preparation = <Future<void> Function()>[
          () => player.setAudioContext(AudioContext(
                iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
              )),
          () => player.setVolume(1.0),
          () => player.setSource(
              kIsWeb ? UrlSource(audioPath) : DeviceFileSource(audioPath)),
          if (_currentPlaybackRate != 1.0)
            () => player.setPlaybackRate(_currentPlaybackRate),
        ];
        for (final prepare in preparation) {
          await _nativeCall(owner, prepare);
          if (owner.nativeError) {
            throw const SpeechAudioException('speech-native-player-error');
          }
          if (!isPlaybackRequestCurrent(resolvedToken, resolvedSourceId)) {
            return false;
          }
        }
        _playbackArbiter.markPlaying(resolvedToken, resolvedSourceId);
        await _nativeCall(owner, player.resume);
        if (owner.nativeError) {
          throw const SpeechAudioException('speech-native-player-error');
        }
        owner.started = true;
        return isPlaybackGenerationCurrent(resolvedToken);
      });
    } catch (e) {
      if (!isAudioAvailable) _requireAvailable();
      await _stopFailedRequest(resolvedToken);
      if (!isPlaybackGenerationCurrent(resolvedToken)) return false;
      reportSpeechFailure('playback', 'speech-native-player-error');
      // Cache IO is not part of the native operation queue.
      unawaited(_evictFailedAudio(audioPath));
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
    if (_disposed) return;
    _requireAvailable();
    final owner = _owner;
    final ownsNative = owner != null && owner.sourceId == sourceId;
    final ownsRequest = _playbackArbiter.state.value.sourceId == sourceId;
    if (!ownsNative && !ownsRequest) return;
    if (ownsRequest ||
        (ownsNative && _playbackArbiter.isGenerationCurrent(owner.token))) {
      _playbackArbiter.stop();
    }
    if (ownsNative) owner.acceptsEvents = false;
    await _serializeAudioOperation(() async {
      if (_unavailable) _requireAvailable();
      if (ownsNative && identical(_owner, owner)) await _retireCurrentOwner();
    });
  }

  /// Stop current playback
  Future<void> stop() async {
    if (_disposed) return;
    _requireAvailable();
    _playbackArbiter.stop();
    _owner?.acceptsEvents = false;
    _currentPlaybackRate = 1.0;
    await _serializeAudioOperation(() async {
      if (_unavailable) _requireAvailable();
      await _retireCurrentOwner();
    });
  }

  Future<T> _serializeAudioOperation<T>(Future<T> Function() operation) {
    final result = _audioOperation.then((_) => operation());
    _audioOperation =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _requireAvailable() {
    if (_disposed) throw const SpeechAudioException('speech-audio-disposed');
    if (_unavailable) {
      throw const SpeechAudioException('speech-audio-unavailable');
    }
  }

  void _quarantine() {
    if (_unavailable) return;
    _unavailable = true;
    _owner?.acceptsEvents = false;
    if (!_notifierDisposed) _playbackArbiter.makeUnavailable();
    reportSpeechFailure('playback', 'speech-audio-unavailable');
    final owner = _owner;
    if (owner != null) unawaited(_attemptQuarantinedStop(owner));
  }

  /// Bounds the Dart wait, not the native operation. Late completion/error is
  /// observed and can only request another stop of this captured owner.
  Future<T> _nativeCall<T>(
    _PlaybackOwner owner,
    Future<T> Function() operation, {
    bool stopping = false,
  }) async {
    var expired = false;
    owner.pendingCalls++;
    final pending = Future<T>.sync(operation);
    void settled() {
      owner.pendingCalls--;
      if (expired) unawaited(_attemptQuarantinedStop(owner));
    }

    unawaited(pending.then<void>((_) => settled(),
        onError: (Object _, StackTrace __) {
      settled();
    }));
    try {
      return await pending.timeout(_nativeCallTimeout, onTimeout: () {
        expired = true;
        _quarantine();
        throw const SpeechAudioException('speech-audio-unavailable');
      });
    } catch (_) {
      if (stopping) _quarantine();
      rethrow;
    }
  }

  Future<void> _stopNative(_PlaybackOwner owner) async {
    if (owner.player case final player?) {
      await player.stop();
    } else {
      final result = await _systemTts.stop();
      if (result != 1) {
        throw const SpeechAudioException('speech-system-stop-failed');
      }
    }
  }

  Future<void> _attemptQuarantinedStop(_PlaybackOwner owner) async {
    if (owner.player?.state == PlayerState.disposed) return;
    // This is best-effort cleanup only. Even a late stop acknowledgement does
    // not re-enable audio after an ambiguous native operation. Each late
    // operation gets its own attempt: an earlier late stop may settle before
    // a later resume that was already in flight when disposal began.
    owner.pendingCalls++;
    final pending = Future<void>.sync(() => _stopNative(owner));
    // Observe this cleanup call too, but do not recursively retry a late
    // cleanup stop. Only the original operation may have started new sound.
    unawaited(pending.then<void>((_) {
      owner.pendingCalls--;
    }, onError: (Object _, StackTrace __) {
      owner.pendingCalls--;
    }));
    try {
      await pending.timeout(_nativeCallTimeout);
    } catch (_) {
      reportSpeechFailure('playback', 'speech-native-stop-failed');
    }
  }

  Future<void> _cancelSubscriptions(_PlaybackOwner owner) async {
    final subscriptions = List.of(owner.subscriptions);
    owner.subscriptions.clear();
    await Future.wait(
            subscriptions.map((subscription) => subscription.cancel()))
        .timeout(_nativeCallTimeout);
  }

  Future<void> _retireCurrentOwner() async {
    final owner = _owner;
    if (owner == null) return;
    owner.acceptsEvents = false;
    await _nativeCall(owner, () => _stopNative(owner), stopping: true);
    // dispose() itself calls stop/release in audioplayers. It is not a kill
    // switch for an earlier source/resume Future that is still outstanding.
    if (owner.pendingCalls != 0) return;
    try {
      await _cancelSubscriptions(owner);
    } catch (_) {
      _quarantine();
      rethrow;
    }
    if (owner.player case final player?) {
      await _nativeCall(owner, player.dispose, stopping: true);
    }
    if (identical(_owner, owner)) _owner = null;
  }

  Future<void> _stopFailedRequest(int token) =>
      _serializeAudioOperation(() async {
        if (_owner?.token == token) await _retireCurrentOwner();
      });

  double _currentPlaybackRate = 1.0;

  /// Set playback rate (speed)
  /// Can be called during playback to adjust speed in real-time
  /// Rate: 0.25 to 4.0 (1.0 = normal speed)
  Future<void> setPlaybackRate(double rate) async {
    _requireAvailable();
    if (!rate.isFinite || rate < 0.25 || rate > 4.0) {
      throw ArgumentError.value(rate, 'rate', 'Must be between 0.25 and 4.0');
    }
    final owner = _owner;
    await _serializeAudioOperation(() async {
      _requireAvailable();
      if (owner == null || owner.player == null || !_acceptsEvents(owner)) {
        return;
      }
      await _nativeCall(owner, () => owner.player!.setPlaybackRate(rate));
      if (_acceptsEvents(owner)) _currentPlaybackRate = rate;
    });
  }

  /// Get current playback rate
  double getPlaybackRate() {
    return _currentPlaybackRate;
  }

  /// Check if audio is currently playing
  bool get isPlaying =>
      _playbackArbiter.state.value.phase == TtsPlaybackPhase.playing;

  /// Get audio player state stream
  Stream<PlayerState> get playerStateStream => _playerStates.stream;

  /// Dispose resources
  Future<void> dispose() {
    if (_disposeOperation != null) return _disposeOperation!;
    _disposed = true;
    if (!_unavailable) _playbackArbiter.stop();
    _owner?.acceptsEvents = false;
    _systemTts.setCompletionHandler(() {});
    _systemTts.setCancelHandler(() {});
    _systemTts.setErrorHandler((_) {});
    return _disposeOperation = _serializeAudioOperation(() async {
      try {
        await _retireCurrentOwner();
      } catch (_) {
        _quarantine();
      } finally {
        final owner = _owner;
        if (owner != null) {
          try {
            await _cancelSubscriptions(owner);
          } catch (_) {
            _quarantine();
          }
        }
        // Closing a broadcast stream can wait for a paused consumer. It must
        // not hold native cleanup or logical service disposal hostage.
        unawaited(_playerStates.close());
        _notifierDisposed = true;
        _playbackArbiter.dispose();
      }
    });
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
