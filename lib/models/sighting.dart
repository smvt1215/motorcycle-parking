/// A rider's on-site sighting (#189): the scale the backend stores, what the
/// app sends to submit-sighting, and how long a sighting shows. Pure Dart.
library;

import 'parking.dart';

/// Minutes of sightings the map badge and the preview read (A0, A6).
const sightingMapWindow = 15;

/// Minutes of sightings the details list (A10, A12).
const sightingDetailWindow = 30;

/// Ids `spot_sightings` and submit-sighting take: official and community
/// spots. Others (a TDX spot) have no sightings and refuse one.
final _sightable = RegExp(
  r'^(official:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

bool sightableSpot(String spotId) => _sightable.hasMatch(spotId);

/// Why submit-sighting refused a report.
enum SightingRefusal { tooSoon, dailyLimit, spotGone, signIn }

/// The app's scale for a level of the backend's, and back.
///
/// The backend counts how full it is: 0 很多空位, 1 還有一些, 2 快滿了,
/// 3 已停滿. The app counts how much space there is, the bars a meter
/// fills: 3 很多空位, 2 還有一些, 1 快滿了, 0 已停滿. The one place the two
/// meet; the same flip goes both ways.
int riderLevelFromBackend(int level) => 3 - level;

/// [riderLevelFromBackend] the other way, for what is sent.
int backendLevelFromRider(int level) => 3 - level;

/// What a rider sends: a level of the scale for one place, or that nobody
/// can park here (the whole spot: submit-sighting takes no zone or segment
/// for it).
class SightingReport {
  const SightingReport.level({
    required this.spotId,
    required this.vehicle,
    required int this.level,
    this.zoneId,
    this.segmentId,
  }) : closed = false,
       assert(zoneId == null || segmentId == null);

  const SightingReport.closed({required this.spotId, required this.vehicle})
    : level = null,
      closed = true,
      zoneId = null,
      segmentId = null;

  final String spotId;
  final VehicleType vehicle;

  /// The app's scale; null when [closed].
  final int? level;
  final bool closed;
  final String? zoneId, segmentId;

  /// The body of submit-sighting, without its `device_id`.
  Map<String, Object?> toJson() => {
    'spot_id': spotId,
    'kind': closed ? 'closed' : 'level',
    'level': closed ? null : backendLevelFromRider(level!),
    'zone_id': zoneId,
    'segment_id': segmentId,
    'vehicle': vehicle.name,
  };
}
