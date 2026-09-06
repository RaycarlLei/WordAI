import 'package:flutter/foundation.dart';

void reportSpeechFailure(String stage, String code) {
  debugPrint('Audio unavailable: $stage/$code');
}
