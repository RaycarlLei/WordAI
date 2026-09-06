import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_a_i/services/tts_service.dart';
import 'package:word_a_i/widgets/tts_playback_icon.dart';

void main() {
  group('TtsPlaybackArbiter', () {
    test('a newer source permanently invalidates an older request', () {
      final arbiter = TtsPlaybackArbiter();
      addTearDown(arbiter.dispose);

      final first = arbiter.claim('first');
      expect(arbiter.markPlaying(first, 'first'), isTrue);
      expect(arbiter.state.value.isPlayingFor('first'), isTrue);

      final second = arbiter.claim('second');
      expect(arbiter.state.value.isLoadingFor('second'), isTrue);
      expect(arbiter.isCurrent(first, 'first'), isFalse);
      expect(arbiter.markPlaying(first, 'first'), isFalse);

      expect(arbiter.markPlaying(second, 'second'), isTrue);
      expect(arbiter.state.value.isPlayingFor('first'), isFalse);
      expect(arbiter.state.value.isPlayingFor('second'), isTrue);

      arbiter.complete();
      expect(arbiter.state.value.phase, TtsPlaybackPhase.idle);
    });

    test('stop invalidates a request that is still loading', () {
      final arbiter = TtsPlaybackArbiter();
      addTearDown(arbiter.dispose);

      final token = arbiter.claim('slow-request');
      arbiter.stop();

      expect(arbiter.state.value.phase, TtsPlaybackPhase.idle);
      expect(arbiter.markPlaying(token, 'slow-request'), isFalse);
    });
  });

  testWidgets('playing animation follows only the active source',
      (tester) async {
    final arbiter = TtsPlaybackArbiter();
    addTearDown(arbiter.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: Row(
          children: [
            _PlaybackIconHarness(
              key: const ValueKey('source-a'),
              arbiter: arbiter,
              sourceId: 'a',
            ),
            _PlaybackIconHarness(
              key: const ValueKey('source-b'),
              arbiter: arbiter,
              sourceId: 'b',
            ),
          ],
        ),
      ),
    );

    final first = arbiter.claim('a');
    arbiter.markPlaying(first, 'a');
    await tester.pump();
    expect(_animatedIconInside('a'), findsOneWidget);
    expect(_animatedIconInside('b'), findsNothing);

    final second = arbiter.claim('b');
    await tester.pump();
    expect(_animatedIconInside('a'), findsNothing);
    expect(_animatedIconInside('b'), findsNothing);

    arbiter.markPlaying(second, 'b');
    await tester.pump();
    expect(_animatedIconInside('a'), findsNothing);
    expect(_animatedIconInside('b'), findsOneWidget);

    arbiter.complete();
    await tester.pump();
    expect(find.byKey(const ValueKey('tts_playback_icon_animating')),
        findsNothing);
  });
}

Finder _animatedIconInside(String sourceId) => find.descendant(
      of: find.byKey(ValueKey('source-$sourceId')),
      matching: find.byKey(const ValueKey('tts_playback_icon_animating')),
    );

class _PlaybackIconHarness extends StatelessWidget {
  const _PlaybackIconHarness({
    super.key,
    required this.arbiter,
    required this.sourceId,
  });

  final TtsPlaybackArbiter arbiter;
  final String sourceId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TtsPlaybackSnapshot>(
      valueListenable: arbiter.state,
      builder: (context, state, child) => TtsPlaybackIcon(
        isPlaying: state.isPlayingFor(sourceId),
        color: CupertinoColors.activeBlue,
        size: 20,
      ),
    );
  }
}
