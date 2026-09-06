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
  CommunityGateway(
      {this.baseUrl = const String.fromEnvironment('WORD_AI_API_BASE_URL')});
  static final instance = CommunityGateway();
  final String baseUrl;

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
    final client = http.Client();
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers['Content-Type'] = 'text/plain; charset=utf-8'
        ..body = text;
      final response =
          await client.send(request).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw const CommunityGatewayException(
            'Speech is temporarily unavailable.',
            code: 'unavailable');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 10))) {
        if (bytes.length + chunk.length > 900000) {
          throw const SpeechAudioException('speech-payload-too-large');
        }
        bytes.add(chunk);
      }
      final result = bytes.takeBytes();
      if (!isValidMp3(result)) {
        throw const SpeechAudioException('speech-invalid-mp3');
      }
      return result;
    } finally {
      client.close();
    }
  }
}
