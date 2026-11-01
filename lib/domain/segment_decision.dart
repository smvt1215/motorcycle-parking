/// Segment by segment decisions for a street spot (design canvas A6, A10):
/// whether [VehicleType] may park on each stretch of a street, and whether
/// it may park there now. Every verdict comes from [decideParking], which
/// this file only reads: a segment is judged as the spot itself with the
/// segment's painted condition, so the city rules, the law and the spot's
/// own trust decide as they do for a single bay. Pure Dart.
library;

import '../models/holiday_calendar.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import 'eligibility.dart';
import 'parking_decision.dart';

/// When an open place can be used: now (with the time the current slot
/// ends, if it ends within a day), or later (with when it opens next).
class OpenWindow {
  const OpenWindow({
    required this.now,
    this.until,
    this.untilMinute,
    this.opensAt,
    this.opensAtMinute,
  });

  /// Never open: closed, unconfirmed, or no slot opens within a week.
  static const never = OpenWindow(now: false);

  /// Open now without a slot that ends.
  static const always = OpenWindow(now: true);

  final bool now;

  /// 「22:00」 when [now] and the slot holding now ends within a day.
  final String? until;

  /// [until] as minutes from today's 00:00 in Taiwan: past 1440 when the
  /// slot runs past midnight (隔天 02:00 is 1560), so ends compare right.
  final int? untilMinute;

  /// 「20:00」, 「明天 08:00」 or 「週一 08:00」 when not [now] and a slot
  /// opens within a week.
  final String? opensAt;

  /// [opensAt] as minutes from today's 00:00 in Taiwan.
  final int? opensAtMinute;
}

String _clock(int minute) {
  final m = minute % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

SlotVehicle _slotVehicle(VehicleType v) =>
    v == VehicleType.heavy ? SlotVehicle.heavy : SlotVehicle.scooter;

/// Whether [condition] lists opening slots, none of them for [vehicle]:
/// such a schedule states no time [vehicle] may park.
bool scheduleSilentFor(ParkingCondition? condition, VehicleType vehicle) {
  final c = condition;
  if (c == null || c.schedule.isEmpty) return false;
  return !c.schedule.any((s) => s.vehicles.contains(_slotVehicle(vehicle)));
}

/// Half-open minute ranges, from today's 00:00 in Taiwan, that stand for
/// no bound: before anything and after anything a window reads.
const _past = -1 << 40, _future = 1 << 40;

/// [spans] merged where they touch or overlap, in order.
List<(int, int)> _union(Iterable<(int, int)> spans) {
  final sorted = [
    for (final s in spans)
      if (s.$1 < s.$2) s,
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(int, int)>[];
  for (final s in sorted) {
    if (out.isNotEmpty && s.$1 <= out.last.$2) {
      if (s.$2 > out.last.$2) out.last = (out.last.$1, s.$2);
    } else {
      out.add(s);
    }
  }
  return out;
}

/// [spans] with every minute of [cuts] (both merged) taken out.
List<(int, int)> _subtract(List<(int, int)> spans, List<(int, int)> cuts) {
  if (cuts.isEmpty) return spans;
  final out = <(int, int)>[];
  for (final (start, end) in spans) {
    var from = start;
    for (final (cutStart, cutEnd) in cuts) {
      if (cutEnd <= from || cutStart >= end) continue;
      if (cutStart > from) out.add((from, cutStart));
      from = cutEnd;
      if (from >= end) break;
    }
    if (from < end) out.add((from, end));
  }
  return out;
}

/// When a place judged [status] with [condition] lets [vehicle] park,
/// read at [now]. Only an allowed or conditional place opens; its slots
/// for the vehicle decide when (a period across midnight belongs to the
/// day it starts, as [decideParking] reads them). On the street a heavy
/// bike on a car bay parks by law whatever the slots say ([street]),
/// shared car bays without slots too (#248); on a shared car bay with
/// slots it parks in [heavyShareSlotsOf]'s, read with [rules] (matched to
/// the spot's city and heavy bikes) in [district]. A city rule in the
/// decision's [basis] that grants the place holds up to, not on, its
/// expiry day (as [ruleExpired]): the window ends there too, except on a
/// street bay the law opens to a heavy bike, which the law keeps open
/// after the rule ends. The condition's 禁停 periods (#188 layer 2) close
/// it for everyone, as [decideParking]'s 現在禁停 reads them.
OpenWindow openWindow(
  EligibilityStatus status,
  ParkingCondition? condition,
  VehicleType vehicle,
  DateTime now, {
  bool street = false,
  HolidayCalendar? calendar,
  Iterable<DecisionBasis> basis = const [],
  List<CityRule> rules = const [],
  String district = '',
}) {
  if (status != EligibilityStatus.allowed &&
      status != EligibilityStatus.conditional) {
    return OpenWindow.never;
  }
  final (today, at) = taipeiDateMinute(now);
  final cal = calendar ?? HolidayCalendar.current;
  const last = 7;
  final c = condition;
  final banned = _union([
    for (final l in c?.limits ?? const <ParkingLimit>[])
      if (l.kind == LimitKind.noParking)
        for (final p in l.periods)
          ...datedSpans(p.days, p.from, p.to, today, cal, last: last),
  ]);
  OpenWindow read(Iterable<(int, int)> open) =>
      _windowOf(_subtract(_union(open), banned), at, today, last);
  int dayMinute(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).difference(today).inDays * 1440;
  final heavy = street && vehicle == VehicleType.heavy;
  final carShare = c?.share == ShareKind.carMotorcycle;
  final slotted = c != null && c.schedule.isNotEmpty;
  // A heavy bike on a car bay parks by law whatever its slots or notice
  // say (decideParking's step 3 skips them; its notice is not what opens
  // the bay), so nothing here ends it. A shared car bay without slots is
  // judged as a car bay too (#248); only its slots, when it lists them,
  // limit heavy bikes.
  if (heavy && c != null && c.bay == Bay.car && !(carShare && slotted)) {
    return read(const [(_past, _future)]);
  }
  // A street bay the law opens to a heavy bike (a heavy-bike or plain car
  // bay, as ruleVerdict's lawful branch keeps them) stays open once its
  // rule ends: decideParking then cites the law. Only a place the rule
  // itself opens closes on the rule's expiry, and a shared car bay's
  // scooter slots are such a place.
  bool lawful(CityRule rule) =>
      street &&
      c != null &&
      !(carShare && slotted) &&
      rule.vehicle == VehicleType.heavy &&
      ruleKindsOf(c)
          .every((k) => k == SpaceType.heavyOnly || k == SpaceType.car);
  final ruleEnds = [
    for (final b in basis)
      if (b.kind == BasisKind.cityRule && !b.expired)
        if (b.rule case final rule? when !lawful(rule))
          if (rule.expiresOn case final e?) dayMinute(e),
  ];
  final ruleEnd = ruleEnds.isEmpty
      ? null
      : ruleEnds.reduce((a, b) => a < b ? a : b);
  // The notice holds from its effective day and up to, not on, its
  // expiry day (as decideParking's notice check): slots outside it open
  // nothing, and a night slot stops where the notice ends. So does the
  // city rule granting the place.
  int? ymdMinute(String? ymd) {
    final d = ymd == null ? null : DateTime.tryParse(ymd);
    return d == null ? null : dayMinute(d);
  }

  final from = ymdMinute(c?.basis?.effectiveDate);
  final noticeEnd = ymdMinute(c?.basis?.expiresOn);
  final until = noticeEnd == null
      ? ruleEnd
      : ruleEnd == null || noticeEnd < ruleEnd
      ? noticeEnd
      : ruleEnd;
  if (!slotted) {
    // Open all the time the notice and the rule hold: from the notice's
    // effective day, until the earlier of their ends.
    return read([(from ?? _past, until ?? _future)]);
  }
  final slots = heavy && carShare
      ? heavyShareSlotsOf(c, rules, district: district, now: now).slots
      : [
          for (final s in c.schedule)
            if (s.vehicles.contains(_slotVehicle(vehicle))) s,
        ];
  // The decision already reads a slot-less schedule as unconfirmed; an
  // open status here means something else opened it.
  if (slots.isEmpty) return read(const [(_past, _future)]);
  return read([
    for (final s in slots)
      for (final (start, end) in datedSpans(
        s.days,
        s.from,
        s.to,
        today,
        cal,
        last: last,
      ))
        (
          from != null && start < from ? from : start,
          until != null && end > until ? until : end,
        ),
  ]);
}

/// The window [open] (merged spans, minutes from [today]'s 00:00) gives
/// at [at]: open now until the span holding it ends, else opening at the
/// next span within [last] days.
OpenWindow _windowOf(List<(int, int)> open, int at, DateTime today, int last) {
  final holding = open.where((s) => s.$1 <= at && at < s.$2).firstOrNull;
  if (holding != null) {
    final end = holding.$2;
    if (end - at >= 1440) return OpenWindow.always;
    return OpenWindow(now: true, until: _clock(end), untilMinute: end);
  }
  final next = open.where((s) => s.$1 > at).firstOrNull?.$1;
  if (next == null || next - at >= last * 1440) return OpenWindow.never;
  return _opensAt(next, today);
}

/// Not open now; opens at [first], minutes from [today]'s 00:00.
OpenWindow _opensAt(int first, DateTime today) {
  final day = first ~/ 1440;
  final date = DateTime.utc(today.year, today.month, today.day + day);
  return OpenWindow(
    now: false,
    opensAtMinute: first,
    opensAt: switch (day) {
      0 => _clock(first),
      1 => '明天 ${_clock(first)}',
      _ => '週${'一二三四五六日'[date.weekday - 1]} ${_clock(first)}',
    },
  );
}

/// One stretch of a street spot, judged for a vehicle.
class SegmentDecision {
  const SegmentDecision({
    required this.segment,
    required this.decision,
    required this.window,
  });

  /// The segment; null when the spot has none and stands as one stretch.
  final ParkingSegment? segment;
  final ParkingDecision decision;
  final OpenWindow window;

  EligibilityStatus get status => decision.status;
  bool get open =>
      status == EligibilityStatus.allowed ||
      status == EligibilityStatus.conditional;
  bool get openNow => window.now;
}

/// The condition [segment] of [spot] is judged by, as [decideParking]
/// reads it (#188 layer 2, its `_segmentCondition`, private to
/// parking_decision.dart, another session's file; keep the two in step):
/// its own when it names a bay; one naming no bay takes the rest (the bay,
/// its use and share, the limits it leaves out, its slots) from the
/// spot's; none at all is the spot's.
ParkingCondition? segmentConditionOf(ParkingSegment segment, ParkingSpot spot) {
  final seg = segment.condition;
  final whole = spot.condition ?? conditionOf(spot.spaceType);
  if (seg == null) return whole;
  if (seg.bay != null || whole == null) return seg;
  return ParkingCondition(
    bay: whole.bay,
    use: whole.use,
    share: whole.share,
    charge: seg.charge ?? whole.charge,
    limits: [
      for (final l in whole.limits)
        if (!seg.hasLimit(l.kind)) l,
      ...seg.limits,
    ]..sort((a, b) => a.kind.index.compareTo(b.kind.index)),
    schedule: seg.schedule.isEmpty ? whole.schedule : seg.schedule,
    basis: seg.basis ?? whole.basis,
    allow: seg.allow,
  );
}

/// [spot] with [segment] as its only segment. ParkingSpot has no copyWith
/// (lib/models/parking.dart is another session's), so the fields
/// [decideParking] reads are copied here. Left out on purpose, as no
/// decision reads them: note, sourceUrl, sourceName, licenseNote,
/// contributorName, contributorRole, address, roadSegment, entranceNote,
/// parkingGuide, specialRules, photoUrls, zones (a street spot judges no
/// zones), availabilityUpdatedAt and zonesComplete.
ParkingSpot _withSegment(ParkingSpot spot, ParkingSegment segment) =>
    ParkingSpot(
      id: spot.id,
      name: spot.name,
      lat: spot.lat,
      lng: spot.lng,
      city: spot.city,
      spaceType: spot.spaceType,
      source: spot.source,
      feeNote: spot.feeNote,
      fee: spot.fee,
      scooterTotal: spot.scooterTotal,
      available: spot.available,
      heavyAllowed: spot.heavyAllowed,
      scooterAllowed: spot.scooterAllowed,
      scooterNotStated: spot.scooterNotStated,
      heavyNotStated: spot.heavyNotStated,
      status: spot.status,
      updatedAt: spot.updatedAt,
      lastConfirmedAt: spot.lastConfirmedAt,
      createdAt: spot.createdAt,
      district: spot.district,
      facilityType: spot.facilityType,
      facilityTypes: spot.facilityTypes,
      access: spot.access,
      scooterVerifiedAt: spot.scooterVerifiedAt,
      heavyVerifiedAt: spot.heavyVerifiedAt,
      condition: spot.condition,
      segments: [segment],
      closure: spot.closure,
    );

/// [vehicle]'s decision on each segment of the street [spot] at [now], in
/// the spot's order. A spot without segments stands as one segment judged
/// as itself ([whole], when the caller has it, else [decideParking]), so
/// a street never reads empty. Each segment is [decideParking] of the spot
/// with that segment alone (#188 layer 2 judges a street segment by
/// segment), so its status and restriction are the ones the spot's
/// decision lists for it in [ParkingDecision.segments], and its basis is
/// its own.
List<SegmentDecision> decideSegments(
  ParkingSpot spot,
  VehicleType vehicle,
  Iterable<CityRule> rules, {
  DateTime? now,
  HolidayCalendar? calendar,
  ParkingDecision? whole,
}) {
  final at = now ?? DateTime.now();
  final matched = matchingRules(rules, spot, vehicle);
  OpenWindow windowOf(ParkingDecision d, ParkingCondition? c) => openWindow(
    d.status,
    c,
    vehicle,
    at,
    street: true,
    calendar: calendar,
    basis: d.basis,
    rules: matched,
    district: spot.district,
  );
  // Rolled back to the judgement before C4 (useParkingDecision false), a
  // street stands as one stretch judged as [whole], so the signs never
  // judge segments by a decision the rest of the app no longer uses.
  if (!useParkingDecision || spot.segments.isEmpty) {
    final d =
        whole ??
        decideParking(spot, vehicle, rules, now: at, calendar: calendar);
    return [
      SegmentDecision(
        segment: null,
        decision: d,
        window: windowOf(d, spot.condition ?? conditionOf(spot.spaceType)),
      ),
    ];
  }
  return [
    for (final s in spot.segments)
      () {
        final d = decideParking(
          _withSegment(spot, s),
          vehicle,
          rules,
          now: at,
          calendar: calendar,
        );
        return SegmentDecision(
          segment: s,
          decision: d,
          window: windowOf(d, segmentConditionOf(s, spot)),
        );
      }(),
  ];
}
