import 'package:flutter/material.dart';

import '../../domain/availability_display.dart';
import 'map_legend.dart';

/// Paper white behind delayed and car-bay pills, from the design palette.
const capsulePaper = Color(0xfff9fbfc);

/// A space count beside a marker. Always neutral ink: colour and shape
/// belong to the eligibility marker alone, so a 「剩 20」 next to a red
/// square never reads as parkable.
class AvailabilityCapsuleView extends StatelessWidget {
  const AvailabilityCapsuleView({
    super.key,
    required this.capsule,
    this.scale = 1,
  });
  final AvailabilityCapsule capsule;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final style = capsule.style;
    final filled = style == CapsuleStyle.live;
    final ink = filled ? Colors.white : badgeInk;
    final delayed = style == CapsuleStyle.delayed;
    // The design canvas pads live pills 10/9 and delayed ones 9/8.
    final (left, right) = switch (style) {
      CapsuleStyle.live => (10.0, 9.0),
      CapsuleStyle.delayed => (9.0, 8.0),
      // 7 on the 22-high reference table, scaled to the map's 24.
      CapsuleStyle.car => (7 * 24 / 22, 7 * 24 / 22),
    };
    return Semantics(
      label: capsule.semantics,
      excludeSemantics: true,
      child: Container(
        height: 24 * scale,
        padding: EdgeInsets.fromLTRB(left * scale, 0, right * scale, 0),
        decoration: BoxDecoration(
          color: filled ? badgeInk : capsulePaper,
          borderRadius: BorderRadius.circular(12 * scale),
          border: Border.all(
            // Live pills sit on the map with a white keyline; delayed ones
            // trade it for an ink outline; car bays use a thinner one.
            color: switch (style) {
              CapsuleStyle.live => Colors.white,
              CapsuleStyle.delayed => badgeInk,
              CapsuleStyle.car => badgeInk,
            },
            width: (style == CapsuleStyle.car ? 1.25 : 2) * scale,
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 6,
              // .2 for the outlined delayed pill, .27 otherwise.
              color: style != CapsuleStyle.live
                  ? const Color(0x33000000)
                  : const Color(0x44000000),
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (style == CapsuleStyle.car) ...[
              CapsuleCar(size: 13 * scale, color: ink),
              SizedBox(width: 3 * scale),
            ],
            if (delayed || capsule.delayed) ...[
              CapsuleClock(size: 12 * scale, color: ink),
              // The car pill keeps its 3 gap after the clock as well.
              SizedBox(width: (delayed ? 4 : 3) * scale),
            ],
            Text(
              capsule.text,
              // Markers keep their size at any text scale, like the badge;
              // the screen reader label carries the meaning.
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: ink,
                fontSize: 13 * scale,
                fontWeight: FontWeight.w700,
                height: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The design's line clock (a circle of radius 9 and the hands
/// `M12 7v5l3 2` in a 24 box, 2.6 stroke, round caps), for delayed counts.
class CapsuleClock extends StatelessWidget {
  const CapsuleClock({super.key, required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('capsule-clock'),
    size: Size.square(size),
    painter: _ClockPainter(color),
  );
}

class _ClockPainter extends CustomPainter {
  const _ClockPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(12, 12), 9, paint);
    canvas.drawPath(
      Path()
        ..moveTo(12, 7)
        ..lineTo(12, 12)
        ..lineTo(15, 14),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.color != color;
}

/// The design's line car (2.4 stroke in a 24 box) for car-bay counts.
class CapsuleCar extends StatelessWidget {
  const CapsuleCar({super.key, required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('capsule-car'),
    size: Size.square(size),
    painter: _CarPainter(color),
  );
}

class _CarPainter extends CustomPainter {
  const _CarPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // M4 16v-3.5L6.2 7h11.6L20 12.5V16z, wheels and the waist line.
    canvas.drawPath(
      Path()
        ..moveTo(4, 16)
        ..lineTo(4, 12.5)
        ..lineTo(6.2, 7)
        ..lineTo(17.8, 7)
        ..lineTo(20, 12.5)
        ..lineTo(20, 16)
        ..close()
        ..moveTo(6.5, 16)
        ..lineTo(6.5, 18.5)
        ..moveTo(17.5, 16)
        ..lineTo(17.5, 18.5)
        ..moveTo(4, 12.5)
        ..lineTo(20, 12.5),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CarPainter old) => old.color != color;
}

/// Room each side of a marker for its pills, so the marker stays centred on
/// its point when the pills sit to its right.
const capsuleReach = 136.0;

/// [marker] with [capsules] to its right, slightly overlapping it. The box
/// is symmetric so a map that centres it on the point keeps the marker
/// there; the empty side takes no taps.
class MarkerWithCapsules extends StatelessWidget {
  const MarkerWithCapsules({
    super.key,
    required this.marker,
    required this.capsules,
    this.markerSize = 38,
    this.boxSize = 48,
    this.selected = false,
  });
  final Widget marker;
  final List<AvailabilityCapsule> capsules;
  final double markerSize, boxSize;
  final bool selected;

  static double width(double boxSize) => boxSize + capsuleReach * 2;

  @override
  Widget build(BuildContext context) {
    if (capsules.isEmpty) return marker;
    final scale = selected ? 26 / 24 : 1.0;
    final size = selected ? markerSize * selectedScale : markerSize;
    final total = width(boxSize);
    return SizedBox(
      width: total,
      height: boxSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: capsuleReach,
            top: 0,
            width: boxSize,
            height: boxSize,
            child: marker,
          ),
          Positioned(
            // Overlaps the marker by 5 (6 when selected), centred on it.
            left: total / 2 + size / 2 - (selected ? 6 : 5),
            top: boxSize / 2 - 12 * scale,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, capsule) in capsules.indexed) ...[
                  if (i > 0) const SizedBox(width: 4),
                  AvailabilityCapsuleView(capsule: capsule, scale: scale),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A spot the 「目前有位」 filter leaves out: a small grey dot in place, so
/// riders see the spots are there but have no space. Not the faded full
/// marker, which means a spot reported gone.
class ExcludedSpotDot extends StatelessWidget {
  const ExcludedSpotDot({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      key: const ValueKey('excluded-spot-dot'),
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: unverifiedColor,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(
            blurRadius: 3,
            color: Color(0x33000000),
            offset: Offset(0, 1),
          ),
        ],
      ),
    ),
  );
}
