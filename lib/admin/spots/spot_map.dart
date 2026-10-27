import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/eligibility.dart';
import '../../domain/map_viewport.dart';
import '../../features/map/google_parking_map.dart';
import '../../models/parking.dart';
import '../admin_gateway.dart';
import 'spot_models.dart';

/// The spots page map's layers (docs/ADMIN_WEB.md「點位」). Each is
/// independent: hidden spots of either kind form their own layer.
enum SpotLayer {
  official('官方點'),
  community('社群點'),
  hidden('已隱藏');

  const SpotLayer(this.label);
  final String label;
}

/// A spot on the admin map, from `admin_viewport_spots`.
class AdminMapSpot {
  const AdminMapSpot(this.spot, {this.hidden = false});
  final ParkingSpot spot;
  final bool hidden;
}

/// Where the map should move: a spot opened from the list or the URL. [seq]
/// tells a new request from the same one rebuilt.
class SpotMapFocus {
  const SpotMapFocus({
    required this.lat,
    required this.lng,
    required this.seq,
    this.zoom,
    this.leftOfCenter = 0,
  });
  final double lat, lng;

  /// Null keeps the zoom, as when the admin tapped a marker in view.
  final double? zoom;

  /// Pixels left of the map's center to show the spot at, clear of the
  /// panels over the map.
  final double leftOfCenter;
  final int seq;
}

/// What the map part of the spots page shows and reports.
class SpotMapView {
  const SpotMapView({
    required this.center,
    required this.spots,
    required this.eligibility,
    required this.dimmed,
    required this.onViewport,
    required this.onSpotTap,
    this.selected,
    this.focus,
    this.satellite = false,
    this.covered = false,
  });
  final LatLng center;
  final List<ParkingSpot> spots;
  final Eligibility Function(ParkingSpot) eligibility;
  final bool Function(ParkingSpot) dimmed;
  final ValueChanged<MapViewport> onViewport;
  final ValueChanged<ParkingSpot> onSpotTap;
  final ParkingSpot? selected;
  final SpotMapFocus? focus;
  final bool satellite;

  /// The list or form covers the whole map (phone width): no queries.
  final bool covered;
}

typedef SpotMapBuilder = Widget Function(BuildContext, SpotMapView);

Widget googleSpotMap(BuildContext context, SpotMapView view) =>
    _GoogleSpotMap(view: view);

/// The app's Google map and markers (colour, shape, badge, selected ring
/// and clusters), with the admin layers on top.
class _GoogleSpotMap extends StatefulWidget {
  const _GoogleSpotMap({required this.view});
  final SpotMapView view;
  @override
  State<_GoogleSpotMap> createState() => _GoogleSpotMapState();
}

class _GoogleSpotMapState extends State<_GoogleSpotMap> {
  final _map = GlobalKey<GoogleParkingMapState>();

  @override
  void initState() {
    super.initState();
    _follow(null);
  }

  @override
  void didUpdateWidget(covariant _GoogleSpotMap old) {
    super.didUpdateWidget(old);
    _follow(old.view.focus);
  }

  void _follow(SpotMapFocus? old) {
    final focus = widget.view.focus;
    if (focus == null || focus.seq == old?.seq) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _map.currentState?.moveTo(
        LatLng(focus.lat, focus.lng),
        focus.zoom,
        leftOfCenter: focus.leftOfCenter,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    return GoogleParkingMap(
      key: _map,
      center: v.center,
      spots: v.spots,
      eligibility: v.eligibility,
      onViewport: (bounds, _) => v.onViewport(bounds),
      onSpotTap: v.onSpotTap,
      interactive: true,
      panelVisible: v.covered,
      selected: v.selected,
      dimmed: v.dimmed,
      mapType: v.satellite ? gm.MapType.hybrid : gm.MapType.normal,
    );
  }
}

/// Layers, vehicle and the spots in view for the spots page map.
class SpotMapController extends ChangeNotifier {
  SpotMapController(this.gateway);
  final AdminGateway? gateway;

  VehicleType vehicle = VehicleType.scooter;
  Set<SpotLayer> layers = {SpotLayer.official, SpotLayer.community};
  bool satellite = false;

  List<CityRule> rules = [];
  bool _rulesLoaded = false;

  List<AdminMapSpot> spots = [];
  MapViewport? viewport;
  bool loading = false;
  String? error;

  /// A layer had more spots in view than one query returns.
  bool truncated = false;

  /// Each chosen layer's spots shown and in view, when the server counts.
  Map<SpotLayer, ({int shown, int total})> counts = const {};

  /// Spots shown in all, as the limit note says it (1,000 at most).
  int get shownCount => spots.length;

  /// The view is too large to query; the admin zooms in.
  bool tooWide = false;

  int _seq = 0;
  int _generation = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// The spots of [layers]; a layer turned off drops its spots at once.
  List<ParkingSpot> get shown => [
    for (final s in spots)
      if (layers.contains(_layerOf(s))) s.spot,
  ];

  static SpotLayer _layerOf(AdminMapSpot s) => s.hidden
      ? SpotLayer.hidden
      : s.spot.isOfficial
      ? SpotLayer.official
      : SpotLayer.community;

  /// Ids of [spots] by layer, rebuilt with each load: markers ask per spot.
  Set<String> _hiddenIds = {};
  Map<String, ParkingSpot> _byId = {};

  bool isHidden(ParkingSpot spot) => _hiddenIds.contains(spot.id);

  ParkingSpot? find(String id) => _byId[id];

  void _index() {
    _hiddenIds = {
      for (final s in spots)
        if (s.hidden) s.spot.id,
    };
    _byId = {for (final s in spots) s.spot.id: s.spot};
  }

  CityRule? _ruleFor(ParkingSpot spot) {
    final own = rules.where((r) => r.vehicle == vehicle && r.city == spot.city);
    return own.firstOrNull ??
        rules.where((r) => r.vehicle == vehicle && r.city == '全國').firstOrNull;
  }

  /// The marker the app shows for [spot] to a rider of [vehicle].
  Eligibility eligible(ParkingSpot spot) =>
      eligibility(spot, vehicle, _ruleFor(spot));

  void setVehicle(VehicleType value) {
    vehicle = value;
    _notify();
  }

  void setSatellite(bool value) {
    satellite = value;
    _notify();
  }

  void toggle(SpotLayer layer) {
    layers = layers.contains(layer)
        ? ({...layers}..remove(layer))
        : {...layers, layer};
    _notify();
    refresh();
  }

  /// Loads the spots of [bounds]; a newer view wins.
  Future<void> show(MapViewport bounds) async {
    viewport = bounds;
    final gateway = this.gateway;
    if (gateway == null) return;
    final generation = _generation;
    final seq = ++_seq;
    bool current() => generation == _generation && seq == _seq;
    tooWide = !bounds.canQuery;
    if (tooWide || !bounds.intersectsTaiwan || layers.isEmpty) {
      spots = [];
      _index();
      truncated = false;
      counts = const {};
      loading = false;
      error = null;
      _notify();
      return;
    }
    loading = true;
    error = null;
    _notify();
    try {
      if (!_rulesLoaded) {
        rules = await gateway.cityRules();
        _rulesLoaded = true;
      }
      final page = await gateway.mapSpots(
        bounds,
        community: layers.contains(SpotLayer.community),
        official: layers.contains(SpotLayer.official),
        hidden: layers.contains(SpotLayer.hidden),
      );
      if (!current()) return;
      spots = page.spots;
      _index();
      truncated = page.truncated;
      counts = page.counts;
    } catch (_) {
      if (current()) error = '地圖上的停車點載入失敗，請檢查連線後重試。';
    } finally {
      if (current()) loading = false;
      _notify();
    }
  }

  /// Reloads the last view, after a write changed what it shows.
  Future<void> refresh() async {
    final bounds = viewport;
    if (bounds != null) await show(bounds);
  }

  /// Drops everything private when access is lost or the admin signs out.
  void reset() {
    _generation++;
    spots = [];
    _index();
    rules = [];
    _rulesLoaded = false;
    viewport = null;
    loading = false;
    error = null;
    truncated = false;
    counts = const {};
    tooWide = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// One `admin_viewport_spots` answer: at most 500 spots per layer.
class MapSpotPage {
  const MapSpotPage(
    this.spots, {
    this.truncated = false,
    this.counts = const {},
  });
  final List<AdminMapSpot> spots;
  final bool truncated;

  /// Each chosen layer's spots shown and in view (#133); empty when the
  /// server did not count them.
  final Map<SpotLayer, ({int shown, int total})> counts;

  /// `admin_viewport_spots_v2`: `{rows, counts, truncated}`, at most 1,000
  /// rows in all.
  factory MapSpotPage.fromJson(Map<String, dynamic> json) {
    final rows = MapSpotPage.fromRows(json['rows'] as List? ?? const []);
    final counts = json['counts'];
    return MapSpotPage(
      rows.spots,
      truncated: json['truncated'] == true,
      counts: {
        if (counts is Map)
          for (final layer in SpotLayer.values)
            if (counts[layer.name] case {
              'shown': final num shown,
              'total': final num total,
            })
              layer: (shown: shown.toInt(), total: total.toInt()),
      },
    );
  }

  /// Rows as the RPC returns them, 501 per layer at most: the extra row only
  /// tells the layer was cut off. Kinds this build does not know are skipped,
  /// as in the app.
  factory MapSpotPage.fromRows(List<dynamic> rows) {
    final byLayer = <SpotLayer, List<AdminMapSpot>>{};
    for (final row in rows.cast<Map<String, dynamic>>()) {
      final hidden = row['hidden'] == true;
      for (final spot in ParkingSpot.known(row)) {
        final s = AdminMapSpot(spot, hidden: hidden);
        (byLayer[SpotMapController._layerOf(s)] ??= []).add(s);
      }
    }
    return MapSpotPage(
      [for (final list in byLayer.values) ...list.take(500)],
      // The API cuts any answer at max_rows (1,000) without saying so:
      // that many rows means some may be missing (#133).
      truncated:
          rows.length >= 1000 ||
          byLayer.values.any((list) => list.length > 500),
    );
  }
}

/// The open spot as a marker, at the position in the form: the map's copy
/// when it is loaded, else built from the record. A new spot without a space
/// type yet shows as unverified.
ParkingSpot? selectedSpot(
  SpotRecord? record,
  Map<String, dynamic> draft,
  ParkingSpot? loaded,
) {
  if (record == null) return null;
  final lat = draft['lat'] ?? record.values['lat'];
  final lng = draft['lng'] ?? record.values['lng'];
  if (lat is! num || lng is! num) return null;
  final base =
      loaded?.toJson() ??
      {
        ...record.values,
        'id': record.sourceId,
        'name': record.values['name'] ?? '',
        'city': record.values['city'] ?? '',
        'source': record.official
            ? 'official'
            : record.values['source'] ?? 'community',
        'status': record.official
            ? 'confirmed'
            : record.values['status'] ?? 'pending',
      };
  final known = SpaceType.values.asNameMap().containsKey(base['space_type']);
  try {
    return ParkingSpot.fromJson({
      ...base,
      if (!known && base['exact'] == null) 'space_type': 'offStreet',
      'lat': lat.toDouble(),
      'lng': lng.toDouble(),
    });
  } catch (_) {
    return null;
  }
}

/// The spots page map's floating controls: vehicle, layers and satellite.
class SpotMapControls extends StatefulWidget {
  const SpotMapControls({super.key, required this.map});
  final SpotMapController map;

  @override
  State<SpotMapControls> createState() => _SpotMapControlsState();
}

class _SpotMapControlsState extends State<SpotMapControls> {
  bool _layersOpen = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final map = widget.map;
    final status = map.error != null
        ? null
        : map.tooWide
        ? '放大地圖以顯示停車點。'
        : map.truncated && map.counts.isEmpty
        ? '這個範圍的停車點太多，只顯示一部分，放大地圖可看到全部。'
        : map.layers.isEmpty
        ? '所有圖層都已關閉，打開「圖層」選擇要顯示的點。'
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: colors.surface,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      label: '依車種顯示停放資格',
                      container: true,
                      child: Wrap(
                        spacing: 2,
                        runSpacing: 2,
                        children: [
                          for (final v in VehicleType.values)
                            _VehicleChoice(
                              vehicle: v,
                              selected: map.vehicle == v,
                              onPressed: () => map.setVehicle(v),
                            ),
                        ],
                      ),
                    ),
                    Semantics(
                      expanded: _layersOpen,
                      child: TextButton.icon(
                        key: const ValueKey('map-layers'),
                        onPressed: () =>
                            setState(() => _layersOpen = !_layersOpen),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        icon: Icon(
                          _layersOpen
                              ? Icons.expand_less
                              : Icons.layers_outlined,
                        ),
                        label: const Text('圖層'),
                      ),
                    ),
                    if (map.loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
                if (_layersOpen)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final layer in SpotLayer.values)
                          CheckboxListTile(
                            key: ValueKey('layer-${layer.name}'),
                            value: map.layers.contains(layer),
                            onChanged: (_) => map.toggle(layer),
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(layer.label),
                            subtitle: layer == SpotLayer.hidden
                                ? const Text('App 上看不到的點，以半透明顯示')
                                : null,
                          ),
                        SwitchListTile(
                          key: const ValueKey('layer-satellite'),
                          value: map.satellite,
                          onChanged: map.setSatellite,
                          dense: true,
                          title: const Text('衛星圖'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (map.error != null) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Material(
              color: colors.surface,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    Expanded(child: AdminMapNote(map.error!, error: true)),
                    TextButton(onPressed: map.refresh, child: const Text('重試')),
                  ],
                ),
              ),
            ),
          ),
        ] else if (status != null) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: AdminMapNote(status),
          ),
        ] else if (map.truncated) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: MapLimitNote(map: map),
          ),
        ],
      ],
    );
  }
}

/// A short notice floating on the map.
class AdminMapNote extends StatelessWidget {
  const AdminMapNote(this.message, {super.key, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                error ? Icons.error_outline : Icons.zoom_in,
                size: 18,
                color: error ? colors.error : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}

class _VehicleChoice extends StatelessWidget {
  const _VehicleChoice({
    required this.vehicle,
    required this.selected,
    required this.onPressed,
  });
  final VehicleType vehicle;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: TextButton.icon(
        key: ValueKey('map-vehicle-${vehicle.name}'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          foregroundColor: selected ? colors.surface : colors.onSurface,
          backgroundColor: selected ? colors.onSurface : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(
          vehicle == VehicleType.heavy
              ? Icons.sports_motorsports_outlined
              : Icons.two_wheeler,
          size: 20,
        ),
        label: Text(vehicle.label),
      ),
    );
  }
}

/// The map holds more spots than it shows (#133; C6 canvas MapLimit): how
/// many it shows, each layer's count, and how to see the rest.
class MapLimitNote extends StatelessWidget {
  const MapLimitNote({super.key, required this.map});
  final SpotMapController map;

  static String _number(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final layers = [
      // In the order the server fills them.
      for (final layer in const [
        SpotLayer.community,
        SpotLayer.official,
        SpotLayer.hidden,
      ])
        if (map.layers.contains(layer))
          switch (map.counts[layer]) {
            null => '${layer.label} 未載入',
            (shown: 0, total: > 0) => '${layer.label} 未載入',
            (:final shown, :final total) when shown < total =>
              '${layer.label} ${_number(shown)}／${_number(total)}',
            (:final shown, total: _) => '${layer.label} ${_number(shown)}',
          },
    ];
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        key: const ValueKey('map-limit'),
        color: colors.surface,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xffe3ae00), width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '這個範圍的點位太多，只顯示 ${_number(map.shownCount)} 個',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '放大地圖或關掉一個圖層，就能看到全部點位。',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    if (layers.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        layers.join('・'),
                        key: const ValueKey('map-limit-counts'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
