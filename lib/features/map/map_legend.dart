import 'dart:math' as math;

import '../../domain/eligibility.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../domain/availability_display.dart';
import 'availability_capsule.dart';
import 'spot_details.dart';

const unverifiedColor = Color(0xff59646c);

/// What a marker shows: its status and, for a conditional spot, the kind of
/// limit. Shared by the Flutter and Google maps so the legend matches both.
typedef MarkerLook = (EligibilityStatus, RuleRestriction?);

MarkerLook markerLook(Eligibility e) => (
  e.status,
  e.status == EligibilityStatus.conditional ? e.restriction : null,
);

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
/// does not rely on colour alone.
double spotMarkerRadius(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => 19,
  EligibilityStatus.conditional => 10,
  EligibilityStatus.unverified => 10,
  EligibilityStatus.notAllowed => 4,
};

/// A space's kind beyond whether it is parkable, shown as a corner badge:
/// car bays (including heavy-and-car shared ones), heavy-only bays, and bays
/// shared by scooters and heavy bikes.
enum SpaceBadge { car, heavyOnly, shared, disabled }

SpaceBadge? spaceBadge(ParkingSpot spot) {
  final access = reportedAccess(spot);
  if (spot.spaceType == SpaceType.heavyOnly ||
      access == ParkingAccess.heavyOnly) {
    return SpaceBadge.heavyOnly;
  }
  if (spot.spaceType == SpaceType.car || access == ParkingAccess.heavyCar) {
    return SpaceBadge.car;
  }
  if (spot.spaceType == SpaceType.disabledMotorcycle) {
    return SpaceBadge.disabled;
  }
  if (access == ParkingAccess.scooterHeavy) return SpaceBadge.shared;
  return null;
}

/// The car and the helmet (as on the heavy-bike vehicle pill) are icons;
/// shared bays read 共, as painted on the ground.
IconData? spaceBadgeIcon(SpaceBadge badge) => switch (badge) {
  SpaceBadge.car => Icons.directions_car,
  SpaceBadge.heavyOnly => Icons.sports_motorsports,
  SpaceBadge.shared => null,
  SpaceBadge.disabled => Icons.accessible,
};

String spaceBadgeLabel(SpaceBadge badge) => switch (badge) {
  SpaceBadge.car => '汽車格',
  SpaceBadge.heavyOnly => '重機專用格',
  SpaceBadge.shared => '普大共用格',
  SpaceBadge.disabled => '身障機車專用格',
};

/// Ring and scale that mark the spot whose details are open.
const selectedRingColor = Color(0xff1a73e8);
const selectedScale = 1.35;

class SpotMarker extends StatelessWidget {
  const SpotMarker({
    super.key,
    required this.look,
    this.size = 38,
    this.selected = false,
    this.badge,
    this.rider = false,
  });
  final MarkerLook look;
  final double size;
  final bool selected;
  final SpaceBadge? badge;

  /// A rider reported spaces or a full bay here within 15 minutes (#154):
  /// the 16 px rider badge, bottom right — bottom left when the space-kind
  /// badge holds that corner. Never a number.
  final bool rider;
  @override
  Widget build(BuildContext context) {
    final size = selected ? this.size * selectedScale : this.size;
    final marker = Container(
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
        boxShadow: const [
          BoxShadow(
            blurRadius: 6,
            color: Color(0x44000000),
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Icon(
        spotMarkerIcon(look),
        color: Colors.white,
        size: size * 22 / 38,
      ),
    );
    final badge = this.badge;
    if (badge == null && !rider) return Center(child: marker);
    final dot = size * .5;
    final room = badge == null ? riderBadgeSize * .3 : dot * .3;
    return Center(
      child: SizedBox(
        width: size + room * (badge != null && rider ? 2 : 1),
        height: size + room,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: badge != null && rider ? room : 0,
              top: 0,
              child: marker,
            ),
            if (badge != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: SpaceBadgeDot(badge: badge, size: dot),
              ),
            if (rider)
              Positioned(
                left: badge != null ? 0 : null,
                right: badge != null ? null : 0,
                bottom: 0,
                child: const RiderBadge(),
              ),
          ],
        ),
      ),
    );
  }
}

/// The rider badge's size (realtime availability canvas, 狀態總表 row 10).
const riderBadgeSize = 16.0;

/// A rider reported here recently: white disc, ink ring and a person, no
/// number (canvas 狀態總表 「騎士回報・近期」).
class RiderBadge extends StatelessWidget {
  const RiderBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('rider-badge'),
    width: riderBadgeSize,
    height: riderBadgeSize,
    decoration: BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      border: Border.all(color: badgeInk, width: 1.5),
    ),
    alignment: Alignment.center,
    child: const CustomPaint(size: Size.square(9), painter: _RiderPainter()),
  );
}

/// The canvas's person: head r4 at (12,8), shoulders `M4 21a8 8 0 0 1 16 0`,
/// stroke 3 on a 24 grid.
class _RiderPainter extends CustomPainter {
  const _RiderPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final pen = Paint()
      ..color = badgeInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * k
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(12 * k, 8 * k), 4 * k, pen);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(12 * k, 21 * k), radius: 8 * k),
      math.pi,
      math.pi,
      false,
      pen,
    );
  }

  @override
  bool shouldRepaint(_RiderPainter oldDelegate) => false;
}

class SpaceBadgeDot extends StatelessWidget {
  const SpaceBadgeDot({super.key, required this.badge, this.size = 19});
  final SpaceBadge badge;
  final double size;
  @override
  Widget build(BuildContext context) {
    final icon = spaceBadgeIcon(badge);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: badgeInk, width: size * .08),
      ),
      child: icon != null
          ? Icon(icon, size: size * .66, color: badgeInk)
          : Text(
              '共',
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: badgeInk,
                fontSize: size * .6,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
    );
  }
}

const badgeInk = Color(0xff22282d);

/// Marker meanings for the selected vehicle; shape repeats the colour so the
/// legend does not rely on colour alone.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key, required this.vehicle});
  final VehicleType vehicle;
  @override
  Widget build(BuildContext context) {
    final entries = <(MarkerLook, String, String)>[
      (
        (EligibilityStatus.allowed, null),
        '可停',
        '法規或已查核資料確認${vehicle.label}可停放',
      ),
      (
        (EligibilityStatus.conditional, RuleRestriction.signage),
        '有條件・限標示車格',
        '僅地面或標牌標示開放${vehicle.label}的車格可停',
      ),
      (
        (EligibilityStatus.conditional, RuleRestriction.timeLimited),
        '有條件・限時段',
        '限時停車或汽機車彈性共用格，依牌面時段停放',
      ),
      (
        (EligibilityStatus.conditional, RuleRestriction.evOnly),
        '有條件・限電動機車',
        '電動機車停車或充換電格，燃油機車不可停',
      ),
      ((EligibilityStatus.conditional, null), '有條件・其他限制', '法規開放但另有限制，詳見停車點說明'),
      (
        (EligibilityStatus.unverified, null),
        '待確認',
        '資料不足以判斷：社群回報未查核或過時、場站未標示、尚無生效規則',
      ),
      (
        (EligibilityStatus.notAllowed, null),
        '不可停',
        '法規或已查核資料不開放${vehicle.label}停放',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (look, title, detail) in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 44,
                    child: SpotMarker(look: look),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        detail,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// [availability] adds the space-count pills, shown only where live counts
/// exist (the example build until P2).
Future<void> showMapLegend(
  BuildContext context,
  VehicleType vehicle, {
  bool availability = false,
}) => showAdaptiveSheet<void>(
  context,
  (ctx) => ContentPage(
    children: [
      SheetTitle('地圖怎麼看'),
      const SizedBox(height: 4),
      Text(
        '標記依目前車種「${vehicle.label}」判斷，切換車種會即時更新。',
        style: Theme.of(ctx).textTheme.bodyMedium,
      ),
      const SizedBox(height: 20),
      MapLegend(vehicle: vehicle),
      const SizedBox(height: 8),
      Text('角落小圖示', style: Theme.of(ctx).textTheme.titleSmall),
      const SizedBox(height: 12),
      for (final (badge, detail) in const [
        (SpaceBadge.car, '汽車格，或大型重機與汽車共用的格位'),
        (SpaceBadge.heavyOnly, '標示大型重機專用的格位'),
        (SpaceBadge.shared, '普通機車與大型重機共用的格位'),
        (SpaceBadge.disabled, '限經監理站檢驗合格的身障特製機車，並持識別證或專用牌照'),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 44,
                child: Center(
                  child: ExcludeSemantics(
                    child: SpaceBadgeDot(badge: badge, size: 26),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spaceBadgeLabel(badge),
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    Text(detail, style: Theme.of(ctx).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (availability) ...[
        const SizedBox(height: 8),
        Text('標記上方的車位數', style: Theme.of(ctx).textTheme.titleSmall),
        const SizedBox(height: 12),
        const AvailabilityLegend(),
      ],
      const Divider(height: 32),
      const Text('數字圓圈：附近有多個停車點，放大地圖即可展開。'),
      const SizedBox(height: 8),
      const Text('長按地圖：在該位置回報新的停車點。'),
      const SizedBox(height: 16),
      const Text('社群資訊可能有延遲，停車前請確認現場標示。'),
    ],
  ),
);

/// The pill states, as on the canvas's map board: a count, a delayed
/// count, full, closed, and no pill for an unknown space.
class AvailabilityLegend extends StatelessWidget {
  const AvailabilityLegend({super.key});
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const rows = [
      (
        AvailabilityCapsule(
          text: '剩 12',
          style: CapsuleStyle.live,
          semantics: '',
        ),
        '官方即時剩餘',
      ),
      (
        AvailabilityCapsule(
          text: '剩 7',
          style: CapsuleStyle.delayed,
          semantics: '',
        ),
        '更新延遲，數字可能已變',
      ),
      (
        AvailabilityCapsule(
          text: '已滿',
          style: CapsuleStyle.full,
          semantics: '',
        ),
        '官方資料目前沒有空位',
      ),
      (
        AvailabilityCapsule(
          text: '暫停',
          style: CapsuleStyle.suspended,
          semantics: '',
        ),
        '場站暫停營運',
      ),
    ];
    return Column(
      key: const ValueKey('availability-legend'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (capsule, detail) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 88,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ExcludeSemantics(
                      child: AvailabilityCapsuleView(capsule: capsule),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    detail,
                    semanticsLabel: '${capsule.text}：$detail',
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            SizedBox(
              width: 88,
              child: Align(
                alignment: Alignment.centerLeft,
                child: ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 24,
                    child: SpotMarker(
                      look: (EligibilityStatus.unverified, null),
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('沒有膠囊＝空位未知，或目前車種不可停', style: text.bodySmall)),
          ],
        ),
      ],
    );
  }
}
