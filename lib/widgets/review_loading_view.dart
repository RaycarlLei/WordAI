import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '/flutter_flow/flutter_flow_theme.dart';

/// Quiet, layout-matched placeholders. Only one ticker and no full-screen
/// blur/shader; no invented percentage while the amount of work is unknown.
class ReviewLoadingView extends StatefulWidget {
  const ReviewLoadingView(
      {super.key,
      required this.text,
      required this.detail,
      required this.hint});
  final String text, detail, hint;

  @override
  State<ReviewLoadingView> createState() => _ReviewLoadingViewState();
}

class _ReviewLoadingViewState extends State<ReviewLoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = .5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget bar(double width, {double height = 12}) => FractionallySizedBox(
        widthFactor: width,
        alignment: Alignment.centerLeft,
        child: Container(
            height: height,
            decoration: BoxDecoration(
                color: theme.secondaryText.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(20))));
    Widget surface(Widget child, {double padding = 20}) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.primary.withValues(alpha: dark ? .09 : .05),
                  theme.secondaryBackground.withValues(alpha: .5)
                ]),
            border:
                Border.all(color: theme.secondaryText.withValues(alpha: .12))),
        child: child);
    return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
              key: const ValueKey('review-loading-scroll'),
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 28),
              child: Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                                padding:
                                    const EdgeInsets.only(top: 3, right: 10),
                                child: Icon(CupertinoIcons.sparkles,
                                    size: 23, color: theme.primary)),
                            Expanded(
                                child: Text(widget.text,
                                    style: theme.titleLarge.copyWith(
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -.4))),
                          ]),
                      const SizedBox(height: 10),
                      Semantics(
                          liveRegion: true,
                          child: AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            child: Align(
                                key: ValueKey(widget.detail),
                                alignment: Alignment.centerLeft,
                                child: Text(widget.detail,
                                    style: theme.bodySmall.copyWith(
                                        color: theme.secondaryText,
                                        height: 1.4))),
                          )),
                      const SizedBox(height: 28),
                      ExcludeSemantics(
                          child: RepaintBoundary(
                              child: AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, child) => Opacity(
                            opacity: .58 + .3 * _pulse.value, child: child),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              bar(.24, height: 10),
                              const SizedBox(height: 14),
                              surface(
                                  Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 16),
                                        bar(.88, height: 19),
                                        const SizedBox(height: 14),
                                        bar(.64, height: 19),
                                        const SizedBox(height: 16),
                                      ]),
                                  padding: 24),
                              const SizedBox(height: 20),
                              for (final width in [.62, .78, .5, .7]) ...[
                                surface(bar(width, height: 14)),
                                const SizedBox(height: 10),
                              ],
                            ]),
                      ))),
                      const SizedBox(height: 12),
                      Text(widget.hint,
                          textAlign: TextAlign.center,
                          style: theme.bodySmall.copyWith(
                              color: theme.secondaryText, height: 1.4)),
                    ]),
              )),
            ));
  }
}
