import 'package:flutter_svg/flutter_svg.dart' show PictureInfo;
import 'package:go_router/go_router.dart';

import '../../domain/eligibility.dart';
import '../../domain/map_legend_display.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../models/zone_entries.dart';
import '../../ui/adaptive/adaptive.dart';
import 'heavy_glyph.dart';
import 'map_legend_page.dart';
import 'spot_details.dart';

export '../../domain/map_legend_display.dart' show SpaceBadge;

const unverifiedColor = Color(0xff59646c);

/// What a marker shows: its status and, for a conditional spot, the kind of
/// limit. Shared by the Flutter and Google maps so the legend matches both.
typedef MarkerLook = (EligibilityStatus, RuleRestriction?);

MarkerLook markerLook(Eligibility e) => (
  e.status,
  e.status == EligibilityStatus.conditional ? e.restriction : null,
);

/// Fixed design colours (A0), never the dynamic colour scheme.
Color spotMarkerColor(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => allowedColor,
  EligibilityStatus.conditional => conditionalColor,
  EligibilityStatus.unverified => unverifiedColor,
  EligibilityStatus.notAllowed => deniedColor,
};

IconData spotMarkerIcon(MarkerLook look) => switch (look) {
  (EligibilityStatus.allowed, _) => Icons.local_parking,
  (EligibilityStatus.conditional, RuleRestriction.signage) => Icons.signpost,
  (EligibilityStatus.conditional, RuleRestriction.timeLimited) =>
    Icons.schedule,
  (EligibilityStatus.conditional, RuleRestriction.evOnly) => Icons.bolt,
  (EligibilityStatus.conditional, _) => Icons.rule,
  (EligibilityStatus.unverified, _) => Icons.question_mark,
  (EligibilityStatus.notAllowed, _) => Icons.close,
};

/// Corner radius per 38dp marker: the shape repeats the meaning so the map
/// does not rely on colour alone (A0: circle, rounded square, rounded
/// square, square).
double spotMarkerRadius(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => 19,
  EligibilityStatus.conditional => 10,
  EligibilityStatus.unverified => 10,
  EligibilityStatus.notAllowed => 4,
};

/// The spot's corner badge, from the bay kind painted there (#188's seven
/// kinds): none for a plain 一般機車格. A lot, or a street bay that reads
/// as a plain one, falls back to the access the spot reports, as before
/// the kinds: 大重專用, 大汽共用 and 普大共用.
SpaceBadge? spaceBadge(ParkingSpot spot) {
  final street = !isOffStreet(spot.spaceType, spot.facilityType);
  final kind = street
      ? bayKindOf(spot.condition ?? conditionOf(spot.spaceType))
      : null;
  if (kind != null) {
    if (SpaceBadge.ofBay(kind) case final badge?) return badge;
  }
  return switch (reportedAccess(spot)) {
    ParkingAccess.heavyOnly => SpaceBadge.heavyOnly,
    ParkingAccess.heavyCar => SpaceBadge.car,
    ParkingAccess.scooterHeavy => SpaceBadge.shared,
    _ => null,
  };
}

/// The badge's icon; both heavy-bike badges draw the IconScout silhouette
/// when the build carries it ([heavyGlyph]) and this helmet otherwise.
IconData? spaceBadgeIcon(SpaceBadge badge) => switch (badge) {
  SpaceBadge.heavyOnly || SpaceBadge.shared => heavyGlyphFallback,
  SpaceBadge.car || SpaceBadge.carMotorcycle => Icons.directions_car,
  SpaceBadge.disabled => Icons.accessible,
  SpaceBadge.ev => Icons.ev_station,
};

String spaceBadgeLabel(SpaceBadge badge) => badge.label;

/// The second colour of a shared bay's square, after the ground markings:
/// yellow for 普大共用, light blue for 汽機車共用.
Color? spaceBadgeAccent(SpaceBadge badge) => switch (badge) {
  SpaceBadge.shared => const Color(0xfff2c200),
  SpaceBadge.carMotorcycle => const Color(0xff6aaad6),
  _ => null,
};

/// Paints [badge] filling [rect] (A0, 19 units across): a white circle for
/// a dedicated bay, a square split white and its accent for a shared one,
/// a 1.5 ink outline and the 12.5 icon or 13 silhouette. The Flutter marker
/// and the Google bitmap both paint it here.
void paintSpaceBadge(
  Canvas canvas,
  Rect rect,
  SpaceBadge badge, {
  PictureInfo? glyph,
}) {
  final unit = rect.width / 19;
  final shape = RRect.fromRectAndRadius(
    rect,
    Radius.circular(badge.square ? 5 * unit : rect.width / 2),
  );
  canvas.save();
  canvas.clipRRect(shape);
  canvas.drawRect(rect, Paint()..color = Colors.white);
  if (spaceBadgeAccent(badge) case final accent?) {
    // CSS linear-gradient(135deg, white 50%, accent 50%): the lower right
    // half, below the diagonal from top right to bottom left.
    canvas.drawPath(
      Path()
        ..moveTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close(),
      Paint()..color = accent,
    );
  }
  canvas.restore();
  final stroke = 1.5 * unit;
  canvas.drawRRect(
    shape.deflate(stroke / 2),
    Paint()
      ..color = badgeInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke,
  );
  final center = rect.center;
  final heavy = badge == SpaceBadge.heavyOnly || badge == SpaceBadge.shared;
  if (heavy && glyph != null) {
    paintHeavyGlyph(
      canvas,
      glyph,
      Rect.fromCenter(center: center, width: 13 * unit, height: 13 * unit),
      badgeInk,
    );
    return;
  }
  final icon = spaceBadgeIcon(badge)!;
  final painter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        color: badgeInk,
        fontSize: 12.5 * unit,
        height: 1,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  painter.dispose();
}

/// Ring and scale that mark the spot whose details are open.
const selectedRingColor = Color(0xff1a73e8);
const selectedScale = 1.35;

/// The marker shadow (A0: 0 2px 4px rgba(0,0,0,.27)), kept as drawn
/// before so the rules page goldens hold.
const markerShadow = BoxShadow(
  blurRadius: 6,
  color: Color(0x44000000),
  offset: Offset(0, 2),
);

class SpotMarker extends StatelessWidget {
  const SpotMarker({
    super.key,
    required this.look,
    this.size = 38,
    this.selected = false,
    this.badge,
    this.faded = false,
  });
  final MarkerLook look;
  final double size;
  final bool selected;
  final SpaceBadge? badge;

  /// A spot reported gone: the plain marker at .45, no shadow (A0).
  final bool faded;
  @override
  Widget build(BuildContext context) {
    final size = selected ? this.size * selectedScale : this.size;
    Widget marker = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: spotMarkerColor(look.$1),
        border: Border.all(
          color: selected ? selectedRingColor : Colors.white,
          width: size * (selected ? 4 : 3) / 38,
        ),
        borderRadius: BorderRadius.circular(
          size * spotMarkerRadius(look.$1) / 38,
        ),
        boxShadow: faded ? null : const [markerShadow],
      ),
      child: Icon(
        spotMarkerIcon(look),
        color: Colors.white,
        size: size * 22 / 38,
      ),
    );
    if (faded) marker = Opacity(opacity: .45, child: marker);
    final badge = this.badge;
    if (badge == null) return Center(child: marker);
    final dot = size * .5;
    return Center(
      child: SizedBox.square(
        dimension: size + dot * .3,
        child: Stack(
          children: [
            marker,
            Positioned(
              right: 0,
              bottom: 0,
              child: SpaceBadgeDot(badge: badge, size: dot),
            ),
          ],
        ),
      ),
    );
  }
}

class SpaceBadgeDot extends StatelessWidget {
  const SpaceBadgeDot({super.key, required this.badge, this.size = 19});
  final SpaceBadge badge;
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(
    key: ValueKey('space-badge-${badge.name}'),
    size: Size.square(size),
    painter: _SpaceBadgePainter(badge),
  );
}

class _SpaceBadgePainter extends CustomPainter {
  _SpaceBadgePainter(this.badge) : super(repaint: heavyGlyph);
  final SpaceBadge badge;
  @override
  void paint(Canvas canvas, Size size) => paintSpaceBadge(
    canvas,
    Offset.zero & size,
    badge,
    glyph: heavyGlyph.value,
  );

  @override
  bool shouldRepaint(_SpaceBadgePainter old) => old.badge != badge;
}

const badgeInk = Color(0xff22282d);

/// The first-launch introduction: the legend in a sheet over the map, as
/// before the page (it closes with 關閉, then the launch prompts resume).
/// [availability] adds the space-count pills, shown only where live counts
/// exist.
Future<void> showMapLegend(
  BuildContext context,
  VehicleType vehicle, {
  bool availability = false,
}) => showAdaptiveSheet<void>(
  context,
  (ctx) => ContentPage(
    children: [
      SheetTitle(legendTitle),
      MapLegendContent(vehicle: vehicle, availability: availability),
    ],
  ),
);

/// Opens the 地圖怎麼看 page (P3) inside the current tab, so the tab bar
/// stays: /map/legend from the map, /parking/legend from 個人中心. Both are
/// sub-routes, so back returns to their parent tab page. Outside the app's
/// router (tests of a single page), a plain route.
void openMapLegend(BuildContext context, {required bool fromMap}) {
  if (GoRouter.maybeOf(context) case final router?) {
    router.go(fromMap ? '/map/legend' : '/parking/legend');
    return;
  }
  Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => MapLegendPage(fromMap: fromMap)),
  );
}
