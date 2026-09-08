import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'speech_audio.dart';

class CommunityGatewayException implements Exception {
  const CommunityGatewayException(this.message, {this.code});
  final String message;
  final String? code;
}

/// No hosted service is configured or contacted by default. Provider secrets
/// belong on the operator's server, never in this client or a dart-define.
class CommunityGateway {
  CommunityGateway({
    this.baseUrl = const String.fromEnvironment('WORD_AI_API_BASE_URL'),
    this.requestTimeout = const Duration(seconds: 10),
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 10)) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout',
          'Must be positive and at most ten seconds.');
    }
  }
  static final instance = CommunityGateway();
  final String baseUrl;
  final Duration requestTimeout;
  // A fresh client belongs to one request and is always closed on completion.
  final http.Client Function() _clientFactory;

  Uri get speechEndpoint {
    final base = Uri.tryParse(baseUrl);
    if (base == null ||
        base.host.isEmpty ||
        base.scheme != 'https' ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const CommunityGatewayException(
          'Configure an HTTPS speech gateway to enable downloads.',
          code: 'unavailable');
    }
    return base.replace(
        path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/tts');
  }

  Future<Uint8List> synthesizeSpeech(String text) async {
    final uri = speechEndpoint;
    final client = _clientFactory();
    final abort = Completer<void>();
    final elapsed = Stopwatch()..start();
    StreamIterator<List<int>>? body;
    const timeout = CommunityGatewayException(
        'Speech download timed out. Please retry.',
        code: 'timeout');

    void checkDeadline() {
      if (elapsed.elapsed >= requestTimeout) throw timeout;
    }

    Future<Uint8List> receive() async {
      final request =
          http.AbortableRequest('POST', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Content-Type'] = 'text/plain; charset=utf-8'
            ..body = text;
      final response = await client.send(request);
      // A late header response must not start another body read after timeout.
      if (abort.isCompleted) throw timeout;
      checkDeadline();
      if (response.statusCode != 200) {
        throw const CommunityGatewayException(
            'Speech is temporarily unavailable.',
            code: 'unavailable');
      }
      if ((response.contentLength ?? 0) > 900000) {
        throw const SpeechAudioException('speech-payload-too-large');
      }
      final stream = StreamIterator(response.stream);
      body = stream;
      final bytes = BytesBuilder(copy: false);
      while (await stream.moveNext()) {
        checkDeadline();
        final chunk = stream.current;
        if (bytes.length + chunk.length > 900000) {
          throw const SpeechAudioException('speech-payload-too-large');
        }
        bytes.add(chunk);
      }
      checkDeadline();
      final result = bytes.takeBytes();
      if (!isValidMp3(result)) {
        throw const SpeechAudioException('speech-invalid-mp3');
      }
      return result;
    }

    try {
      // One deadline includes headers and the entire body, even with progress.
      return await receive()
          .timeout(requestTimeout, onTimeout: () => throw timeout);
    } finally {
      elapsed.stop();
      abort.complete();
      // Cancellation and transport shutdown are real; Future.timeout alone
      // only stops waiting. A slow cancellation must not delay the caller.
      final cancellation = body?.cancel();
      if (cancellation != null) {
        unawaited(cancellation.catchError((Object _) {}));
      }
      client.close();
    }
  }
}
