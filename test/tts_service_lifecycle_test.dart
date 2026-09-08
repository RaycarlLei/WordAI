import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:word_a_i/services/speech_audio.dart';
import 'package:word_a_i/services/tts_service.dart';

import 'support/controlled_audio_platform.dart';

const _deadline = Duration(seconds: 1);
final _unavailable = throwsA(isA<SpeechAudioException>()
    .having((error) => error.code, 'code', 'speech-audio-unavailable'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final global = ControlledGlobalAudioPlatform();
  GlobalAudioplayersPlatformInterface.instance = global;
  tearDownAll(() => global.events.close());

  _lifecycleTest(
      'device speech does not allocate or stop an unused media backend',
      (h) async {
    expect(await h.speak('system'), isTrue);
    expect(h.players, isEmpty);
    expect(h.systemCalls.where((method) => method == 'stop'), isEmpty);
    await h.service.stopSource('system');
    expect(h.systemCalls.last, 'stop');
  });

  _lifecycleTest('retired media events cannot finish or recover system speech',
      (h) async {
    await h.media('media');
    await h.speak('system');
    h.platform.complete('p1');
    h.platform.fail('p1');
    await _flush();
    expect(h.service.playbackState.value.isPlayingFor('system'), isTrue);
    expect(h.systemCalls.where((method) => method == 'speak'), hasLength(1));
    await h.service.stopSource('system');
    expect(h.systemCalls.last, 'stop');
  });

  _lifecycleTest('system events cannot complete or stop a media owner',
      (h) async {
    await h.speak('system');
    await h.media('media');
    await h.systemEvent('speak.onComplete');
    await h.systemEvent('speak.onCancel');
    await h.systemEvent('speak.onError');
    expect(h.service.playbackState.value.isPlayingFor('media'), isTrue);
    expect(h.platform.calls.where((call) => call == 'p1:stop'), isEmpty);
  });

  _lifecycleTest('a system callback cannot erase stopSource ownership',
      (h) async {
    await h.speak('first');
    await h.speak('second');
    // The locked flutter_tts protocol cannot distinguish a delayed callback
    // for "first" from completion of "second". Its UI indicator is advisory.
    await h.systemEvent('speak.onComplete');
    expect(h.service.playbackState.value.phase, TtsPlaybackPhase.idle);
    final stops = h.systemCalls.where((method) => method == 'stop').length;
    await h.service.stopSource('second');
    expect(h.systemCalls.where((method) => method == 'stop'),
        hasLength(stops + 1));
  });

  _lifecycleTest(
      'each media utterance retires its player before a new one starts',
      (h) async {
    await h.media('first');
    await h.media('second');
    h.platform.complete('p1');
    h.platform.fail('p1');
    await _flush();
    expect(h.service.playbackState.value.isPlayingFor('second'), isTrue);
    expect(h.platform.calls.indexOf('p1:dispose'),
        lessThan(h.platform.calls.indexOf('p2:resume')));
    h.platform.complete('p2');
    await _flush();
    expect(h.service.playbackState.value.phase, TtsPlaybackPhase.idle);
    await h.service.stopSource('second');
    expect(h.platform.calls, contains('p2:stop'));
  });

  _lifecycleTest('a delayed download cannot play after its source is stopped',
      (h) async {
    final download = Completer<String>();
    h.audioLoader = (_) => download.future;
    final pending =
        h.service.generateAndPlay(text: 'word', sourceId: 'download');
    await _flush();
    await h.service.stopSource('download');
    await h.speak('new');
    download.complete('/fake/word.mp3');
    expect(await pending, isFalse);
    expect(h.players, isEmpty);
    expect(h.service.playbackState.value.isPlayingFor('new'), isTrue);
  });

  _lifecycleTest(
      'stopSource interrupts preparation without resuming late audio',
      (h) async {
    final source = h.platform.hold('setSourceUrl');
    final pending = h.media('old');
    await _flush();
    expect(h.platform.calls, contains('p1:setSourceUrl'));
    final stopped = h.service.stopSource('old');
    source.complete();
    expect(await pending, isFalse);
    await stopped;
    expect(h.platform.calls, isNot(contains('p1:resume')));
    expect(await h.media('new'), isTrue);
  });

  _lifecycleTest('stopping an old native owner does not cancel a newer claim',
      (h) async {
    await h.media('old');
    final held = h.platform.hold('stop', id: 'p1');
    final newClaim = h.service.beginPlayback('new');
    await _flush();
    final oldStop = h.service.stopSource('old');
    held.complete();
    final token = await newClaim;
    await oldStop;
    expect(h.service.isPlaybackRequestCurrent(token, 'new'), isTrue);
    expect(
        await h.service
            .playAudio('/fake/new.mp3', sourceId: 'new', requestToken: token),
        isTrue);
  });

  _lifecycleTest(
      'hung media stop bounds queued callers and forbids both backends',
      (h) async {
    await h.media('old');
    final held = h.platform.hold('stop', id: 'p1');
    final first = expectLater(h.service.beginPlayback('next'), _unavailable);
    final queued = expectLater(h.service.beginPlayback('queued'), _unavailable);
    await _flush();
    await _flush(_deadline);
    await Future.wait([first, queued]);
    expect(h.service.playbackState.value.phase, TtsPlaybackPhase.unavailable);
    await expectLater(h.media('again'), _unavailable);
    await expectLater(h.speak('again'), _unavailable);
    held.complete();
    await _flush();
    expect(h.players, hasLength(1));
    expect(h.systemCalls, isEmpty);
    expect(h.service.isAudioAvailable, isFalse);
  });

  _lifecycleTest(
      'hung system stop observes a late rejection without restarting',
      (h) async {
    await h.speak('system');
    final held = h.holdSystem('stop');
    final stop = expectLater(h.service.stopSource('system'), _unavailable);
    await _flush();
    await _flush(_deadline);
    await stop;
    held.completeError(StateError('late native error'));
    await _flush();
    await expectLater(h.media('media'), _unavailable);
    expect(h.players, isEmpty);
    expect(h.systemCalls.where((method) => method == 'speak'), hasLength(1));
  });

  for (final method in [
    'create',
    'setAudioContext',
    'setSourceUrl',
    'resume'
  ]) {
    _lifecycleTest(
        'hung media $method is bounded; its late result cannot advance playback',
        (h) async {
      final held = h.platform.hold(method);
      final result = expectLater(h.media('held'), _unavailable);
      await _flush();
      expect(h.platform.calls, contains('p1:$method'));
      await _flush(_deadline);
      await result;
      final audibleCalls =
          h.platform.calls.where((call) => call.endsWith(':resume')).length;
      held.complete();
      await _flush();
      expect(h.platform.calls.where((call) => call.endsWith(':resume')),
          hasLength(audibleCalls));
      expect(h.platform.calls, contains('p1:stop'));
      await expectLater(h.media('new'), _unavailable);
      expect(h.service.playbackState.value.phase, TtsPlaybackPhase.unavailable);
      expect(h.players, hasLength(1));
    });
  }

  for (final method in ['setLanguage', 'speak']) {
    _lifecycleTest('hung system $method prevents later settings and utterances',
        (h) async {
      final held = h.holdSystem(method);
      final result = expectLater(h.speak('held'), _unavailable);
      await _flush();
      await _flush(_deadline);
      await result;
      final callsAtTimeout = List.of(h.systemCalls);
      held.complete(1);
      await _flush();
      expect(h.systemCalls.take(callsAtTimeout.length), callsAtTimeout);
      expect(h.systemCalls.skip(callsAtTimeout.length), everyElement('stop'));
      await expectLater(h.speak('new'), _unavailable);
      expect(h.service.isAudioAvailable, isFalse);
    });
  }

  _lifecycleTest(
      'a source error arriving after timeout is observed and cannot fall back',
      (h) async {
    final held = h.platform.hold('setSourceUrl');
    final result = expectLater(
        h.service.playAudio('/fake/broken.mp3',
            sourceId: 'broken', fallbackText: 'word'),
        _unavailable);
    await _flush();
    await _flush(_deadline);
    await result;
    held.completeError(StateError('late source error'));
    await _flush();
    expect(h.platform.calls, isNot(contains('p1:resume')));
    expect(h.systemCalls, isEmpty);
    expect(h.service.isAudioAvailable, isFalse);
  });

  _lifecycleTest('a rejected source is retired before system fallback',
      (h) async {
    final source = h.platform.hold('setSourceUrl');
    final playback = h.service
        .playAudio('/fake/broken.mp3', sourceId: 'word', fallbackText: 'word');
    await _flush();
    source.completeError(StateError('decoder rejected source'));
    expect(await playback, isTrue);
    expect(h.platform.calls, contains('p1:dispose'));
    expect(h.platform.calls, isNot(contains('p1:resume')));
    expect(h.systemCalls.where((method) => method == 'speak'), hasLength(1));
  });

  _lifecycleTest('a negative system stop response is not a safe handoff',
      (h) async {
    await h.speak('old');
    final stop = h.holdSystem('stop');
    final replacement =
        expectLater(h.media('new'), throwsA(isA<SpeechAudioException>()));
    await _flush();
    stop.complete(0);
    await replacement;
    expect(h.service.playbackState.value.phase, TtsPlaybackPhase.unavailable);
    expect(h.players, isEmpty);
    await expectLater(h.speak('retry'), _unavailable);
  });

  _lifecycleTest(
      'a hung rate change attempts stop before the held call settles',
      (h) async {
    await h.media('word');
    final rate = h.platform.hold('setPlaybackRate');
    final change = expectLater(h.service.setPlaybackRate(0.8), _unavailable);
    await _flush();
    await _flush(_deadline);
    await change;
    expect(rate.isCompleted, isFalse);
    expect(h.platform.calls.where((call) => call == 'p1:stop'), hasLength(1));
    await expectLater(h.service.stopSource('word'), _unavailable);
    rate.complete();
    await _flush();
    expect(h.platform.calls.where((call) => call == 'p1:stop'), hasLength(2));
    expect(h.service.isAudioAvailable, isFalse);
    expect(h.players, hasLength(1));
    expect(h.systemCalls, isEmpty);
  });

  _lifecycleTest(
      'runtime media failure falls back only after confirmed retirement',
      (h) async {
    await h.service
        .playAudio('/fake/broken.mp3', sourceId: 'word', fallbackText: 'word');
    final stop = h.platform.hold('stop', id: 'p1');
    h.platform.fail('p1');
    await _flush();
    expect(h.systemCalls, isEmpty);
    stop.complete();
    await _flush();
    expect(h.platform.calls, contains('p1:dispose'));
    expect(h.systemCalls.where((method) => method == 'speak'), hasLength(1));
    expect(h.service.playbackState.value.isPlayingFor('word'), isTrue);
  });

  _lifecycleTest('failed media recovery stop cannot start system fallback',
      (h) async {
    await h.service
        .playAudio('/fake/broken.mp3', sourceId: 'word', fallbackText: 'word');
    final stop = h.platform.hold('stop', id: 'p1');
    h.platform.fail('p1');
    await _flush();
    stop.completeError(StateError('native stop failed'));
    await _flush();
    expect(h.service.playbackState.value.phase, TtsPlaybackPhase.unavailable);
    expect(h.systemCalls, isEmpty);
  });

  _lifecycleTest(
      'dispose during hung resume is bounded and ignores later events',
      (h) async {
    final resume = h.platform.hold('resume');
    final nativeStop = h.platform.hold('stop');
    final playback = expectLater(
        h.media('word'),
        throwsA(isA<SpeechAudioException>()
            .having((error) => error.code, 'code', 'speech-audio-disposed')));
    await _flush();
    final disposal = h.service.dispose();
    expect(identical(h.service.dispose(), disposal), isTrue);
    await _flush(_deadline);
    await playback;
    await _flush(_deadline);
    await disposal;
    expect(h.platform.calls, isNot(contains('p1:dispose')),
        reason: 'Do not use dispose as a kill switch for pending resume');
    // A late stop may settle before an already dispatched resume. Cleanup
    // must stop again when that resume eventually returns.
    nativeStop.complete();
    await _flush();
    final previousStops =
        h.platform.calls.where((call) => call == 'p1:stop').length;
    resume.complete();
    h.platform.complete('p1');
    h.platform.fail('p1');
    await h.systemEvent('speak.onComplete');
    await _flush();
    expect(h.platform.calls.where((call) => call == 'p1:stop'),
        hasLength(previousStops + 1));
    expect(h.platform.calls.where((call) => call == 'p1:resume'), hasLength(1));
    await expectLater(
        h.media('after disposal'), throwsA(isA<SpeechAudioException>()));
  });

  _lifecycleTest(
      'native disposal has a deadline and never re-enables the service',
      (h) async {
    await h.media('word');
    final held = h.platform.hold('dispose');
    final disposed = h.service.dispose();
    await _flush();
    await _flush(_deadline);
    await disposed;
    held.complete();
    await _flush();
    expect(h.service.isAudioAvailable, isFalse);
    expect(h.players, hasLength(1));
  });

  _lifecycleTest('a paused state subscriber cannot block logical disposal',
      (h) async {
    final subscription = h.service.playerStateStream.listen((_) {})..pause();
    await h.media('word');
    await h.service.dispose();
    await subscription.cancel();
    expect(h.service.isAudioAvailable, isFalse);
  });

  _lifecycleTest('completion, replacement and disposal never poll position',
      (h) async {
    // The factory returns unmodified AudioPlayers. The fake platform rejects
    // position queries, including updater calls made by the plugin itself.
    expect(await h.media('first'), isTrue);
    h.platform.complete('p1');
    await _flush();
    expect(await h.media('second'), isTrue);
    await h.service.stopSource('second');
    await h.service.dispose();
    expect(
        h.platform.calls,
        isNot(contains(predicate<String>(
            (call) => call.endsWith(':getCurrentPosition')))));
    expect(h.platform.calls,
        containsAll(['p1:resume', 'p1:dispose', 'p2:resume', 'p2:dispose']));
  });
}

void _lifecycleTest(
    String description, Future<void> Function(_Harness harness) body) {
  test(description, () async {
    final harness = _Harness();
    try {
      await body(harness);
    } finally {
      harness.releaseGates();
      await _flush();
      await harness.close();
    }
  });
}

// These tests exercise plugin Futures/streams, not widgets. Method gates fix
// event order; the one-second injected deadline leaves ample scheduling room.
Future<void> _flush([Duration duration = Duration.zero]) =>
    Future<void>.delayed(duration);

class _Harness {
  _Harness() {
    AudioplayersPlatformInterface.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_systemChannel, (call) async {
      systemCalls.add(call.method);
      final gate = _systemGates.remove(call.method);
      return gate == null ? 1 : await gate.future;
    });
    tts = FlutterTts();
    service = TTSService.forTesting(
      audioPlayerFactory: () {
        final player = AudioPlayer(playerId: 'p${players.length + 1}');
        players.add(player);
        return player;
      },
      systemTts: tts,
      nativeCallTimeout: _deadline,
      audioLoader: (text) =>
          audioLoader?.call(text) ?? Future.value('/fake/word.mp3'),
    );
  }

  static const _systemChannel = MethodChannel('flutter_tts');
  final platform = ControlledAudioPlatform();
  final players = <AudioPlayer>[];
  final systemCalls = <String>[];
  final _systemGates = <String, Completer<dynamic>>{};
  final _outstanding = <Completer<dynamic>>[];
  late final FlutterTts tts;
  late final TTSService service;
  Future<String> Function(String)? audioLoader;

  Completer<dynamic> holdSystem(String method) {
    final gate = Completer<dynamic>();
    _systemGates[method] = gate;
    _outstanding.add(gate);
    return gate;
  }

  Future<void> systemEvent(String method) => tts.platformCallHandler(
      MethodCall(method, method == 'speak.onError' ? 'native error' : true));

  Future<bool> media(String source) =>
      service.playAudio('/fake/$source.mp3', sourceId: source);

  Future<bool> speak(String source) async {
    final token = await service.beginPlayback(source);
    return service.playSystemSpeech('word',
        sourceId: source, requestToken: token);
  }

  void releaseGates() {
    platform.releaseGates();
    for (final gate in _outstanding) {
      if (!gate.isCompleted) gate.complete(1);
    }
    _systemGates.clear();
  }

  Future<void> close() async {
    await service.dispose();
    // Quarantine deliberately retains a native handle when an earlier call
    // might still act. Test teardown settles every gate before releasing it.
    for (final player in players) {
      if (player.state != PlayerState.disposed) await player.dispose();
    }
    await platform.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_systemChannel, null);
  }
}
