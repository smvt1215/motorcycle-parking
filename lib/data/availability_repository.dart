import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/availability.dart';
import '../models/parking.dart';

/// Where live counts come from: the backend's `viewport_availability` when
/// connected (P2, migration 202610270140), fixed counts in the example
/// build (REALTIME_AVAILABILITY_UI_PLAN §9).
abstract class AvailabilitySource {
  const AvailabilitySource();

  /// Whether this source can ever have counts; the map hides the
  /// availability filter when it cannot.
  bool get enabled;

  /// The latest counts for [spots], by spot id. Spots without counts are
  /// left out.
  Future<Map<String, SpotAvailability>> forSpots(List<ParkingSpot> spots);
}

/// No live counts.
class NoAvailabilitySource extends AvailabilitySource {
  const NoAvailabilitySource();
  @override
  bool get enabled => false;
  @override
  Future<Map<String, SpotAvailability>> forSpots(List<ParkingSpot> spots) =>
      Future.value(const {});
}

/// Official counts from the backend (`viewport_availability`), one row per
/// spot and vehicle. Only official spots can have one: community spots are
/// never sent, so a rider's report never becomes 「剩 N」.
class SupabaseAvailabilitySource extends AvailabilitySource {
  const SupabaseAvailabilitySource(this.client);
  final SupabaseClient client;

  /// The function reads at most this many ids; a viewport holds fewer.
  static const maxIds = 600;

  /// Ids per call: up to three rows each (scooter, heavy, car) must stay
  /// under the API's 1,000-row limit, or the last lots would lose counts.
  static const batch = 300;

  @override
  bool get enabled => true;

  @override
  Future<Map<String, SpotAvailability>> forSpots(
    List<ParkingSpot> spots,
  ) async {
    final ids = [
      for (final spot in spots)
        if (spot.source == 'official' && spot.id.startsWith('official:'))
          spot.id,
    ].take(maxIds).toList();
    if (ids.isEmpty) return const {};
    final pages = await Future.wait([
      for (var i = 0; i < ids.length; i += batch)
        client.rpc<List<dynamic>>(
          'viewport_availability',
          params: {
            'p_spot_ids': ids.sublist(
              i,
              i + batch > ids.length ? ids.length : i + batch,
            ),
          },
        ),
    ]);
    return availabilityFromRows([
      for (final rows in pages) ...rows.cast<Map<String, dynamic>>(),
    ]);
  }
}

/// Groups `viewport_availability` rows by spot; rows that do not parse are
/// left out, so the spot reads as having no count rather than a wrong one.
Map<String, SpotAvailability> availabilityFromRows(
  List<Map<String, dynamic>> rows,
) {
  final bySpot = <String, List<AvailabilitySnapshot>>{};
  for (final row in rows) {
    final snapshot = availabilitySnapshotFromRow(row);
    if (snapshot != null) (bySpot[snapshot.spotId] ??= []).add(snapshot);
  }
  return {
    for (final MapEntry(:key, :value) in bySpot.entries)
      key: SpotAvailability(value),
  };
}

/// One `viewport_availability` row. The backend withholds the number of an
/// unusable count and says so in `status`; freshness is judged again here
/// from the source time, so a count ages on screen between reads.
AvailabilitySnapshot? availabilitySnapshotFromRow(Map<String, dynamic> row) {
  final spotId = row['spot_id'], status = row['status'];
  final vehicle = AvailabilityVehicle.values.asNameMap()[row['vehicle']];
  if (spotId is! String || vehicle == null || status is! String) return null;
  int? whole(Object? value) => value is num ? value.toInt() : null;
  DateTime? time(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
  final provider = row['provider'];
  return AvailabilitySnapshot(
    spotId: spotId,
    vehicle: vehicle,
    provider: provider is String && provider.isNotEmpty ? provider : '官方資料',
    window: AvailabilityWindow.seconds(
      whole(row['fresh_seconds']),
      whole(row['delayed_seconds']),
    ),
    total: whole(row['total']),
    available: status == 'unavailable' || status == 'invalid'
        ? null
        : whole(row['available']),
    sourceUpdatedAt: time(row['source_updated_at']),
    fetchedAt: time(row['fetched_at']),
    invalid: status == 'invalid',
    zeroSince: time(row['zero_since']),
  );
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
