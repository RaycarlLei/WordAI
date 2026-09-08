import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The small, attributed subset of Reicon used by the community home.
enum ReiconGlyph {
  book,
  archive,
  folderOpen,
  globe,
  refresh,
  chevronRight,
  download,
  upload
}

class Reicon extends StatelessWidget {
  const Reicon(this.glyph, {super.key, this.size, this.color});

  final ReiconGlyph glyph;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final tint =
        color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    return ExcludeSemantics(
      child: Opacity(
        opacity: theme.opacity ?? 1,
        child: SvgPicture.asset(
          'assets/reicon/${glyph.name}.svg',
          width: size ?? theme.size ?? 24,
          height: size ?? theme.size ?? 24,
          colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
        ),
      ),
    );
  }
}
