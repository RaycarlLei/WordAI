import 'package:flutter_test/flutter_test.dart';
import 'package:word_a_i/services/review_pronunciation.dart';

void main() {
  test('same word plays again in a new question, but rebuilds never repeat it',
      () async {
    final words = <String>[];
    final audio = ReviewPronunciation(
      play: (word) async {
        words.add(word);
      },
      stop: () async {},
    );
    audio.show('round1:target:context', ' hello ');
    audio.show('round1:target:context', 'hello');
    audio.show('round2:target:independent', 'hello');
    expect(words, ['hello', 'hello']);
    audio.dispose();
    audio.show('round3:target:context', 'hello');
    expect(words, hasLength(2));
  });

  test(
      'audio failures and cleanup failures do not escape or block another word',
      () async {
    final words = <String>[];
    final audio = ReviewPronunciation(
      play: (word) async {
        words.add(word);
        throw StateError('offline');
      },
      stop: () async {
        throw StateError('player unavailable');
      },
    );
    audio.show('first', 'first');
    audio.stop();
    audio.show('second', 'second');
    audio.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(words, ['first', 'second']);
  });
}
