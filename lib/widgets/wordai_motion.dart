import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Shared motion language for WordAI.
///
/// Durations stay deliberately short enough to preserve responsiveness while
/// the curves avoid abrupt starts and stops. Every helper collapses motion
/// when iOS Reduce Motion or an equivalent accessibility preference is active.
abstract final class WordAIMotion {
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 320);
  static const Duration emphasized = Duration(milliseconds: 420);

  static const Curve standardCurve = Cubic(0.20, 0.80, 0.20, 1.00);
  static const Curve emphasizedCurve = Cubic(0.16, 1.00, 0.30, 1.00);
  static const Curve exitCurve = Cubic(0.40, 0.00, 1.00, 1.00);

  static const PageTransitionsTheme pageTransitionsTheme = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
    },
  );

  static bool reduceMotion(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    return media?.disableAnimations == true ||
        media?.accessibleNavigation == true;
  }

  static Duration duration(BuildContext context, Duration preferred) =>
      reduceMotion(context) ? Duration.zero : preferred;

  static AnimationStyle sheetAnimationStyle(BuildContext context) =>
      AnimationStyle(
        duration: duration(context, emphasized),
        reverseDuration: duration(context, standard),
      );

  static Widget fadeThrough(
    BuildContext context,
    Animation<double> animation,
    Widget child, {
    double verticalOffset = 10,
    double beginScale = 0.985,
  }) {
    if (reduceMotion(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: emphasizedCurve,
      reverseCurve: exitCurve,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, verticalOffset / 100),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: beginScale, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

/// Shared glass-dialog route. This retains normal dialog semantics while
/// avoiding the abrupt default Material scale transition.
Future<T?> showWordAIGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.34),
    transitionDuration: WordAIMotion.duration(
      context,
      WordAIMotion.emphasized,
    ),
    pageBuilder: (dialogContext, _, __) => builder(dialogContext),
    transitionBuilder: (dialogContext, animation, _, child) =>
        WordAIMotion.fadeThrough(
      dialogContext,
      animation,
      child,
      verticalOffset: 4,
      beginScale: 0.94,
    ),
  );
}
