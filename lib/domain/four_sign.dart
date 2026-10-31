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
  });
  final FeeMode mode;

  /// Worked out from a follow's factor; may have decimals.
  final num? amount, dailyCap;
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
      other.to == to;

  @override
  int get hashCode => Object.hash(mode, amount, perMinutes, dailyCap, from, to);
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

BayKind? _zoneBay(ParkingZone z) {
  final c = z.condition ?? zoneConditionOf(z.access);
  return bayKindOf(c) ??
      switch (z.area) {
        ZoneArea.heavy => BayKind.heavy,
        ZoneArea.car => BayKind.car,
        ZoneArea.motorcycle => BayKind.motorcycle,
        _ => null,
      };
}

/// Whose official count describes a zone's bays for [vehicle] (Taipei
/// sends one count per scooter, heavy bike and car for the whole lot,
/// decision 2026-10-29): heavy bays the heavy count, car bays the car
/// count (heavy bikes only, as [heavyCarOpen] reads them), motorcycle bays
/// the scooter count for scooters. A heavy bike on motorcycle bays has no
/// count of its own: the scooter count never stands for it.
AvailabilityVehicle? _countClass(ParkingZone z, VehicleType vehicle) {
  final bay = (z.condition ?? zoneConditionOf(z.access))?.bay;
  final area = z.area;
  final heavy = bay == Bay.heavy || (bay == null && area == ZoneArea.heavy);
  final car = area == ZoneArea.car || (area == null && bay == Bay.car);
  final moto =
      bay == Bay.motorcycle || (bay == null && area == ZoneArea.motorcycle);
  return switch (vehicle) {
    VehicleType.heavy when heavy => AvailabilityVehicle.heavy,
    VehicleType.heavy when car => AvailabilityVehicle.car,
    VehicleType.scooter when moto && !car => AvailabilityVehicle.scooter,
    _ => null,
  };
}

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
            window: openWindow(
              status,
              zone.condition ?? zoneConditionOf(zone.access),
              vehicle,
              now,
              calendar: calendar,
            ),
          );
        }(),
    ];
  }
  return [
    SignArea(
      name: '',
      status: whole.status,
      restriction: whole.restriction,
      window: openWindow(whole.status, null, vehicle, now),
      countClass: availabilityVehicle(vehicle),
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
      areas.every((a) => a.status == EligibilityStatus.notAllowed)) {
    return VerdictAnswer(
      status: EligibilityStatus.notAllowed,
      basis: basis,
      city: city,
    );
  }
  if (openNow.isNotEmpty) {
    final limited = openNow
        .where((a) => a.status == EligibilityStatus.conditional)
        .toList();
    // One place open now without a limit is enough for 可停 (A11 card 1:
    // B2 all day beside B3 by the hour); the details list the rest.
    if (openNow.any((a) => a.status == EligibilityStatus.allowed)) {
      return VerdictAnswer(
        status: EligibilityStatus.allowed,
        basis: basis,
        city: city,
        openNow: true,
      );
    }
    // Every place open now closes: the latest time stands.
    final ends = [for (final a in openNow) a.window.until];
    final until = ends.every((e) => e != null)
        ? (ends.cast<String>()..sort()).last
        : null;
    return VerdictAnswer(
      status: EligibilityStatus.conditional,
      restriction: limited.first.restriction,
      until: until,
      basis: basis,
      city: city,
      openNow: true,
    );
  }
  if (open.isNotEmpty) {
    final opens = [for (final a in open) ?a.window.opensAt];
    return VerdictAnswer(
      status: EligibilityStatus.conditional,
      restriction: open.first.restriction ?? RuleRestriction.timeLimited,
      opensAt: opens.firstOrNull,
      basis: basis,
      city: city,
    );
  }
  return VerdictAnswer(
    status: EligibilityStatus.unverified,
    basis: basis,
    city: city,
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
      // No zone a count describes: the lot's own class's count stands for
      // the whole lot, as before zones.
      if (groups.isEmpty) groups[availabilityVehicle(vehicle)] = const [];
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
    final fresh = [
      for (final c in usable)
        if (c.$1.status(now) == AvailabilityStatus.fresh) c,
    ];
    final pool = fresh.isNotEmpty ? fresh : usable;
    DateTime time(AvailabilitySnapshot s) =>
        s.sourceUpdatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    // Fresh first, then most free, then newer (2026-10-29); with none
    // fresh, the newest.
    pool.sort(
      (a, b) => fresh.isNotEmpty
          ? b.$1.available!.compareTo(a.$1.available!) != 0
                ? b.$1.available!.compareTo(a.$1.available!)
                : time(b.$1).compareTo(time(a.$1))
          : time(b.$1).compareTo(time(a.$1)),
    );
    final best = pool.first;
    final more = [
      for (final c in usable)
        if (!identical(c, best) && c.$1.available! > 0)
          c.$2.isEmpty ? 1 : c.$2.length,
    ].fold<int>(0, (a, b) => a + b);
    return SeatAnswer(
      kind: fresh.isNotEmpty ? SeatKind.live : SeatKind.delayed,
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

/// [vehicle]'s rate in [fee] with a follow worked out: the rate and the
/// factor; null when unconfirmed.
(Rate, int)? _resolved(Fee fee, VehicleType vehicle) {
  final key = vehicle == VehicleType.heavy ? 'heavy' : 'scooter';
  if (fee.textOf(key) == null) return null;
  final rate = vehicle == VehicleType.heavy ? fee.heavy : fee.scooter;
  if (rate == null) return null;
  if (!rate.mode.follows) return (rate, 100);
  final target = rate.mode == FeeMode.sameAsScooter ? fee.scooter : fee.car;
  if (target == null) return null;
  return (target, rate.factorPct ?? 100);
}

num? _times(int? amount, int pct) {
  if (amount == null) return null;
  final v = amount * pct;
  return v % 100 == 0 ? v ~/ 100 : v / 100;
}

/// [rate] (worked out by [pct]) as it holds at [now]; null when it is not
/// one the plate can state (依現場公告, or no period of a by_time rate
/// holds now).
PlateRate? _plateRate(
  Rate rate,
  int pct,
  DateTime now,
  HolidayCalendar? calendar, {
  String? from,
  String? to,
}) {
  switch (rate.mode) {
    case FeeMode.free:
      return PlateRate(FeeMode.free, from: from, to: to);
    case FeeMode.hourly:
      return PlateRate(
        FeeMode.hourly,
        amount: _times(rate.amount, pct),
        perMinutes: rate.perMinutes,
        dailyCap: _times(rate.dailyCap, pct),
        from: from,
        to: to,
      );
    case FeeMode.perVisit || FeeMode.daily:
      return PlateRate(
        rate.mode,
        amount: _times(rate.amount, pct),
        from: from,
        to: to,
      );
    case FeeMode.byTime:
      final cal = calendar ?? HolidayCalendar.current;
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
          cal,
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
        pct,
        now,
        calendar,
        from: best.from,
        to: best.to,
      );
    case FeeMode.posted || FeeMode.sameAsScooter || FeeMode.sameAsCar:
      return null;
  }
}

/// A place's price: a structured rate, legacy text, or nothing.
sealed class _Price {
  const _Price();
}

class _RatePrice extends _Price {
  const _RatePrice(this.rate);
  final PlateRate rate;
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
  DateTime now,
  HolidayCalendar? calendar,
) {
  if (fee != null) {
    final resolved = _resolved(fee, vehicle);
    if (resolved == null) return const _NoPrice();
    final rate = _plateRate(resolved.$1, resolved.$2, now, calendar);
    return rate == null ? const _NoPrice() : _RatePrice(rate);
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
  final spotPrice = _priceOf(spot.fee, spot.feeNote, vehicle, now, calendar);
  final List<_Price> prices;
  if (street || places.every((a) => a.whole) || spot.zones.isEmpty) {
    // Segments carry no rate of their own yet: the spot's covers them.
    prices = [spotPrice];
  } else {
    final anyZoneFee = spot.zones.any((z) => z.fee != null);
    prices = [
      for (final a in places)
        if (a.zone case final z?)
          z.fee != null
              ? _priceOf(z.fee, '', vehicle, now, calendar)
              : !anyZoneFee && spot.fee != null
              ? spotPrice
              : switch (_zoneLegacy(z, vehicle)) {
                  final t when !_placeholder(t) => _TextPrice(t.trim()),
                  _ when anyZoneFee => const _NoPrice(),
                  _ => spotPrice,
                },
    ];
  }
  if (prices.isEmpty) return const FeeAnswer(kind: FeeKind.unknown);
  final rates = [
    for (final p in prices)
      if (p is _RatePrice) p.rate,
  ];
  if (rates.length == prices.length) {
    if (rates.toSet().length == 1) {
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
