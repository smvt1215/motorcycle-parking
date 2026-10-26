import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/address_search.dart';
import '../models/parking.dart';
import '../domain/map_viewport.dart';
import '../domain/precheck.dart';

class RulesRepository {
  RulesRepository(this.client);
  final SupabaseClient? client;
  Future<List<CityRule>> load() async {
    final raw = jsonDecode(
      await rootBundle.loadString('assets/rules/parking_rules.json'),
    ) as List<dynamic>;
    final rules = raw
        .map((e) => CityRule.fromJson(e as Map<String, dynamic>))
        .toList();
    if (client != null) {
      final remote = await client!.from('city_rules').select();
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

  /// Reads [name]'s newest variant this backend has: _v3 returns every row
  /// as stored, with its parking conditions; _v2 every space kind, with rows
  /// older builds cannot read safely projected (§5.2 of
  /// docs/designs/2026-10-26-parking-conditions-and-fees.md); the original
  /// only the five first kinds. A backend not yet migrated lacks the newer
  /// ones, so fall back in that order.
  Future<List<dynamic>> _viewport(String name, MapViewport bounds) async {
    for (final suffix in const ['_v3', '_v2']) {
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
