/// The map's space kind filter (PLAN.md 篩選列). 免費機車格 keeps the bays
/// that are free for the rider: only a rate of `mode: free` or a bay marked
/// free, never a toll bay whose first minutes cost 0 元 (design §2.3, C5).
library;

import '../models/fee.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';

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

/// Whether the space filter [type] keeps [spot]: 免費機車格 by [freeFor],
/// every other kind by its space type.
bool matchesSpaceFilter(
  ParkingSpot spot,
  SpaceType type,
  VehicleType vehicle,
) => type == SpaceType.freeMotorcycle
    ? freeFor(spot, vehicle)
    : spot.spaceType == type;
