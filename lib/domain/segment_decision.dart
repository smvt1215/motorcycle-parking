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

/// When a place judged [status] with [condition] lets [vehicle] park,
/// read at [now]. Only an allowed or conditional place opens; its slots
/// for the vehicle decide when (a period across midnight belongs to the
/// day it starts, as [decideParking] reads them). On the street a heavy
/// bike on a car bay parks by law whatever the slots say ([street]).
/// A city rule in the decision's [basis] that grants the place holds up to,
/// not on, its expiry day (as [ruleExpired]): the window ends there too,
/// except on a street bay the law opens to a heavy bike, which the law
/// keeps open after the rule ends.
OpenWindow openWindow(
  EligibilityStatus status,
  ParkingCondition? condition,
  VehicleType vehicle,
  DateTime now, {
  bool street = false,
  HolidayCalendar? calendar,
  Iterable<DecisionBasis> basis = const [],
}) {
  if (status != EligibilityStatus.allowed &&
      status != EligibilityStatus.conditional) {
    return OpenWindow.never;
  }
  final (today, at) = taipeiDateMinute(now);
  int dayMinute(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).difference(today).inDays * 1440;
  final c = condition;
  // A street bay the law opens to a heavy bike (a heavy-bike or car bay,
  // as ruleVerdict's lawful branch keeps them) stays open once its rule
  // ends: decideParking then cites the law. Only a place the rule itself
  // opens closes on the rule's expiry.
  bool lawful(CityRule rule) =>
      street &&
      c != null &&
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
  final unslotted =
      c == null ||
      c.schedule.isEmpty ||
      street && vehicle == VehicleType.heavy && c.bay == Bay.car;
  if (unslotted) {
    // Open all the time the rule lasts: until its expiry, when that comes
    // within a day.
    if (ruleEnd == null) return OpenWindow.always;
    if (ruleEnd <= at) return OpenWindow.never;
    final within = ruleEnd - at < 1440;
    return OpenWindow(
      now: true,
      until: within ? _clock(ruleEnd) : null,
      untilMinute: within ? ruleEnd : null,
    );
  }
  final slots = [
    for (final s in c.schedule)
      if (s.vehicles.contains(_slotVehicle(vehicle))) s,
  ];
  // The decision already reads a slot-less schedule as unconfirmed; an
  // open status here means something else opened it.
  if (slots.isEmpty) return OpenWindow.always;
  final cal = calendar ?? HolidayCalendar.current;
  const last = 7;
  // The notice holds from its effective day and up to, not on, its
  // expiry day (as decideParking's notice check): slots outside it open
  // nothing, and a night slot stops where the notice ends. So does the
  // city rule granting the place.
  int? ymdMinute(String? ymd) {
    final d = ymd == null ? null : DateTime.tryParse(ymd);
    return d == null ? null : dayMinute(d);
  }

  final from = ymdMinute(c.basis?.effectiveDate);
  final noticeEnd = ymdMinute(c.basis?.expiresOn);
  final until = noticeEnd == null
      ? ruleEnd
      : ruleEnd == null || noticeEnd < ruleEnd
      ? noticeEnd
      : ruleEnd;
  final spans = [
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
  ].where((s) => s.$1 < s.$2).toList()..sort((a, b) => a.$1.compareTo(b.$1));
  final holding = spans.where((s) => s.$1 <= at && at < s.$2).toList();
  if (holding.isNotEmpty) {
    // Slots that touch or overlap run on as one.
    var end = holding.map((s) => s.$2).reduce((a, b) => a > b ? a : b);
    for (var grew = true; grew;) {
      grew = false;
      for (final (start, stop) in spans) {
        if (start <= end && stop > end) {
          end = stop;
          grew = true;
        }
      }
    }
    final within = end - at < 1440;
    return OpenWindow(
      now: true,
      until: within ? _clock(end) : null,
      untilMinute: within ? end : null,
    );
  }
  final next = [
    for (final (start, _) in spans)
      if (start > at) start,
  ];
  if (next.isEmpty) return OpenWindow.never;
  final first = next.reduce((a, b) => a < b ? a : b);
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

/// The reason a segment whose painted condition is unconfirmed reads.
const segmentUncheckedReason = '此路段的格位類型未確認，請以現場標誌標線為準';

/// [spot] as one segment of it: the same spot, painted as [condition].
/// ParkingSpot has no copyWith (lib/models/parking.dart is another
/// session's), so the fields [decideParking] reads are copied here. Left
/// out on purpose, as no decision reads them: note, sourceUrl, sourceName,
/// licenseNote, contributorName, contributorRole, address, roadSegment,
/// entranceNote, parkingGuide, specialRules, photoUrls, zones (a street
/// spot judges no zones), segments (the segment is the spot here),
/// availabilityUpdatedAt and zonesComplete.
ParkingSpot _asSegment(ParkingSpot spot, ParkingCondition condition) =>
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
      condition: condition,
      closure: spot.closure,
    );

/// [vehicle]'s decision on each segment of the street [spot] at [now], in
/// the spot's order. A spot without segments stands as one segment judged
/// as itself ([whole], when the caller has it, else [decideParking]), so
/// a street never reads empty. A segment whose condition is unconfirmed
/// is unconfirmed; it never borrows the spot's.
List<SegmentDecision> decideSegments(
  ParkingSpot spot,
  VehicleType vehicle,
  Iterable<CityRule> rules, {
  DateTime? now,
  HolidayCalendar? calendar,
  ParkingDecision? whole,
}) {
  final at = now ?? DateTime.now();
  final spotDecision =
      whole ?? decideParking(spot, vehicle, rules, now: at, calendar: calendar);
  OpenWindow windowOf(ParkingDecision d, ParkingCondition? c) => openWindow(
    d.status,
    c,
    vehicle,
    at,
    street: true,
    calendar: calendar,
    basis: d.basis,
  );
  if (spot.segments.isEmpty) {
    return [
      SegmentDecision(
        segment: null,
        decision: spotDecision,
        window: windowOf(
          spotDecision,
          spot.condition ?? conditionOf(spot.spaceType),
        ),
      ),
    ];
  }
  return [
    for (final s in spot.segments)
      if (s.condition case final c?)
        () {
          // The segment is the spot painted as the segment: works and the
          // spot's own data close it as they close the spot.
          final d = decideParking(
            _asSegment(spot, c),
            vehicle,
            rules,
            now: at,
            calendar: calendar,
          );
          return SegmentDecision(
            segment: s,
            decision: d,
            window: windowOf(d, c),
          );
        }()
      else
        () {
          // No painted condition: judged as the spot with an empty one, so
          // what closes the spot itself (works, its own explicit 不可停)
          // still closes the segment, and otherwise the bay reads
          // unconfirmed. Missing bay data never weakens a prohibition.
          final d = decideParking(
            _asSegment(spot, const ParkingCondition()),
            vehicle,
            rules,
            now: at,
            calendar: calendar,
          );
          return SegmentDecision(
            segment: s,
            decision: d.status == EligibilityStatus.notAllowed
                ? d
                : ParkingDecision(
                    EligibilityStatus.unverified,
                    segmentUncheckedReason,
                    basis: d.basis,
                  ),
            window: OpenWindow.never,
          );
        }(),
  ];
}
