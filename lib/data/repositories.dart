import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/address_search.dart';
import '../models/parking.dart';
import '../models/spot_history.dart';
import '../domain/map_viewport.dart';
import '../domain/eligibility.dart' show useParkingDecision;
import '../domain/precheck.dart';

class RulesRepository {
  RulesRepository(this.client);
  final SupabaseClient? client;

  /// Every rule as stored, expired ones and their `expires_on` included
  /// (`city_rules_v2()`, §3.2). A backend not yet migrated lacks it; its
  /// `city_rules` table has no end dates, so reading it loses nothing.
  /// Builds before C4 read the `city_rules` view, which serves expired rows
  /// as a conservative projection over the bundled copies.
  Future<List<Map<String, dynamic>>> _remoteRules() async {
    // Rolled back to the judgement before C4, which never reads end dates:
    // read the view's conservative projection, as older builds do.
    if (!useParkingDecision) return client!.from('city_rules').select();
    try {
      final rows = await client!.rpc<List<dynamic>>('city_rules_v2');
      return rows.cast<Map<String, dynamic>>();
    } on PostgrestException catch (e) {
      // PostgREST: no function with this name.
      if (e.code != 'PGRST202') rethrow;
      return client!.from('city_rules').select();
    }
  }

  Future<List<CityRule>> load() async {
    final raw = jsonDecode(
      await rootBundle.loadString('assets/rules/parking_rules.json'),
    ) as List<dynamic>;
    final rules = raw
        .map((e) => CityRule.fromJson(e as Map<String, dynamic>))
        .toList();
    if (client != null) {
      final remote = await _remoteRules();
      for (final row in remote) {
        final r = CityRule.fromJson(row);
        final i = rules.indexWhere(
          (old) => old.city == r.city && old.vehicle == r.vehicle,
        );
        if (i < 0) {
          rules.add(r);
          // Admins maintain the remote rows; the bundled copy is the fallback,
          // so a tie keeps the admin's edit (a migration leaves such a row
          // alone rather than overwrite it).
        } else if (r.version >= rules[i].version) {
          rules[i] = r;
        }
      }
    }
    return rules;
  }
}

/// The viewport RPC variants this build reads, newest first; the original
/// (no suffix) is the last fallback. _v3 returns every row as stored, with
/// its parking conditions; _v2 projects the rows that builds judging
/// eligibility without conditions would read too loosely (§5.2 of
/// docs/designs/2026-10-26-parking-conditions-and-fees.md). This build's
/// `eligibility()` judges through `decideParking()` (stack C, C4), which
/// reads conditions, so this build reads _v3 first.
/// Rolled back to the judgement before C4 (`useParkingDecision` false), it
/// reads _v2's conservative projection again.
@visibleForTesting
const viewportVariants = useParkingDecision ? ['_v3', '_v2'] : ['_v2'];

class ParkingResult {
  const ParkingResult(this.spots, {this.warning, this.truncated = false});
  final List<ParkingSpot> spots;
  final String? warning;
  final bool truncated;
}

class ParkingRepository {
  ParkingRepository(this.client);
  final SupabaseClient? client;
  List<ParkingSpot>? _demoSpots;

  /// Reads [name]'s newest variant in [viewportVariants] this backend has;
  /// a backend not yet migrated lacks the newer ones, so fall back in that
  /// order, then to the original, which returns the five first kinds only.
  Future<List<dynamic>> _viewport(String name, MapViewport bounds) async {
    for (final suffix in viewportVariants) {
      try {
        return await client!.rpc<List<dynamic>>(
          '$name$suffix',
          params: bounds.toJson(),
        );
      } on PostgrestException catch (e) {
        // PostgREST: no function with this name.
        if (e.code != 'PGRST202') rethrow;
      }
    }
    return client!.rpc<List<dynamic>>(name, params: bounds.toJson());
  }

  Future<ParkingResult> inViewport(MapViewport bounds) async {
    if (!bounds.canQuery || !bounds.intersectsTaiwan) {
      return const ParkingResult([]);
    }
    if (client == null) {
      if (_demoSpots == null) {
        final raw = jsonDecode(
          await rootBundle.loadString('assets/demo/spots.json'),
        ) as List<dynamic>;
        _demoSpots = raw.expand(ParkingSpot.known).toList();
      }
      return ParkingResult(
        _demoSpots!.where((s) => bounds.contains(s.lat, s.lng)).toList(),
      );
    }
    final raw = await _viewport('viewport_spots', bounds);
    final community = raw.expand(ParkingSpot.known).toList();
    // Admin-maintained municipal bays; a failure only drops this layer.
    var official = const <ParkingSpot>[];
    String? officialWarning;
    try {
      final rows = await _viewport('official_viewport_spots', bounds);
      official = rows.expand(ParkingSpot.known).toList();
    } catch (_) {
      officialWarning = '官方停車點暫時無法讀取';
    }
    return ParkingResult(
      [
        ...official.take(500),
        ...community.take(500),
      ].where((s) => bounds.contains(s.lat, s.lng)).toList(),
      warning: officialWarning,
      truncated: official.length > 500 || community.length > 500,
    );
  }

  void addDemo(ParkingSpot spot) => (_demoSpots ??= []).add(spot);

  /// The spot's latest public changes (`spot_history`, #141), newest
  /// first; none without a backend (demo) or for a spot that has no
  /// history there (TDX, hidden).
  Future<List<HistoryEntry>> history(String spotId) async {
    if (client == null) return const [];
    return HistoryEntry.list(
      await client!.rpc<dynamic>(
        'spot_history',
        params: {'p_source_id': spotId},
      ),
    );
  }

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('device_id');
    if (existing != null) return existing;
    final value = const Uuid().v4();
    await prefs.setString('device_id', value);
    return value;
  }

  /// Sends a report; a precheck refusal becomes a [StateError] carrying the
  /// server's sentence, which the forms show as is.
  Future<Map<String, dynamic>> report(Map<String, dynamic> body) async {
    final deviceId = await _deviceId();
    try {
      final res = await client!.functions.invoke(
        'submit-report',
        body: {...body, 'device_id': deviceId},
      );
      return res.data as Map<String, dynamic>;
    } on FunctionException catch (e) {
      if (precheckRefusal(e.details) case final message?) {
        throw StateError(message);
      }
      rethrow;
    }
  }

  /// Sends a rider's on-site sighting (#154) to `submit-sighting`: the spot,
  /// what they saw and their vehicle, never where they are. A refusal the
  /// rider can act on becomes a [StateError] with the sentence to show.
  Future<Map<String, dynamic>> sighting({
    required String spotId,
    required String kind,
    required String vehicle,
  }) async {
    final deviceId = await _deviceId();
    try {
      final res = await client!.functions.invoke(
        'submit-sighting',
        body: {
          'spot_id': spotId,
          'kind': kind,
          'vehicle': vehicle,
          'device_id': deviceId,
        },
      );
      return res.data as Map<String, dynamic>;
    } on FunctionException catch (e) {
      if (sightingRefusal(e.status, e.details) case final message?) {
        throw StateError(message);
      }
      rethrow;
    }
  }

  /// House number, road or intersection search for the location picker
  /// (`LocationPicker.search`); needs a Google or Apple sign-in.
  Future<List<AddressCandidate>> searchAddress(
    String query, {
    double? lat,
    double? lng,
  }) async {
    if (client == null) {
      throw const AddressSearchException('not_configured');
    }
    return geocodeSearch(client!.functions, query, lat: lat, lng: lng);
  }
}

/// The sentence for a sighting the server refused, or null for a failure
/// the generic message covers.
@visibleForTesting
String? sightingRefusal(int status, Object? details) {
  final error = details is Map ? details['error'] : null;
  return switch ((status, error)) {
    (429, 'sighting too soon') => '10 分鐘內已回報過這個停車點。',
    (429, _) => '今天的現場回報已達上限，明天再試。',
    (403, 'sighting suspended') => '現場回報暫停中，請稍後再試。',
    (401, _) => '請先以 Google 或 Apple 登入才能回報',
    (404, _) => '找不到這個停車點，請重新整理地圖。',
    _ => null,
  };
}

class LocalRepository {
  LocalRepository(this.prefs);
  final SharedPreferences prefs;
  VehicleType get vehicle =>
      VehicleType.values.byName(prefs.getString('vehicle') ?? 'scooter');
  Future<void> setVehicle(VehicleType value) =>
      prefs.setString('vehicle', value.name);
  bool get legendSeen => prefs.getBool('legendSeen') ?? false;
  Future<void> setLegendSeen() => prefs.setBool('legendSeen', true);
  ParkedRecord? get parked {
    final s = prefs.getString('parked');
    return s == null
        ? null
        : ParkedRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<void> setParked(ParkedRecord? value) async {
    if (value == null) {
      await prefs.remove('parked');
    } else {
      await prefs.setString('parked', jsonEncode(value.toJson()));
    }
  }

  List<ParkingSpot> favorites(String key) =>
      (jsonDecode(prefs.getString('favorites:$key') ?? '[]') as List<dynamic>)
          .expand(ParkingSpot.favorite)
          .toList();
  Future<void> setFavorites(String key, List<ParkingSpot> spots) =>
      prefs.setString(
        'favorites:$key',
        jsonEncode(spots.map((e) => e.toJson()).toList()),
      );
}
