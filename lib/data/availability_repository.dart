import '../models/availability.dart';
import '../models/parking.dart';

/// Where live counts come from. P0 has no backend: the backend adapter,
/// snapshot table and schedule arrive in P2 (REALTIME_AVAILABILITY_UI_PLAN
/// §9). Until then a connected app has no source, so it shows no pill and
/// no availability filter.
abstract class AvailabilitySource {
  const AvailabilitySource();

  /// Whether this source can ever have counts; the map hides the
  /// availability filter when it cannot.
  bool get enabled;

  /// The latest counts for [spots], by spot id. Spots without counts are
  /// left out.
  Future<Map<String, SpotAvailability>> forSpots(List<ParkingSpot> spots);
}

/// No live counts: the production default until P2.
class NoAvailabilitySource extends AvailabilitySource {
  const NoAvailabilitySource();
  @override
  bool get enabled => false;
  @override
  Future<Map<String, SpotAvailability>> forSpots(List<ParkingSpot> spots) =>
      Future.value(const {});
}

/// Fixed counts for the example build and tests.
class FakeAvailabilitySource extends AvailabilitySource {
  FakeAvailabilitySource(this.snapshots);

  /// Counts built on demand, so times stay relative to the clock.
  final List<AvailabilitySnapshot> Function() snapshots;

  @override
  bool get enabled => true;

  @override
  Future<Map<String, SpotAvailability>> forSpots(
    List<ParkingSpot> spots,
  ) async {
    final ids = {for (final spot in spots) spot.id};
    final bySpot = <String, List<AvailabilitySnapshot>>{};
    for (final snapshot in snapshots()) {
      if (ids.contains(snapshot.spotId)) {
        (bySpot[snapshot.spotId] ??= []).add(snapshot);
      }
    }
    return {
      for (final MapEntry(:key, :value) in bySpot.entries)
        key: SpotAvailability(value),
    };
  }
}

/// The example build's only lot (assets/demo/spots.json), with a fresh
/// scooter count and no heavy-bike count, so both the pill and 「無即時資料」
/// show by switching vehicle.
FakeAvailabilitySource demoAvailabilitySource({DateTime Function()? clock}) =>
    FakeAvailabilitySource(() {
      final now = (clock ?? DateTime.now)();
      return [
        AvailabilitySnapshot(
          spotId: '00000000-0000-4000-8000-000000000004',
          vehicle: AvailabilityVehicle.scooter,
          provider: '範例資料',
          window: AvailabilityWindow.taipei,
          total: 32,
          available: 12,
          sourceUpdatedAt: now.subtract(const Duration(minutes: 3)),
          fetchedAt: now,
        ),
        AvailabilitySnapshot(
          spotId: '00000000-0000-4000-8000-000000000004',
          vehicle: AvailabilityVehicle.heavy,
          provider: '範例資料',
          window: AvailabilityWindow.taipei,
          available: -9,
          sourceUpdatedAt: now.subtract(const Duration(minutes: 3)),
          fetchedAt: now,
        ),
      ];
    });
