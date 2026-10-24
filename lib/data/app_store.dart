import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config.dart';
import '../core/notifications.dart';
import '../core/geo.dart';
import '../core/location_access.dart';
import '../domain/eligibility.dart';
import '../domain/map_viewport.dart';
import '../models/parking.dart';
import 'repositories.dart';

/// Sources stored in `community_spots`: user reports and authorized imports
/// (`tool/import_kml.py`), both subject to moderation.
const communitySpotSources = {'community', 'import'};

/// Official spot ids are `official:<official_heavy_spots.id>`.
const officialIdPrefix = 'official:';

/// Favorites are stored as snapshots; drop community, imported and official
/// spots that are no longer readable (hidden, deleted, or not yet effective).
/// TDX spots come from their own source and stay as saved.
List<ParkingSpot> visibleFavorites(
  List<ParkingSpot> favorites,
  Set<String> visibleIds,
) => favorites
    .where(
      (s) =>
          !(communitySpotSources.contains(s.source) ||
              s.source == 'official') ||
          visibleIds.contains(s.id),
    )
    .toList();

/// TDX fixture points were sample data from the removed live layer; saved
/// copies cannot be shown or reported any more.
List<ParkingSpot> withoutRetiredFavorites(List<ParkingSpot> favorites) => [
  for (final s in favorites)
    if (s.source != 'fixture') s,
];

final storeProvider = ChangeNotifierProvider<AppStore>(
  (ref) => throw StateError('AppStore 尚未初始化'),
);

class AppStore extends ChangeNotifier {
  AppStore(
    this.local,
    this.client, {
    ParkingRepository? parkingRepository,
    RulesRepository? rulesRepository,
  }) : parking = parkingRepository ?? ParkingRepository(client),
       rulesRepository = rulesRepository ?? RulesRepository(client) {
    vehicle = local.vehicle;
    parked = local.parked;
    _auth = client?.auth.onAuthStateChange.listen((_) {
      unawaited(loadFavorites());
      notifyListeners();
    });
  }
  final LocalRepository local;
  final SupabaseClient? client;
  final ParkingRepository parking;
  final RulesRepository rulesRepository;
  final notifications = ParkingNotifications();
  StreamSubscription<AuthState>? _auth;
  late VehicleType vehicle;
  ParkedRecord? parked;
  List<ParkingSpot> spots = [], favorites = [];
  List<CityRule> rules = [];
  double lat = 25.0339, lng = 121.5623;
  double mapLat = 25.0339, mapLng = 121.5623;
  String city = 'Taipei';
  String? error;

  /// Kept apart from [error] so a parking refresh cannot hide stale rules
  /// or a failed cloud favorites sync.
  String? rulesWarning, favoritesWarning;
  bool loading = false;
  bool truncated = false;

  /// True while the launch screen covers the app (see [start]).
  bool starting = false;

  /// True until the launch location attempt settles.
  bool locatingAtLaunch = false;

  /// True once a device fix is in [lat]/[lng], so the map can mark it.
  bool located = false;

  /// Why the last location attempt failed; cleared once access works.
  LocationIssue? locationIssue;

  /// The launch location attempt; the map follows it when it succeeds.
  Future<bool>? launchLocation;

  /// First launch only: the map opens the legend once [starting] ends.
  bool introduceLegend = false;
  MapViewport viewport = const MapViewport(
    south: 25.01,
    west: 121.54,
    north: 25.06,
    east: 121.59,
  );
  Timer? _viewportTimer;
  int _request = 0;
  bool _disposed = false;

  /// Invalidates older requests immediately; loads only after movement stops.
  void queueViewport(MapViewport value) {
    if (viewport == value || _disposed) return;
    viewport = value;
    _request++;
    _viewportTimer?.cancel();
    _viewportTimer = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(refresh()),
    );
  }

  String? get mapNotice => !viewport.canQuery
      ? '放大地圖即可查看停車點'
      : truncated
      ? '此範圍停車點較多，請放大地圖查看完整資料'
      : spots.isEmpty && !loading && error == null
      ? '目前範圍尚無停車資料，試著移動地圖'
      : null;
  bool get demo => client == null;
  bool get canReport =>
      demo ||
      (client!.auth.currentUser != null &&
          !client!.auth.currentUser!.isAnonymous);
  String get favoritesKey => client?.auth.currentUser?.id ?? 'guest';
  Future<void> init() => reload();

  /// Loads data and locates the device behind the launch screen. Waits at
  /// most [locationWait] for a fix so a slow GPS never holds the app; a later
  /// fix still reaches the map through [launchLocation]. The map replaces the
  /// first load as it lays out and follows the fix, so the screen also waits
  /// up to [settleLimit] for those loads to finish.
  Future<void> start({
    Future<bool> Function()? locator,
    Duration locationWait = const Duration(seconds: 6),
    Duration settleLimit = const Duration(seconds: 4),
  }) async {
    starting = locatingAtLaunch = true;
    introduceLegend = !local.legendSeen;
    final location = launchLocation = (locator ?? locateOnLaunch)();
    notifyListeners();
    unawaited(
      location.whenComplete(() {
        locatingAtLaunch = false;
        if (!_disposed) notifyListeners();
      }),
    );
    // Armed before loading so the wait overlaps data, not adds to it.
    final settled = location.timeout(locationWait, onTimeout: () => false);
    try {
      await init();
      await settled;
      await _viewportSettled(settleLimit);
    } finally {
      starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Resolves once no viewport load has been queued or running for a short
  /// quiet spell (a camera move queues its load only after it settles), or
  /// when [limit] runs out.
  Future<void> _viewportSettled(Duration limit) async {
    const step = Duration(milliseconds: 100);
    final deadline = DateTime.now().add(limit);
    var quiet = 0;
    while (quiet < 5 && DateTime.now().isBefore(deadline) && !_disposed) {
      await Future<void>.delayed(step);
      quiet = loading || (_viewportTimer?.isActive ?? false) ? 0 : quiet + 1;
    }
  }

  /// Retries every data source, including startup failures shown by the banner.
  /// Camera movement still calls [refresh] to load only viewport data.
  Future<void> reload() async {
    await loadFavorites();
    try {
      rules = await rulesRepository.load();
      rulesWarning = null;
    } catch (_) {
      rules = await RulesRepository(null).load();
      error = rulesWarning = '遠端規則讀取失敗，顯示內建規則';
    }
    await refresh();
  }

  Future<void> refresh() async {
    _viewportTimer?.cancel();
    final request = ++_request;
    final bounds = viewport;
    loading = true;
    notifyListeners();
    try {
      final result = await parking.inViewport(bounds);
      if (_disposed || request != _request) return;
      spots = result.spots;
      error = result.warning ?? rulesWarning ?? favoritesWarning;
      truncated = result.truncated;
    } catch (_) {
      if (_disposed || request != _request) return;
      spots = [];
      error = '停車資料讀取失敗，請確認連線後重試';
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  CityRule? ruleFor(ParkingSpot spot) {
    final matches = rules.where(
      (r) => r.vehicle == vehicle && r.city == spot.city,
    );
    return matches.isNotEmpty
        ? matches.first
        : rules
              .where((r) => r.vehicle == vehicle && r.city == '全國')
              .firstOrNull;
  }

  Eligibility eligible(ParkingSpot spot) =>
      eligibility(spot, vehicle, ruleFor(spot));
  Future<void> markLegendSeen() {
    introduceLegend = false;
    return local.setLegendSeen();
  }

  Future<void> setVehicle(VehicleType value) async {
    vehicle = value;
    notifyListeners();
    await local.setVehicle(value);
  }

  /// Throws a [LocationAccessError] when location is off or not permitted
  /// and keeps the reason in [locationIssue]. Asks for permission only when
  /// [request] is set.
  Future<void> _ensureLocationAccess({bool request = true}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw LocationAccessError(LocationIssue.serviceOff);
      }
      var permission = await Geolocator.checkPermission();
      if (request && permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw LocationAccessError(LocationIssue.denied);
      }
      locationIssue = null;
    } on LocationAccessError catch (e) {
      locationIssue = e.issue;
      rethrow;
    }
  }

  Future<Position> _currentPosition() => Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 20),
    ),
  );

  void _setLocation(Position p) {
    lat = p.latitude;
    lng = p.longitude;
    located = true;
    notifyListeners();
  }

  Future<void> locate() async {
    if (demo && AppConfig.offlineMap) return;
    await _ensureLocationAccess();
    _setLocation(await _currentPosition());
  }

  /// Best effort: asks for permission once and never throws, so the map
  /// keeps its default center; the map prompts for [locationIssue]. A recent
  /// cached fix answers first.
  Future<bool> locateOnLaunch({bool request = true}) async {
    if (demo && AppConfig.offlineMap) return false;
    try {
      await _ensureLocationAccess(request: request);
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      final fresh =
          last != null &&
          DateTime.now().difference(last.timestamp) <
              const Duration(minutes: 5);
      _setLocation(fresh ? last : await _currentPosition());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> recordParking(String note, String floor, int? minutes) async {
    await locate();
    final at = DateTime.now();
    final reminder = minutes == null
        ? null
        : at.add(Duration(minutes: minutes));
    await notifications.cancel();
    final scheduled = reminder != null
        ? await notifications.schedule(reminder)
        : false;
    parked = ParkedRecord(
      lat: lat,
      lng: lng,
      at: at,
      note: note,
      floor: floor,
      remindAt: scheduled ? reminder : null,
    );
    await local.setParked(parked);
    notifyListeners();
    return scheduled;
  }

  Future<void> clearParking() async {
    await notifications.cancel();
    await local.setParked(null);
    parked = null;
    notifyListeners();
  }

  Future<void> loadFavorites() async {
    final key = favoritesKey;
    // Retired snapshots are dropped before anything is shown or awaited.
    final saved = local.favorites(key);
    favorites = withoutRetiredFavorites(saved);
    if (favorites.length != saved.length) {
      await local.setFavorites(key, favorites);
    }
    if (client?.auth.currentUser != null) {
      try {
        final rows = await client!.from('favorites').select('spot');
        final all = rows
            .map((r) => r['spot'])
            .expand(ParkingSpot.known)
            .toList();
        final loaded = withoutRetiredFavorites(all);
        if (key != favoritesKey) return;
        favorites = loaded;
        favoritesWarning = null;
        await local.setFavorites(key, loaded);
        final retired = [
          for (final s in all)
            if (!loaded.contains(s)) s.id,
        ];
        if (retired.isNotEmpty) {
          // Best effort: the snapshots are already hidden locally.
          unawaited(
            client!
                .from('favorites')
                .delete()
                .inFilter('spot_id', retired)
                .then((_) {}, onError: (_) {}),
          );
        }
      } catch (_) {
        if (key != favoritesKey) return;
        error = favoritesWarning = '雲端收藏同步失敗，顯示本機收藏';
      }
    }
    final community = [
      for (final s in favorites)
        if (communitySpotSources.contains(s.source)) s.id,
    ];
    final official = [
      for (final s in favorites)
        if (s.source == 'official' && s.id.startsWith(officialIdPrefix))
          s.id.substring(officialIdPrefix.length),
    ];
    if (client != null && (community.isNotEmpty || official.isNotEmpty)) {
      try {
        // RLS hides moderated and not-yet-effective rows, so only
        // still-visible ids come back.
        final visible = <String>{
          if (community.isNotEmpty)
            for (final r
                in await client!
                    .from('community_spots')
                    .select('id')
                    .inFilter('id', community))
              r['id'] as String,
          if (official.isNotEmpty)
            for (final r
                in await client!
                    .from('official_heavy_spots')
                    .select('id')
                    .inFilter('id', official))
              '$officialIdPrefix${r['id']}',
        };
        if (key != favoritesKey) return;
        favorites = visibleFavorites(favorites, visible);
      } catch (_) {
        // Keep the saved snapshots when the check itself fails.
      }
    }
    notifyListeners();
  }

  Future<void> toggleFavorite(ParkingSpot spot) async {
    final exists = favorites.any((s) => s.id == spot.id);
    if (client?.auth.currentUser != null) {
      if (exists) {
        await client!.from('favorites').delete().eq('spot_id', spot.id);
      } else {
        await client!.from('favorites').upsert({
          'user_id': client!.auth.currentUser!.id,
          'spot_id': spot.id,
          'spot': spot.toJson(),
        });
      }
    }
    if (exists) {
      favorites.removeWhere((s) => s.id == spot.id);
    } else {
      favorites.add(spot);
    }
    await local.setFavorites(favoritesKey, favorites);
    notifyListeners();
  }

  Future<String> submit(Map<String, dynamic> body) async {
    if (!canReport) throw StateError('請先以 Google 或 Apple 登入才能回報');
    if (demo) {
      if (body['action'] == 'create') {
        final data = body['spot'] as Map<String, dynamic>;
        final existing = spots
            .where(
              (s) =>
                  s.spaceType.name == data['space_type'] &&
                  distanceMeters(
                        s.lat,
                        s.lng,
                        (data['lat'] as num).toDouble(),
                        (data['lng'] as num).toDouble(),
                      ) <
                      15,
            )
            .firstOrNull;
        if (existing != null) return '15 公尺內已有「${existing.name}」，請確認既有停車點';
        final spot = ParkingSpot.fromJson({
          ...data,
          'id': 'demo-${DateTime.now().microsecondsSinceEpoch}',
          'status': 'pending',
          'source': 'community',
        });
        parking.addDemo(spot);
        if (viewport.contains(spot.lat, spot.lng)) spots.add(spot);
        notifyListeners();
      }
      return '範例回報已送出（只用於本次測試）';
    }
    final result = await parking.report(body);
    await refresh();
    return result['duplicate_id'] != null
        ? '附近已有相同類型的停車點，請確認既有停車點'
        : '回報已送出，等待管理者確認';
  }

  Future<void> signIn(OAuthProvider provider) async {
    await client!.auth.signInWithOAuth(
      provider,
      redirectTo: kIsWeb
          ? Uri.base.replace(fragment: '', query: '').toString()
          : AppConfig.redirectUrl,
      // An in-app Safari view can remain blank above the app after callback.
      authScreenLaunchMode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
    );
  }

  Future<void> signOut() async {
    await client?.auth.signOut();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _viewportTimer?.cancel();
    unawaited(_auth?.cancel());
    super.dispose();
  }
}

Future<void> navigateTo(double lat, double lng) async {
  final apple = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  final uri = Uri.parse(
    apple
        ? 'https://maps.apple.com/?daddr=$lat,$lng&dirflg=d'
        : 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
  );
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw StateError('無法開啟導航');
  }
}
