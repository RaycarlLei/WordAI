import 'dart:convert';
import 'dart:typed_data';

class SpeechAudioException implements Exception {
  const SpeechAudioException(this.code);
  final String code;
  @override
  String toString() => code;
}

/// Rejects JSON/HTML/base64 text disguised as MP3 and truncated first frames.
/// This checks the container; native decoders remain authoritative for playback.
bool isValidMp3(List<int> bytes) {
  if (bytes.length < 4 || bytes.length > 900000) return false;
  var offset = 0;
  if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
    if (bytes.length < 10 ||
        bytes[3] < 2 ||
        bytes[3] > 4 ||
        bytes.sublist(6, 10).any((byte) => byte > 127)) {
      return false;
    }
    offset =
        10 + bytes[6] * 2097152 + bytes[7] * 16384 + bytes[8] * 128 + bytes[9];
    if (bytes[3] == 4 && bytes[5] & 16 != 0) offset += 10;
  }
  if (offset + 4 > bytes.length) return false;
  final b = bytes[offset + 1];
  final c = bytes[offset + 2];
  final version = (b >> 3) & 3;
  final bitrateIndex = c >> 4;
  final rateIndex = (c >> 2) & 3;
  if (bytes[offset] != 255 ||
      b & 224 != 224 ||
      version == 1 ||
      (b >> 1) & 3 != 1 ||
      bitrateIndex == 0 ||
      bitrateIndex == 15 ||
      rateIndex == 3) {
    return false;
  }
  final bitrates = version == 3
      ? const [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
      : const [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
  final rate = const [44100, 48000, 32000][rateIndex] /
      (version == 3
          ? 1
          : version == 2
              ? 2
              : 4);
  final frameLength =
      ((version == 3 ? 144 : 72) * bitrates[bitrateIndex] * 1000 / rate)
              .floor() +
          ((c >> 1) & 1);
  return offset + frameLength <= bytes.length;
}

Uint8List decodeSpeechAudio(String encoded) {
  if (encoded.length > 1200000) {
    throw const SpeechAudioException('speech-payload-too-large');
  }
  try {
    final bytes = base64Decode(encoded);
    if (!isValidMp3(bytes)) {
      throw const SpeechAudioException('speech-invalid-mp3');
    }
    return bytes;
  } on FormatException {
    throw const SpeechAudioException('speech-invalid-base64');
  }
}
