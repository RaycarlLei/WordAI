import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:word_a_i/services/community_gateway.dart';
import 'package:word_a_i/services/speech_audio.dart';

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final requests = <http.BaseRequest>[];
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return respond(request);
  }

  @override
  void close() => closes++;
}

Uint8List _mp3() => Uint8List(417)..setRange(0, 4, [0xff, 0xfb, 0x90, 0]);

CommunityGateway _gateway(_Client client, {int timeoutMs = 1000}) =>
    CommunityGateway(
      baseUrl: 'https://speech.example/api',
      requestTimeout: Duration(milliseconds: timeoutMs),
      clientFactory: () => client,
    );

final _timesOut = throwsA(isA<CommunityGatewayException>()
    .having((error) => error.code, 'code', 'timeout'));

void main() {
  test('valid audio uses one owned request and preserves the HTTPS endpoint',
      () async {
    final audio = _mp3();
    final client = _Client((request) async {
      expect(request, isA<http.AbortableRequest>());
      expect(request.url.toString(), 'https://speech.example/api/tts');
      expect(request.followRedirects, isFalse);
      expect((request as http.Request).body, 'hello');
      return http.StreamedResponse(Stream.value(audio), 200);
    });
    expect(await _gateway(client).synthesizeSpeech('hello'), audio);
    expect(client.requests, hasLength(1));
    expect(client.closes, 1);
  });

  test('continuous body progress cannot extend the total request deadline',
      () async {
    Timer? producer;
    var cancelled = false;
    var aborted = false;
    var chunks = 0;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        producer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          chunks++;
          controller.add([0]);
        });
      },
      onCancel: () {
        cancelled = true;
        producer?.cancel();
      },
    );
    addTearDown(() {
      producer?.cancel();
      unawaited(controller.close());
    });
    final client = _Client((request) async {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
      });
      return http.StreamedResponse(controller.stream, 200);
    });
    await expectLater(
        _gateway(client, timeoutMs: 100).synthesizeSpeech('hello'), _timesOut);
    await Future<void>.delayed(Duration.zero);
    expect(chunks, greaterThan(0));
    expect(cancelled, isTrue);
    expect(aborted, isTrue);
    expect(client.closes, 1);
    expect(client.requests, hasLength(1));
  });

  test('header time consumes the same budget as the response body', () async {
    final client = _Client((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 70));
      return http.StreamedResponse(
          Stream.fromFuture(
              Future.delayed(const Duration(milliseconds: 70), _mp3)),
          200);
    });
    await expectLater(
        _gateway(client, timeoutMs: 100).synthesizeSpeech('hello'), _timesOut);
    expect(client.closes, 1);
  });

  test('a stalled header is aborted and late failure remains observed',
      () async {
    final headers = Completer<http.StreamedResponse>();
    var aborted = false;
    final client = _Client((request) {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
      });
      return headers.future;
    });
    await expectLater(
        _gateway(client, timeoutMs: 30).synthesizeSpeech('hello'), _timesOut);
    headers.completeError(StateError('late network failure'));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
    expect(client.closes, 1);
  });

  test('late headers do not start reading a body after timeout', () async {
    final headers = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>();
    final client = _Client((_) => headers.future);
    await expectLater(
        _gateway(client, timeoutMs: 30).synthesizeSpeech('hello'), _timesOut);
    headers.complete(http.StreamedResponse(body.stream, 200));
    await Future<void>.delayed(Duration.zero);
    expect(body.hasListener, isFalse);
    expect(client.closes, 1);
    unawaited(body.close());
  });

  test('oversized body without content-length is cancelled', () async {
    var cancelled = false;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () => body.add(Uint8List(900001)),
      onCancel: () => cancelled = true,
    );
    final client =
        _Client((_) async => http.StreamedResponse(body.stream, 200));
    await expectLater(
        _gateway(client).synthesizeSpeech('hello'),
        throwsA(isA<SpeechAudioException>().having(
            (error) => error.code, 'code', 'speech-payload-too-large')));
    expect(cancelled, isTrue);
    expect(client.closes, 1);
    unawaited(body.close());
  });

  test('declared oversized response is rejected before reading its body',
      () async {
    final body = StreamController<List<int>>();
    final client = _Client((_) async =>
        http.StreamedResponse(body.stream, 200, contentLength: 900001));
    await expectLater(_gateway(client).synthesizeSpeech('hello'),
        throwsA(isA<SpeechAudioException>()));
    expect(body.hasListener, isFalse);
    expect(client.closes, 1);
    unawaited(body.close());
  });

  test('redirect and invalid audio fail without retrying', () async {
    for (final status in [302, 200]) {
      final client = _Client((_) async =>
          http.StreamedResponse(Stream.value([0x7b, 0x7d]), status));
      await expectLater(
          _gateway(client).synthesizeSpeech('hello'),
          throwsA(status == 302
              ? isA<CommunityGatewayException>()
              : isA<SpeechAudioException>()));
      expect(client.closes, 1);
      expect(client.requests, hasLength(1));
    }
  });

  test('transport errors close the owned client', () async {
    final client = _Client((_) => Future.error(StateError('offline')));
    await expectLater(
        _gateway(client).synthesizeSpeech('hello'), throwsA(isA<StateError>()));
    expect(client.closes, 1);
  });

  test('invalid endpoints and deadlines never allocate a client', () async {
    var opened = false;
    http.Client factory() {
      opened = true;
      throw StateError('must not be called');
    }

    await expectLater(
        CommunityGateway(baseUrl: '', clientFactory: factory)
            .synthesizeSpeech('hello'),
        throwsA(isA<CommunityGatewayException>()));
    for (final duration in [
      Duration.zero,
      const Duration(milliseconds: -1),
      const Duration(seconds: 11),
    ]) {
      expect(
          () => CommunityGateway(
              requestTimeout: duration, clientFactory: factory),
          throwsArgumentError);
    }
    expect(opened, isFalse);
  });
}
