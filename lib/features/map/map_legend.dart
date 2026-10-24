import '../../domain/eligibility.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
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
  });
  final MarkerLook look;
  final double size;
  final bool selected;
  final SpaceBadge? badge;
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

Future<void> showMapLegend(BuildContext context, VehicleType vehicle) =>
    showAdaptiveSheet<void>(
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
            (SpaceBadge.disabled, '身心障礙者專用，須持識別證明'),
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
          const Divider(height: 32),
          const Text('數字圓圈：附近有多個停車點，放大地圖即可展開。'),
          const SizedBox(height: 8),
          const Text('長按地圖：在該位置回報新的停車點。'),
          const SizedBox(height: 16),
          const Text('社群資訊可能有延遲，停車前請確認現場標示。'),
        ],
      ),
    );
