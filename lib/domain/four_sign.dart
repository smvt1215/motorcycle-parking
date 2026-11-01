/// The four signs (design canvas Ver.143 A1–A6, A11): what a rider asks of
/// a spot, in order — 能不能停, 有沒有位, 怎麼算錢, 停哪裡 — answered for the
/// rider's vehicle at this moment. The answers are data; how they read is
/// four_sign_display.dart's. Every eligibility comes from [decideParking]
/// (through [decideSegments] on the street), read here and never changed.
///
/// Only the zones or segments the vehicle may park in now count
/// (sightings-4-level decisions, 2026-10-29); when none is open now, the
/// ones open later stand in, so the answers name where and when.
/// Pure Dart.
library;

import '../models/availability.dart';
import '../models/closure.dart';
import '../models/fee.dart';
import '../models/holiday_calendar.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import '../models/zone_entries.dart';
import 'availability_display.dart' show availabilityVehicle, heavyCarOpen;
import 'eligibility.dart';
import 'parking_decision.dart';
import 'segment_decision.dart';

/// The four faces, in the order riders read them (2026-10-29).
enum FourSignFace { verdict, seat, fee, where }

/// One place a rider may park in: a lot zone, a street segment, or the
/// whole spot when it has neither.
class SignArea {
  const SignArea({
    required this.name,
    required this.status,
    required this.window,
    this.id,
    this.restriction,
    this.bayKind,
    this.side,
    this.total,
    this.countClass,
    this.zone,
    this.segment,
    this.condition,
  });

  /// The zone's or segment's stable id; null for the whole spot.
  final String? id;

  /// The zone's or segment's name as stored; empty for the whole spot.
  final String name;
  final EligibilityStatus status;
  final RuleRestriction? restriction;
  final OpenWindow window;

  /// What is painted there; null when unconfirmed.
  final BayKind? bayKind;

  /// A segment's side of the road.
  final RoadSide? side;

  /// A segment's bay count; null when unconfirmed.
  final int? total;

  /// Whose official count describes this place's bays; null when none
  /// does (the count would describe other bays).
  final AvailabilityVehicle? countClass;

  /// The lot zone this place is; null for a segment or the whole spot.
  final ParkingZone? zone;

  /// The street segment this place is; null for a zone or the whole spot.
  final ParkingSegment? segment;

  /// The condition the place is judged by (a segment's as [decideParking]
  /// fills it from the spot's); its time limit gives a per-visit rate's
  /// stay and extensions. Null when unconfirmed.
  final ParkingCondition? condition;

  bool get whole => id == null && name.isEmpty;
  bool get open =>
      status == EligibilityStatus.allowed ||
      status == EligibilityStatus.conditional;
}

/// 能不能停.
class VerdictAnswer {
  const VerdictAnswer({
    required this.status,
    this.restriction,
    this.until,
    this.opensAt,
    this.basis = BasisKind.none,
    this.city,
    this.openNow = false,
    this.notStated = false,
  });

  /// The four signs' status: [decideParking]'s, except that only places
  /// open now decide whether it reads 可停 or 有條件.
  final EligibilityStatus status;
  final RuleRestriction? restriction;

  /// Every place open now closes at this time (「22:00」).
  final String? until;

  /// Nothing is open now; the first place opens then.
  final String? opensAt;

  /// Who decided it: government data, an administrator, a city rule…
  final BasisKind basis;

  /// The city of the rule that decided it.
  final String? city;
  final bool openNow;

  /// 官方未標示 (#201): an unverified answer because the official data
  /// names the vehicle without saying whether it may park (A3 不確定).
  final bool notStated;
}

enum SeatKind {
  /// An official count inside its update window.
  live,

  /// The newest official count, past its window (every place is delayed).
  delayed,

  /// The source says the lot is closed.
  suspended,

  /// Riders' reports, with no official count to show.
  rider,

  /// Only how many bays there are.
  total,

  /// Nothing says.
  unknown,
}

/// A rider report's reading of one place (A6, A7): level 0 已停滿 to 3 很多
/// 空位; two levels when reports disagree (說法不一).
class RiderSeat {
  const RiderSeat({
    required this.level,
    required this.at,
    this.areaId,
    this.otherLevel,
    this.highCount,
    this.lowCount,
  });

  /// 0 已停滿, 1 快滿了, 2 還有一些, 3 很多空位.
  final int level;

  /// The other end when reports disagree; null when they agree.
  final int? otherLevel;

  /// How many said the higher and the lower level, when they disagree.
  final int? highCount, lowCount;
  final DateTime at;

  /// The zone or segment it is about; null for the whole spot.
  final String? areaId;

  bool get conflict => otherLevel != null;
}

/// Where riders' reports come from. PR-E (#185 rework) gives the store's;
/// until then nothing reports.
abstract interface class RiderSeats {
  /// The reports about [spotId] the preview may show (the caller filters
  /// them by age), one per place.
  List<RiderSeat> of(String spotId);
}

class _NoRiderSeats implements RiderSeats {
  const _NoRiderSeats();
  @override
  List<RiderSeat> of(String spotId) => const [];
}

/// No rider reports.
const RiderSeats noRiderSeats = _NoRiderSeats();

/// 有沒有位.
class SeatAnswer {
  const SeatAnswer({
    required this.kind,
    this.areas = const [],
    this.available,
    this.total,
    this.at,
    this.counted = 0,
    this.more = 0,
    this.rider,
  });
  final SeatKind kind;

  /// The places the number is about (a shared count names several).
  final List<SignArea> areas;
  final int? available, total;

  /// The count's source time, or the report's.
  final DateTime? at;

  /// How many places a static [total] adds up.
  final int counted;

  /// Other places with space (「另 N 區有位」).
  final int more;
  final RiderSeat? rider;
}

enum FeeKind {
  /// One rate for every place counted.
  rate,

  /// Places counted charge differently.
  varies,

  /// Text that is not a structured rate.
  text,

  /// No source states it (官方未標示).
  unknown,
}

/// A rate as the plate reads it, at this moment: a by_time rate's current
/// period.
class PlateRate {
  const PlateRate(
    this.mode, {
    this.amount,
    this.perMinutes,
    this.dailyCap,
    this.from,
    this.to,
    this.firstMinutes,
    this.extensionAmount,
    this.extensionTimes,
  });
  final FeeMode mode;

  /// A per-visit rate of 0 on a place with a time limit (首 20 分鐘 0 元,
  /// #188 layer 2 「計次 0 元」): the stay the time limit allows now; never
  /// read as free.
  final int? firstMinutes;

  /// A per-visit rate's paid extension (可付 40 元延長 1 次): what each
  /// costs (the rate's `extension_amount`) and how many times the place's
  /// time limit allows now; null when either is unstated or none is
  /// allowed.
  final int? extensionAmount;
  final int? extensionTimes;

  /// Heavy bikes following another vehicle's rate pay it as it is (#188
  /// layer 2 removed the factor).
  final int? amount, dailyCap;
  final int? perMinutes;

  /// The current period of a by_time rate.
  final String? from, to;

  bool get hourly => mode == FeeMode.hourly && perMinutes == 60;

  @override
  bool operator ==(Object other) =>
      other is PlateRate &&
      other.mode == mode &&
      other.amount == amount &&
      other.perMinutes == perMinutes &&
      other.dailyCap == dailyCap &&
      other.from == from &&
      other.to == to &&
      other.firstMinutes == firstMinutes &&
      other.extensionAmount == extensionAmount &&
      other.extensionTimes == extensionTimes;

  @override
  int get hashCode => Object.hash(
    mode,
    amount,
    perMinutes,
    dailyCap,
    from,
    to,
    firstMinutes,
    extensionAmount,
    extensionTimes,
  );
}

/// 怎麼算錢.
class FeeAnswer {
  const FeeAnswer({
    required this.kind,
    this.rate,
    this.rates = const [],
    this.text,
    this.places = 1,
  });
  final FeeKind kind;

  /// The one rate ([FeeKind.rate]).
  final PlateRate? rate;

  /// Each place's rate ([FeeKind.varies]).
  final List<PlateRate> rates;

  /// [FeeKind.text]'s text.
  final String? text;

  /// How many places the answer covers; above one with one rate reads
  /// 全場同價.
  final int places;
}

/// 停哪裡.
class WhereAnswer {
  const WhereAnswer({required this.areas, this.entrance = '', this.wholeBay});

  /// The places open now (or later, when none is now); empty when the
  /// spot names none.
  final List<SignArea> areas;
  final String entrance;

  /// A street spot without segments: the bay painted there.
  final BayKind? wholeBay;
}

class FourSign {
  const FourSign({
    required this.vehicle,
    required this.street,
    required this.verdict,
    required this.seat,
    required this.fee,
    required this.where,
  });
  final VehicleType vehicle;

  /// A street spot (segments), not a lot (zones).
  final bool street;
  final VerdictAnswer verdict;
  final SeatAnswer seat;
  final FeeAnswer fee;
  final WhereAnswer where;

  /// The vehicle may not park here: the signs collapse to one.
  bool get denied => verdict.status == EligibilityStatus.notAllowed;

  /// Whether 停哪裡 already names the one place, so 有沒有位 need not.
  bool get singlePlace => where.areas.length == 1 && !where.areas.single.whole;
}

/// The four signs of [spot] for [vehicle] at [now]. [decision] is the
/// spot's [decideParking] result when the caller has it; [availability]
/// its official counts; [riders] the reports the caller lets it show.
FourSign fourSign(
  ParkingSpot spot,
  VehicleType vehicle,
  Iterable<CityRule> rules, {
  required DateTime now,
  SpotAvailability availability = SpotAvailability.none,
  RiderSeats riders = noRiderSeats,
  ParkingDecision? decision,
  HolidayCalendar? calendar,
}) {
  final whole =
      decision ??
      decideParking(spot, vehicle, rules, now: now, calendar: calendar);
  final street = !spot.isFacility;
  final areas = street
      ? _streetAreas(spot, vehicle, rules, whole, now, calendar)
      : _lotAreas(spot, vehicle, whole, now, calendar);
  final openNow = [
    for (final a in areas)
      if (a.window.now) a,
  ];
  final open = [
    for (final a in areas)
      if (a.open) a,
  ];
  final counted = openNow.isNotEmpty ? openNow : open;
  final verdict = _verdict(spot, now, whole, areas, openNow, open, street);
  return FourSign(
    vehicle: vehicle,
    street: street,
    verdict: verdict,
    seat: verdict.status == EligibilityStatus.notAllowed
        ? const SeatAnswer(kind: SeatKind.unknown)
        : _seat(spot, vehicle, whole, counted, availability, riders, now),
    fee: _fee(spot, vehicle, counted, street, now, calendar),
    where: WhereAnswer(
      areas: [
        for (final a in counted)
          if (!a.whole) a,
      ],
      entrance: spot.isFacility ? spot.entranceNote.trim() : '',
      wholeBay: street && areas.length == 1 && areas.single.whole
          ? areas.single.bayKind
          : null,
    ),
  );
}

ParkingCondition? _zoneCondition(ParkingZone z) =>
    z.condition ?? zoneConditionOf(z.access);

/// What is painted in a zone: its condition's bay alone (#188 layer 2
/// removed `area`); null when unconfirmed.
BayKind? _zoneBay(ParkingZone z) => bayKindOf(_zoneCondition(z));

/// Whose official count describes a zone's bays for [vehicle] (Taipei
/// sends one count per scooter, heavy bike and car for the whole lot,
/// decision 2026-10-29), read from the zone's bay: heavy bays the heavy
/// count, car bays the car count (heavy bikes only, as [heavyCarOpen]
/// reads them), motorcycle bays the scooter count for scooters. A heavy
/// bike on motorcycle bays has no count of its own: the scooter count
/// never stands for it. A zone whose bay is unconfirmed has none.
AvailabilityVehicle? _countClass(ParkingZone z, VehicleType vehicle) =>
    switch ((vehicle, _zoneCondition(z)?.bay)) {
      (VehicleType.heavy, Bay.heavy) => AvailabilityVehicle.heavy,
      (VehicleType.heavy, Bay.car) => AvailabilityVehicle.car,
      (VehicleType.scooter, Bay.motorcycle) => AvailabilityVehicle.scooter,
      _ => null,
    };

List<SignArea> _lotAreas(
  ParkingSpot spot,
  VehicleType vehicle,
  ParkingDecision whole,
  DateTime now,
  HolidayCalendar? calendar,
) {
  final zones = whole.zones;
  // Zones decide only as decideParking listed them, in the lot's order,
  // and only once the lot itself is open: zones of a lot whose access is
  // unknown open nothing. Zones that say nothing leave the lot as one
  // place.
  final lotOpen =
      whole.status == EligibilityStatus.allowed ||
      whole.status == EligibilityStatus.conditional;
  if (zones.length == spot.zones.length && zones.any((z) => z.hasData)) {
    return [
      for (final (i, z) in zones.indexed)
        () {
          final status = lotOpen || z.status == EligibilityStatus.notAllowed
              ? z.status
              : EligibilityStatus.unverified;
          final zone = spot.zones[i];
          return SignArea(
            id: zone.id,
            name: z.name.trim(),
            status: status,
            restriction: lotOpen ? z.restriction : null,
            bayKind: _zoneBay(zone),
            countClass: _countClass(zone, vehicle),
            zone: zone,
            condition: _zoneCondition(zone),
            window: openWindow(
              status,
              _zoneCondition(zone),
              vehicle,
              now,
              calendar: calendar,
              basis: whole.basis,
            ),
          );
        }(),
    ];
  }
  // A whole lot's decision does not read its own slots: a schedule that
  // lists none for this vehicle states no time it may park (待確認), not
  // all day.
  final silent =
      lotOpen &&
      whole.zones.isEmpty &&
      scheduleSilentFor(spot.condition, vehicle);
  final status = silent ? EligibilityStatus.unverified : whole.status;
  return [
    SignArea(
      name: '',
      status: status,
      restriction: silent ? null : whole.restriction,
      window: openWindow(
        status,
        spot.condition,
        vehicle,
        now,
        calendar: calendar,
        basis: whole.basis,
      ),
      countClass: availabilityVehicle(vehicle),
      condition: spot.condition,
    ),
  ];
}

List<SignArea> _streetAreas(
  ParkingSpot spot,
  VehicleType vehicle,
  Iterable<CityRule> rules,
  ParkingDecision whole,
  DateTime now,
  HolidayCalendar? calendar,
) => [
  for (final s in decideSegments(
    spot,
    vehicle,
    rules,
    now: now,
    calendar: calendar,
    whole: whole,
  ))
    SignArea(
      id: s.segment?.id,
      name: s.segment?.name.trim() ?? '',
      status: s.status,
      restriction: s.decision.restriction,
      window: s.window,
      segment: s.segment,
      condition: s.segment == null
          ? spot.condition ?? conditionOf(spot.spaceType)
          : segmentConditionOf(s.segment!, spot),
      bayKind:
          s.segment?.bayKind ??
          (s.segment == null
              ? bayKindOf(spot.condition ?? conditionOf(spot.spaceType))
              : null),
      side: s.segment?.side,
      total:
          s.segment?.total ??
          (s.segment == null && (spot.scooterTotal ?? 0) > 0
              ? spot.scooterTotal
              : null),
    ),
];

BasisKind _basisOf(ParkingDecision d, bool street) {
  final source = d.basis.firstOrNull?.kind ?? BasisKind.none;
  if (!street) return source;
  // On the street the rule or the law decides; the data only says the
  // bay is there.
  for (final b in d.basis.skip(1)) {
    if (b.kind == BasisKind.cityRule ||
        b.kind == BasisKind.law ||
        b.kind == BasisKind.notice) {
      return b.kind;
    }
  }
  return source;
}

VerdictAnswer _verdict(
  ParkingSpot spot,
  DateTime now,
  ParkingDecision whole,
  List<SignArea> areas,
  List<SignArea> openNow,
  List<SignArea> open,
  bool street,
) {
  final basis = _basisOf(whole, street);
  final city = [
    for (final b in whole.basis)
      if (b.rule case final rule?) rule.city,
  ].firstOrNull;
  // A spot closed as a whole (works, its own data) or in every place.
  final works = spot.closure?.stateOn(now) == ClosureState.active;
  if (works ||
      whole.status == EligibilityStatus.notAllowed && !street ||
      // Every segment closed closes a street. A lot whose listed zones are
      // all closed stays as decideParking judged it: open to the vehicle
      // but with a partial or conflicting zone list, it is unverified.
      street && areas.every((a) => a.status == EligibilityStatus.notAllowed)) {
    return VerdictAnswer(
      status: EligibilityStatus.notAllowed,
      basis: basis,
      city: city,
    );
  }
  if (openNow.isNotEmpty) {
    // Open now with nothing that ends it: allowed, and no slot closing it
    // (a lot allowed only 20:00–23:00 by its own hours is not all day).
    bool unlimited(SignArea a) =>
        a.status == EligibilityStatus.allowed && a.window.until == null;
    // One place open now without a limit is enough for 可停 (A11 card 1:
    // B2 all day beside B3 by the hour); the details list the rest.
    if (openNow.any(unlimited)) {
      return VerdictAnswer(
        status: EligibilityStatus.allowed,
        basis: basis,
        city: city,
        openNow: true,
      );
    }
    // Every place open now closes: the one closing last stands, compared by
    // minutes (a slot to 隔天 02:00 closes after one to 23:00).
    final closing = openNow.every((a) => a.window.untilMinute != null)
        ? openNow.reduce(
            (a, b) => b.window.untilMinute! > a.window.untilMinute! ? b : a,
          )
        : null;
    return VerdictAnswer(
      status: EligibilityStatus.conditional,
      // A place limited only by its hours reads as 限時段. Places limited
      // differently (one 限電動 all day, one open to all 20–23) share no
      // limit: plain 有條件, never one place's limit standing for all.
      restriction: {for (final a in openNow) _restrictionOf(a)}.singleOrNull,
      until: closing?.window.until,
      basis: basis,
      city: city,
      openNow: true,
    );
  }
  if (open.isNotEmpty) {
    // The place opening first names the time and its limit.
    final later = [
      for (final a in open)
        if (a.window.opensAtMinute != null) a,
    ];
    final first = later.isEmpty
        ? null
        : later.reduce(
            (a, b) => b.window.opensAtMinute! < a.window.opensAtMinute! ? b : a,
          );
    return VerdictAnswer(
      status: EligibilityStatus.conditional,
      restriction:
          (first ?? open.first).restriction ?? RuleRestriction.timeLimited,
      opensAt: first?.window.opensAt,
      basis: basis,
      city: city,
    );
  }
  return VerdictAnswer(
    status: EligibilityStatus.unverified,
    basis: basis,
    city: city,
    notStated: whole.gaps.contains(DecisionGap.notStated),
  );
}

bool _shown(AvailabilitySnapshot s, DateTime now) =>
    s.status(now) == AvailabilityStatus.fresh ||
    s.status(now) == AvailabilityStatus.delayed;

SeatAnswer _seat(
  ParkingSpot spot,
  VehicleType vehicle,
  ParkingDecision whole,
  List<SignArea> places,
  SpotAvailability availability,
  RiderSeats riders,
  DateTime now,
) {
  // Official counts, lots only: each class's count with the places it
  // describes (zones sharing a count merge, decision 2026-10-29).
  final groups = <AvailabilityVehicle, List<SignArea>>{};
  if (spot.isFacility && places.isNotEmpty) {
    if (places.every((a) => a.whole)) {
      // The whole lot: its own class's count, and for heavy bikes the car
      // bays the lot opens to them.
      groups[availabilityVehicle(vehicle)] = const [];
    } else {
      for (final a in places) {
        if (a.countClass case final cls?) {
          groups.putIfAbsent(cls, () => []).add(a);
        }
      }
      // No zone open now that a count describes: the space stays unknown.
      // The lot's count would describe the zones left out (a heavy-bike
      // count while only a shared motorcycle zone is open); only a lot
      // with no zone data at all reads it, above.
    }
    if (vehicle == VehicleType.heavy &&
        !groups.containsKey(AvailabilityVehicle.car) &&
        places.every((a) => a.whole) &&
        heavyCarOpen(spot, whole)) {
      groups[AvailabilityVehicle.car] = const [];
    }
  }
  final counts = [
    for (final MapEntry(:key, :value) in groups.entries)
      if (availability.of(key) case final s?) (s, value),
  ];
  if (counts.any((c) => c.$1.status(now) == AvailabilityStatus.suspended)) {
    return const SeatAnswer(kind: SeatKind.suspended);
  }
  final usable = [
    for (final c in counts)
      if (_shown(c.$1, now)) c,
  ];
  if (usable.isNotEmpty) {
    bool isFresh(int i) => usable[i].$1.status(now) == AvailabilityStatus.fresh;
    final anyFresh = [for (var i = 0; i < usable.length; i++) i].any(isFresh);
    // Indexes into [usable]: fresh ones when any, else every one.
    final pool = [
      for (var i = 0; i < usable.length; i++)
        if (!anyFresh || isFresh(i)) i,
    ];
    DateTime time(AvailabilitySnapshot s) =>
        s.sourceUpdatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    // Fresh first, then most free, then newer (2026-10-29); with none
    // fresh, the newest.
    pool.sort((i, j) {
      final a = usable[i].$1, b = usable[j].$1;
      final byFree = b.available!.compareTo(a.available!);
      return anyFresh && byFree != 0 ? byFree : time(b).compareTo(time(a));
    });
    final bestAt = pool.first;
    final best = usable[bestAt];
    // Only counts in the same pool say another place has space: with fresh
    // ones, a delayed count never does.
    final more = [
      for (final i in pool)
        if (i != bestAt && usable[i].$1.available! > 0)
          usable[i].$2.isEmpty ? 1 : usable[i].$2.length,
    ].fold<int>(0, (a, b) => a + b);
    return SeatAnswer(
      kind: anyFresh ? SeatKind.live : SeatKind.delayed,
      areas: best.$2.isEmpty && best.$1.vehicle == AvailabilityVehicle.car
          ? const [
              SignArea(
                id: 'car',
                name: '汽車格',
                status: EligibilityStatus.allowed,
                window: OpenWindow.always,
              ),
            ]
          : best.$2,
      available: best.$1.available,
      total: best.$1.capacity,
      at: best.$1.sourceUpdatedAt,
      more: more,
    );
  }
  // Riders' reports, where no official count shows (A11 card 3).
  final reports = riders.of(spot.id);
  if (reports.isNotEmpty) {
    final byPlace = <SignArea?, RiderSeat>{};
    for (final r in reports) {
      final place = places
          .where((a) => r.areaId != null && a.id == r.areaId)
          .firstOrNull;
      // A report about a place the rider may not park in now is not
      // shown; one about the whole spot is.
      if (place == null && r.areaId != null) continue;
      final known = byPlace[place];
      if (known == null || r.at.isAfter(known.at)) byPlace[place] = r;
    }
    if (byPlace.isNotEmpty) {
      final ranked = byPlace.entries.toList()
        ..sort(
          (a, b) => b.value.level != a.value.level
              ? b.value.level.compareTo(a.value.level)
              : b.value.at.compareTo(a.value.at),
        );
      final best = ranked.first;
      return SeatAnswer(
        kind: SeatKind.rider,
        areas: [?best.key],
        rider: best.value,
        at: best.value.at,
        more: ranked.skip(1).where((e) => e.value.level > 0).length,
      );
    }
  }
  // Only how many bays: the places open now added up (A6 card 2).
  if (spot.isFacility) {
    final totals = [
      for (final c in counts)
        if (c.$1.capacity case final n?) (n, c.$2),
    ];
    final total = totals.isNotEmpty
        ? totals.fold<int>(0, (a, b) => a + b.$1)
        : vehicle == VehicleType.scooter && (spot.scooterTotal ?? 0) > 0
        ? spot.scooterTotal
        : null;
    if (total != null) {
      final named = [for (final t in totals) ...t.$2];
      return SeatAnswer(
        kind: SeatKind.total,
        total: total,
        areas: named,
        counted: named.length,
      );
    }
    return const SeatAnswer(kind: SeatKind.unknown);
  }
  final known = [
    for (final a in places)
      if (a.total != null) a,
  ];
  if (known.isEmpty) return const SeatAnswer(kind: SeatKind.unknown);
  return SeatAnswer(
    kind: SeatKind.total,
    total: known.fold<int>(0, (a, b) => a + b.total!),
    areas: known,
    counted: known.length,
  );
}

/// [vehicle]'s rate in [fee], a heavy follow read as the rate it follows
/// (same_as_scooter, same_as_car; no factor since #188 layer 2); null when
/// unconfirmed or not applicable (不適用), or when it follows one that is.
Rate? _resolved(Fee fee, VehicleType vehicle) {
  final key = vehicle == VehicleType.heavy ? 'heavy' : 'scooter';
  if (fee.textOf(key) == null) return null;
  final rate = vehicle == VehicleType.heavy ? fee.heavy : fee.scooter;
  if (rate == null || !rate.mode.follows) return rate;
  return rate.mode == FeeMode.sameAsScooter ? fee.scooter : fee.car;
}

/// The period of [condition]'s time limit that holds at [now], as
/// decideParking reads it (an old all-day `max_minutes` as one period);
/// null when there is none, or none holds now.
LimitPeriod? _stayAt(
  ParkingCondition? condition,
  DateTime now,
  HolidayCalendar calendar,
) {
  final (today, at) = taipeiDateMinute(now);
  for (final l in condition?.limits ?? const <ParkingLimit>[]) {
    if (l.kind != LimitKind.timeLimit) continue;
    for (final p in l.timePeriods) {
      final spans = datedSpans(p.days, p.from, p.to, today, calendar);
      if (spans.any((s) => s.$1 <= at && at < s.$2)) return p;
    }
  }
  return null;
}

/// [rate] as it holds at [now] on a place judged by [condition]; null
/// when it is not one the plate can state (no period of a by_time rate
/// holds now).
PlateRate? _plateRate(
  Rate rate,
  ParkingCondition? condition,
  DateTime now,
  HolidayCalendar calendar, {
  String? from,
  String? to,
}) {
  switch (rate.mode) {
    case FeeMode.free:
      return PlateRate(FeeMode.free, from: from, to: to);
    case FeeMode.hourly:
      return PlateRate(
        FeeMode.hourly,
        amount: rate.amount,
        perMinutes: rate.perMinutes,
        dailyCap: rate.dailyCap,
        from: from,
        to: to,
      );
    case FeeMode.perVisit:
      // How long one visit and each extension lasts is the place's time
      // limit now (#188 layer 2): 0 元 for that stay reads 首段 0 元.
      final stay = _stayAt(condition, now, calendar);
      final times = stay?.extensions ?? 0;
      final extensible = rate.extensionAmount != null && times > 0;
      return PlateRate(
        rate.mode,
        amount: rate.amount,
        firstMinutes: rate.amount == 0 ? stay?.maxMinutes : null,
        extensionAmount: extensible ? rate.extensionAmount : null,
        extensionTimes: extensible ? times : null,
        from: from,
        to: to,
      );
    case FeeMode.byTime:
      final (today, at) = taipeiDateMinute(now);
      FeePeriod? best;
      int? since;
      // Where periods overlap, the one that started last holds, as the
      // details' rate now reads it.
      for (final p in rate.periods ?? const <FeePeriod>[]) {
        for (final (start, end) in datedSpans(
          p.days,
          p.from,
          p.to,
          today,
          calendar,
        )) {
          final elapsed = at - start;
          if (elapsed >= 0 && at < end && (since == null || elapsed < since)) {
            (best, since) = (p, elapsed);
          }
        }
      }
      if (best == null) return null;
      return _plateRate(
        best.rate,
        condition,
        now,
        calendar,
        from: best.from,
        to: best.to,
      );
    case FeeMode.notApplicable || FeeMode.sameAsScooter || FeeMode.sameAsCar:
      return null;
  }
}

/// A place's price: a structured rate, legacy text, or nothing.
sealed class _Price {
  const _Price();
}

class _RatePrice extends _Price {
  const _RatePrice(this.rate, this.source);
  final PlateRate rate;

  /// The whole rule behind [rate]: what decides whether two places charge
  /// alike, since the plate drops terms such as a cap's reset.
  final Rate source;
}

class _TextPrice extends _Price {
  const _TextPrice(this.text);
  final String text;
}

class _NoPrice extends _Price {
  const _NoPrice();
}

bool _placeholder(String text) =>
    const {'', '依現場公告', '請依現場公告', '費率未確認'}.contains(text.trim());

_Price _priceOf(
  Fee? fee,
  String legacy,
  VehicleType vehicle,
  ParkingCondition? condition,
  DateTime now,
  HolidayCalendar calendar,
) {
  if (fee != null) {
    final resolved = _resolved(fee, vehicle);
    if (resolved == null) return const _NoPrice();
    final rate = _plateRate(resolved, condition, now, calendar);
    return rate == null ? const _NoPrice() : _RatePrice(rate, resolved);
  }
  return _placeholder(legacy) ? const _NoPrice() : _TextPrice(legacy.trim());
}

String _zoneLegacy(ParkingZone z, VehicleType vehicle) {
  final own = vehicle == VehicleType.heavy ? z.heavyFeeNote : z.scooterFeeNote;
  return own.trim().isNotEmpty ? own : z.feeNote;
}

FeeAnswer _fee(
  ParkingSpot spot,
  VehicleType vehicle,
  List<SignArea> places,
  bool street,
  DateTime now,
  HolidayCalendar? calendar,
) {
  final cal = calendar ?? HolidayCalendar.current;
  _Price spotPrice(ParkingCondition? condition) =>
      _priceOf(spot.fee, spot.feeNote, vehicle, condition, now, cal);
  final wholeSpot = places.isEmpty || places.every((a) => a.whole);
  final List<_Price> prices;
  if (street) {
    // A segment's own rate, else the whole road's (#188 layer 2, C3), as
    // decideParking prices it: read segment by segment. No segment open
    // (or none at all): every segment prices it.
    final segments = wholeSpot
        ? [for (final s in spot.segments) (s, segmentConditionOf(s, spot))]
        : [
            for (final a in places)
              if (a.segment case final s?) (s, a.condition),
          ];
    prices = segments.isEmpty
        ? [spotPrice(spot.condition ?? conditionOf(spot.spaceType))]
        : [
            for (final (s, c) in segments)
              s.fee != null
                  ? _priceOf(s.fee, '', vehicle, c, now, cal)
                  : spotPrice(c),
          ];
  } else if (spot.zones.isEmpty) {
    prices = [spotPrice(spot.condition)];
  } else {
    // A zone's own rate, else the lot-wide one (#188 layer 2, C2), as
    // decideParking prices it; only with no structured rate anywhere does
    // a zone read its own text, then the lot's. No zone place open (none
    // open, or zones without access data standing as the whole lot):
    // every zone prices it.
    final anyZoneFee = spot.zones.any((z) => z.fee != null);
    final zones = wholeSpot ? spot.zones : [for (final a in places) ?a.zone];
    prices = [
      for (final z in zones)
        z.fee != null
            ? _priceOf(z.fee, '', vehicle, _zoneCondition(z), now, cal)
            : spot.fee != null
            ? spotPrice(_zoneCondition(z))
            : switch (_zoneLegacy(z, vehicle)) {
                final t when !_placeholder(t) => _TextPrice(t.trim()),
                _ when anyZoneFee => const _NoPrice(),
                _ => spotPrice(_zoneCondition(z)),
              },
    ];
  }
  if (prices.isEmpty) return const FeeAnswer(kind: FeeKind.unknown);
  final rates = [
    for (final p in prices)
      if (p is _RatePrice) p.rate,
  ];
  if (rates.length == prices.length) {
    // 全場同價 only when the whole rules match, not just what the plate shows.
    final sources = {for (final p in prices) (p as _RatePrice).source};
    if (rates.toSet().length == 1 && sources.length == 1) {
      return FeeAnswer(
        kind: FeeKind.rate,
        rate: rates.first,
        places: street ? 1 : prices.length,
      );
    }
    return FeeAnswer(kind: FeeKind.varies, rates: rates, places: prices.length);
  }
  if (prices.every((p) => p is _NoPrice)) {
    return const FeeAnswer(kind: FeeKind.unknown);
  }
  final texts = {
    for (final p in prices)
      if (p is _TextPrice) p.text,
  };
  if (texts.length == 1 && rates.isEmpty && !prices.any((p) => p is _NoPrice)) {
    return FeeAnswer(kind: FeeKind.text, text: texts.single);
  }
  return FeeAnswer(kind: FeeKind.varies, rates: rates, places: prices.length);
}

/// What limits [area]: its own restriction, else 限時段 only when its hours
/// end it; a condition the decision words in its reasons stays plain 有條件.
RuleRestriction? _restrictionOf(SignArea area) =>
    area.restriction ??
    (area.window.until != null ? RuleRestriction.timeLimited : null);
