import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../data/app_store.dart';
import '../../domain/space_filter.dart';
import '../../domain/availability_display.dart';
import '../../domain/capsule_layout.dart';
import '../../domain/eligibility.dart';
import '../../domain/map_viewport.dart';
import '../../domain/spot_clusters.dart';
import '../../models/parking.dart';
import '../../models/space_kind.dart';
import '../../ui/adaptive/adaptive.dart';
import '../report/report_sheet.dart';
import 'availability_capsule.dart';
import 'map_legend.dart';
import 'space_type_sheet.dart';
import 'spot_sheet.dart';
import 'vehicle_sheet.dart';
import 'google_parking_map.dart';
import 'osm_tiles.dart';
import 'cluster_badge.dart';

class MapPage extends ConsumerStatefulWidget {
  const MapPage({super.key, this.showControls = true});
  final bool showControls;
  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage> {
  final controller = MapController();
  final googleMap = GlobalKey<GoogleParkingMapState>();
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  bool hideDenied = false;

  /// 「目前有位」 or 「有即時資訊」; only offered while live counts exist.
  AvailabilityFilter availabilityFilter = AvailabilityFilter.off;
  bool searchResultsSuppressed = false;

  /// The spot whose details are open over the map. The sheet is part of this
  /// page, not a route, so the map stays movable and other spots tappable.
  ParkingSpot? selected;

  /// The spot sheet sits on the root overlay, over the tab bar as in map
  /// apps, while the rest of the map still takes gestures.
  final sheetPortal = OverlayPortalController()..show();

  /// Kept for dispose, where `ref` can no longer be read.
  late final launchStore = ref.read(storeProvider);
  SpaceKind? type;
  bool greeted = false;
  bool promptDeferred = false;
  late final AppLifecycleListener lifecycle;

  @override
  void initState() {
    super.initState();
    searchFocus.addListener(_searchChanged);
    searchController.addListener(_searchChanged);
    unawaited(_followLaunchLocation(launchStore));
    launchStore.addListener(_afterLaunch);
    if (!widget.showControls) launchStore.setMapShown(false);
    lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_relocateAfterSettings()),
    );
  }

  /// Runs once the launch screen lifts: the location prompt and, on first
  /// launch, the legend, one after the other.
  void _afterLaunch() {
    final store = launchStore;
    if (greeted ||
        store.starting ||
        store.launchLocation == null ||
        !widget.showControls) {
      return;
    }
    greeted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_greet(store));
    });
  }

  @override
  void didUpdateWidget(MapPage old) {
    super.didUpdateWidget(old);
    // Live counts are polled only while the map is on screen.
    if (widget.showControls != old.showControls) {
      launchStore.setMapShown(widget.showControls);
    }
    // Another tab covers the map: its details close with it.
    if (!widget.showControls) selected = null;
    if (!widget.showControls || old.showControls) return;
    // Launched into another tab: greet once the map is first shown.
    _afterLaunch();
    if (promptDeferred) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_promptLocation(launchStore)),
      );
    }
  }

  /// A settled failure is prompted before the legend; a fix still pending
  /// (slow GPS, or the system permission dialog) is prompted after it.
  Future<void> _greet(AppStore store) async {
    // Read once: the fix may settle while the legend is open.
    final pending = store.locatingAtLaunch;
    if (!pending) await _promptLocation(store);
    if (store.introduceLegend && mounted) {
      unawaited(store.markLegendSeen());
      await showMapLegend(
        context,
        store.vehicle,
        availability: store.availabilitySource.enabled,
      );
    }
    if (pending) {
      await store.launchLocation;
      await _promptLocation(store);
    }
  }

  /// A failure that settles while another tab covers the map waits until
  /// the map is shown again.
  Future<void> _promptLocation(AppStore store) async {
    if (!mounted) return;
    promptDeferred = !widget.showControls;
    if (promptDeferred) return;
    if (store.locationIssue case final issue?) {
      await showLocationPrompt(context, issue);
    }
  }

  /// Back from the settings the prompt opened: locate if access now works,
  /// without asking for permission again. Fixing one blocker can reveal the
  /// next (services on, permission still denied), which is prompted in turn.
  Future<void> _relocateAfterSettings() async {
    final store = launchStore;
    final before = store.locationIssue;
    if (before == null) return;
    if (await store.locateOnLaunch(request: false)) {
      if (mounted) await _moveCamera(LatLng(store.lat, store.lng), 16);
    } else if (store.locationIssue != before) {
      await _promptLocation(store);
    }
  }

  /// Centers on the launch fix unless the user already panned the map,
  /// which can happen when the fix arrives after the launch screen.
  Future<void> _followLaunchLocation(AppStore store) async {
    final start = LatLng(store.mapLat, store.mapLng);
    if (!(await store.launchLocation ?? false)) return;
    // FlutterMap's controller can only move once the map has laid out.
    await WidgetsBinding.instance.endOfFrame;
    const distance = Distance();
    if (!mounted || distance(start, LatLng(store.mapLat, store.mapLng)) > 50) {
      return;
    }
    await _moveCamera(LatLng(store.lat, store.lng), 16);
  }

  void _searchChanged() {
    if (mounted) setState(() {});
  }

  void _updateViewport(AppStore store, MapCamera camera) {
    store.mapLat = camera.center.latitude;
    store.mapLng = camera.center.longitude;
    final b = camera.visibleBounds;
    store.queueViewport(
      MapViewport(south: b.south, west: b.west, north: b.north, east: b.east),
    );
  }

  /// From search: zooms in on the spot as well.
  void _selectSpot(AppStore store, ParkingSpot spot) {
    searchResultsSuppressed = true;
    searchController.text = spot.name;
    searchFocus.unfocus();
    _showSpot(spot, zoom: 17);
  }

  /// Centers the selected point above the panel once. Closing the panel
  /// preserves the resulting camera position, as in Google Maps.
  void _showSpot(ParkingSpot spot, {double? zoom}) {
    setState(() => selected = spot);
    unawaited(
      runAction(
        context,
        () => _moveCamera(LatLng(spot.lat, spot.lng), zoom, above: true),
      ),
    );
  }

  void _closeSpot() {
    if (selected != null) setState(() => selected = null);
  }

  void _submitSearch(AppStore store, List<ParkingSpot> matches) {
    if (searchController.text.trim().isEmpty) return;
    if (matches.length == 1) {
      _selectSpot(store, matches.single);
    } else {
      setState(() => searchResultsSuppressed = false);
      searchFocus.requestFocus();
    }
  }

  void _clearFilters() => setState(() {
    type = null;
    hideDenied = false;
    availabilityFilter = AvailabilityFilter.off;
  });

  void _openSpaceSelector(AppStore store) {
    final inView = store.spots
        .where((s) => store.viewport.contains(s.lat, s.lng))
        .toList();
    showSpaceTypeSheet(
      context,
      value: type,
      counts: {
        null: inView.length,
        for (final option in SpaceKind.values)
          option: inView
              .where((s) => matchesSpaceFilter(s, option, store.vehicle))
              .length,
      },
      onChanged: (option) => setState(() => type = option),
    );
  }

  /// Keeps the current zoom when [zoom] is null.
  Future<void> _moveCamera(
    LatLng point,
    double? zoom, {
    bool above = false,
  }) async {
    var inset = 0.0;
    if (above) {
      final screen = MediaQuery.sizeOf(context);
      final box = context.findRenderObject() as RenderBox;
      final gap =
          screen.height - box.localToGlobal(Offset(0, box.size.height)).dy;
      final panel =
          (screen.height - MediaQuery.paddingOf(context).top) * spotSheetPeek;
      final mapPadding = AppConfig.useGoogleMaps
          ? 8 + MediaQuery.paddingOf(context).bottom
          : 0;
      inset = (panel - gap - mapPadding).clamp(0, double.infinity) / 2;
    }
    if (AppConfig.useGoogleMaps) {
      await googleMap.currentState?.moveTo(point, zoom, abovePanel: inset);
    } else {
      controller.move(
        point,
        zoom ?? controller.camera.zoom,
        offset: Offset(0, -inset),
      );
    }
  }

  Widget _interceptOverlay(Widget overlay) {
    if (!kIsWeb || !AppConfig.useGoogleMaps) return overlay;
    if (overlay is Positioned) {
      return Positioned(
        left: overlay.left,
        top: overlay.top,
        right: overlay.right,
        bottom: overlay.bottom,
        width: overlay.width,
        height: overlay.height,
        child: PointerInterceptor(child: overlay.child),
      );
    }
    return PointerInterceptor(child: overlay);
  }

  @override
  void dispose() {
    launchStore.removeListener(_afterLaunch);
    lifecycle.dispose();
    controller.dispose();
    searchFocus.removeListener(_searchChanged);
    searchController.removeListener(_searchChanged);
    searchFocus.dispose();
    searchController.dispose();
    super.dispose();
  }

  void openVehicleSelector(AppStore store) => showVehicleSheet(
    context,
    value: store.vehicle,
    onChanged: store.setVehicle,
  );

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final darkMap = colors.brightness == Brightness.dark;
    // iOS extends the map behind the floating tab bar; Scaffold reports its
    // height here (0 on Android, where the body already ends above the bar).
    final tabBarInset = MediaQuery.paddingOf(context).bottom;
    final query = searchController.text.trim().toLowerCase();
    final visible = store.spots.where(
      (s) => store.viewport.contains(s.lat, s.lng),
    );
    final spots = visible
        .where(
          (s) =>
              (type == null || matchesSpaceFilter(s, type!, store.vehicle)) &&
              // Pending reports reach notAllowed only through legal rules
              // (see eligibility()), so hiding them here is intended.
              (!hideDenied ||
                  store.eligible(s).status != EligibilityStatus.notAllowed),
        )
        .toList();
    // Spots an availability filter leaves out stay on the map as grey dots,
    // with the reason kept for the empty-result card.
    final now = store.clock();
    final liveFilter = store.availabilitySource.enabled
        ? availabilityFilter
        : AvailabilityFilter.off;
    final excluded = <(ParkingSpot, AvailabilityExclusion)>[];
    if (liveFilter != AvailabilityFilter.off) {
      spots.removeWhere((s) {
        final reason = availabilityExclusion(
          liveFilter,
          s,
          store.availabilityOf(s),
          store.vehicle,
          store.eligible(s).status,
          now,
        );
        if (reason != null) excluded.add((s, reason));
        return reason != null;
      });
    }
    // Most parkable first; List.sort is not stable, so tie-break by input order.
    final ranked = [
      for (final (i, s) in spots.indexed)
        if ('${s.name} ${s.city} ${s.district} ${s.note}'
            .toLowerCase()
            .contains(query))
          (store.eligible(s).status.index, i, s),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    final matches = [for (final (_, _, s) in ranked) s];
    final filtered =
        type != null || hideDenied || liveFilter != AvailabilityFilter.off;
    final searchHeight = 32 + MediaQuery.textScalerOf(context).scale(20);
    final filterHeight = (16 + MediaQuery.textScalerOf(context).scale(15))
        .clamp(40.0, double.infinity);
    final open = widget.showControls ? selected : null;
    return PopScope(
      // Back closes the details before leaving the map.
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSpot();
      },
      child: OverlayPortal(
        controller: sheetPortal,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: (overlay) => open == null
            ? const SizedBox.shrink()
            : Positioned(
                left: 0,
                right: 0,
                top: MediaQuery.paddingOf(overlay).top,
                bottom: 0,
                child: SpotSheet(
                  key: ValueKey(open.id),
                  store: store,
                  spot: open,
                  onClose: _closeSpot,
                ),
              ),
        child: _layers(
          context,
          store,
          colors,
          darkMap: darkMap,
          tabBarInset: tabBarInset,
          spots: spots,
          excluded: excluded,
          liveFilter: liveFilter,
          now: now,
          matches: matches,
          query: query,
          filtered: filtered,
          searchHeight: searchHeight,
          filterHeight: filterHeight,
          open: open,
        ),
      ),
    );
  }

  Widget _layers(
    BuildContext context,
    AppStore store,
    ColorScheme colors, {
    required bool darkMap,
    required double tabBarInset,
    required List<ParkingSpot> spots,
    required List<(ParkingSpot, AvailabilityExclusion)> excluded,
    required AvailabilityFilter liveFilter,
    required DateTime now,
    required List<ParkingSpot> matches,
    required String query,
    required bool filtered,
    required double searchHeight,
    required double filterHeight,
    required ParkingSpot? open,
  }) {
    final openCapsules = open == null
        ? const <AvailabilityCapsule>[]
        : markerCapsules(
            open,
            store.availabilityOf(open),
            store.vehicle,
            store.decide(open),
            now,
          );
    return Stack(
      children: [
        if (AppConfig.useGoogleMaps)
          GoogleParkingMap(
            key: googleMap,
            center: LatLng(store.lat, store.lng),
            spots: spots,
            eligibility: store.eligible,
            interactive:
                widget.showControls &&
                (ModalRoute.of(context)?.isCurrent ?? true),
            panelVisible: !widget.showControls,
            selected: open,
            onMapTap: _closeSpot,
            location: store.located ? LatLng(store.lat, store.lng) : null,
            onViewport: (bounds, center) {
              store.mapLat = center.latitude;
              store.mapLng = center.longitude;
              store.queueViewport(bounds);
            },
            onSpotTap: _showSpot,
            onLongPress: (point) =>
                showReport(context, store, point.latitude, point.longitude),
          )
        else
          FlutterMap(
            mapController: controller,
            options: MapOptions(
              initialCenter: LatLng(store.lat, store.lng),
              initialZoom: 16,
              backgroundColor: darkMap
                  ? const Color(0xff142130)
                  : const Color(0xffe6eee9),
              onMapReady: () => _updateViewport(store, controller.camera),
              onMapEvent: (event) {
                if (event is MapEventNonRotatedSizeChange) {
                  _updateViewport(store, event.camera);
                }
              },
              onPositionChanged: (camera, hasGesture) {
                _updateViewport(store, camera);
              },
              onTap: (_, _) => _closeSpot(),
              onLongPress: widget.showControls
                  ? (tap, point) => showReport(
                      context,
                      store,
                      point.latitude,
                      point.longitude,
                    )
                  : null,
            ),
            children: [
              if (AppConfig.showsOsmTiles) OsmTiles(dark: darkMap),
              if (excluded.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (final (s, _) in excluded)
                      if (s.id != open?.id)
                        Marker(
                          point: LatLng(s.lat, s.lng),
                          width: 48,
                          height: 48,
                          child: Semantics(
                            label:
                                '${s.name}，不符合「${availabilityFilterLabel(liveFilter)}」',
                            button: true,
                            child: GestureDetector(
                              onTap: () => _showSpot(s),
                              child: const ExcludedSpotDot(),
                            ),
                          ),
                        ),
                  ],
                ),
              Builder(
                builder: (mapContext) {
                  final camera = MapCamera.of(mapContext);
                  final zoom = camera.zoom;
                  final groups = clusterSpots(
                    spots.where((s) => s.id != open?.id).toList(),
                    zoom,
                  );
                  // Crowded markers keep only the rider's own count, and
                  // pills that would touch the open spot's set hide.
                  final pills = {
                    for (final s in [
                      for (final group in groups)
                        if (group.spots.length == 1) ...group.spots,
                      ?open,
                    ])
                      s.id: (
                        s,
                        markerCapsules(
                          s,
                          store.availabilityOf(s),
                          store.vehicle,
                          store.decide(s),
                          now,
                        ),
                      ),
                  };
                  final layout = layoutCapsules([
                    for (final (s, capsules) in pills.values)
                      if (s.id == open?.id)
                        CapsuleItem(
                          id: s.id,
                          center: camera.latLngToScreenOffset(
                            LatLng(s.lat, s.lng),
                          ),
                          fullWidth: capsuleRowWidth(capsules, scale: 26 / 24),
                          markerSize: 38 * selectedScale,
                          height: 26,
                        )
                      else
                        CapsuleItem(
                          id: s.id,
                          center: camera.latLngToScreenOffset(
                            LatLng(s.lat, s.lng),
                          ),
                          fullWidth: capsuleRowWidth(capsules),
                          primaryWidth: capsuleRowWidth(
                            primaryCapsules(
                              s,
                              store.vehicle,
                              store.decide(s),
                              capsules,
                            ),
                          ),
                        ),
                  ], selected: open?.id);
                  List<AvailabilityCapsule> shown(ParkingSpot s) {
                    final capsules = pills[s.id]?.$2 ?? const [];
                    return switch (layout[s.id]) {
                      CapsuleShow.primary => primaryCapsules(
                        s,
                        store.vehicle,
                        store.decide(s),
                        capsules,
                      ),
                      CapsuleShow.none => const [],
                      _ => capsules,
                    };
                  }

                  return MarkerLayer(
                    markers: [
                      for (final group in groups)
                        if (group.spots.length > 1)
                          Marker(
                            point: group.center,
                            width: clusterBadgeSize,
                            height: clusterBadgeSize,
                            child: Semantics(
                              label: '${group.spots.length} 個停車點，點選放大',
                              button: true,
                              child: GestureDetector(
                                onTap: () => controller.move(
                                  group.center,
                                  (zoom + 2).clamp(0, 20).toDouble(),
                                ),
                                child: ClusterBadge(count: group.spots.length),
                              ),
                            ),
                          )
                        else
                          for (final s in group.spots)
                            if (shown(s) case final capsules)
                              Marker(
                                point: LatLng(s.lat, s.lng),
                                width: capsules.isEmpty ? 48 : capsuleBoxWidth,
                                height: capsules.isEmpty
                                    ? 48
                                    : capsuleBoxHeight,
                                child: Semantics(
                                  label: '${s.name} ${store.eligible(s).label}',
                                  button: true,
                                  child: GestureDetector(
                                    onTap: () => _showSpot(s),
                                    child: MarkerWithCapsules(
                                      capsules: capsules,
                                      marker: SpotMarker(
                                        look: markerLook(store.eligible(s)),
                                        badge: spaceBadge(s),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                    ],
                  );
                },
              ),
              // Outside the clusters, so the open spot never folds away.
              if (open != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(open.lat, open.lng),
                      width: openCapsules.isEmpty ? 56 : capsuleBoxWidth,
                      height: openCapsules.isEmpty ? 56 : capsuleBoxHeight,
                      child: Semantics(
                        label: '${open.name} ${store.eligible(open).label}，已選取',
                        button: true,
                        // Its own tap, as on the Google map: never a tap on
                        // the empty map, which would close the details.
                        child: GestureDetector(
                          onTap: () => _showSpot(open),
                          child: MarkerWithCapsules(
                            capsules: openCapsules,
                            boxSize: 56,
                            selected: true,
                            marker: SpotMarker(
                              key: const ValueKey('selected-spot-marker'),
                              look: markerLook(store.eligible(open)),
                              badge: spaceBadge(open),
                              selected: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (store.located)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(store.lat, store.lng),
                      width: 30,
                      height: 30,
                      child: Semantics(
                        label: '我的位置',
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xff2879ef),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x442879ef),
                                blurRadius: 16,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        if (widget.showControls) ...[
          for (final overlay in <Widget>[
            SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: Material(
                      color: colors.surface,
                      elevation: 4,
                      shadowColor: const Color(0x44000000),
                      borderRadius: BorderRadius.circular(34),
                      child: SizedBox(
                        height: searchHeight,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 16,
                                right: 10,
                              ),
                              child: Icon(
                                Icons.local_parking_rounded,
                                color: colors.primary,
                                size: 26,
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                key: const ValueKey('parking-search'),
                                controller: searchController,
                                focusNode: searchFocus,
                                textInputAction: TextInputAction.search,
                                style: const TextStyle(fontSize: 18),
                                onTap: () => setState(
                                  () => searchResultsSuppressed = false,
                                ),
                                onChanged: (_) => setState(
                                  () => searchResultsSuppressed = false,
                                ),
                                onTapOutside: (_) => searchFocus.unfocus(),
                                onSubmitted: (_) =>
                                    _submitSearch(store, matches),
                                decoration: InputDecoration(
                                  hintText: '搜尋此範圍停車點',
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  suffixIcon: searchController.text.isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: '清除搜尋',
                                          onPressed: searchController.clear,
                                          icon: const Icon(
                                            Icons.close,
                                            size: 20,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            TextFieldTapRegion(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: IconButton.filledTonal(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: '搜尋停車點',
                                  onPressed: query.isEmpty
                                      ? null
                                      : () => _submitSearch(store, matches),
                                  icon: const Icon(Icons.search),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: filterHeight,
                    // Few pills: build all of them so none is skipped lazily.
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _MapPill(
                            label: store.vehicle.label,
                            showChevron: true,
                            icon: store.vehicle == VehicleType.heavy
                                ? Icons.sports_motorsports_outlined
                                : Icons.two_wheeler,
                            onTap: () => openVehicleSelector(store),
                          ),
                          _MapPill(
                            label: type?.label ?? '全部格位',
                            icon: Icons.local_parking_outlined,
                            showChevron: true,
                            selected: type != null,
                            onTap: () => _openSpaceSelector(store),
                          ),
                          _MapPill(
                            label: '隱藏不可停',
                            icon: Icons.block,
                            selected: hideDenied,
                            onTap: () =>
                                setState(() => hideDenied = !hideDenied),
                          ),
                          if (store.availabilitySource.enabled)
                            _MapPill(
                              key: const ValueKey('availability-filter'),
                              label: availabilityFilterLabel(
                                liveFilter == AvailabilityFilter.off
                                    ? AvailabilityFilter.available
                                    : liveFilter,
                              ),
                              icon: Icons.event_available_outlined,
                              selected: liveFilter != AvailabilityFilter.off,
                              onTap: () => setState(
                                () => availabilityFilter =
                                    liveFilter == AvailabilityFilter.off
                                    ? AvailabilityFilter.available
                                    : AvailabilityFilter.off,
                              ),
                            ),
                          if (filtered)
                            _MapPill(
                              label: '清除篩選',
                              icon: Icons.filter_alt_off_outlined,
                              onTap: _clearFilters,
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Reference, not a filter: a corner button under the
                  // filters on the trailing edge (Main board: 44pt on iOS
                  // 4 below the filters, 48dp on Android 8 below).
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(
                        top: isCupertino ? 4 : 8,
                        end: 16,
                      ),
                      child: SizedBox.square(
                        dimension: isCupertino ? 44 : 48,
                        child: _MapIconPill(
                          key: const ValueKey('map-legend-button'),
                          tooltip: '地圖怎麼看',
                          icon: Icons.help_outline,
                          iconSize: 24,
                          onTap: () => openMapLegend(context, fromMap: true),
                        ),
                      ),
                    ),
                  ),
                  if (store.error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Material(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          title: Text(store.error!),
                          trailing: IconButton(
                            tooltip: '重新整理',
                            onPressed: store.reload,
                            icon: const Icon(Icons.refresh),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (store.mapNotice != null)
              Positioned(
                top:
                    MediaQuery.paddingOf(context).top +
                    searchHeight +
                    filterHeight +
                    22,
                // Clear of the legend button on the trailing edge.
                left: 68,
                right: 68,
                child: Center(
                  child: Material(
                    color: colors.surface,
                    elevation: 2,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(
                        store.mapNotice!,
                        key: const ValueKey('map-notice'),
                      ),
                    ),
                  ),
                ),
              ),
            if (liveFilter != AvailabilityFilter.off &&
                spots.isEmpty &&
                excluded.isNotEmpty &&
                !store.loading)
              Positioned(
                top:
                    MediaQuery.paddingOf(context).top +
                    searchHeight +
                    filterHeight +
                    72,
                left: 16,
                right: 16,
                // Above the two stacked map actions, so the card never
                // covers them; a tall card scrolls instead.
                bottom: tabBarInset + 16 + MapActions.width * 2 + 12 + 16,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: _AvailabilityEmptyCard(
                      filter: liveFilter,
                      vehicle: store.vehicle,
                      excluded: [for (final (_, reason) in excluded) reason],
                      onClear: () => setState(
                        () => availabilityFilter = AvailabilityFilter.off,
                      ),
                      onLiveOnly: liveFilter == AvailabilityFilter.live
                          ? null
                          : () => setState(
                              () =>
                                  availabilityFilter = AvailabilityFilter.live,
                            ),
                    ),
                  ),
                ),
              ),
            if (open == null)
              Positioned(
                right: 16,
                bottom: tabBarInset + 16,
                child: MapActions(
                  onLocate: () => runAction(context, () async {
                    await store.locate();
                    await _moveCamera(LatLng(store.lat, store.lng), 16);
                  }),
                  onRecord: () => showParkingForm(context, store),
                ),
              ),
            // Notice and OSM credit share one column so they never overlap,
            // and stay clear of the record button and the iOS tab bar.
            Positioned(
              left: 16,
              right: 32 + MapActions.width,
              bottom: tabBarInset + (AppConfig.useGoogleMaps ? 76 : 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Only sample data keeps a standing notice; the reminder to
                  // check site signs lives in the legend and vehicle sheet.
                  if (store.demo)
                    Material(
                      color: colors.surface.withValues(alpha: .96),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          '範例資料 · 行駛中請勿操作',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ),
                  if (AppConfig.showsOsmTiles) ...[
                    if (store.demo) const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse('https://www.openstreetmap.org/copyright'),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: colors.surface.withValues(alpha: .96),
                        foregroundColor: colors.onSurfaceVariant,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        '© OpenStreetMap contributors',
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (searchFocus.hasFocus && !searchResultsSuppressed)
              Positioned(
                top: MediaQuery.paddingOf(context).top + searchHeight + 12,
                left: 16,
                right: 16,
                child: TextFieldTapRegion(
                  child: Material(
                    color: colors.surface,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            (MediaQuery.sizeOf(context).height -
                                    MediaQuery.viewInsetsOf(context).bottom -
                                    MediaQuery.paddingOf(context).top -
                                    searchHeight -
                                    108)
                                .clamp(72.0, 320.0),
                      ),
                      child: ListView(
                        key: const ValueKey('parking-search-results'),
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Text(
                              filtered
                                  ? '目前地圖範圍 · 已套用篩選（${matches.length} 筆）'
                                  : '目前地圖範圍內的停車點（${matches.length} 筆）',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          if (matches.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('沒有符合的停車點。請換個關鍵字，或移動地圖查看其他範圍。'),
                            ),
                          if (matches.isEmpty && filtered)
                            TextButton(
                              onPressed: _clearFilters,
                              child: const Text('清除篩選查看結果'),
                            ),
                          for (final spot in matches)
                            ListTile(
                              leading: ExcludeSemantics(
                                child: SizedBox.square(
                                  dimension: 32,
                                  child: SpotMarker(
                                    look: markerLook(store.eligible(spot)),
                                    badge: spaceBadge(spot),
                                    size: 28,
                                  ),
                                ),
                              ),
                              title: Text(spot.name),
                              // Fees live in the details; one line here.
                              subtitle: Text(
                                '${spot.city}${spot.district} · ${store.eligible(spot).label} · ${spot.spaceType.label}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.north_west, size: 18),
                              onTap: () => _selectSpot(store, spot),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ])
            _interceptOverlay(overlay),
        ],
      ],
    );
  }
}

class _MapIconPill extends StatelessWidget {
  const _MapIconPill({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.iconSize = 20,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  @override
  Widget build(BuildContext context) => Material(
    elevation: 2,
    shadowColor: const Color(0x33000000),
    color: Theme.of(context).colorScheme.surface,
    shape: const CircleBorder(),
    child: Semantics(
      button: true,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AspectRatio(
            aspectRatio: 1,
            child: Icon(
              icon,
              size: iconSize,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    ),
  );
}

class _MapPill extends StatelessWidget {
  const _MapPill({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.showChevron = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;
  final bool showChevron;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        elevation: 2,
        shadowColor: const Color(0x33000000),
        color: selected ? colors.primaryContainer : colors.surface,
        borderRadius: BorderRadius.circular(24),
        child: Semantics(
          button: true,
          selected: selected,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurface,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: selected
                          ? colors.onPrimaryContainer
                          : colors.onSurface,
                    ),
                  ),
                  if (showChevron) const Icon(Icons.expand_more, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains an empty 「目前有位」 result: the spots are there, they just
/// have no free space this vehicle can use, and why.
class _AvailabilityEmptyCard extends StatelessWidget {
  const _AvailabilityEmptyCard({
    required this.filter,
    required this.vehicle,
    required this.excluded,
    required this.onClear,
    required this.onLiveOnly,
  });
  final AvailabilityFilter filter;
  final VehicleType vehicle;
  final List<AvailabilityExclusion> excluded;
  final VoidCallback onClear;
  final VoidCallback? onLiveOnly;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final counts = <AvailabilityExclusion, int>{};
    for (final reason in excluded) {
      counts[reason] = (counts[reason] ?? 0) + 1;
    }
    final label = availabilityFilterLabel(filter);
    return Material(
      key: const ValueKey('availability-empty'),
      color: colors.surface,
      elevation: 3,
      shadowColor: const Color(0x33000000),
      borderRadius: BorderRadius.circular(16),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              filter == AvailabilityFilter.available
                  ? '這個範圍沒有「${vehicle.label}$label」的停車點'
                  : '這個範圍沒有${vehicle.label}的即時資訊',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '範圍內 ${excluded.length} 個點都還在，只是都不符合條件：',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 10),
            for (final reason in AvailabilityExclusion.values)
              if (counts[reason] case final count?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '$count',
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          exclusionReason(reason, filter, vehicle),
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: onClear,
                  child: Text('清除「$label」'),
                ),
                if (onLiveOnly != null)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: onLiveOnly,
                    child: const Text('只看有即時資訊'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              filter == AvailabilityFilter.available
                  ? '「目前有位」只列資料新鮮、車種相符、剩餘大於 0、且目前車種可停或有條件可停的點。未知、過期、延遲與不可停都不算。'
                  : '「有即時資訊」只列資料新鮮、車種相符的點，已滿也算。未知、過期與延遲都不算。',
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
