import '../models/availability.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import '../models/zone_entries.dart';
import 'eligibility.dart';
import 'map_legend_display.dart' show SpaceBadge;
import 'parking_decision.dart';
import 'rider_meter_display.dart';
import 'segment_decision.dart' show openWindow, scheduleSilentFor;

/// How a count reads on the map and in the details. Whether a rider may
/// park and whether a space is free are separate: nothing here looks at
/// the eligibility colour, and nothing in eligibility looks at a count;
/// only a lot closed to the rider shows no count at all (designs/2026-10-26-realtime-availability-ui.md).

AvailabilityVehicle availabilityVehicle(VehicleType vehicle) =>
    vehicle == VehicleType.scooter
    ? AvailabilityVehicle.scooter
    : AvailabilityVehicle.heavy;

/// Whether heavy bikes may use [spot]'s car bays now, as [decision] (the
/// heavy-bike [decideParking] result) judges them (#136): the lot must be
/// trusted and open to heavy bikes, and
/// - with zones: a car-area zone is allowed or conditional for heavy bikes;
///   a car zone that is unconfirmed (an expired notice, a missing slot) or
///   closed does not count, nor does a lot whose zones disagree;
/// - without zones, or zones that say nothing: the lot's own data puts heavy
///   bikes in car bays, which the law allows (§3.2 step 1).
/// Admitting heavy bikes alone does not.
bool heavyCarOpen(ParkingSpot spot, ParkingDecision decision) {
  if (decision.status != EligibilityStatus.allowed &&
      decision.status != EligibilityStatus.conditional) {
    return false;
  }
  final zones = decision.zones;
  // decideParking judges every zone in the lot's order. A decision without
  // them (the rolled-back judgement) speaks for the lot only.
  if (zones.length == spot.zones.length && zones.any((z) => z.hasData)) {
    for (var i = 0; i < zones.length; i++) {
      if (zones[i].open && _carArea(spot.zones[i])) return true;
    }
    return false;
  }
  return spot.access == ParkingAccess.heavyCar ||
      (spot.condition?.bay == Bay.car && spot.condition?.allow?.heavy != false);
}

/// A zone of car bays: its condition (or the one its access stands for) is
/// a car bay (zone areas are gone, #188 layer 2).
bool _carArea(ParkingZone zone) =>
    (zone.condition ?? zoneConditionOf(zone.access))?.bay == Bay.car;

// 普大共用格與普通機車數字（A'，使用者 2026-11-15 決定）---------------------
//
// The source sends one scooter count for a whole lot and no count of its
// own for 普大共用格 (bay motorcycle, share scooter_heavy). #222's rule
// stands: a scooter count never stands for heavy-only bays (重機專用格,
// `bay: heavy`) or car bays. The one exception: where every motorcycle bay
// of the lot is 普大共用 ([motorcycleBaysAllShared]), the scooter count is
// the shared bays' count, and heavy bikes read it on those bays, marked
// [sharedWithScooterLabel] (scooters park there too). A lot that also has
// motorcycle bays for scooters alone keeps 空位未知 on its shared bays,
// with the scooter count only as a secondary line ([scooterCountLine],
// [notForHeavyNote]).

/// Beside a count heavy bikes read from the scooter count: those bays are
/// 普大共用, so scooters park there too. The same word as 停哪裡's
/// 「普大共用格」 (user decision 2026-11-16, #489).
const sharedWithScooterLabel = '普大共用';

/// [sharedWithScooterLabel] for screen readers, which may not know the
/// short word.
const sharedWithScooterSpoken = '普大共用，與普通機車共用格位';

/// After the scooter count shown beside a heavy-bike 空位未知.
const notForHeavyNote = '不代表重機可用格數';

/// What the scooter count heavy bikes borrow stands for (#493): the two are
/// different things and never share a name or a badge.
enum BorrowedBays {
  /// Every motorcycle bay is a 普大共用格: 「普大共用」, the white and yellow
  /// square.
  shared,

  /// At least one zone is plain 一般機車格 that states heavy bikes may
  /// park, alone or beside 普大共用格 (M1, user decision 2026-11-17: the
  /// lighter word where the count mixes both): 「一般機車格可停」, the ink
  /// circle.
  general;

  /// Beside the count: on the plate, the rows and the summary.
  String get label => switch (this) {
    shared => sharedWithScooterLabel,
    general => generalHeavyLabel,
  };

  /// [label] where it does not fit a line (the plate at large text); null
  /// when there is no shorter word.
  String? get shortLabel => switch (this) {
    shared => null,
    general => generalHeavyShortLabel,
  };

  /// [label] for screen readers, after a count.
  String get spoken => switch (this) {
    shared => sharedWithScooterSpoken,
    general => generalHeavySpoken,
  };

  /// Before a pill's count for screen readers (design #492 v3).
  String get source => switch (this) {
    shared => '普大共用格，與普通機車共用',
    general => generalHeavySpoken,
  };

  /// The badge before the pill's count and on the marker's corner.
  SpaceBadge get badge => switch (this) {
    shared => SpaceBadge.shared,
    general => SpaceBadge.generalHeavy,
  };
}

/// Beside a count heavy bikes read from the scooter count of plain
/// 一般機車格 that admit them (#493, T3, user decision 2026-11-17).
const generalHeavyLabel = '一般機車格可停';

/// [generalHeavyLabel] only where its seven characters do not fit a line.
const generalHeavyShortLabel = '一般格可停';

/// [generalHeavyLabel] for screen readers (design #492 v3).
const generalHeavySpoken = '一般機車格可停，大型重機也可以停，與普通機車共用';

/// Whether heavy bikes may read [spot]'s scooter count, and as what (A',
/// #493): every motorcycle bay of the lot is one heavy bikes share with
/// scooters, a 普大共用格 or a plain 一般機車格 that states they may park.
/// Read from the data alone, the same way for the four signs, the details,
/// the map's pills and badges and the 「目前有位」 filter:
/// - a lot only (street spots have no official count);
/// - only where a stored condition states it ([explicitlyShared],
///   [explicitlyGeneralHeavy]): a legacy `access: scooterHeavy` alone is
///   the importer's guess for a 機車區, often one whose heavy bikes park on
///   重機專用格, so it may hold scooter-only bays (user decision 2026-11-16,
///   #489). Elsewhere (停哪裡, the decision) it still reads as 普大共用格;
/// - zones that say something (a condition or a legacy access; as
///   [decideParking] reads them): at least one zone lends its count and
///   every other zone has no motorcycle bay: heavy-only or car bays, or no
///   bay with scooters excluded. Any zone that says nothing, a legacy
///   普大共用 zone, motorcycle bays of another kind (一般 without heavy
///   bikes、身障、充電) or no bay without excluding scooters may hold
///   scooter-only bays the count includes: null. Heavy-only zones never
///   matter. [ParkingSpot.zonesComplete] is not required;
/// - no zone says anything: the lot's own condition is explicitly 普大共用
///   (a lot's condition carries no `allow`, so it never states 一般格准重機).
BorrowedBays? borrowedBays(ParkingSpot spot) {
  if (!spot.isFacility) return null;
  final zones = [
    for (final z in spot.zones) (z.condition ?? zoneConditionOf(z.access), z),
  ];
  if (zones.any((c) => c.$1 != null)) {
    var shared = false, general = false;
    for (final (c, z) in zones) {
      if (c == null) return null;
      if (explicitlyShared(z.condition)) {
        shared = true;
      } else if (explicitlyGeneralHeavy(z.condition)) {
        general = true;
      } else if (c.bay == Bay.motorcycle ||
          (c.bay == null && c.allow?.scooter != false)) {
        return null;
      }
    }
    return general
        ? BorrowedBays.general
        : shared
        ? BorrowedBays.shared
        : null;
  }
  return explicitlyShared(spot.condition) ? BorrowedBays.shared : null;
}

/// Whether every motorcycle bay of [spot] is explicitly a 普大共用格
/// ([borrowedBays]): the only lots that wear the white and yellow square
/// for their zones.
bool motorcycleBaysAllShared(ParkingSpot spot) =>
    borrowedBays(spot) == BorrowedBays.shared;

/// Whether [condition], as stored (never one a legacy access stands for),
/// states 普大共用格 (#489).
bool explicitlyShared(ParkingCondition? condition) =>
    condition?.share == ShareKind.scooterHeavy;

/// Whether [condition], as stored, states plain 一般機車格 that heavy bikes
/// may park on (#493): a motorcycle bay of no other kind (not 普大共用,
/// 身障 or 充電), `allow.heavy` true (官方未標示 is not yes) and scooters
/// not excluded, so the scooter count is these bays' count.
bool explicitlyGeneralHeavy(ParkingCondition? condition) =>
    condition != null &&
    bayKindOf(condition) == BayKind.motorcycle &&
    condition.allow?.heavy == true &&
    condition.allow?.scooter != false;

/// Whether the zone or lot [condition] (as stored) lends its scooter count
/// to heavy bikes where the whole lot does ([borrowedBays]).
bool lendsScooterCount(ParkingCondition? condition) =>
    explicitlyShared(condition) || explicitlyGeneralHeavy(condition);

/// Whether [count], read for [vehicle], is the scooter count heavy bikes
/// borrow (A', #493): it is marked with the lot's [BorrowedBays].
bool sharedScooterCount(VehicleType vehicle, AvailabilityVehicle? count) =>
    vehicle == VehicleType.heavy && count == AvailabilityVehicle.scooter;

bool _countShown(AvailabilitySnapshot s, DateTime now) =>
    s.status(now) == AvailabilityStatus.fresh ||
    s.status(now) == AvailabilityStatus.delayed;

/// The count that speaks for [spot] as a whole for [vehicle] on the map
/// (pills, 「目前有位」) and in a lot's summary without zones: the
/// vehicle's own; for heavy bikes on a lot whose motorcycle bays are all
/// 普大共用 ([motorcycleBaysAllShared]) the scooter count when the heavy
/// count shows nothing (no value, stale, invalid) and the scooter count
/// does (fresh, delayed or suspended), read as the four signs read it:
/// - only while [decision] opens every 普大共用 place to heavy bikes now
///   (a shared zone whose notice has lapsed, or closed to them while
///   scooters park, keeps the count from them);
/// - after a heavy count that shows; beside a car count that shows where
///   [decision] opens car bays to them now ([heavyCarOpen], read by their
///   windows as the four signs read them), only where it is the better
///   ([sharedBeatsCar]); else the pills show the car pill instead.
/// Without [decision] the scooter count is never read. [beside] false
/// skips the car comparison: the 「目前有位」 filter reads the shared count
/// whichever answers on the pills (car bays never count there), so more
/// car space never takes it away.
AvailabilitySnapshot? lotCount(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  ParkingDecision? decision,
  DateTime now, {
  bool beside = true,
}) {
  final own = availability.of(availabilityVehicle(vehicle));
  if (vehicle != VehicleType.heavy ||
      decision == null ||
      borrowedBays(spot) == null ||
      !_sharedOpenNow(spot, decision, now)) {
    return own;
  }
  if (own != null &&
      (_countShown(own, now) ||
          own.status(now) == AvailabilityStatus.suspended)) {
    return own;
  }
  final scooter = availability.of(AvailabilityVehicle.scooter);
  if (scooter == null ||
      !(_countShown(scooter, now) ||
          scooter.status(now) == AvailabilityStatus.suspended)) {
    return own;
  }
  // Car bays open to heavy bikes now with a count that shows: the shared
  // count stands only where it is the better of the two ([sharedBeatsCar]);
  // otherwise the car pill answers.
  final car = availability.of(AvailabilityVehicle.car);
  if (beside &&
      car != null &&
      _countShown(car, now) &&
      _carOpenNow(spot, decision, now) &&
      !(_countShown(scooter, now) && sharedBeatsCar(scooter, car, now))) {
    return own;
  }
  return scooter;
}

/// Whether the shared scooter count [shared] answers before the car-bay
/// count [car] where heavy bikes may read both, both showing (user
/// decision 2026-11-16, #489: 空位多、資料新的當主答案): fresh before
/// delayed; then more space; then the newer; at a tie the car bays, heavy
/// bikes' own by law. The other stays as another place with space (the
/// four signs) or beside it (the details' rows, the full set of pills).
bool sharedBeatsCar(
  AvailabilitySnapshot shared,
  AvailabilitySnapshot car,
  DateTime now,
) {
  final sharedFresh = shared.status(now) == AvailabilityStatus.fresh;
  final carFresh = car.status(now) == AvailabilityStatus.fresh;
  if (sharedFresh != carFresh) return sharedFresh;
  final byFree = shared.available!.compareTo(car.available!);
  if (byFree != 0) return byFree > 0;
  final a = shared.sourceUpdatedAt, b = car.sourceUpdatedAt;
  return a != null && b != null && a.isAfter(b);
}

/// Whether [decision] opens the places of [spot] that lend their count
/// ([lendsScooterCount]) to heavy bikes now (their windows, as the four
/// signs read them): every such zone,
/// since the scooter count covers them all, or, for a lot standing as one
/// (no zones, or zones that say nothing), the lot itself.
bool _sharedOpenNow(ParkingSpot spot, ParkingDecision decision, DateTime now) {
  bool openNow(EligibilityStatus status, ParkingCondition? condition) =>
      openWindow(
        status,
        condition,
        VehicleType.heavy,
        now,
        basis: decision.basis,
      ).now;
  final zones = decision.zones;
  if (zones.length == spot.zones.length && zones.any((z) => z.hasData)) {
    if (decision.status != EligibilityStatus.allowed &&
        decision.status != EligibilityStatus.conditional) {
      return false;
    }
    var any = false;
    for (var i = 0; i < zones.length; i++) {
      final c =
          spot.zones[i].condition ?? zoneConditionOf(spot.zones[i].access);
      if (!lendsScooterCount(spot.zones[i].condition)) continue;
      if (!openNow(zones[i].status, c)) return false;
      any = true;
    }
    return any;
  }
  // A schedule that lists no slot for heavy bikes states no time they may
  // park (待確認), as the four signs read the lot.
  if (scheduleSilentFor(spot.condition, VehicleType.heavy)) return false;
  return openNow(decision.status, spot.condition);
}

/// Whether [decision] opens car bays of [spot] to heavy bikes now: as
/// [heavyCarOpen] reads them, and for zones only while their window is
/// open (a zone opening later is conditional, not open now).
bool _carOpenNow(ParkingSpot spot, ParkingDecision decision, DateTime now) {
  if (!heavyCarOpen(spot, decision)) return false;
  final zones = decision.zones;
  if (zones.length == spot.zones.length && zones.any((z) => z.hasData)) {
    for (var i = 0; i < zones.length; i++) {
      final c =
          spot.zones[i].condition ?? zoneConditionOf(spot.zones[i].access);
      if (zones[i].open &&
          c?.bay == Bay.car &&
          openWindow(
            zones[i].status,
            c,
            VehicleType.heavy,
            now,
            basis: decision.basis,
          ).now) {
        return true;
      }
    }
    return false;
  }
  return true;
}

/// The scooter count as a secondary line beside a heavy-bike 空位未知:
/// 「普通機車區剩 N 格」 (or 已滿), with its delay. The details without zones
/// and the zone rows both write it from here.
String scooterCountLine(AvailabilitySnapshot scooter, DateTime now) {
  final delay = scooter.status(now) == AvailabilityStatus.delayed
      ? '，更新延遲 ${scooter.ageMinutes(now)} 分鐘'
      : '';
  return scooter.available == 0
      ? '普通機車區已滿$delay'
      : '普通機車區剩 ${scooter.available} 格$delay';
}

/// 「17:02」 in local time.
String availabilityClock(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

enum CapsuleStyle {
  /// Filled ink: an official count inside its update window.
  live,

  /// Outlined with a clock: the last count, past the window.
  delayed,

  /// Light grey with ink text: an official count of zero, apart from the
  /// ink pill of a lot with space.
  full,

  /// Deep purple with a pause sign: the source says the lot is closed.
  suspended,

  /// Light grey with a meter: riders' reports (A0), not an official count.
  rider,
}

/// One pill above a marker.
class AvailabilityCapsule {
  const AvailabilityCapsule({
    required this.text,
    required this.style,
    required this.semantics,
    this.badge,
  }) : meter = null;

  /// The riders' badge, where a space pill would sit (A0).
  AvailabilityCapsule.rider(RiderMeter this.meter)
    : text = meter.label,
      style = CapsuleStyle.rider,
      semantics = meter.semantics,
      badge = null;

  /// What [CapsuleStyle.rider] draws.
  final RiderMeter? meter;
  final String text;
  final CapsuleStyle style;

  /// Whose bays the count is of, where not the rider's own (#492, plan B):
  /// the corner badge of that bay kind, drawn before the number.
  /// [SpaceBadge.car] for car bays heavy bikes may use, [SpaceBadge.shared]
  /// or [SpaceBadge.generalHeavy] for the scooter count they borrow; null
  /// for the vehicle's own count. The style says only how fresh it is (B2).
  final SpaceBadge? badge;

  /// What a screen reader says, e.g. 「官方即時：剩 12 格」.
  final String semantics;

  @override
  bool operator ==(Object other) =>
      other is AvailabilityCapsule &&
      other.text == text &&
      other.style == style &&
      other.semantics == semantics &&
      other.badge == badge &&
      other.meter == meter;

  @override
  int get hashCode => Object.hash(text, style, semantics, badge, meter);
}

/// Whether [capsule] is an official count, not the riders' badge.
bool officialCapsule(AvailabilityCapsule capsule) =>
    capsule.style != CapsuleStyle.rider;

/// Whether a rider badge may show beside [capsules]: never next to an
/// official pill, which rider reports do not override.
bool riderMeterShown(List<AvailabilityCapsule> capsules) => capsules.isEmpty;

String _count(int available) => available == 0 ? '已滿' : '剩 $available';

/// The pills beside [spot]'s marker for [vehicle]: none when the space is
/// unknown (no data, stale, invalid), so a missing pill never reads as
/// zero. A car-bay pill joins only for heavy bikes where [decision] opens
/// car bays to them ([heavyCarOpen]), while its count is fresh or delayed.
/// [decision] is [vehicle]'s [decideParking] result. [rider] is the riders'
/// badge for the place 有沒有位 picks (A0): it stands only where no official
/// pill does, street spots included.
List<AvailabilityCapsule> markerCapsules(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  ParkingDecision decision,
  DateTime now, {
  RiderMeter? rider,
}) {
  final eligibility = decision.status;
  // A count where the rider may not park only invites them in (canvas v30).
  if (eligibility == EligibilityStatus.notAllowed) return const [];
  final capsules = spot.isFacility
      ? _officialCapsules(spot, availability, vehicle, decision, now)
      : const <AvailabilityCapsule>[];
  return rider != null && riderMeterShown(capsules)
      ? [AvailabilityCapsule.rider(rider)]
      : capsules;
}

List<AvailabilityCapsule> _officialCapsules(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  ParkingDecision decision,
  DateTime now,
) {
  // A heavy bike on a lot whose motorcycle bays all admit it reads the
  // scooter count (A', #493, [lotCount]); the pill carries those bays'
  // badge and the screen reader names them first.
  final own = lotCount(spot, availability, vehicle, decision, now);
  final borrowed = sharedScooterCount(vehicle, own?.vehicle)
      ? borrowedBays(spot)
      : null;
  final capsules = <AvailabilityCapsule>[
    if (own != null)
      if (own.status(now) == AvailabilityStatus.suspended)
        const AvailabilityCapsule(
          text: '暫停',
          style: CapsuleStyle.suspended,
          semantics: '暫停營運',
        )
      else
        ?_countCapsule(
          own,
          now,
          source: borrowed?.source,
          badge: borrowed?.badge,
        ),
  ];
  final car = availability.of(AvailabilityVehicle.car);
  if (vehicle == VehicleType.heavy &&
      car != null &&
      heavyCarOpen(spot, decision)) {
    if (_countCapsule(car, now, source: carBaySource, badge: SpaceBadge.car)
        case final pill?) {
      capsules.add(pill);
    }
  }
  return capsules;
}

/// Before a car-bay pill's count for screen readers (design #492 v3).
const carBaySource = '汽車格，大型重機現在可停';

/// The pill of [count] while it is fresh or delayed, else null. [source]
/// names whose bays it counts where not the rider's own, and [badge] draws
/// them; the style is the same for every source (B2).
AvailabilityCapsule? _countCapsule(
  AvailabilitySnapshot count,
  DateTime now, {
  String? source,
  SpaceBadge? badge,
}) {
  final full = count.available == 0;
  final left = full ? '已滿' : '剩 ${count.available} 格';
  switch (count.status(now)) {
    case AvailabilityStatus.fresh:
      return AvailabilityCapsule(
        text: _count(count.available!),
        style: full ? CapsuleStyle.full : CapsuleStyle.live,
        badge: badge,
        semantics: source == null ? '官方即時：$left' : '$source：官方即時$left',
      );
    case AvailabilityStatus.delayed:
      final age = count.ageMinutes(now);
      return AvailabilityCapsule(
        text: _count(count.available!),
        style: CapsuleStyle.delayed,
        badge: badge,
        semantics: source == null
            ? '更新延遲 $age 分鐘：最後一筆$left'
            : '$source：更新延遲 $age 分鐘，最後一筆$left',
      );
    default:
      return null;
  }
}

/// The one pill a crowded marker keeps, chosen by the parking rules; the
/// pill still shows only a number (MapDensity board, third panel):
/// - the rider may not park here, or it is unconfirmed: none, the
///   eligibility marker alone speaks;
/// - the rider's own count when there is one;
/// - heavy bikes with no heavy count, where [decision] opens car bays to
///   them ([heavyCarOpen]): the car-bay count.
/// [capsules] is [markerCapsules]'s result; [decision] is [vehicle]'s
/// [decideParking] result for [spot].
List<AvailabilityCapsule> primaryCapsules(
  ParkingSpot spot,
  VehicleType vehicle,
  ParkingDecision decision,
  List<AvailabilityCapsule> capsules,
) {
  if (decision.status == EligibilityStatus.notAllowed ||
      decision.status == EligibilityStatus.unverified) {
    return const [];
  }
  final own = capsules.where((c) => c.badge != SpaceBadge.car);
  if (own.isNotEmpty) return [own.first];
  final car = capsules.where((c) => c.badge == SpaceBadge.car);
  return vehicle == VehicleType.heavy &&
          car.isNotEmpty &&
          heavyCarOpen(spot, decision)
      ? [car.first]
      : const [];
}

/// A secondary line under the summary: another vehicle's count, never the
/// selected vehicle's.
class AvailabilityNote {
  const AvailabilityNote(this.text, this.caption);
  final String text, caption;
}

/// The availability half of the details summary.
class AvailabilityFact {
  const AvailabilityFact({
    required this.title,
    required this.headline,
    required this.caption,
    this.count,
    this.capacity,
    this.notes = const [],
    this.spokenCaption,
  });

  /// 「有沒有位」, the four signs' name for it (A14).
  final String title;

  /// The large number, only for a fresh or delayed count.
  final int? count;

  /// Beside the number (「剩餘」「剩餘，已滿」), or alone without one
  /// (「空位未知」).
  final String headline;

  /// 「／ 共 80 格（普通機車）」 after a number, naming whose bays; null
  /// otherwise.
  final String? capacity;
  final String caption;
  final List<AvailabilityNote> notes;

  /// [caption] for screen readers where it differs (the shared count's
  /// 「普大共用」 said in full); null when the caption reads as it is.
  final String? spokenCaption;

  /// The whole fact as one sentence for screen readers.
  String get semantics => [
    title,
    if (count != null) '$headline $count 格' else headline,
    if (capacity != null) capacity!.replaceFirst('／ ', ''),
    spokenCaption ?? caption,
    for (final note in notes) '${note.text}，${note.caption}',
  ].join('，');
}

String _withTotal(int? total, String rest) => [
  if (total != null) '共 $total 格',
  rest,
].where((s) => s.isNotEmpty).join(' ・ ');

/// The summary for an off-street lot. [decision] ([vehicle]'s
/// [decideParking] result) hides the count where the rider may not park and
/// decides whether the car-bay line joins ([heavyCarOpen]); it never
/// changes a count.
AvailabilityFact availabilityFact(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  ParkingDecision decision,
  DateTime now,
) {
  final eligibility = decision.status;
  const title = '有沒有位';
  // No count where the rider may not park, so it never reads as an
  // invitation (canvas v30).
  if (eligibility == EligibilityStatus.notAllowed) {
    return AvailabilityFact(
      title: title,
      headline: '不顯示空位',
      caption: '${vehicle.label}不能停這個場站',
    );
  }
  // A heavy bike on a lot of 普大共用格 alone reads the scooter count
  // there (A', [lotCount]), named as shared.
  final own = lotCount(spot, availability, vehicle, decision, now);
  final borrowed = sharedScooterCount(vehicle, own?.vehicle)
      ? borrowedBays(spot)
      : null;
  final shared = borrowed != null;
  final notes = _notes(spot, availability, vehicle, decision, own, now);
  // Whose bays: the vehicle's, or the shared ones (named in the caption).
  String? capacity(AvailabilitySnapshot own) => own.total == null
      ? null
      : shared
      ? '／ 共 ${own.total} 格'
      : '／ 共 ${own.total} 格（${vehicle.label}）';
  String withShared(String caption, [String? label]) => borrowed != null
      ? [
          caption,
          label ?? borrowed.label,
        ].where((t) => t.isNotEmpty).join(' ・ ')
      : caption;
  String? spoken(String caption) =>
      borrowed != null ? withShared(caption, borrowed.spoken) : null;
  final staticTotal =
      own?.capacity ??
      (vehicle == VehicleType.scooter && (spot.scooterTotal ?? 0) > 0
          ? spot.scooterTotal
          : null);
  final status = own?.status(now) ?? AvailabilityStatus.unavailable;
  final source = own == null
      ? ''
      : '${availabilityClock(own.sourceUpdatedAt ?? now)} 更新　${own.provider}';
  switch (status) {
    case AvailabilityStatus.fresh:
      final full = own!.available == 0;
      return AvailabilityFact(
        title: title,
        count: own.available,
        headline: full ? '剩餘，已滿' : '剩餘',
        capacity: capacity(own),
        caption: withShared(source),
        spokenCaption: spoken(source),
        notes: notes,
      );
    case AvailabilityStatus.delayed:
      final delayedSource =
          '最後更新 ${availabilityClock(own!.sourceUpdatedAt!)}　'
          '${own.provider}';
      return AvailabilityFact(
        title: title,
        count: own.available,
        headline:
            '剩餘${own.available == 0 ? '，已滿' : ''}，'
            '更新延遲 ${own.ageMinutes(now)} 分鐘',
        capacity: capacity(own),
        caption: withShared(delayedSource),
        spokenCaption: spoken(delayedSource),
        notes: notes,
      );
    case AvailabilityStatus.stale:
      return AvailabilityFact(
        title: title,
        headline: '資料過期 ・ 空位未知',
        caption: _withTotal(staticTotal, ''),
        notes: notes,
      );
    case AvailabilityStatus.suspended:
      return AvailabilityFact(
        title: title,
        headline: '暫停營運',
        caption: '來源標示場站停止服務 ・ $source'.replaceAll(RegExp(r' ・ $'), ''),
        notes: notes,
      );
    case AvailabilityStatus.invalid:
      return AvailabilityFact(
        title: title,
        headline: '空位未知',
        caption: _withTotal(staticTotal, '即時資料暫時無法使用'),
        notes: notes,
      );
    case AvailabilityStatus.unavailable:
      final static = staticTotal == null ? '總格數未提供' : '共 $staticTotal 格（靜態資料）';
      // A source that covers the lot but not this vehicle says so; a lot
      // with no source at all only has its static capacity.
      final missing = availability.isEmpty
          ? ''
          : vehicle == VehicleType.scooter
          ? '場站未提供此車種剩餘'
          : notes.any((n) => n.text.startsWith('汽車格'))
          ? '場站未提供重機剩餘'
          : '場站未提供重機或汽車格剩餘';
      return AvailabilityFact(
        title: title,
        headline: '空位未知',
        caption: [static, missing].where((s) => s.isNotEmpty).join(' ・ '),
        notes: notes,
      );
  }
}

List<AvailabilityNote> _notes(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  ParkingDecision decision,
  AvailabilitySnapshot? own,
  DateTime now,
) {
  if (vehicle != VehicleType.heavy) return const [];
  String delay(AvailabilitySnapshot s) =>
      s.status(now) == AvailabilityStatus.delayed
      ? '，更新延遲 ${s.ageMinutes(now)} 分鐘'
      : '';
  String time(AvailabilitySnapshot s) =>
      s.status(now) == AvailabilityStatus.delayed
      ? '最後更新 ${availabilityClock(s.sourceUpdatedAt!)}'
      : '${availabilityClock(s.sourceUpdatedAt!)} 更新';
  bool shown(AvailabilitySnapshot? s) =>
      s != null &&
      const {
        AvailabilityStatus.fresh,
        AvailabilityStatus.delayed,
      }.contains(s.status(now));
  final car = availability.of(AvailabilityVehicle.car);
  final scooter = availability.of(AvailabilityVehicle.scooter);
  return [
    if (shown(car) && heavyCarOpen(spot, decision))
      AvailabilityNote(
        car!.available == 0
            ? '汽車格已滿${delay(car)}'
            : '汽車格剩餘 ${car.available}${delay(car)}',
        '${time(car)} ・ ${car.provider}',
      ),
    // Another class's count only when this class has none to show. The
    // scooter count standing as the answer (A', [lotCount]) is not
    // repeated.
    if (!shown(own) && shown(scooter) && !identical(own, scooter))
      AvailabilityNote(
        scooterCountLine(scooter!, now),
        '${time(scooter)} ・ ${scooter.provider} ・ $notForHeavyNote',
      ),
  ];
}

/// The availability filters. They narrow the map; they never decide that
/// an unknown space is full.
enum AvailabilityFilter {
  off,

  /// 「有即時資訊」: a fresh count for this vehicle, full included.
  live,

  /// 「有即時空位」: fresh, more than zero, and the vehicle may park.
  available,
}

/// Why a spot is left out by an [AvailabilityFilter]. Unknown spaces get
/// their own reasons and are never counted as [full].
enum AvailabilityExclusion {
  roadside,
  noData,
  stale,
  delayed,
  suspended,
  full,
  notAllowed,
  unverified,
}

/// Why [filter] leaves [spot] out, or null when it keeps it.
AvailabilityExclusion? availabilityExclusion(
  AvailabilityFilter filter,
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  EligibilityStatus eligibility,
  DateTime now, {
  ParkingDecision? decision,
}) {
  if (filter == AvailabilityFilter.off) return null;
  if (!spot.isFacility) return AvailabilityExclusion.roadside;
  // The same count as the pills (A', [lotCount]); without [decision] the
  // vehicle's own count alone.
  final own = lotCount(
    spot,
    availability,
    vehicle,
    decision,
    now,
    beside: false,
  );
  switch (own?.status(now)) {
    case null:
    case AvailabilityStatus.unavailable:
    case AvailabilityStatus.invalid:
      return AvailabilityExclusion.noData;
    case AvailabilityStatus.stale:
      return AvailabilityExclusion.stale;
    case AvailabilityStatus.delayed:
      return AvailabilityExclusion.delayed;
    case AvailabilityStatus.suspended:
      return AvailabilityExclusion.suspended;
    case AvailabilityStatus.fresh:
      break;
  }
  // A lot closed to the rider shows no count, so it is not live
  // information for them either (canvas v30).
  if (eligibility == EligibilityStatus.notAllowed) {
    return AvailabilityExclusion.notAllowed;
  }
  if (filter == AvailabilityFilter.live) return null;
  if (own!.available == 0) return AvailabilityExclusion.full;
  return eligibility == EligibilityStatus.unverified
      ? AvailabilityExclusion.unverified
      : null;
}

/// One line of the empty-result card.
String exclusionReason(
  AvailabilityExclusion reason,
  AvailabilityFilter filter,
  VehicleType vehicle,
) => switch (reason) {
  AvailabilityExclusion.roadside => '路邊格沒有官方即時資料，空位未知',
  AvailabilityExclusion.noData => '場站沒有${vehicle.label}的即時資料，空位未知',
  AvailabilityExclusion.stale => '資料過期，空位未知',
  AvailabilityExclusion.delayed =>
    filter == AvailabilityFilter.available
        ? '資料更新延遲，暫不列為有位'
        : '資料更新延遲，暫不列為即時資訊',
  AvailabilityExclusion.suspended => '暫停營運',
  AvailabilityExclusion.full => '目前已滿',
  AvailabilityExclusion.notAllowed => '${vehicle.label}不能停',
  AvailabilityExclusion.unverified => '有位，但${vehicle.label}是否可停待確認',
};

/// The filter's name as its pill and messages write it.
String availabilityFilterLabel(AvailabilityFilter filter) => switch (filter) {
  AvailabilityFilter.off => '即時車位',
  AvailabilityFilter.live => '有即時資訊',
  AvailabilityFilter.available => '有即時空位',
};
