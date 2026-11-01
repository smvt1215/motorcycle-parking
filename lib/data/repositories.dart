import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/address_search.dart';
import '../core/app_check.dart';
import '../models/holiday_calendar.dart';
import '../models/parking.dart';
import '../models/spot_history.dart';
import '../domain/map_viewport.dart';
import '../domain/eligibility.dart' show useParkingDecision;
import '../domain/precheck.dart';
import 'rules_cache.dart';

class RulesRepository {
  RulesRepository(this.client, {this.cache});
  final SupabaseClient? client;

  /// Where downloaded rules are kept for offline use; null keeps none (the
  /// admin site, tests).
  final RulesCache? cache;

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

  /// Bundled rules, overlaid with the backend's (see [overlayRules]). With a
  /// [cache], a successful download is stored for offline launches.
  Future<List<CityRule>> load() async {
    final bundled = await bundledRuleEntries();
    if (client == null) return [for (final e in bundled) e.rule];
    final merged = overlayRules(bundled, parseRuleRows(await _remoteRules()));
    await cache?.write([for (final e in merged) e.row]);
    return [for (final e in merged) e.rule];
  }
}

/// The national holidays (decision 61): the backend's `holiday_calendar()`
/// for this year and the next over the app's copy ([builtinHolidays]).
class HolidayRepository {
  HolidayRepository(this.client);
  final SupabaseClient? client;

  /// The calendar for [now]'s year (in Taiwan) and the next. Without a
  /// client, or when the backend lacks the function (not yet migrated) or
  /// sends something else, the app's copy stays; other failures throw.
  Future<HolidayCalendar> load(DateTime now) async {
    if (client == null) return builtinHolidays;
    final year = now.toUtc().add(const Duration(hours: 8)).year;
    try {
      final json = await client!.rpc<Object?>(
        'holiday_calendar',
        params: {'p_from': year, 'p_to': year + 1},
      );
      final remote = HolidayCalendar.fromJson(json);
      return remote == null
          ? builtinHolidays
          : builtinHolidays.overriddenBy(remote);
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      return builtinHolidays;
    }
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
  ParkingRepository(this.client, {AppCheckTokenSource? appCheckToken})
    : _appCheckToken = appCheckToken ?? AppCheck.token;
  final SupabaseClient? client;

  /// The App Check token sent with reports (#203); none leaves them as is.
  final AppCheckTokenSource _appCheckToken;
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

  /// Sends a report; a precheck refusal, or one for a spot an admin deleted
  /// (#200), becomes a [StateError] carrying the sentence the forms show.
  Future<Map<String, dynamic>> report(Map<String, dynamic> body) async {
    final deviceId = await _deviceId();
    try {
      final res = await client!.functions.invoke(
        'submit-report',
        body: {...body, 'device_id': deviceId},
        headers: await AppCheck.headers(_appCheckToken),
      );
      return res.data as Map<String, dynamic>;
    } on FunctionException catch (e) {
      if (reportRefusal(e.details) case final message?) {
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

  /// The Beta cities the backend last named; null before it ever answered.
  List<String>? get availabilityBetaCities =>
      prefs.getStringList('availabilityBetaCities');
  Future<void> setAvailabilityBetaCities(List<String> cities) =>
      prefs.setStringList('availabilityBetaCities', cities);

  /// The rider pressed 知道了 on the 即時車位 Beta sheet.
  bool get availabilityBetaIntroSeen =>
      prefs.getBool('availabilityBetaIntroSeen') ?? false;
  Future<void> setAvailabilityBetaIntroSeen() =>
      prefs.setBool('availabilityBetaIntroSeen', true);
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
