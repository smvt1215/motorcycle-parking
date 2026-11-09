import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' as v1 show SpotClosure;
import '../api/v1/api_v1.g.dart' show ApiV1Client, SpotSighting;
import '../core/app_check.dart';
import '../domain/four_sign.dart';
import '../models/parking.dart';
import '../models/sighting.dart';
import 'account_suspended.dart';
import 'repositories.dart' show reportDeviceId;

class SightingRefused implements Exception {
  const SightingRefused(this.reason);
  final SightingRefusal reason;

  @override
  String toString() => 'SightingRefused($reason)';
}

/// One read of `spot_sightings`: the summaries of a time window, and what
/// riders reported closed (A7d, always the last 2 hours), both by
/// lower-case spot id.
class SightingsRead {
  const SightingsRead(this.sightings, [this.closures = const {}]);
  final Map<String, List<SpotSighting>> sightings;
  final Map<String, List<v1.SpotClosure>> closures;
}

/// Where riders' sightings come from and go.
abstract class SightingsSource {
  const SightingsSource();

  /// Whether sightings can be read at all.
  bool get enabled;

  /// [forSpots] with what riders reported closed; a source without
  /// closures has none.
  Future<SightingsRead> read(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) async =>
      SightingsRead(await forSpots(spots, windowMinutes: windowMinutes));

  /// The summaries of [spots] over the last [windowMinutes], by lower-case
  /// spot id. Spots without sightings are left out.
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  });

  /// Sends [report]. A refusal is a [SightingRefused], a suspended account's
  /// an [AccountSuspended].
  Future<void> submit(SightingReport report);
}

/// No backend (the example build): nothing to read, and a report goes
/// nowhere.
class NoSightingsSource extends SightingsSource {
  const NoSightingsSource();
  @override
  bool get enabled => false;
  @override
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) => Future.value(const {});
  @override
  Future<void> submit(SightingReport report) => Future.value();
}

/// `api_v1.spot_sightings` and the submit-sighting Edge Function.
class SupabaseSightingsSource extends SightingsSource {
  SupabaseSightingsSource(this.client, {this.appCheckToken = AppCheck.token})
    : api = ApiV1Client(client);
  final SupabaseClient client;
  final ApiV1Client api;
  final AppCheckTokenSource appCheckToken;

  /// The API takes this many ids a call (`request.too_many_ids` above it).
  static const batch = 600;

  @override
  bool get enabled => true;

  @override
  Future<Map<String, List<SpotSighting>>> forSpots(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) async => (await read(spots, windowMinutes: windowMinutes)).sightings;

  @override
  Future<SightingsRead> read(
    List<ParkingSpot> spots, {
    required int windowMinutes,
  }) async {
    final ids = {
      for (final spot in spots)
        if (sightableSpot(spot.id)) spot.id,
    }.toList();
    final pages = await Future.wait([
      for (var i = 0; i < ids.length; i += batch)
        api.spotSightings(
          pSpotIds: ids.sublist(i, math.min(i + batch, ids.length)),
          pWindowMinutes: windowMinutes,
        ),
    ]);
    return SightingsRead(
      sightingsBySpot([for (final p in pages) ...p.sightings]),
      closuresBySpot([for (final p in pages) ...p.closures]),
    );
  }

  @override
  Future<void> submit(SightingReport report) async {
    try {
      await client.functions.invoke(
        'submit-sighting',
        body: {...report.toJson(), 'device_id': await reportDeviceId()},
        headers: await AppCheck.headers(appCheckToken),
      );
    } on FunctionException catch (e) {
      if (accountSuspendedFrom(e) case final suspended?) throw suspended;
      if (sightingRefusal(e) case final reason?) {
        throw SightingRefused(reason);
      }
      rethrow;
    }
  }
}

/// What a refusal of submit-sighting means; null for any other failure.
SightingRefusal? sightingRefusal(FunctionException e) {
  final details = e.details;
  return switch (details is Map ? details['error'] : null) {
    'sighting too soon' => SightingRefusal.tooSoon,
    'daily sighting limit reached' => SightingRefusal.dailyLimit,
    'spot not found' || 'area not found' => SightingRefusal.spotGone,
    'sign-in required' ||
    'Google or Apple sign-in required' => SightingRefusal.signIn,
    _ => null,
  };
}

Map<String, List<SpotSighting>> sightingsBySpot(List<SpotSighting> rows) {
  final bySpot = <String, List<SpotSighting>>{};
  for (final row in rows) {
    (bySpot[row.spotId.toLowerCase()] ??= []).add(row);
  }
  return bySpot;
}

/// [row] on the app's scale, or null when it does not parse: the spot then
/// reads as having no report rather than a wrong one.
///
/// Reports that disagree show their two ends, never the median in
/// [SpotSighting.level]. The backend's `low` is the emptier end, so it is
/// the app's higher level, and its riders the ones who said more space.
RiderSeat? riderSeatOf(SpotSighting row) {
  final at = DateTime.tryParse(row.latestAt);
  bool scale(int level) => level >= 0 && level <= 3;
  if (at == null || !scale(row.level) || !scale(row.low) || !scale(row.high)) {
    return null;
  }
  final split = row.conflicting && row.low != row.high;
  return RiderSeat(
    level: riderLevelFromBackend(split ? row.low : row.level),
    otherLevel: split ? riderLevelFromBackend(row.high) : null,
    highCount: split ? row.lowRiders : null,
    lowCount: split ? row.highRiders : null,
    riders: row.count,
    at: at,
    areaId: row.zoneId ?? row.segmentId,
  );
}

Map<String, List<v1.SpotClosure>> closuresBySpot(List<v1.SpotClosure> rows) {
  final bySpot = <String, List<v1.SpotClosure>>{};
  for (final row in rows) {
    (bySpot[row.spotId.toLowerCase()] ??= []).add(row);
  }
  return bySpot;
}

/// [row] as the four signs read it, or null when its time does not parse
/// or it names both a zone and a segment.
RiderClosure? riderClosureOf(v1.SpotClosure row) {
  final at = DateTime.tryParse(row.latestAt);
  if (at == null || row.riders < 1) return null;
  if (row.zoneId != null && row.segmentId != null) return null;
  return RiderClosure(
    areaId: row.zoneId ?? row.segmentId,
    riders: row.riders,
    confirmed: row.confirmed,
    at: at,
    derived: row.derived,
  );
}
