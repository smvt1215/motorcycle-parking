/// The map's space kind filter (PLAN.md 篩選列; #188, design canvas P1):
/// any of the seven bay kinds and the lot, none picked keeping every spot.
/// [freeFor] still says which bays are free for the rider: only a rate of
/// `mode: free` or a bay marked free, never a toll bay whose first minutes
/// cost 0 元 (design §2.3, C5).
library;

import '../models/fee.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import '../models/space_kind.dart';
import '../models/zone_entries.dart';

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

/// The bay kinds painted at a street spot (#188): its own condition's (or
/// its space type's), and each segment's. Empty for a lot.
Set<BayKind> bayKindsAt(ParkingSpot spot) {
  if (isOffStreet(spot.spaceType, spot.facilityType)) return const {};
  return {
    ?bayKindOf(spot.condition ?? conditionOf(spot.spaceType)),
    for (final s in spot.segments) ?s.bayKind,
  };
}

/// Whether the space filter [kind] keeps [spot]: 停車場 by placement, every
/// painted kind by the bays painted there ([bayKindsAt]), whatever they
/// charge or limit.
bool matchesSpaceFilter(
  ParkingSpot spot,
  SpaceKind kind,
  VehicleType vehicle,
) => switch (kind.bay) {
  null => isOffStreet(spot.spaceType, spot.facilityType),
  final bay => bayKindsAt(spot).contains(bay),
};

/// Whether the multiple-choice space filter [kinds] keeps [spot] (P1): an
/// empty set is 全部格位 and keeps every spot; otherwise any picked kind
/// that keeps it ([matchesSpaceFilter]) does.
bool matchesSpaceKinds(
  ParkingSpot spot,
  Set<SpaceKind> kinds,
  VehicleType vehicle,
) => kinds.isEmpty || kinds.any((k) => matchesSpaceFilter(spot, k, vehicle));
