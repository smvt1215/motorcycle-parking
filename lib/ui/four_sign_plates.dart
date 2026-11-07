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

  /// Outlined plates on the dark details page (A4).
  static const darkInk = Color(0xffe6eef0);
  static const darkMuted = Color(0xffa3b4ba);
  static const darkLine = Color(0xff4a5d64);
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
    this.dense = false,
  });
  final List<SignPlate> plates;
  final ValueChanged<FourSignFace>? onTap;
  final FourSignFace? current;

  /// Smaller type, for list cards (P4, P6).
  final bool compact;

  /// The full-page details' table of contents (A2, A4): each plate only
  /// its question and answer, as tall as a touch target (iOS 44, Android
  /// 48), with a bar under the one shown in place of an outline. Outlined
  /// plates follow the theme's brightness; solid ones keep their colours.
  final bool dense;

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
            dense: dense,
            // Only a table of contents marks one; elsewhere no plate
            // carries a selected state.
            current: current == null ? null : current == p.face,
            onTap: onTap == null ? null : () => onTap!(p.face),
          ),
      ];
      if (tiles.length == 1) {
        // The dense plate stretches to its row; alone it takes its own
        // height.
        return dense ? IntrinsicHeight(child: tiles.single) : tiles.single;
      }
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
    this.dense = false,
    this.onTap,
  });
  final SignPlate plate;
  final bool compact, dense;

  /// Whether this is the section shown; null where nothing is.
  final bool? current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var (
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
    final dark = dense && Theme.of(context).brightness == Brightness.dark;
    if (dark && (border != null || plate.tone == PlateTone.rider)) {
      // A4: outlined plates sit on the dark page, not on white paper.
      (fill, fg, label, border) = switch (plate.tone) {
        PlateTone.dashed => (
          Colors.transparent,
          PlateColors.darkInk,
          PlateColors.darkMuted,
          PlateColors.darkMuted,
        ),
        PlateTone.delayed => (fill, fg, label, border),
        _ => (
          Colors.transparent,
          PlateColors.darkInk,
          PlateColors.darkMuted,
          PlateColors.darkLine,
        ),
      };
    }
    final solid = border == null && plate.tone != PlateTone.rider;
    final small = TextStyle(
      fontSize: 11,
      fontWeight: dense ? FontWeight.w500 : null,
      height: 1.3,
      color: solid ? label.withValues(alpha: .92) : label,
    );
    final big = TextStyle(
      fontSize: dense ? 14 : (compact ? 15 : 16),
      fontWeight: FontWeight.w700,
      height: 1.25,
      color: fg,
    );
    final radius = BorderRadius.all(Radius.circular(dense ? 8 : 10));
    if (dense) {
      return _densePlate(context, fill, fg, border, dashed, small, big, radius);
    }
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(plate.question, style: small),
          const SizedBox(height: 4),
          if (plate.meters.isNotEmpty) ...[
            RiderMeters(levels: plate.meters),
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
              painter: DashedBorder(color: border!),
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

extension on _Plate {
  /// The table of contents' plate (A2): the question over the answer, one
  /// line each, a touch target tall, and the bar under the one shown.
  Widget _densePlate(
    BuildContext context,
    Color fill,
    Color fg,
    Color? border,
    bool dashed,
    TextStyle small,
    TextStyle big,
    BorderRadius radius,
  ) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(plate.question, style: small),
          Text(plate.main, style: big),
        ],
      ),
    );
    final box = Container(
      constraints: BoxConstraints(minHeight: isCupertino ? 44 : 48),
      alignment: AlignmentDirectional.centerStart,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: border != null && !dashed
            ? Border.all(color: border, width: 1.5)
            : null,
      ),
      child: dashed
          ? CustomPaint(
              painter: DashedBorder(color: border!, radius: 8),
              child: content,
            )
          : content,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tile = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: box),
        const SizedBox(height: 5),
        Container(
          key: current == true ? const ValueKey('four-sign-current') : null,
          height: 3,
          decoration: BoxDecoration(
            color: current == true
                ? (dark ? PlateColors.darkInk : PlateColors.ink)
                : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(2)),
          ),
        ),
      ],
    );
    return Semantics(
      button: onTap != null,
      selected: current,
      label: plate.semantics,
      onTap: onTap,
      excludeSemantics: true,
      child: isCupertino
          ? _PressOpacity(onTap: onTap, child: tile)
          : Material(
              type: MaterialType.transparency,
              child: InkWell(borderRadius: radius, onTap: onTap, child: tile),
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
  Widget build(BuildContext context) {
    // Without a tap the plate claims no gesture, so a card around it
    // still gets the tap (Codex P2 on #263).
    if (widget.onTap == null) return widget.child;
    return GestureDetector(
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
}

/// Riders' levels as 3-bar meters (A6); two side by side, slashed, when
/// reports disagree. [ink] and [paper] default to the plates' fixed colours,
/// which sit on a light ground in both themes.
class RiderMeters extends StatelessWidget {
  const RiderMeters({
    super.key,
    required this.levels,
    this.ink = PlateColors.ink,
    this.paper = PlateColors.paper,
  });
  final List<int> levels;
  final Color ink, paper;

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
            color: i < level ? ink : paper,
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            border: Border.all(color: ink, width: 1.5),
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

class DashedBorder extends CustomPainter {
  const DashedBorder({required this.color, this.radius = 10});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 1.5, dash = 5.0, gap = 3.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    final rect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(w / 2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorder old) =>
      old.color != color || old.radius != radius;
}
