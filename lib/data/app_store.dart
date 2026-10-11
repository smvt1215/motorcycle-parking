import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config.dart';
import '../core/notifications.dart';
import '../core/geo.dart';
import '../domain/eligibility.dart';
import '../domain/map_viewport.dart';
import '../models/parking.dart';
import 'repositories.dart';

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

  /// Kept apart from [error] so a parking refresh cannot hide stale rules.
  String? rulesWarning;
  bool loading = false;
  bool truncated = false;
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
  Future<void> init() async {
    await loadFavorites();
    try {
      rules = await rulesRepository.load();
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
      error = result.warning ?? rulesWarning;
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
  Future<void> setVehicle(VehicleType value) async {
    vehicle = value;
    notifyListeners();
    await local.setVehicle(value);
  }

  Future<void> locate() async {
    if (demo && AppConfig.offlineMap) return;
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('請開啟裝置定位服務');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('定位未授權，請在設定中開啟定位權限');
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    lat = p.latitude;
    lng = p.longitude;
    notifyListeners();
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
    favorites = local.favorites(key);
    if (client?.auth.currentUser != null) {
      try {
        final rows = await client!.from('favorites').select('spot');
        final loaded = rows
            .map((r) => ParkingSpot.fromJson(r['spot'] as Map<String, dynamic>))
            .toList();
        if (key != favoritesKey) return;
        favorites = loaded;
        await local.setFavorites(key, loaded);
      } catch (_) {
        if (key != favoritesKey) return;
        error = '雲端收藏同步失敗，顯示本機收藏';
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
        if (existing != null) return '15 公尺內已有「${existing.name}」，請確認既有點位';
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
        ? '附近已有相同類型點位，請確認既有點'
        : '回報已送出，等待社群確認';
  }

  Future<void> signIn(OAuthProvider provider) async {
    await client!.auth.signInWithOAuth(
      provider,
      redirectTo: kIsWeb
          ? Uri.base.replace(fragment: '', query: '').toString()
          : AppConfig.redirectUrl,
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
