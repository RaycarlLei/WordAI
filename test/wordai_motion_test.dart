import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_a_i/widgets/wordai_motion.dart';

void main() {
  testWidgets('WordAI motion uses one responsive duration scale',
      (tester) async {
    late BuildContext motionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            motionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(WordAIMotion.reduceMotion(motionContext), isFalse);
    expect(
      WordAIMotion.duration(motionContext, WordAIMotion.standard),
      WordAIMotion.standard,
    );
    expect(WordAIMotion.sheetAnimationStyle(motionContext).duration,
        WordAIMotion.emphasized);
  });

  testWidgets('Reduce Motion removes nonessential WordAI transitions',
      (tester) async {
    late BuildContext motionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            disableAnimations: true,
            accessibleNavigation: true,
          ),
          child: Builder(
            builder: (context) {
              motionContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(WordAIMotion.reduceMotion(motionContext), isTrue);
    expect(
      WordAIMotion.duration(motionContext, WordAIMotion.emphasized),
      Duration.zero,
    );
    expect(
      WordAIMotion.sheetAnimationStyle(motionContext).duration,
      Duration.zero,
    );
  });
}
