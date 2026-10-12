import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/parking.dart';
import '../domain/map_viewport.dart';

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
        } else if (r.version > rules[i].version) {
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
  Future<ParkingResult> inViewport(MapViewport bounds) async {
    if (!bounds.canQuery || !bounds.intersectsTaiwan) {
      return const ParkingResult([]);
    }
    if (client == null) {
      if (_demoSpots == null) {
        final raw = jsonDecode(
          await rootBundle.loadString('assets/demo/spots.json'),
        ) as List<dynamic>;
        _demoSpots = raw
            .map((e) => ParkingSpot.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return ParkingResult(
        _demoSpots!.where((s) => bounds.contains(s.lat, s.lng)).toList(),
      );
    }
    final raw = await client!.rpc<List<dynamic>>(
      'viewport_spots',
      params: bounds.toJson(),
    );
    final community = raw
        .map((e) => ParkingSpot.fromJson(e as Map<String, dynamic>))
        .toList();
    // Admin-maintained municipal bays; a failure only drops this layer.
    var official = const <ParkingSpot>[];
    String? officialWarning;
    try {
      final rows = await client!.rpc<List<dynamic>>(
        'official_viewport_spots',
        params: bounds.toJson(),
      );
      official = rows
          .map((e) => ParkingSpot.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      officialWarning = '縣市公告的重機專用格暫時無法讀取';
    }
    try {
      final response = await client!.functions.invoke(
        'tdx-parking',
        body: {'bounds': bounds.toJson()},
      );
      final body = response.data as Map<String, dynamic>;
      final fixture = body['fixture'] == true;
      final warning = fixture
          ? 'TDX 使用範例資料，請勿依範例點位停車'
          : body['partial'] == true
          ? '部分官方資料暫時無法讀取，請稍後重試'
          : null;
      final tdx = (body['spots'] as List<dynamic>).map((e) {
        final row = e as Map<String, dynamic>;
        return ParkingSpot.fromJson(
          fixture
              ? {
                  ...row,
                  'name': '[TDX 範例] ${row['name']}',
                  'source': 'fixture',
                  'status': 'pending',
                  'available': null,
                }
              : row,
        );
      });
      return ParkingResult(
        [
          ...official.take(500),
          ...community.take(500),
          ...tdx,
        ].where((s) => bounds.contains(s.lat, s.lng)).toList(),
        warning: warning ?? officialWarning,
        truncated:
            official.length > 500 ||
            community.length > 500 ||
            body['truncated'] == true,
      );
    } catch (_) {
      return ParkingResult(
        [...official.take(500), ...community.take(500)],
        warning: officialWarning == null
            ? 'TDX 停車資料暫時無法讀取，目前僅顯示社群回報與縣市公告'
            : '官方停車資料暫時無法讀取，目前僅顯示社群回報',
        truncated: official.length > 500 || community.length > 500,
      );
    }
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

  Future<Map<String, dynamic>> report(Map<String, dynamic> body) async {
    final res = await client!.functions.invoke(
      'submit-report',
      body: {...body, 'device_id': await _deviceId()},
    );
    return res.data as Map<String, dynamic>;
  }
}

class LocalRepository {
  LocalRepository(this.prefs);
  final SharedPreferences prefs;
  VehicleType get vehicle =>
      VehicleType.values.byName(prefs.getString('vehicle') ?? 'scooter');
  Future<void> setVehicle(VehicleType value) =>
      prefs.setString('vehicle', value.name);
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
          .map((e) => ParkingSpot.fromJson(e as Map<String, dynamic>))
          .toList();
  Future<void> setFavorites(String key, List<ParkingSpot> spots) =>
      prefs.setString(
        'favorites:$key',
        jsonEncode(spots.map((e) => e.toJson()).toList()),
      );
}
