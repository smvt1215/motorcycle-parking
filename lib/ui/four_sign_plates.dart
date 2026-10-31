import 'package:material_ui/material_ui.dart';

import 'adaptive/adaptive.dart' show isCupertino;

import '../domain/four_sign.dart';
import '../domain/four_sign_display.dart';

/// The plates' fixed colours (canvas Ver.143 A0–A6): never the dynamic
/// scheme, in light and dark alike, so a plate reads the same everywhere
/// (A4, DynamicColorBuilder on Android).
abstract final class PlateColors {
  static const allowed = Color(0xff186348);
  static const conditional = Color(0xff865500);
  static const unverified = Color(0xff59646c);
  static const denied = Color(0xffa13042);
  static const ink = Color(0xff16313a);
  static const muted = Color(0xff59646c);
  static const paper = Color(0xffffffff);
  static const delayedPaper = Color(0xfffbf3e4);
  static const delayedNote = Color(0xff6b4500);
  static const riderPaper = Color(0xffeef2f3);
}

/// The four signs as a row of plates (Main, A3, A6), or 2×2 at large text
/// sizes (A5); a vehicle that may not park gets one full-width plate.
/// Each plate is a button when [onTap] is given: the preview opens the
/// details at that section, the details' top jumps to it ([current] marks
/// the one shown). The favourites cards and the details' table of
/// contents reuse it.
class FourSignPlates extends StatelessWidget {
  const FourSignPlates({
    super.key,
    required this.plates,
    this.onTap,
    this.current,
    this.compact = false,
  });
  final List<SignPlate> plates;
  final ValueChanged<FourSignFace>? onTap;
  final FourSignFace? current;

  /// Smaller type, for list cards (P4, P6).
  final bool compact;

  /// Whether the plates go 2×2: large text, or too narrow for four.
  static bool gridFor(BuildContext context, double width) =>
      MediaQuery.textScalerOf(context).scale(14) > 18 || width < 300;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tiles = [
        for (final p in plates)
          _Plate(
            key: ValueKey('four-sign-${p.face.name}'),
            plate: p,
            compact: compact,
            // Only a table of contents marks one; elsewhere no plate
            // carries a selected state.
            current: current == null ? null : current == p.face,
            onTap: onTap == null ? null : () => onTap!(p.face),
          ),
      ];
      if (tiles.length == 1) return tiles.single;
      final grid = gridFor(context, constraints.maxWidth);
      final gap = grid ? 8.0 : 6.0;
      Widget row(List<Widget> items) => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, t) in items.indexed) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(child: t),
            ],
          ],
        ),
      );
      if (!grid) return row(tiles);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i += 2) ...[
            if (i > 0) SizedBox(height: gap),
            row(tiles.sublist(i, (i + 2).clamp(0, tiles.length))),
          ],
        ],
      );
    },
  );
}

class _Plate extends StatelessWidget {
  const _Plate({
    super.key,
    required this.plate,
    required this.compact,
    required this.current,
    this.onTap,
  });
  final SignPlate plate;
  final bool compact;

  /// Whether this is the section shown; null where nothing is.
  final bool? current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (
      Color fill,
      Color fg,
      Color label,
      Color? border,
      bool dashed,
    ) = switch (plate.tone) {
      PlateTone.allowed => (
        PlateColors.allowed,
        PlateColors.paper,
        PlateColors.paper,
        null,
        false,
      ),
      PlateTone.conditional => (
        PlateColors.conditional,
        PlateColors.paper,
        PlateColors.paper,
        null,
        false,
      ),
      PlateTone.unverified => (
        PlateColors.unverified,
        PlateColors.paper,
        PlateColors.paper,
        null,
        false,
      ),
      PlateTone.denied => (
        PlateColors.denied,
        PlateColors.paper,
        PlateColors.paper,
        null,
        false,
      ),
      PlateTone.line => (
        PlateColors.paper,
        PlateColors.ink,
        PlateColors.muted,
        PlateColors.ink,
        false,
      ),
      PlateTone.dashed => (
        PlateColors.paper,
        PlateColors.ink,
        PlateColors.muted,
        PlateColors.muted,
        true,
      ),
      PlateTone.delayed => (
        PlateColors.delayedPaper,
        PlateColors.conditional,
        PlateColors.delayedNote,
        PlateColors.conditional,
        false,
      ),
      PlateTone.rider => (
        PlateColors.riderPaper,
        PlateColors.ink,
        PlateColors.muted,
        null,
        false,
      ),
    };
    final solid = border == null && plate.tone != PlateTone.rider;
    final small = TextStyle(
      fontSize: 11,
      height: 1.3,
      color: solid ? label.withValues(alpha: .92) : label,
    );
    final big = TextStyle(
      fontSize: compact ? 15 : 16,
      fontWeight: FontWeight.w700,
      height: 1.25,
      color: fg,
    );
    const radius = BorderRadius.all(Radius.circular(10));
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(plate.question, style: small),
          const SizedBox(height: 4),
          if (plate.meters.isNotEmpty) ...[
            _Meters(levels: plate.meters),
            const SizedBox(height: 4),
          ],
          Text(plate.main, style: big),
          if (plate.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(plate.note, style: small),
          ],
          if (plate.tag case final tag?) ...[
            const SizedBox(height: 4),
            DecoratedBox(
              decoration: const BoxDecoration(
                color: PlateColors.ink,
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                child: Text(
                  tag,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: PlateColors.paper,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    Widget box = Container(
      constraints: BoxConstraints(minHeight: compact ? 64 : 74),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: border != null && !dashed
            ? Border.all(color: border, width: 1.5)
            : null,
      ),
      child: dashed
          ? CustomPaint(
              painter: _DashedBorder(color: border!),
              child: content,
            )
          : content,
    );
    if (current == true) {
      box = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: Border.all(color: PlateColors.ink, width: 2),
        ),
        child: Padding(padding: const EdgeInsets.all(2), child: box),
      );
    }
    return Semantics(
      button: onTap != null,
      selected: current,
      label: plate.semantics,
      onTap: onTap,
      excludeSemantics: true,
      // iOS dims on press (HIG); Android keeps the Material ripple.
      child: isCupertino
          ? _PressOpacity(onTap: onTap, child: box)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(borderRadius: radius, onTap: onTap, child: box),
            ),
    );
  }
}

/// A plate that dims while pressed, as iOS buttons do.
class _PressOpacity extends StatefulWidget {
  const _PressOpacity({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_PressOpacity> createState() => _PressOpacityState();
}

class _PressOpacityState extends State<_PressOpacity> {
  bool down = false;

  void press(bool value) {
    if (widget.onTap != null && down != value) setState(() => down = value);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: widget.onTap,
    onTapDown: (_) => press(true),
    onTapUp: (_) => press(false),
    onTapCancel: () => press(false),
    child: AnimatedOpacity(
      opacity: down ? .55 : 1,
      duration: Duration(milliseconds: down ? 10 : 120),
      child: widget.child,
    ),
  );
}

/// Riders' levels as 3-bar meters (A6); two side by side, slashed, when
/// reports disagree.
class _Meters extends StatelessWidget {
  const _Meters({required this.levels});
  final List<int> levels;

  Widget _meter(int level, double width) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      for (final (i, h) in const [6.0, 10.0, 14.0].indexed) ...[
        if (i > 0) SizedBox(width: width < 8 ? 2 : 3),
        Container(
          width: width,
          height: h,
          decoration: BoxDecoration(
            color: i < level ? PlateColors.ink : PlateColors.paper,
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            border: Border.all(color: PlateColors.ink, width: 1.5),
          ),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 14,
    child: levels.length == 1
        ? _meter(levels.single, 8)
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _meter(levels.first, 6),
              const SizedBox(width: 5),
              Transform.rotate(
                angle: .35,
                child: Container(
                  width: 1.5,
                  height: 14,
                  color: PlateColors.muted,
                ),
              ),
              const SizedBox(width: 5),
              _meter(levels.last, 6),
            ],
          ),
  );
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 1.5, dash = 5.0, gap = 3.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    final rect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(w / 2),
      const Radius.circular(10),
    );
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}
