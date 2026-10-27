import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/parking.dart';
import '../models/rider_sighting.dart';
import 'app_store.dart' show communitySpotSources, officialIdPrefix;

/// Spots stored in the backend; only those can be sighted (TDX and example
/// spots have no row to attach a sighting to).
bool canSight(ParkingSpot spot) =>
    (spot.source == 'official' && spot.id.startsWith(officialIdPrefix)) ||
    (communitySpotSources.contains(spot.source) && _uuid.hasMatch(spot.id));

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Where riders' recent sightings come from (#154): `spot_sightings` when
/// connected; none otherwise.
abstract class SightingSource {
  const SightingSource();

  /// The judged sightings of [spots] in the last 30 minutes, by spot id.
  Future<Map<String, RiderSighting>> forSpots(List<ParkingSpot> spots);
}

class NoSightingSource extends SightingSource {
  const NoSightingSource();
  @override
  Future<Map<String, RiderSighting>> forSpots(List<ParkingSpot> spots) =>
      Future.value(const {});
}

/// `spot_sightings`: one row per spot with recent sightings, never a
/// rider's name or a single sighting.
class SupabaseSightingSource extends SightingSource {
  const SupabaseSightingSource(this.client);
  final SupabaseClient client;

  /// The function reads at most this many ids; one row each.
  static const maxIds = 600;

  @override
  Future<Map<String, RiderSighting>> forSpots(List<ParkingSpot> spots) async {
    final ids = [
      for (final spot in spots)
        if (canSight(spot)) spot.id,
    ].take(maxIds).toList();
    if (ids.isEmpty) return const {};
    final rows = await client.rpc<List<dynamic>>(
      'spot_sightings',
      params: {'p_spot_ids': ids},
    );
    return sightingsFromRows(rows.cast<Map<String, dynamic>>());
  }
}

/// Rows by spot; rows that do not parse are left out.
Map<String, RiderSighting> sightingsFromRows(List<Map<String, dynamic>> rows) {
  final bySpot = <String, RiderSighting>{};
  for (final row in rows) {
    final sighting = RiderSighting.fromRow(row);
    if (sighting != null) bySpot[sighting.spotId] = sighting;
  }
  return bySpot;
}

/// Fixed sightings for tests.
class FakeSightingSource extends SightingSource {
  FakeSightingSource(this.sightings);
  final List<RiderSighting> Function() sightings;
  @override
  Future<Map<String, RiderSighting>> forSpots(List<ParkingSpot> spots) async {
    final ids = {for (final spot in spots) spot.id};
    return {
      for (final s in sightings())
        if (ids.contains(s.spotId)) s.spotId: s,
    };
  }
}
