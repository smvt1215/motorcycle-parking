import '../../ui/adaptive/adaptive.dart';

import '../../domain/availability_display.dart';
import '../../domain/capsule_layout.dart';
import 'map_legend.dart';

/// Paper white behind delayed and car-bay pills, from the design palette.
const capsulePaper = Color(0xfff9fbfc);

/// Inner padding (left, right) per style, from the MapBadges board.
(double, double) _padding(CapsuleStyle style) => switch (style) {
  CapsuleStyle.live => (10, 9),
  CapsuleStyle.delayed => (8, 9),
  CapsuleStyle.car => (8, 9),
  CapsuleStyle.full => (10, 9),
  CapsuleStyle.suspended => (8, 9),
};

/// Light grey behind 「已滿」 and deep purple behind 「暫停」 (canvas v30).
const capsuleFull = Color(0xffc3ccd0), capsuleSuspended = Color(0xff5e4b75);

/// The app font, named here so the measured width in [capsuleWidth] and
/// the drawn pill use the same face.
const _capsuleText = TextStyle(
  fontFamily: 'Outfit',
  fontSize: 13,
  fontWeight: FontWeight.w700,
  height: 1,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// The pill's width at [scale], for laying out crowded markers.
double capsuleWidth(AvailabilityCapsule capsule, {double scale = 1}) {
  final painter = TextPainter(
    text: TextSpan(text: capsule.text, style: _capsuleText),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout();
  final (left, right) = _padding(capsule.style);
  final icons = switch (capsule.style) {
    CapsuleStyle.live => 0.0,
    CapsuleStyle.delayed => 12 + 4,
    CapsuleStyle.car => 12 + 3 + (capsule.delayed ? 12 + 3 : 0),
    CapsuleStyle.full => 0.0,
    CapsuleStyle.suspended => 12 + 3,
  };
  final width = 4 + left + right + icons + painter.width;
  painter.dispose();
  return width * scale;
}

/// Width of a row of pills with their 4 gaps.
double capsuleRowWidth(
  List<AvailabilityCapsule> capsules, {
  double scale = 1,
}) => capsules.isEmpty
    ? 0
    : capsules
              .map((c) => capsuleWidth(c, scale: scale))
              .reduce((a, b) => a + b) +
          4 * (capsules.length - 1);

/// A space count above a marker. Always neutral ink: colour and shape
/// belong to the eligibility marker alone, so a 「剩 20」 over a red square
/// never reads as parkable. Every pill has the same 2px white keyline;
/// delayed and car-bay pills draw their ink outline inside it, so dark and
/// light pills are the same size.
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
    final (fill, ink) = switch (style) {
      CapsuleStyle.live => (badgeInk, Colors.white),
      CapsuleStyle.full => (capsuleFull, badgeInk),
      CapsuleStyle.suspended => (capsuleSuspended, Colors.white),
      CapsuleStyle.delayed || CapsuleStyle.car => (capsulePaper, badgeInk),
    };
    // Solid pills cast .27, the outlined paper ones .2.
    final solid = fill != capsulePaper;
    final delayed = style == CapsuleStyle.delayed;
    final (left, right) = _padding(style);
    final outline = switch (style) {
      CapsuleStyle.live => 0.0,
      CapsuleStyle.delayed => 2.0,
      CapsuleStyle.car => 1.25,
      CapsuleStyle.full || CapsuleStyle.suspended => 0.0,
    };
    return Semantics(
      label: capsule.semantics,
      excludeSemantics: true,
      child: Container(
        height: 24 * scale,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12 * scale),
          boxShadow: [
            BoxShadow(
              blurRadius: 6,
              color: solid ? const Color(0x44000000) : const Color(0x33000000),
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: EdgeInsets.all(2 * scale),
        child: Container(
          padding: EdgeInsets.fromLTRB(left * scale, 0, right * scale, 0),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10 * scale),
          ),
          foregroundDecoration: outline == 0
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(10 * scale),
                  border: Border.all(color: badgeInk, width: outline * scale),
                ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (style == CapsuleStyle.suspended) ...[
                CapsulePause(size: 12 * scale, color: ink),
                SizedBox(width: 3 * scale),
              ],
              if (style == CapsuleStyle.car) ...[
                CapsuleCar(size: 12 * scale, color: ink),
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
                style: _capsuleText.copyWith(color: ink, fontSize: 13 * scale),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The design's pause sign: two bars (x 6 and 14, 4 wide, 14 high, radius
/// 1, in a 24 box), for a closed lot.
class CapsulePause extends StatelessWidget {
  const CapsulePause({super.key, required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('capsule-pause'),
    size: Size.square(size),
    painter: _PausePainter(color),
  );
}

class _PausePainter extends CustomPainter {
  const _PausePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final paint = Paint()..color = color;
    for (final x in [6.0, 14.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 5, 4, 14),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PausePainter old) => old.color != color;
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

/// The marker box with room above it for pills, symmetric about the
/// marker's centre so a map that centres the box keeps the marker on its
/// point.
const capsuleBoxWidth = 200.0, capsuleBoxHeight = 136.0;

/// [marker] with [capsules] side by side above it, centred, [capsuleGap]
/// clear of its top (MapBadges board). The corner badge stays on the marker.
/// Taps anywhere on the pills reach the marker's own handler.
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

  @override
  Widget build(BuildContext context) {
    if (capsules.isEmpty) return marker;
    final scale = selected ? 26 / 24 : 1.0;
    final size = selected ? markerSize * selectedScale : markerSize;
    return SizedBox(
      width: capsuleBoxWidth,
      height: capsuleBoxHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          SizedBox.square(dimension: boxSize, child: marker),
          Positioned(
            left: 0,
            right: 0,
            bottom: capsuleBoxHeight / 2 + size / 2 + capsuleGap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
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
