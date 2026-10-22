import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../data/app_store.dart';
import '../../domain/eligibility.dart';
import '../../domain/map_viewport.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../report/report_sheet.dart';
import 'map_legend.dart';
import 'spot_sheet.dart';
import 'google_parking_map.dart';

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
  bool searchResultsSuppressed = false;

  /// Kept for dispose, where `ref` can no longer be read.
  late final launchStore = ref.read(storeProvider);
  SpaceType? type;
  bool greeted = false;
  late final AppLifecycleListener lifecycle;

  @override
  void initState() {
    super.initState();
    searchFocus.addListener(_searchChanged);
    searchController.addListener(_searchChanged);
    unawaited(_followLaunchLocation(launchStore));
    launchStore.addListener(_afterLaunch);
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

  /// A settled failure is prompted before the legend; a fix still pending
  /// (slow GPS, or the system permission dialog) is prompted after it.
  Future<void> _greet(AppStore store) async {
    // Read once: the fix may settle while the legend is open.
    final pending = store.locatingAtLaunch;
    if (!pending) await _promptLocation(store);
    if (store.introduceLegend && mounted) {
      unawaited(store.markLegendSeen());
      await showMapLegend(context, store.vehicle);
    }
    if (pending) {
      await store.launchLocation;
      await _promptLocation(store);
    }
  }

  Future<void> _promptLocation(AppStore store) async {
    if (!mounted) return;
    if (store.locationIssue case final issue?) {
      await showLocationPrompt(context, issue);
    }
  }

  /// Back from the settings the prompt opened: locate if access now works,
  /// without asking for permission again.
  Future<void> _relocateAfterSettings() async {
    final store = launchStore;
    if (store.locationIssue == null) return;
    if (await store.locateOnLaunch(request: false) && mounted) {
      await _moveCamera(LatLng(store.lat, store.lng), 16);
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

  void _selectSpot(AppStore store, ParkingSpot spot) {
    searchResultsSuppressed = true;
    searchController.text = spot.name;
    searchFocus.unfocus();
    unawaited(
      runAction(context, () => _moveCamera(LatLng(spot.lat, spot.lng), 17)),
    );
    showSpot(context, store, spot);
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
  });

  void _openSpaceSelector() {
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          SheetTitle('格位類型'),
          const SizedBox(height: 12),
          for (final option in <SpaceType?>[null, ...SpaceType.values])
            ListTile(
              title: Text(option?.label ?? '全部格位'),
              trailing: type == option ? const Icon(Icons.check) : null,
              onTap: () {
                setState(() => type = option);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _moveCamera(LatLng point, double zoom) async {
    if (AppConfig.useGoogleMaps) {
      await googleMap.currentState?.moveTo(point, zoom);
    } else {
      controller.move(point, zoom);
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

  void openVehicleSelector(AppStore store) {
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          SheetTitle('選擇車種'),
          const SizedBox(height: 20),
          VehicleSelector(
            value: store.vehicle,
            onChanged: (v) {
              store.setVehicle(v);
              Navigator.pop(ctx);
            },
          ),
          const Divider(height: 32),
          MapLegend(vehicle: store.vehicle),
          const SizedBox(height: 4),
          const Text('社群資訊可能有延遲，停車前請確認現場標示。'),
        ],
      ),
    );
  }

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
              (type == null || s.spaceType == type) &&
              // Pending reports reach notAllowed only through legal rules
              // (see eligibility()), so hiding them here is intended.
              (!hideDenied ||
                  store.eligible(s).status != EligibilityStatus.notAllowed),
        )
        .toList();
    // Most parkable first; List.sort is not stable, so tie-break by input order.
    final ranked = [
      for (final (i, s) in spots.indexed)
        if ('${s.name} ${s.city} ${s.district} ${s.note}'
            .toLowerCase()
            .contains(query))
          (store.eligible(s).status.index, i, s),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    final matches = [for (final (_, _, s) in ranked) s];
    final filtered = type != null || hideDenied;
    final searchHeight = 32 + MediaQuery.textScalerOf(context).scale(20);
    final filterHeight = (16 + MediaQuery.textScalerOf(context).scale(15))
        .clamp(40.0, double.infinity);
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
            location: store.located ? LatLng(store.lat, store.lng) : null,
            onViewport: (bounds, center) {
              store.mapLat = center.latitude;
              store.mapLng = center.longitude;
              store.queueViewport(bounds);
            },
            onSpotTap: (spot) => showSpot(context, store, spot),
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
              if (AppConfig.showsOsmTiles)
                ColorFiltered(
                  colorFilter: ColorFilter.matrix(
                    darkMap
                        ? const [
                            -.72,
                            0,
                            0,
                            0,
                            210,
                            0,
                            -.64,
                            0,
                            0,
                            224,
                            0,
                            0,
                            -.5,
                            0,
                            238,
                            0,
                            0,
                            0,
                            1,
                            0,
                          ]
                        : const [
                            1,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                          ],
                  ),
                  child: TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'tw.motopark.motorcycle_parking',
                  ),
                ),
              MarkerClusterLayerWidget(
                options: MarkerClusterLayerOptions(
                  maxClusterRadius: 45,
                  size: const Size(46, 46),
                  markers: [
                    for (final s in spots)
                      Marker(
                        point: LatLng(s.lat, s.lng),
                        width: 48,
                        height: 48,
                        child: Semantics(
                          label: '${s.name} ${store.eligible(s).label}',
                          button: true,
                          child: GestureDetector(
                            onTap: () => showSpot(context, store, s),
                            child: SpotMarker(
                              status: store.eligible(s).status,
                              pending: s.status == TrustStatus.pending,
                            ),
                          ),
                        ),
                      ),
                  ],
                  builder: (context, markers) => Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.surface, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Color(0x26000000), blurRadius: 8),
                      ],
                    ),
                    child: Text(
                      '${markers.length}',
                      style: TextStyle(
                        color: colors.onPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
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
                            onTap: _openSpaceSelector,
                          ),
                          _MapPill(
                            label: '隱藏不可停',
                            icon: Icons.block,
                            selected: hideDenied,
                            onTap: () =>
                                setState(() => hideDenied = !hideDenied),
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
                  // Reference, not a filter: a small corner button, the way
                  // map apps place their layer and legend controls.
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        top: 8,
                        end: 16,
                      ),
                      child: SizedBox.square(
                        dimension: 44,
                        child: _MapIconPill(
                          key: const ValueKey('map-legend-button'),
                          tooltip: '地圖怎麼看',
                          icon: Icons.help_outline,
                          onTap: () => showMapLegend(context, store.vehicle),
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
                                    status: store.eligible(spot).status,
                                    pending: spot.status == TrustStatus.pending,
                                    size: 28,
                                  ),
                                ),
                              ),
                              title: Text(spot.name),
                              subtitle: Text(
                                [
                                  '${spot.city}${spot.district}',
                                  store.eligible(spot).label,
                                  spot.spaceType.label,
                                  if (spot.feeNote.trim().isNotEmpty &&
                                      spot.feeNote != '請依現場公告')
                                    spot.feeNote,
                                ].join(' · '),
                                maxLines: 2,
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
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
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
              size: 20,
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
