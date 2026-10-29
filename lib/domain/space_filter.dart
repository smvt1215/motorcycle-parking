/// The map's space kind filter (PLAN.md 篩選列). 免費機車格 keeps the bays
/// that are free for the rider: only a rate of `mode: free` or a bay marked
/// free, never a toll bay whose first minutes cost 0 元 (design §2.3, C5).
library;

import '../models/fee.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import '../models/space_kind.dart';

/// The rider's own rate at [spot], a heavy follow read as the rate it
/// follows; null when unconfirmed.
FeeMode? _modeFor(Fee? fee, VehicleType vehicle) {
  if (fee == null) return null;
  final rate = vehicle == VehicleType.heavy ? fee.heavy : fee.scooter;
  return switch (rate?.mode) {
    FeeMode.sameAsScooter => fee.scooter?.mode,
    FeeMode.sameAsCar => fee.car?.mode,
    final mode => mode,
  };
}

/// Whether [spot] is a free street motorcycle bay for [vehicle]: its rate
/// is `mode: free`, or, with no rate, its condition says free. A toll bay
/// never is, whatever its first minutes cost; nor are lots, car bays, or
/// bays only some vehicles may use (身障特製, 電動).
bool freeFor(ParkingSpot spot, VehicleType vehicle) {
  // A lot by its space type or by how it is built (§1.1 placement).
  if (isOffStreet(spot.spaceType, spot.facilityType)) return false;
  final condition = spot.condition ?? conditionOf(spot.spaceType);
  if (condition == null ||
      condition.bay == Bay.car ||
      condition.charge == Charge.toll ||
      condition.hasLimit(LimitKind.specialVehicle) ||
      condition.hasLimit(LimitKind.evOnly)) {
    return false;
  }
  final mode = _modeFor(spot.fee, vehicle);
  if (mode != null) return mode == FeeMode.free;
  return condition.charge == Charge.free;
}

/// Whether a street bay is posted for both motorcycle classes (condition
/// `share: scooter_heavy`), whatever else limits it.
bool postedShared(ParkingSpot spot) =>
    !isOffStreet(spot.spaceType, spot.facilityType) &&
    (spot.condition ?? conditionOf(spot.spaceType))?.share ==
        ShareKind.scooterHeavy;

/// What the rider pays at [spot]: free or toll by their own rate when it
/// is known, else by the bay's stated charge; null when unconfirmed. A toll
/// bay stays toll whatever its first minutes cost (§2.3).
Charge? chargeFor(ParkingSpot spot, VehicleType vehicle) {
  final condition = isOffStreet(spot.spaceType, spot.facilityType)
      ? null
      : spot.condition ?? conditionOf(spot.spaceType);
  if (condition?.charge == Charge.toll) return Charge.toll;
  return switch (_modeFor(spot.fee, vehicle)) {
    FeeMode.free => Charge.free,
    null || FeeMode.posted => condition?.charge,
    _ => Charge.toll,
  };
}

/// Whether [spot] carries the added condition [kind] (decision 62): on the
/// bay, or, in a lot, on any zone.
bool hasAddedLimit(ParkingSpot spot, LimitKind kind) {
  if (isOffStreet(spot.spaceType, spot.facilityType)) {
    return spot.zones.any((z) => z.condition?.hasLimit(kind) ?? false);
  }
  return (spot.condition ?? conditionOf(spot.spaceType))?.hasLimit(kind) ??
      false;
}

/// Whether [spot] is a bay of [kind] (decision 62): a lot by its space type
/// or how it is built, a street bay by its condition.
bool matchesKind(ParkingSpot spot, SpaceKind kind) {
  if (isOffStreet(spot.spaceType, spot.facilityType)) {
    return kind == SpaceKind.offStreet;
  }
  return SpaceKind.of(spot.spaceType, spot.condition) == kind;
}

/// The map's 格位類型 filter (decision 62): a kind, 收費 or 免費, and the
/// added conditions a spot must carry; each left empty keeps every spot.
class SpaceFilter {
  const SpaceFilter({this.kind, this.charge, this.limits = const {}});
  final SpaceKind? kind;
  final Charge? charge;

  /// Of [addedLimits]: 限時停車, 時段性禁停.
  final Set<LimitKind> limits;

  bool get isEmpty => kind == null && charge == null && limits.isEmpty;

  SpaceFilter copyWith({
    SpaceKind? Function()? kind,
    Charge? Function()? charge,
    Set<LimitKind>? limits,
  }) => SpaceFilter(
    kind: kind == null ? this.kind : kind(),
    charge: charge == null ? this.charge : charge(),
    limits: limits ?? this.limits,
  );

  /// What the filter chip says: 全部格位, or the kind and what narrows it.
  String get label {
    final parts = [
      if (kind != null) kind!.label,
      if (charge != null) charge == Charge.toll ? '收費' : '免費',
      for (final l in limits)
        switch (l) {
          LimitKind.timeLimit => '限時',
          LimitKind.noParking => '時段性禁停',
          _ => l.wire,
        },
    ];
    return parts.isEmpty ? '全部格位' : parts.join('・');
  }

  /// Whether the filter keeps [spot] for [vehicle].
  bool matches(ParkingSpot spot, VehicleType vehicle) =>
      (kind == null || matchesKind(spot, kind!)) &&
      (charge == null || chargeFor(spot, vehicle) == charge) &&
      limits.every((l) => hasAddedLimit(spot, l));

  @override
  bool operator ==(Object other) =>
      other is SpaceFilter &&
      other.kind == kind &&
      other.charge == charge &&
      other.limits.length == limits.length &&
      other.limits.containsAll(limits);

  @override
  int get hashCode =>
      Object.hash(kind, charge, Object.hashAllUnordered(limits));
}
