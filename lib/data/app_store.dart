import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' as v1 show SpotClosure;
import '../api/v1/api_v1.g.dart' show ApiV1Client, SpotSighting;
import '../core/address_search.dart';
import '../core/config.dart';
import '../core/notifications.dart';
import '../core/geo.dart';
import '../core/location_access.dart';
import '../core/navigation.dart' as navigation;
import '../core/town_lookup.dart';
import '../domain/availability_beta_display.dart';
import '../domain/eligibility.dart';
import '../domain/four_sign.dart';
import '../domain/parking_decision.dart';
import '../domain/eligibility_display.dart';
import '../domain/location_check.dart';
import '../domain/map_viewport.dart';
import '../domain/four_sign_display.dart' show riderMeterOf;
import '../domain/rider_meter_display.dart' show RiderMeter;
import '../domain/rules_display.dart';
import '../domain/spot_contributor.dart';
import '../models/availability.dart';
import '../models/holiday_calendar.dart';
import '../models/parking.dart';
import '../models/sighting.dart';
import 'auth_flow.dart';
import 'availability_repository.dart';
import 'contributions_repository.dart';
import 'data_updates.dart';
import 'favorite_handles.dart';
import 'hidden_riders.dart';
import 'repositories.dart';
import 'rules_cache.dart';
import 'sightings_repository.dart';
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
    HolidayRepository? holidayRepository,
    ContributionsRepository? contributionsRepository,
    DataUpdates? dataUpdates,
    AvailabilitySource? availabilitySource,
    SightingsSource? sightingsSource,
    Duration? availabilityPoll,
    Future<List<String>> Function()? availabilityBetaCities,
    DateTime Function()? clock,
    AuthFlow? authFlow,
    FavoriteHandles? favoriteHandles,
    HiddenRidersStore? hiddenRidersAccount,
  }) : authFlow = authFlow ?? (client == null ? null : AuthFlow(client)),
       favoriteHandlesSource =
           favoriteHandles ??
           (client == null
               ? const NoFavoriteHandles()
               : RemoteFavoriteHandles(client)),
       parking = parkingRepository ?? ParkingRepository(client),
       // Official counts from the backend; the example build has fake ones.
       availabilitySource =
           availabilitySource ??
           (client == null
               ? demoAvailabilitySource(clock: clock)
               : SupabaseAvailabilitySource(client)),
       sightingsSource =
           sightingsSource ??
           (client == null
               ? const NoSightingsSource()
               : SupabaseSightingsSource(client)),
       // The example build's counts never change: no polling.
       availabilityPoll =
           availabilityPoll ??
           (client == null ? null : defaultAvailabilityPoll),
       // The example build has no backend to ask: the stored or default
       // cities hold.
       _loadBetaCities =
           availabilityBetaCities ??
           (client == null
               ? null
               : () async => (await ApiV1Client(
                   client,
                 ).clientConfig()).availabilityBetaCities),
       clock = clock ?? DateTime.now,
       rulesRepository =
           rulesRepository ??
           RulesRepository(
             client,
             // The example build has no download to keep.
             cache: client == null ? null : RulesCache(),
           ),
       holidayRepository = holidayRepository ?? HolidayRepository(client),
       contributions =
           contributionsRepository ?? ContributionsRepository(client),
       updates = dataUpdates ?? DataUpdates(client) {
    vehicle = local.vehicle;
    parked = local.parked;
    _ownAccount = riderId;
    hiddenRiders = HiddenRiders(
      local.prefs,
      clock: this.clock,
      // Signed in, the list follows the account (#280).
      remote:
          hiddenRidersAccount ??
          (client == null ? null : RemoteHiddenRidersStore(client!)),
    )..addListener(_hiddenRidersChanged);
    _auth = client?.auth.onAuthStateChange.listen((state) {
      // Signing in joins the device list to the account's; signing out
      // clears the device's copy.
      unawaited(switch (riderId) {
        null => hiddenRiders.signedOut(),
        final id => hiddenRiders.signedIn(id),
      });
      unawaited(loadFavorites());
      // `is_own` follows the session a row was read with (#280): read the
      // map again once someone signs in or out.
      if (_loadedOnce &&
          (state.event == AuthChangeEvent.signedIn ||
              state.event == AuthChangeEvent.signedOut)) {
        unawaited(refresh());
      }
      notifyListeners();
    });
  }
  final LocalRepository local;
  final SupabaseClient? client;

  /// Null in the example build: no accounts there.
  final AuthFlow? authFlow;
  final ParkingRepository parking;
  final RulesRepository rulesRepository;
  final HolidayRepository holidayRepository;
  final ContributionsRepository contributions;
  final DataUpdates updates;
  final AvailabilitySource availabilitySource;
  final SightingsSource sightingsSource;

  /// Riders hidden on this device (#280); their spots leave [spots].
  late final HiddenRiders hiddenRiders;

  void _hiddenRidersChanged() {
    if (_disposed) return;
    _spots = _withoutHidden(_loadedSpots);
    notifyListeners();
  }

  /// Reads the contributor handles of saved favourites, whose snapshots
  /// never keep them (#280 `spots_by_ids`).
  final FavoriteHandles favoriteHandlesSource;

  /// The handles [favoriteHandlesSource] returned, by spot id.
  Map<String, String> favoriteHandles = const {};

  /// Favourites the signed-in account added, from [favoriteHandlesSource].
  Set<String> favoriteOwn = const {};

  /// [spot]'s contributor handle: its own, else the loaded copy's, else a
  /// favourite's looked-up one; null when none is known.
  String? handleOf(ParkingSpot spot) =>
      riderHandle(spot) ?? _loadedHandles[spot.id] ?? favoriteHandles[spot.id];

  /// Whether the signed-in account added [spot]. `is_own` holds only for
  /// the session a row was read with, and an opened spot can outlive that
  /// session: what this session read decides, and a copy from an earlier
  /// session counts as someone else's until it is read again.
  bool ownSpot(ParkingSpot spot) {
    _followAccount();
    return favoriteOwn.contains(spot.id) ||
        (_ownRead[spot.id] ?? (_sameSession && isOwnSpot(spot)));
  }

  /// `is_own` as this session read it, by spot id; never cleared by a
  /// viewport moving on, so an open spot keeps its answer.
  Map<String, bool> _ownRead = {};

  /// False once the account changed: copies made before may say anything.
  bool _sameSession = true;
  late String? _ownAccount;

  /// Forgets what was read for another account, whichever path notices
  /// first.
  void _followAccount() {
    final account = riderId;
    if (account == _ownAccount) return;
    _ownAccount = account;
    _sameSession = false;
    _ownRead = {};
    _favoriteFactsKey = null;
    _favoriteFactsRead++;
    favoriteHandles = const {};
    favoriteOwn = const {};
  }

  /// Whether a content report can be sent for [spot]: community content,
  /// not official data and not the rider's own (P17a ⑤, P17b).
  bool canReportContent(ParkingSpot spot) => !spot.isOfficial && !ownSpot(spot);

  /// Whether the contributor, looking at their own spot, should see that
  /// [field] is under review (P17b ⑪); others see it already hidden.
  bool heldForOwner(ParkingSpot spot, String field) =>
      ownSpot(spot) && contentHeld(spot).contains(field);

  /// [id] as the backend shows it now, for this session; null when it
  /// cannot be read or the account changed meanwhile.
  Future<ParkingSpot?> latestSpot(String id) async {
    final account = riderId;
    final spot = await parking.byId(id);
    if (spot == null || account != riderId) return null;
    _followAccount();
    _ownRead[id] = isOwnSpot(spot);
    return spot;
  }

  /// Handles of the spots last loaded, hidden ones included, by spot id.
  Map<String, String> _loadedHandles = const {};

  /// Whether [spot]'s rider is hidden on this device; never the rider's
  /// own spot.
  bool riderHidden(ParkingSpot spot) =>
      !ownSpot(spot) && hiddenRiders.isHidden(handleOf(spot));

  /// Every spot loaded for the viewport, hidden riders' included.
  List<ParkingSpot> _loadedSpots = [];
  List<ParkingSpot> _spots = [];

  /// The loaded spots without hidden riders' ones: what the map, its
  /// clusters, search and the nearby lists show (#280).
  List<ParkingSpot> get spots => _spots;
  set spots(List<ParkingSpot> value) {
    _followAccount();
    _loadedSpots = value;
    _loadedHandles = {for (final s in value) s.id: ?riderHandle(s)};
    for (final s in value) {
      _ownRead[s.id] = isOwnSpot(s);
    }
    _spots = _withoutHidden(value);
    // Hidden as a guest, then signed in: one's own handle leaves the list.
    final own = [
      for (final s in value)
        if (isOwnSpot(s)) ?riderHandle(s),
    ];
    if (own.isNotEmpty) unawaited(hiddenRiders.forget(own));
  }

  /// [all] without hidden riders' spots; the same list when none is.
  List<ParkingSpot> _withoutHidden(List<ParkingSpot> all) {
    if (hiddenRiders.isEmpty) return all;
    final kept = [
      for (final s in all)
        if (!riderHidden(s)) s,
    ];
    return kept.length == all.length ? all : kept;
  }

  /// Numbers each look-up: only the newest may land.
  int _favoriteFactsRead = 0;

  /// The account [favoriteHandles] and [favoriteOwn] were read for.
  String? _favoriteFactsKey;

  /// Looks up the favourites' handles; a failure keeps the last ones. An
  /// answer for another account, or an older look-up, is dropped: it must
  /// not change this account's facts or hidden list.
  Future<void> _loadFavoriteHandles() async {
    _followAccount();
    final key = favoritesKey, read = ++_favoriteFactsRead;
    if (key != _favoriteFactsKey) {
      _favoriteFactsKey = key;
      favoriteHandles = const {};
      favoriteOwn = const {};
    }
    final ids = [
      for (final s in favorites)
        if (communitySpotSources.contains(s.source)) s.id,
    ];
    if (ids.isEmpty) {
      favoriteHandles = const {};
      favoriteOwn = const {};
      return;
    }
    try {
      final facts = await favoriteHandlesSource.handlesFor(ids);
      _followAccount();
      if (_disposed || read != _favoriteFactsRead || key != favoritesKey) {
        return;
      }
      for (final MapEntry(:key, :value) in facts.entries) {
        _ownRead[key] = value.isOwn;
      }
      favoriteHandles = {
        for (final MapEntry(:key, :value) in facts.entries) key: ?value.handle,
      };
      favoriteOwn = {
        for (final MapEntry(:key, :value) in facts.entries)
          if (value.isOwn) key,
      };
      // One's own favourite: one's own handle leaves the hidden list.
      final own = [
        for (final fact in facts.values)
          if (fact.isOwn) ?fact.handle,
      ];
      if (own.isNotEmpty) unawaited(hiddenRiders.forget(own));
    } catch (_) {}
  }

  /// Reads which cities' counts are in Beta (`api_v1.client_config()`).
  final Future<List<String>> Function()? _loadBetaCities;

  /// The cities whose official counts are in Beta: the backend's last
  /// answer, or [defaultAvailabilityBetaCities] before it ever answered.
  /// Empty when no city is in Beta, and nothing says Beta.
  List<String> get availabilityBetaCities =>
      local.availabilityBetaCities ?? defaultAvailabilityBetaCities;

  /// Asks the backend again; offline, an older backend without the field
  /// (a TypeError while parsing) or any other failure keeps the last
  /// answer. Never throws.
  Future<void> refreshAvailabilityBeta() async {
    final load = _loadBetaCities;
    if (load == null || _disposed) return;
    try {
      final cities = await load();
      if (_disposed) return;
      final stored = local.availabilityBetaCities;
      if (stored != null && listEquals(stored, cities)) return;
      await local.setAvailabilityBetaCities(cities);
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Keep the last answer.
    }
  }

  /// Whether the rider pressed 知道了 on the Beta sheet.
  bool get availabilityBetaIntroSeen => local.availabilityBetaIntroSeen;
  Future<void> markAvailabilityBetaIntroSeen() async {
    await local.setAvailabilityBetaIntroSeen();
    if (!_disposed) notifyListeners();
  }

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

  /// Redraws once a minute while counts are on screen, so a count turns
  /// delayed or stale on time even while reads back off.
  Timer? _availabilityClock;

  /// Every count read, from a viewport load or a poll, takes the next
  /// number; only the newest one started may land.
  int _availabilityRead = 0;
  int _availabilityFailures = 0;
  DateTime? _availabilityReadAt;
  bool _foreground = true, _mapShown = true;

  /// Live counts for the loaded [spots], by spot id; kept apart from them
  /// (see [AvailabilitySnapshot]).
  Map<String, SpotAvailability> availability = const {};

  SpotAvailability availabilityOf(ParkingSpot spot) =>
      availability[spot.id] ?? SpotAvailability.none;

  /// The loaded [spots], then the favourites and open sheets' spots out of
  /// view: the cards and details read the same answers as the map, official
  /// counts first (P4, P6).
  List<ParkingSpot> _watched(List<ParkingSpot> spots) {
    final ids = {for (final spot in spots) spot.id};
    return [
      ...spots,
      for (final spot in [...favorites, ..._following])
        if (ids.add(spot.id)) spot,
    ];
  }

  /// With the map covered, what is left to keep up to date: the favourite
  /// cards and any open sheet, which polling reads on its own.
  bool get _readsWanted =>
      _mapShown || favorites.isNotEmpty || _following.isNotEmpty;

  /// The map is covered and there may be new favourites to keep up to date.
  void _favoritesChanged() {
    if (!_mapShown) _resumeAvailability();
  }

  /// Riders' summaries of the [_watched] spots over [sightingMapWindow], by
  /// lower-case spot id; read and polled with [availability].
  Map<String, List<SpotSighting>> sightings = const {};

  /// What riders reported closed (A7d) at the same spots, read with
  /// [sightings]; the followed spot's newest read lands here too.
  Map<String, List<v1.SpotClosure>> closures = const {};

  /// Riders' closures of [spot] still holding: each lasts
  /// [RiderClosure.holds] after its newest report, also between reads.
  List<RiderClosure> riderClosures(ParkingSpot spot) {
    final rows = closures[spot.id.toLowerCase()];
    if (rows == null) return const [];
    final oldest = clock().subtract(RiderClosure.holds);
    return [
      for (final row in rows)
        if (riderClosureOf(row) case final c? when c.at.isAfter(oldest)) c,
    ];
  }

  /// The spots open sheets show, the top one last, and its summaries over
  /// both windows: the details list a longer window, and it may be a spot
  /// out of view. A sheet opened over another hands it back on closing.
  final _following = <ParkingSpot>[];
  ParkingSpot? get _followed => _following.lastOrNull;
  Map<String, List<SpotSighting>> _followedNear = const {},
      _followedWide = const {};

  /// Numbers each read of the followed spot: only the newest may land.
  int _followRead = 0;

  /// Numbers every read of [sightings] and [closures] as it starts, and
  /// the read each spot's answer came from: an older read that lands late
  /// (a poll waiting on counts) never replaces a newer one (the details'
  /// read after a report).
  int _sightingsSeq = 0;
  final _sightedSeq = <String, int>{};

  /// The spots of [ids] a read later than [seq] already answered.
  Set<String> _sightedSince(int seq, Iterable<String> ids) => {
    for (final id in ids)
      if ((_sightedSeq[id] ?? 0) > seq) id,
  };

  /// Records [seq] as the read that answered [ids].
  void _sighted(int seq, Iterable<String> ids) {
    for (final id in ids) {
      _sightedSeq[id] = seq;
    }
  }

  /// [_sighted] for a viewport read. The followed spot's near rows predate
  /// its answer and, preferred as they are on screen, would hide it.
  void _sightedInView(int seq, Set<String> ids) {
    _sighted(seq, ids);
    if (ids.contains(_followed?.id.toLowerCase())) _followedNear = const {};
  }

  /// What this rider sent, shown at once (A7c) wherever no summary covers
  /// the place yet: a summary leaves out a rider of low credibility, and
  /// the read may lag or fail. They age out like any report.
  final _sent = <_SentSighting>[];

  /// The reports of the last [windowMinutes] for the chosen vehicle: the
  /// map and the preview read [sightingMapWindow], the details
  /// [sightingDetailWindow]. They age out on screen by their own time.
  RiderSeats riderSeats(int windowMinutes) =>
      _StoreRiderSeats(this, windowMinutes);

  /// The map's badge for [spot]: the place 有沒有位 picks, none while an
  /// official count stands there (A0).
  RiderMeter? riderMeter(ParkingSpot spot) {
    final riders = riderSeats(sightingMapWindow);
    if (riders.of(spot.id).isEmpty) return null;
    final seat = fourSign(
      spot,
      vehicle,
      rules,
      now: clock(),
      availability: availabilityOf(spot),
      riders: riders,
      closures: riderClosures(spot),
      decision: decide(spot),
    ).seat;
    return seat.rider == null ? null : riderMeterOf(seat.rider!);
  }

  /// Follows [spot], an open sheet's, until [unfollowSightings].
  Future<void> followSightings(ParkingSpot spot) {
    if (_followed?.id != spot.id) {
      _followedNear = _followedWide = const {};
    }
    _following.add(spot);
    // A sheet opened over a covered map still has to stay up to date.
    if (!_mapShown) _resumeAvailability();
    return readFollowedSightings();
  }

  void unfollowSightings(ParkingSpot spot) {
    final at = _following.lastIndexWhere((s) => s.id == spot.id);
    if (at < 0) return;
    final top = at == _following.length - 1;
    _following.removeAt(at);
    if (!top || _followed?.id == spot.id) return;
    _followRead++;
    _followedNear = _followedWide = const {};
    unawaited(readFollowedSightings());
  }

  /// Reads the followed spot again; a failed read keeps what it had, which
  /// ages out on screen.
  Future<void> readFollowedSightings() async {
    final spot = _followed;
    if (spot == null || !sightingsSource.enabled || _disposed) return;
    final read = ++_followRead, seq = ++_sightingsSeq;
    try {
      final (nearRead, wide) = await (
        sightingsSource.read([spot], windowMinutes: sightingMapWindow),
        sightingsSource.forSpots([spot], windowMinutes: sightingDetailWindow),
      ).wait;
      if (_disposed || read != _followRead) return;
      // A later viewport read answered this spot while this one waited.
      final id = spot.id.toLowerCase();
      if (_sightedSince(seq, [id]).isNotEmpty) return;
      final near = nearRead.sightings;
      _followedNear = near;
      _followedWide = wide;
      // The map's window too: closing the sheet keeps the newest answer
      // instead of going back to the viewport's older one.
      _sighted(seq, [id]);
      sightings = {
        for (final MapEntry(:key, :value) in sightings.entries)
          if (key != id) key: value,
        id: ?near[id],
      };
      closures = {
        for (final MapEntry(:key, :value) in closures.entries)
          if (key != id) key: value,
        id: ?nearRead.closures[id],
      };
      notifyListeners();
    } catch (_) {}
  }

  /// Sends a rider's sighting; it shows at once, and the spot is read
  /// again for what other riders say.
  Future<void> submitSighting(SightingReport report) async {
    await sightingsSource.submit(report);
    if (!report.closed) {
      _sent
        ..removeWhere(
          (s) =>
              s.report.spotId == report.spotId &&
              s.report.vehicle == report.vehicle &&
              s.report.areaId == report.areaId,
        )
        ..add(_SentSighting(report, clock(), riderId));
    }
    notifyListeners();
    // What others say follows on its own: it never holds up the sent report.
    unawaited(readFollowedSightings());
  }

  /// The summaries of [spots], or null when the read fails.
  Future<SightingsRead?> _readSightings(List<ParkingSpot> spots) async {
    if (!sightingsSource.enabled) return const SightingsRead({});
    try {
      return await sightingsSource.read(
        spots,
        windowMinutes: sightingMapWindow,
      );
    } catch (_) {
      return null;
    }
  }

  /// The last summaries of the spots still watched, for when a read fails.
  Map<String, List<SpotSighting>> _keptSightings(List<ParkingSpot> spots) =>
      _kept(sightings, spots);

  /// [_keptSightings] for [closures].
  Map<String, List<v1.SpotClosure>> _keptClosures(List<ParkingSpot> spots) =>
      _kept(closures, spots);

  Map<String, T> _kept<T>(Map<String, T> bySpot, List<ParkingSpot> spots) {
    final ids = {for (final spot in _watched(spots)) spot.id.toLowerCase()};
    return {
      for (final MapEntry(:key, :value) in bySpot.entries)
        if (ids.contains(key)) key: value,
    };
  }

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
  List<ParkingSpot> favorites = [];
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
    unawaited(refreshAvailabilityBeta());
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
          onSubscribed: () {
            unawaited(checkForUpdates());
            // A rejoin means the network is back.
            unawaited(hiddenRiders.syncPending());
          },
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
        unawaited(hiddenRiders.foregrounded());
        unawaited(refreshAvailabilityBeta());
        _resumeAvailability();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // No polling in the background.
        _foreground = false;
        _stopAvailability();
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Whether the map is on screen (another tab covers it otherwise). While
  /// it is not, polling keeps only favourites and open sheets up to date.
  void setMapShown(bool shown) {
    if (_mapShown == shown) return;
    _mapShown = shown;
    _stopAvailability();
    _resumeAvailability();
  }

  /// Back on screen: reads at once when the last read is a poll interval
  /// old, otherwise waits out the rest of it.
  void _resumeAvailability() {
    final poll = availabilityPoll;
    if (poll == null || !_foreground || !_readsWanted) return;
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
        !_readsWanted ||
        !availabilitySource.enabled) {
      return;
    }
    _availabilityTimer = Timer(delay, () => unawaited(pollAvailability()));
    _availabilityClock ??= Timer.periodic(const Duration(minutes: 1), (_) {
      // The pills' ages move on, and riders' reports age out.
      if (!_disposed &&
          (availability.isNotEmpty ||
              sightings.isNotEmpty ||
              closures.isNotEmpty)) {
        notifyListeners();
      }
    });
  }

  void _stopAvailability() {
    _availabilityTimer?.cancel();
    _availabilityClock?.cancel();
    _availabilityClock = null;
  }

  /// Reads the counts of the loaded spots again, without reloading the
  /// spots. A viewport load started meanwhile wins: its spots and counts
  /// are newer, so this result is dropped. A failed read keeps the last
  /// counts, which age on screen by their source time (delayed, then
  /// stale), and backs off.
  Future<void> pollAvailability() async {
    _availabilityTimer?.cancel();
    final current = spots;
    // With the map covered, only what is still on screen.
    final reading = _watched(_mapShown ? current : const []);
    if (_disposed || !availabilitySource.enabled || reading.isEmpty) return;
    final request = _request, read = ++_availabilityRead;
    final seq = ++_sightingsSeq;
    unawaited(readFollowedSightings());
    final (counts, sighted) = await (
      _readAvailability(reading),
      _readSightings(reading),
    ).wait;
    if (_disposed ||
        request != _request ||
        read != _availabilityRead ||
        !identical(current, spots)) {
      return;
    }
    // A read replaces what it covered; the rest stays for when the map
    // comes back.
    final readIds = {for (final spot in reading) spot.id};
    final sightedIds = {for (final id in readIds) id.toLowerCase()};
    // Spots a later read answered keep that answer.
    final newer = _sightedSince(seq, sightedIds);
    if (sighted != null) _sightedInView(seq, sightedIds.difference(newer));
    availability = {
      for (final MapEntry(:key, :value) in _keptAvailability(current).entries)
        if (counts == null || !readIds.contains(key)) key: value,
      ...?counts,
    };
    bool keep(String key) =>
        sighted == null || !sightedIds.contains(key) || newer.contains(key);
    sightings = {
      for (final MapEntry(:key, :value) in _keptSightings(current).entries)
        if (keep(key)) key: value,
      if (sighted != null)
        for (final MapEntry(:key, :value) in sighted.sightings.entries)
          if (!newer.contains(key)) key: value,
    };
    closures = {
      for (final MapEntry(:key, :value) in _keptClosures(current).entries)
        if (keep(key)) key: value,
      if (sighted != null)
        for (final MapEntry(:key, :value) in sighted.closures.entries)
          if (!newer.contains(key)) key: value,
    };
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

  /// The last counts of the spots still watched, for when a read fails.
  Map<String, SpotAvailability> _keptAvailability(List<ParkingSpot> spots) {
    final ids = {for (final spot in _watched(spots)) spot.id};
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
      // The last download over the bundled file, rule by rule.
      final offline = await offlineRules(rulesRepository.cache);
      rules = offline.rules;
      error = rulesWarning = rulesFallbackWarning(offline.cachedAt);
    }
    // The holidays ride along with the rules; a failed read keeps the
    // copy in use, which says so only for a year it lacks.
    try {
      HolidayCalendar.current = await holidayRepository.load(clock());
    } catch (_) {}
  }

  Future<void> refresh() async {
    _viewportTimer?.cancel();
    final request = ++_request;
    final bounds = viewport;
    final account = riderId;
    loading = true;
    notifyListeners();
    try {
      final result = await parking.inViewport(bounds);
      if (_disposed || request != _request) return;
      // `is_own` was read for the account that asked (#280): ask again.
      if (account != riderId) {
        unawaited(refresh());
        return;
      }
      spots = result.spots;
      _loadedOnce = true;
      // A failed count read keeps the last counts of the spots still in
      // view (they age by source time) and never empties the map.
      final read = ++_availabilityRead, seq = ++_sightingsSeq;
      final (counts, sighted) = await (
        _readAvailability(_watched(result.spots)),
        _readSightings(_watched(result.spots)),
      ).wait;
      if (_disposed || request != _request) return;
      // A poll started since read these same spots later: its result wins,
      // so this older one only drops counts of spots out of view.
      availability = read == _availabilityRead
          ? counts ?? _keptAvailability(result.spots)
          : _keptAvailability(result.spots);
      final kept = _keptSightings(result.spots);
      final keptClosures = _keptClosures(result.spots);
      if (read == _availabilityRead && sighted != null) {
        // Spots a later read answered (the details') keep that answer.
        final ids = {
          for (final spot in _watched(result.spots)) spot.id.toLowerCase(),
        };
        final newer = _sightedSince(seq, ids);
        _sightedInView(seq, ids.difference(newer));
        sightings = {
          for (final id in newer) id: ?kept[id],
          for (final MapEntry(:key, :value) in sighted.sightings.entries)
            if (!newer.contains(key)) key: value,
        };
        closures = {
          for (final id in newer) id: ?keptClosures[id],
          for (final MapEntry(:key, :value) in sighted.closures.entries)
            if (!newer.contains(key)) key: value,
        };
      } else {
        sightings = kept;
        closures = keptClosures;
      }
      _scheduleAvailability();
      error = result.warning ?? rulesWarning ?? favoritesWarning;
      truncated = result.truncated;
    } catch (_) {
      if (_disposed || request != _request) return;
      spots = [];
      availability = const {};
      sightings = const {};
      closures = const {};
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
  ///
  /// Riders who closed the spot (A7d ②) make it 不能停 here too, so the
  /// marker and the lists say what the sheet says.
  Eligibility eligible(ParkingSpot spot) {
    final decision = decide(spot);
    final closed = riderClosures(spot);
    if (!closed.any((c) => c.confirmed)) return decision.eligibility;
    final verdict = fourSignVerdict(
      spot,
      vehicle,
      rules,
      now: clock(),
      closures: closed,
      decision: decision,
    );
    return verdict.riderClosed == null
        ? decision.eligibility
        : const Eligibility(EligibilityStatus.notAllowed, '車友回報無法停車');
  }

  /// [eligible] with its basis, zones and prices, for the details sheet;
  /// the same clock as [eligible], so the banner and the marker agree.
  ParkingDecision decide(ParkingSpot spot) {
    if (useParkingDecision) {
      // Every rule of the city, so two that disagree read as a conflict.
      return decideParking(spot, vehicle, rules, now: clock());
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

  /// The rider's answer to the picker forms' explanation (N1c, #462). The
  /// forms look nothing up by themselves unless it is granted; 帳號與設定
  /// changes it too, and an open form follows at once.
  LookupConsent get lookupConsent => _lookupConsent;
  late LookupConsent _lookupConsent = local.lookupConsent;

  /// Whether the picker forms may look the marker up by themselves.
  bool get autoLookup => _lookupConsent == LookupConsent.granted;

  /// Takes effect at once, then is saved on the device.
  Future<void> setLookupConsent(LookupConsent value) async {
    if (value == _lookupConsent) return;
    _lookupConsent = value;
    notifyListeners();
    await local.setLookupConsent(value);
  }

  /// The county or city and district at a position (國土測繪中心); tests
  /// override it to stay offline. The picker forms ask only with
  /// [autoLookup].
  Future<Town?> townAt(double lat, double lng) => lookupTown(lat, lng);

  /// Whether the forms may show an approximate door: Google's results may
  /// only sit beside a Google map (Service Specific Terms 6.2), so never on
  /// the OpenStreetMap or empty map, and a demo has no backend to ask.
  bool get approxAddressEnabled => !demo && AppConfig.useGoogleMaps;

  /// The door nearest a position (Google, through `geocode`); tests override
  /// it. Throws [AddressSearchException].
  Future<ApproxAddress?> approxAddressAt(double lat, double lng) =>
      parking.approxAddress(lat, lng);

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
    _favoritesChanged();
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
        _favoritesChanged();
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
    await _loadFavoriteHandles();
    if (key != favoritesKey || _disposed) return;
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
      // The snapshot drops the handle: keep the one in hand.
      if (handleOf(spot) case final handle?) {
        favoriteHandles = {...favoriteHandles, spot.id: handle};
      }
      if (ownSpot(spot)) favoriteOwn = {...favoriteOwn, spot.id};
      _favoritesChanged();
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
        if (viewport.contains(spot.lat, spot.lng)) {
          spots = [..._loadedSpots, spot];
        }
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

  /// Signs in. Closing a native panel is no failure, so nothing to report.
  Future<void> signIn(OAuthProvider provider) async {
    try {
      await authFlow!.signIn(provider);
    } on SignInCancelled {
      return;
    }
  }

  Future<void> signOut() async {
    await client?.auth.signOut();
  }

  /// Drops a session the backend no longer accepts, so signing in can start
  /// over (A7c). A failure leaves it as it was.
  Future<void> endExpiredSession() async {
    try {
      await client?.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }

  Future<void> updateProfile({required String displayName}) async {
    final backend = client;
    if (backend == null) throw StateError('請先登入再編輯個人資料');
    await ProfileRepository(backend).update(displayName: displayName);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _viewportTimer?.cancel();
    _updateTimer?.cancel();
    _stopAvailability();
    if (_observingLifecycle) WidgetsBinding.instance.removeObserver(this);
    unawaited(_auth?.cancel());
    unawaited(_updates?.cancel());
    hiddenRiders
      ..removeListener(_hiddenRidersChanged)
      ..dispose();
    super.dispose();
  }
}

Future<void> navigateTo(double lat, double lng) =>
    navigation.launchNavigation(lat, lng);

/// [AppStore]'s reports for one window, read when asked: the vehicle and
/// the clock are the store's at that moment.
class _StoreRiderSeats implements RiderSeats {
  const _StoreRiderSeats(this.store, this.windowMinutes);
  final AppStore store;
  final int windowMinutes;

  @override
  List<RiderSeat> of(String spotId) {
    final id = spotId.toLowerCase();
    final followed = store._followed?.id.toLowerCase() == id;
    // Until a followed read lands, or when it fails, the viewport's rows
    // still say what riders reported.
    final rows = !followed
        ? store.sightings[id]
        : (windowMinutes == sightingDetailWindow
                  ? store._followedWide[id]
                  : store._followedNear[id]) ??
              store.sightings[id];
    final oldest = store.clock().subtract(Duration(minutes: windowMinutes));
    final seats = [
      for (final row in rows ?? const <SpotSighting>[])
        if (row.vehicle == store.vehicle.name)
          if (riderSeatOf(row) case final seat? when seat.at.isAfter(oldest))
            seat,
    ];
    final covered = {for (final seat in seats) seat.areaId};
    return [
      ...seats,
      for (final sent in store._sent)
        if (sent.report.spotId.toLowerCase() == id &&
            sent.report.vehicle == store.vehicle &&
            sent.rider == store.riderId &&
            sent.at.isAfter(oldest) &&
            !covered.contains(sent.report.areaId))
          RiderSeat(
            level: sent.report.level!,
            at: sent.at,
            areaId: sent.report.areaId,
          ),
    ];
  }
}

/// A report this rider sent, and who was signed in.
class _SentSighting {
  const _SentSighting(this.report, this.at, this.rider);
  final SightingReport report;
  final DateTime at;
  final String? rider;
}
