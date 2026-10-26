import '../models/availability.dart';
import '../models/parking.dart';
import 'eligibility.dart';

/// How a count reads on the map and in the details. Whether a rider may
/// park and whether a space is free are separate: nothing here looks at
/// the eligibility colour, and nothing in eligibility looks at a count;
/// only a lot closed to the rider shows no count at all (designs/2026-10-26-realtime-availability-ui.md).

AvailabilityVehicle availabilityVehicle(VehicleType vehicle) =>
    vehicle == VehicleType.scooter
    ? AvailabilityVehicle.scooter
    : AvailabilityVehicle.heavy;

/// Whether the spot's data confirms that heavy bikes may use its car bays,
/// for the lot or any zone. Admitting heavy bikes alone does not.
bool heavyCarConfirmed(ParkingSpot spot) =>
    spot.access == ParkingAccess.heavyCar ||
    spot.zones.any((zone) => zone.access == ParkingAccess.heavyCar);

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

  /// Paper with a thin ink outline and a car: car bays heavy bikes may use.
  car,

  /// Light grey with ink text: an official count of zero, apart from the
  /// ink pill of a lot with space.
  full,

  /// Deep purple with a pause sign: the source says the lot is closed.
  suspended,
}

/// One pill above a marker.
class AvailabilityCapsule {
  const AvailabilityCapsule({
    required this.text,
    required this.style,
    required this.semantics,
    this.delayed = false,
  });
  final String text;
  final CapsuleStyle style;

  /// A car-bay count past its window: the car style keeps, with a clock
  /// before the number (the [CapsuleStyle.delayed] outline is for the
  /// rider's own class only).
  final bool delayed;

  /// What a screen reader says, e.g. 「官方即時：剩 12 格」.
  final String semantics;

  @override
  bool operator ==(Object other) =>
      other is AvailabilityCapsule &&
      other.text == text &&
      other.style == style &&
      other.semantics == semantics &&
      other.delayed == delayed;

  @override
  int get hashCode => Object.hash(text, style, semantics, delayed);
}

String _count(int available) => available == 0 ? '已滿' : '剩 $available';

/// The pills beside [spot]'s marker for [vehicle]: none when the space is
/// unknown (no data, stale, invalid), so a missing pill never reads as
/// zero. A car-bay pill joins only for heavy bikes at a lot confirmed to
/// let them use car bays, while its count is fresh or delayed.
List<AvailabilityCapsule> markerCapsules(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  EligibilityStatus eligibility,
  DateTime now,
) {
  // A count where the rider may not park only invites them in (canvas v30).
  if (!spot.isFacility || eligibility == EligibilityStatus.notAllowed) {
    return const [];
  }
  final own = availability.of(availabilityVehicle(vehicle));
  final capsules = <AvailabilityCapsule>[
    if (own != null)
      ...switch (own.status(now)) {
        AvailabilityStatus.fresh => [
          AvailabilityCapsule(
            text: _count(own.available!),
            style: own.available == 0 ? CapsuleStyle.full : CapsuleStyle.live,
            semantics: own.available == 0
                ? '官方即時：已滿'
                : '官方即時：剩 ${own.available} 格',
          ),
        ],
        AvailabilityStatus.delayed => [
          AvailabilityCapsule(
            text: _count(own.available!),
            style: CapsuleStyle.delayed,
            semantics:
                '更新延遲 ${own.ageMinutes(now)} 分鐘：最後一筆'
                '${own.available == 0 ? '已滿' : '剩 ${own.available} 格'}',
          ),
        ],
        AvailabilityStatus.suspended => [
          const AvailabilityCapsule(
            text: '暫停',
            style: CapsuleStyle.suspended,
            semantics: '暫停營運',
          ),
        ],
        _ => const <AvailabilityCapsule>[],
      },
  ];
  final car = availability.of(AvailabilityVehicle.car);
  final carStatus = car?.status(now);
  if (vehicle == VehicleType.heavy &&
      heavyCarConfirmed(spot) &&
      car != null &&
      (carStatus == AvailabilityStatus.fresh ||
          carStatus == AvailabilityStatus.delayed)) {
    final delayed = carStatus == AvailabilityStatus.delayed;
    final count = car.available == 0 ? '已滿' : '剩 ${car.available} 格';
    capsules.add(
      AvailabilityCapsule(
        text: _count(car.available!),
        style: CapsuleStyle.car,
        delayed: delayed,
        semantics: delayed
            ? '汽車格更新延遲 ${car.ageMinutes(now)} 分鐘：最後一筆$count，大型重機可停汽車格'
            : '汽車格$count，大型重機可停汽車格',
      ),
    );
  }
  return capsules;
}

/// The one pill a crowded marker keeps, chosen by the parking rules; the
/// pill still shows only a number (MapDensity board, third panel):
/// - the rider may not park here, or it is unconfirmed: none, the
///   eligibility marker alone speaks;
/// - the rider's own count when there is one;
/// - heavy bikes at a lot confirmed for car bays with no heavy count: the
///   car-bay count.
/// [capsules] is [markerCapsules]'s result. [eligibility] is the
/// [Eligibility] status today; after stack C's C4 (issue #136) it will be
/// read from `ParkingDecision` instead.
List<AvailabilityCapsule> primaryCapsules(
  VehicleType vehicle,
  EligibilityStatus eligibility,
  List<AvailabilityCapsule> capsules,
) {
  if (eligibility == EligibilityStatus.notAllowed ||
      eligibility == EligibilityStatus.unverified) {
    return const [];
  }
  final own = capsules.where((c) => c.style != CapsuleStyle.car);
  if (own.isNotEmpty) return [own.first];
  final car = capsules.where((c) => c.style == CapsuleStyle.car);
  return vehicle == VehicleType.heavy && car.isNotEmpty
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
  });

  /// 「機車車位」 or 「大型重機車位」.
  final String title;

  /// The large number, only for a fresh or delayed count.
  final int? count;

  /// Beside the number (「剩餘」「剩餘，已滿」), or alone without one
  /// (「無即時資料」「空位未知」).
  final String headline;

  /// 「／ 共 80 格」 after a number; empty otherwise.
  final String? capacity;
  final String caption;
  final List<AvailabilityNote> notes;

  /// The whole fact as one sentence for screen readers.
  String get semantics => [
    title,
    if (count != null) '$headline $count 格' else headline,
    if (capacity != null) '共 ${capacity!.replaceAll(RegExp(r'[^0-9]'), '')} 格',
    caption,
    for (final note in notes) '${note.text}，${note.caption}',
  ].join('，');
}

String _withTotal(int? total, String rest) => [
  if (total != null) '共 $total 格',
  rest,
].where((s) => s.isNotEmpty).join(' ・ ');

/// The summary for an off-street lot. [eligibility] only adds a reminder
/// beside a count the rider may not use; it never changes the count.
AvailabilityFact availabilityFact(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
  EligibilityStatus eligibility,
  DateTime now,
) {
  final title = vehicle == VehicleType.scooter ? '機車車位' : '大型重機車位';
  // No count where the rider may not park, so it never reads as an
  // invitation (canvas v30).
  if (eligibility == EligibilityStatus.notAllowed) {
    return AvailabilityFact(
      title: title,
      headline: '不顯示空位',
      caption: '${vehicle.label}不可停放此場站',
    );
  }
  final own = availability.of(availabilityVehicle(vehicle));
  final notes = _notes(spot, availability, vehicle, own, now);
  final staticTotal =
      own?.capacity ??
      (vehicle == VehicleType.scooter && (spot.scooterTotal ?? 0) > 0
          ? spot.scooterTotal
          : null);
  final status = own?.status(now) ?? AvailabilityStatus.unavailable;
  final source = own == null
      ? ''
      : '${availabilityClock(own.sourceUpdatedAt ?? now)} 更新 ・ ${own.provider}';
  switch (status) {
    case AvailabilityStatus.fresh:
      final full = own!.available == 0;
      return AvailabilityFact(
        title: title,
        count: own.available,
        headline: full ? '剩餘，已滿' : '剩餘',
        capacity: '／ 共 ${own.total} 格',
        caption: source,
        notes: notes,
      );
    case AvailabilityStatus.delayed:
      return AvailabilityFact(
        title: title,
        count: own!.available,
        headline:
            '剩餘${own.available == 0 ? '，已滿' : ''}，'
            '更新延遲 ${own.ageMinutes(now)} 分鐘',
        capacity: '／ 共 ${own.total} 格',
        caption:
            '最後更新 ${availabilityClock(own.sourceUpdatedAt!)} ・ '
            '${own.provider}',
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
        headline: '無即時資料',
        caption: [static, missing].where((s) => s.isNotEmpty).join(' ・ '),
        notes: notes,
      );
  }
}

List<AvailabilityNote> _notes(
  ParkingSpot spot,
  SpotAvailability availability,
  VehicleType vehicle,
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
    if (heavyCarConfirmed(spot) && shown(car))
      AvailabilityNote(
        car!.available == 0
            ? '汽車格已滿${delay(car)}'
            : '汽車格剩餘 ${car.available}${delay(car)}',
        '${time(car)} ・ ${car.provider}',
      ),
    // Another class's count only when this class has none to show.
    if (!shown(own) && shown(scooter))
      AvailabilityNote(
        scooter!.available == 0
            ? '普通機車區已滿${delay(scooter)}'
            : '普通機車區剩 ${scooter.available} 格${delay(scooter)}',
        '${time(scooter)} ・ ${scooter.provider} ・ 不代表重機可用格數',
      ),
  ];
}

/// The availability filters. They narrow the map; they never decide that
/// an unknown space is full.
enum AvailabilityFilter {
  off,

  /// 「有即時資訊」: a fresh count for this vehicle, full included.
  live,

  /// 「目前有位」: fresh, more than zero, and the vehicle may park.
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
  DateTime now,
) {
  if (filter == AvailabilityFilter.off) return null;
  if (!spot.isFacility) return AvailabilityExclusion.roadside;
  final own = availability.of(availabilityVehicle(vehicle));
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
  AvailabilityExclusion.notAllowed => '${vehicle.label}不可停',
  AvailabilityExclusion.unverified => '有位，但${vehicle.label}是否可停待確認',
};

/// The filter's name as its pill and messages write it.
String availabilityFilterLabel(AvailabilityFilter filter) => switch (filter) {
  AvailabilityFilter.off => '即時車位',
  AvailabilityFilter.live => '有即時資訊',
  AvailabilityFilter.available => '目前有位',
};
