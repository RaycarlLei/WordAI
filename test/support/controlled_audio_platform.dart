import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';

/// Exercises the real AudioPlayer wrapper without loading a native engine.
/// Gates are consumed by one method call; events are routed by native player ID.
class ControlledAudioPlatform extends AudioplayersPlatformInterface {
  final calls = <String>[];
  final _streams = <String, StreamController<AudioEvent>>{};
  final _gates = <String, Completer<void>>{};
  final _outstanding = <Completer<void>>[];

  Completer<void> hold(String method, {String id = '*'}) {
    final gate = Completer<void>();
    _gates['$id:$method'] = gate;
    _outstanding.add(gate);
    return gate;
  }

  Future<void> _call(String id, String method) async {
    calls.add('$id:$method');
    final gate = _gates.remove('$id:$method') ?? _gates.remove('*:$method');
    if (gate != null) await gate.future;
  }

  void complete(String id) => _streams[id]!.add(
        const AudioEvent(eventType: AudioEventType.complete),
      );

  void fail(String id) => _streams[id]!.addError(StateError('decoder failed'));

  void releaseGates() {
    for (final gate in _outstanding) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }

  Future<void> close() async {
    for (final stream in _streams.values) {
      await stream.close();
    }
  }

  @override
  Future<void> create(String playerId) async {
    _streams[playerId] = StreamController<AudioEvent>.broadcast();
    await _call(playerId, 'create');
  }

  @override
  Stream<AudioEvent> getEventStream(String playerId) =>
      _streams[playerId]!.stream;

  @override
  Future<void> dispose(String playerId) => _call(playerId, 'dispose');
  // Keep the fake native channel alive until fixture cleanup, so a test can
  // deliver an event already queued by a retired native instance.

  @override
  Future<void> stop(String playerId) => _call(playerId, 'stop');
  @override
  Future<void> resume(String playerId) => _call(playerId, 'resume');
  @override
  Future<void> release(String playerId) => _call(playerId, 'release');
  @override
  Future<void> pause(String playerId) => _call(playerId, 'pause');
  @override
  Future<void> seek(String playerId, Duration position) =>
      _call(playerId, 'seek');
  @override
  Future<void> setBalance(String playerId, double balance) =>
      _call(playerId, 'setBalance');
  @override
  Future<void> setVolume(String playerId, double volume) =>
      _call(playerId, 'setVolume');
  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) =>
      _call(playerId, 'setReleaseMode');
  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) =>
      _call(playerId, 'setPlaybackRate');
  @override
  Future<void> setAudioContext(String playerId, AudioContext audioContext) =>
      _call(playerId, 'setAudioContext');
  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) =>
      _call(playerId, 'setPlayerMode');

  @override
  Future<void> setSourceUrl(String playerId, String url,
      {bool? isLocal, String? mimeType}) async {
    try {
      await _call(playerId, 'setSourceUrl');
      _streams[playerId]!.add(
        const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
      );
    } catch (error, stack) {
      _streams[playerId]!.addError(error, stack);
      rethrow;
    }
  }

  @override
  Future<void> setSourceBytes(String playerId, Uint8List bytes,
          {String? mimeType}) =>
      throw UnimplementedError('Tests use DeviceFileSource');
  @override
  Future<int?> getDuration(String playerId) async => 1000;
  @override
  Future<int?> getCurrentPosition(String playerId) async {
    await _call(playerId, 'getCurrentPosition');
    throw StateError('Speech playback must not poll native position');
  }

  @override
  Future<void> emitError(String playerId, String code, String message) async =>
      fail(playerId);
  @override
  Future<void> emitLog(String playerId, String message) async {}
}

class ControlledGlobalAudioPlatform
    extends GlobalAudioplayersPlatformInterface {
  final events = StreamController<GlobalAudioEvent>.broadcast();

  @override
  Future<void> init() async {}
  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => events.stream;
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Future<void> emitGlobalLog(String message) async {}
}
