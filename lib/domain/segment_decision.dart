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
  const OpenWindow({required this.now, this.until, this.opensAt});

  /// Never open: closed, unconfirmed, or no slot opens within a week.
  static const never = OpenWindow(now: false);

  /// Open now without a slot that ends.
  static const always = OpenWindow(now: true);

  final bool now;

  /// 「22:00」 when [now] and the slot holding now ends within a day.
  final String? until;

  /// 「20:00」, 「明天 08:00」 or 「週一 08:00」 when not [now] and a slot
  /// opens within a week.
  final String? opensAt;
}

String _clock(int minute) {
  final m = minute % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

SlotVehicle _slotVehicle(VehicleType v) =>
    v == VehicleType.heavy ? SlotVehicle.heavy : SlotVehicle.scooter;

/// When a place judged [status] with [condition] lets [vehicle] park,
/// read at [now]. Only an allowed or conditional place opens; its slots
/// for the vehicle decide when (a period across midnight belongs to the
/// day it starts, as [decideParking] reads them). On the street a heavy
/// bike on a car bay parks by law whatever the slots say ([street]).
OpenWindow openWindow(
  EligibilityStatus status,
  ParkingCondition? condition,
  VehicleType vehicle,
  DateTime now, {
  bool street = false,
  HolidayCalendar? calendar,
}) {
  if (status != EligibilityStatus.allowed &&
      status != EligibilityStatus.conditional) {
    return OpenWindow.never;
  }
  final c = condition;
  if (c == null || c.schedule.isEmpty) return OpenWindow.always;
  if (street && vehicle == VehicleType.heavy && c.bay == Bay.car) {
    return OpenWindow.always;
  }
  final slots = [
    for (final s in c.schedule)
      if (s.vehicles.contains(_slotVehicle(vehicle))) s,
  ];
  // The decision already reads a slot-less schedule as unconfirmed; an
  // open status here means something else opened it.
  if (slots.isEmpty) return OpenWindow.always;
  final cal = calendar ?? HolidayCalendar.current;
  final (today, at) = taipeiDateMinute(now);
  const last = 7;
  final spans = [
    for (final s in slots)
      ...datedSpans(s.days, s.from, s.to, today, cal, last: last),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
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
    return OpenWindow(now: true, until: end - at < 1440 ? _clock(end) : null);
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
  OpenWindow windowOf(ParkingDecision d, ParkingCondition? c) =>
      openWindow(d.status, c, vehicle, at, street: true, calendar: calendar);
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
        SegmentDecision(
          segment: s,
          decision: ParkingDecision(
            EligibilityStatus.unverified,
            segmentUncheckedReason,
            basis: spotDecision.basis.take(1).toList(),
          ),
          window: OpenWindow.never,
        ),
  ];
}
