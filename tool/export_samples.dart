// Run with: flutter test tool/export_samples.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_a_i/sample_words.dart';

void main() {
  test('export original sample dataset', () {
    File('examples/words.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert(sampleWords().map((word) => word.toJson()).toList()));
  });
}
