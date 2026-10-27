import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';
import '../core/notifications.dart';
import '../core/geo.dart';
import '../core/location_access.dart';
import '../core/navigation.dart' as navigation;
import '../core/town_lookup.dart';
import '../domain/eligibility.dart';
import '../domain/parking_decision.dart';
import '../domain/eligibility_display.dart';
import '../domain/location_check.dart';
import '../domain/map_viewport.dart';
import '../models/availability.dart';
import '../models/parking.dart';
import 'availability_repository.dart';
import 'contributions_repository.dart';
import 'data_updates.dart';
import 'repositories.dart';
import 'profile_repository.dart';

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

class AppStore extends ChangeNotifier with WidgetsBindingObserver {
  AppStore(
    this.local,
    this.client, {
    ParkingRepository? parkingRepository,
    RulesRepository? rulesRepository,
    ContributionsRepository? contributionsRepository,
    DataUpdates? dataUpdates,
    AvailabilitySource? availabilitySource,
    Duration? availabilityPoll,
    DateTime Function()? clock,
  }) : parking = parkingRepository ?? ParkingRepository(client),
       // Official counts from the backend; the example build has fake ones.
       availabilitySource =
           availabilitySource ??
           (client == null
               ? demoAvailabilitySource(clock: clock)
               : SupabaseAvailabilitySource(client)),
       // The example build's counts never change: no polling.
       availabilityPoll =
           availabilityPoll ??
           (client == null ? null : defaultAvailabilityPoll),
       clock = clock ?? DateTime.now,
       rulesRepository = rulesRepository ?? RulesRepository(client),
       contributions =
           contributionsRepository ?? ContributionsRepository(client),
       updates = dataUpdates ?? DataUpdates(client) {
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
  final ContributionsRepository contributions;
  final DataUpdates updates;
  final AvailabilitySource availabilitySource;

  /// The time freshness is judged against; tests pin it.
  final DateTime Function() clock;

  /// How often the counts of the loaded spots are read again while the map
  /// is on screen and the app in the foreground; null never polls. Taipei
  /// writes every five minutes, so two keeps a count at most one cycle
  /// behind without hammering the backend (plan §7.4).
  final Duration? availabilityPoll;
  static const defaultAvailabilityPoll = Duration(minutes: 2);

  /// The longest wait after failed reads in a row (plan §10: back off).
  static const availabilityBackoffLimit = Duration(minutes: 20);
  Timer? _availabilityTimer;
  int _availabilityPollRequest = 0;
  int _availabilityFailures = 0;
  DateTime? _availabilityReadAt;
  bool _foreground = true, _mapShown = true;

  /// Live counts for the loaded [spots], by spot id; kept apart from them
  /// (see [AvailabilitySnapshot]).
  Map<String, SpotAvailability> availability = const {};

  SpotAvailability availabilityOf(ParkingSpot spot) =>
      availability[spot.id] ?? SpotAvailability.none;

  /// Counts reports sent this session, so "我送出的建議" reloads after one.
  int reportsSent = 0;
  final notifications = ParkingNotifications();
  StreamSubscription<AuthState>? _auth;
  StreamSubscription<DataVersion>? _updates;
  bool _observingLifecycle = false;

  /// Backend data versions this store has loaded or been told about.
  final _versions = <DataSet, int>{};

  /// Datasets to reload once [_updateTimer] fires.
  final _staleSets = <DataSet>{};
  Timer? _updateTimer;

  /// True once a viewport load has returned, so a late first version read
  /// (see [_noteVersion]) knows the data may predate it.
  bool _loadedOnce = false;
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

  /// The signed-in Google or Apple account, null for guests and anonymous
  /// sessions: whose contributions the contribute tab lists.
  String? get riderId {
    final user = client?.auth.currentUser;
    return user == null || user.isAnonymous ? null : user.id;
  }

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
    listenForUpdates();
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
    // Baseline for the later checks, read before the data so it can only be
    // older than what loads: a write between the two reads then reloads
    // once instead of being missed. The location wait, already armed,
    // usually covers this round trip.
    await checkForUpdates();
    try {
      await init();
      await settled;
      await _viewportSettled(settleLimit);
    } finally {
      starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Follows the backend's data versions (see [DataUpdates]) so a change
  /// made in the admin site or by another rider reaches this map without a
  /// camera move. [start] calls it; calling it again does nothing.
  void listenForUpdates() {
    if (_disposed || _updates != null) return;
    _updates = updates
        .watch(
          // Each (re)join compares versions, since a dropped connection
          // replays nothing.
          onSubscribed: () => unawaited(checkForUpdates()),
        )
        .listen(
          (version) => _noteVersion(version, changed: true),
          onError: (Object _) {},
        );
    // The resume check needs the binding; demo builds have nothing to check.
    if (!demo && !_observingLifecycle) {
      _observingLifecycle = true;
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// Compares the backend's data versions with the ones loaded and reloads
  /// what changed. Runs at launch for the baseline, when the app returns to
  /// the foreground and when Realtime (re)connects, where a message may have
  /// been missed; never throws.
  Future<void> checkForUpdates() async {
    try {
      for (final version in await updates.current()) {
        _noteVersion(version, changed: false);
      }
    } catch (_) {
      // Offline or the backend is older than the migration: nothing to do.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        unawaited(checkForUpdates());
        _resumeAvailability();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // No polling in the background.
        _foreground = false;
        _availabilityTimer?.cancel();
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Whether the map is on screen (another tab covers it otherwise); counts
  /// are only polled while it is.
  void setMapShown(bool shown) {
    if (_mapShown == shown) return;
    _mapShown = shown;
    if (shown) {
      _resumeAvailability();
    } else {
      _availabilityTimer?.cancel();
    }
  }

  /// Back on screen: reads at once when the last read is a poll interval
  /// old, otherwise waits out the rest of it.
  void _resumeAvailability() {
    final poll = availabilityPoll;
    if (poll == null || !_foreground || !_mapShown) return;
    final at = _availabilityReadAt;
    final since = at == null ? null : DateTime.now().difference(at);
    if (since == null || since >= poll) {
      unawaited(pollAvailability());
    } else {
      _scheduleAvailability(poll - since);
    }
  }

  /// The wait before the next poll: the interval, doubled for each failed
  /// read in a row up to [availabilityBackoffLimit].
  Duration? get availabilityDelay {
    final poll = availabilityPoll;
    if (poll == null) return null;
    final delay = poll * (1 << _availabilityFailures.clamp(0, 4));
    return delay > availabilityBackoffLimit ? availabilityBackoffLimit : delay;
  }

  void _scheduleAvailability([Duration? after]) {
    _availabilityTimer?.cancel();
    final delay = after ?? availabilityDelay;
    if (delay == null ||
        _disposed ||
        !_foreground ||
        !_mapShown ||
        !availabilitySource.enabled) {
      return;
    }
    _availabilityTimer = Timer(delay, () => unawaited(pollAvailability()));
  }

  /// Reads the counts of the loaded spots again, without reloading the
  /// spots. A viewport load started meanwhile wins: its spots and counts
  /// are newer, so this result is dropped. A failed read keeps the last
  /// counts, which age on screen by their source time (delayed, then
  /// stale), and backs off.
  Future<void> pollAvailability() async {
    _availabilityTimer?.cancel();
    if (_disposed || !availabilitySource.enabled || spots.isEmpty) return;
    final request = _request, poll = ++_availabilityPollRequest;
    final current = spots;
    final counts = await _readAvailability(current);
    if (_disposed ||
        request != _request ||
        poll != _availabilityPollRequest ||
        !identical(current, spots)) {
      return;
    }
    if (counts != null) availability = counts;
    // Also on failure: the ages shown move on.
    notifyListeners();
    _scheduleAvailability();
  }

  /// The counts for [spots], or null when the read fails.
  Future<Map<String, SpotAvailability>?> _readAvailability(
    List<ParkingSpot> spots,
  ) async {
    try {
      final counts = await availabilitySource.forSpots(spots);
      _availabilityFailures = 0;
      _availabilityReadAt = DateTime.now();
      return counts;
    } catch (_) {
      _availabilityFailures++;
      return null;
    }
  }

  /// The last counts of the spots still loaded, for when a read fails.
  Map<String, SpotAvailability> _keptAvailability(List<ParkingSpot> spots) {
    final ids = {for (final spot in spots) spot.id};
    return {
      for (final MapEntry(:key, :value) in availability.entries)
        if (ids.contains(key)) key: value,
    };
  }

  /// Records [version]; reloads its dataset when it is newer than the one
  /// loaded. A streamed version ([changed]) is a change by definition. A
  /// fetched one counts against a known baseline; with none, it becomes the
  /// baseline when nothing has loaded yet, and reloads once when data loaded
  /// without one (an offline launch that came back online). Bursts (an
  /// import, a review session) collapse into one reload.
  void _noteVersion(DataVersion version, {required bool changed}) {
    if (_disposed) return;
    final known = _versions[version.set];
    if (known != null && known >= version.version) return;
    _versions[version.set] = version.version;
    if (known == null && !changed && !_loadedOnce) return;
    _staleSets.add(version.set);
    _updateTimer?.cancel();
    _updateTimer = Timer(
      const Duration(seconds: 1),
      () => unawaited(_reloadStale()),
    );
  }

  Future<void> _reloadStale() async {
    final sets = {..._staleSets};
    _staleSets.clear();
    if (_disposed) return;
    if (sets.contains(DataSet.rules)) {
      await _loadRules();
      if (_disposed) return;
      notifyListeners();
    }
    if (sets.contains(DataSet.spots)) await refresh();
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
    await _loadRules();
    await refresh();
  }

  Future<void> _loadRules() async {
    try {
      rules = await rulesRepository.load();
      rulesWarning = null;
    } catch (_) {
      rules = await RulesRepository(null).load();
      error = rulesWarning = '遠端規則讀取失敗，顯示內建規則';
    }
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
      _loadedOnce = true;
      // A failed count read keeps the last counts of the spots still in
      // view (they age by source time) and never empties the map.
      final counts = await _readAvailability(result.spots);
      if (_disposed || request != _request) return;
      availability = counts ?? _keptAvailability(result.spots);
      _scheduleAvailability();
      error = result.warning ?? rulesWarning ?? favoritesWarning;
      truncated = result.truncated;
    } catch (_) {
      if (_disposed || request != _request) return;
      spots = [];
      availability = const {};
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

  /// The map marker's judgement; the details banner reads the same one
  /// ([decide]), so they never disagree.
  Eligibility eligible(ParkingSpot spot) => decide(spot).eligibility;

  /// [eligible] with its basis, zones and prices, for the details sheet;
  /// the same clock as [eligible], so the banner and the marker agree.
  ParkingDecision decide(ParkingSpot spot) {
    if (useParkingDecision) {
      // Every rule of the city, so two that disagree read as a conflict.
      return decideParking(spot, vehicle, rules);
    }
    // Rolled back: the old judgement, with only the spot's own source.
    final e = legacyEligibility(spot, vehicle, ruleFor(spot));
    final now = DateTime.now();
    final explicit = vehicle == VehicleType.heavy
        ? spot.heavyAllowed
        : spot.scooterAllowed;
    return ParkingDecision(
      e.status,
      e.reason,
      restriction: e.restriction,
      basis: [
        sourceBasis(
          spot,
          vehicle,
          now,
          verified: explicit != null && recentlyVerified(spot, vehicle, now),
        ),
      ],
    );
  }

  /// [eligible]'s short status for a list, keeping a rider's claim visible.
  String eligibleLabel(ParkingSpot spot) =>
      eligibilityListLabel(spot, vehicle, eligible(spot));
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

  /// A fresh device fix with its accuracy, for placing a spot by hand. It
  /// does not move the map. Throws [LocationAccessError] like [locate].
  Future<LocationFix> currentFix() async {
    if (demo && AppConfig.offlineMap) return LocationFix(lat, lng, 5);
    await _ensureLocationAccess();
    final p = await _currentPosition();
    return LocationFix(p.latitude, p.longitude, p.accuracy);
  }

  /// The county or city and district at a position (國土測繪中心); tests
  /// override it to stay offline.
  Future<Town?> townAt(double lat, double lng) => lookupTown(lat, lng);

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
            .expand(ParkingSpot.favorite)
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
    reportsSent++;
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

  Future<void> updateProfile({
    required String displayName,
    Uint8List? avatarBytes,
    bool removeAvatar = false,
  }) async {
    final backend = client;
    if (backend == null) throw StateError('請先登入再編輯個人資料');
    await ProfileRepository(backend).update(
      displayName: displayName,
      avatarBytes: avatarBytes,
      removeAvatar: removeAvatar,
    );
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _viewportTimer?.cancel();
    _updateTimer?.cancel();
    _availabilityTimer?.cancel();
    if (_observingLifecycle) WidgetsBinding.instance.removeObserver(this);
    unawaited(_auth?.cancel());
    unawaited(_updates?.cancel());
    super.dispose();
  }
}

Future<void> navigateTo(double lat, double lng) =>
    navigation.launchNavigation(lat, lng);
