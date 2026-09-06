import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

/// A borderless iOS-style speaker glyph whose sound waves move only while the
/// matching utterance is actually playing.
class TtsPlaybackIcon extends StatefulWidget {
  const TtsPlaybackIcon({
    super.key,
    required this.isPlaying,
    required this.color,
    required this.size,
  });

  final bool isPlaying;
  final Color color;
  final double size;

  @override
  State<TtsPlaybackIcon> createState() => _TtsPlaybackIconState();
}

class _TtsPlaybackIconState extends State<TtsPlaybackIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 920),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(TtsPlaybackIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.isPlaying && !_reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isPlaying || _reduceMotion) {
      return Icon(
        widget.isPlaying
            ? CupertinoIcons.speaker_3_fill
            : CupertinoIcons.speaker_2_fill,
        key: ValueKey(widget.isPlaying
            ? 'tts_playback_icon_active_static'
            : 'tts_playback_icon_idle'),
        color: widget.color,
        size: widget.size,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final value = _controller.value;
        final icon = switch (value) {
          < 0.22 => CupertinoIcons.speaker_1_fill,
          < 0.52 => CupertinoIcons.speaker_2_fill,
          < 0.78 => CupertinoIcons.speaker_3_fill,
          _ => CupertinoIcons.speaker_2_fill,
        };
        final pulse = 1 + math.sin(value * math.pi * 2) * .035;
        return Transform.scale(
          scale: pulse,
          child: Icon(
            icon,
            key: const ValueKey('tts_playback_icon_animating'),
            color: widget.color,
            size: widget.size,
          ),
        );
      },
    );
  }
}
