import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart' as ll;
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../core/address_search.dart';
import '../core/config.dart';
import '../core/geo.dart';
import '../core/location_access.dart';
import '../domain/location_check.dart';
import '../features/map/google_map_style.dart';
import '../features/map/maps_sdk.dart';
import '../features/map/osm_tiles.dart';
import 'adaptive/adaptive.dart';

/// What the map part of [LocationPicker] shows and reports.
class LocationMapView {
  const LocationMapView({
    required this.lat,
    required this.lng,
    required this.onMove,
    this.originLat,
    this.originLng,
    this.touchMarker = false,
  });
  final double lat, lng;
  final double? originLat, originLng;

  /// The marker was dragged, or the map tapped, to a new position.
  final void Function(double lat, double lng) onMove;

  /// Draw the finger-sized [TouchMarkerLayer] instead of the map's own
  /// marker (the app); the admin site keeps the mouse-friendly one.
  final bool touchMarker;
}

typedef LocationMapBuilder = Widget Function(BuildContext, LocationMapView);

/// Finds a house number, road or intersection (P4b, docs/ADMIN_WEB.md) and
/// returns the result picked, or null when the rider gave up. Usually
/// [showAddressSearch]; a caller that keeps an address field fills it from
/// [AddressCandidate.field] before returning.
typedef LocationSearch = Future<AddressCandidate?> Function(
  BuildContext context,
);

/// Picks a position by dragging a marker; shared by the admin site and the
/// app (docs/ADMIN_WEB.md「位置選擇」). The caller owns the position: it
/// passes [lat] and [lng] back in after [onChanged].
class LocationPicker extends StatefulWidget {
  const LocationPicker({
    super.key,
    required this.lat,
    required this.lng,
    required this.onChanged,
    this.originLat,
    this.originLng,
    this.nudgeButtons = false,
    this.touchMarker = false,
    this.onLocate,
    this.onSearch,
    this.height = 320,
    this.mapBuilder,
    this.fills = const {},
    this.collapsed = false,
  });

  final double lat, lng;

  /// Where the spot was before this edit; null for a new spot.
  final double? originLat, originLng;
  final void Function(double lat, double lng) onChanged;

  /// One-metre north/south/west/east buttons (admin site).
  final bool nudgeButtons;

  /// A 56×68 marker that lifts above the finger while dragged (app).
  final bool touchMarker;

  /// Reads the device position for「移到我的位置」; the button shows only
  /// when set. May throw [LocationAccessError].
  final Future<LocationFix> Function()? onLocate;

  /// Address and intersection search; the entry shows only when set.
  final LocationSearch? onSearch;

  /// Field key to label for the fields [onSearch] fills, so the note after
  /// a search can say which one changed.
  final Map<String, String> fills;
  final double height;

  /// Tests swap the map for a placeholder.
  final LocationMapBuilder? mapBuilder;

  /// A short viewport (the keyboard is up): the map folds into
  /// 「開地圖調整」, which opens it full screen, so it never squeezes the
  /// form (admin site, C6 畫布 KeyboardForm).
  final bool collapsed;

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker>
    with AutomaticKeepAliveClientMixin {
  LocationFix? fix;
  AddressCandidate? found;
  bool locating = false;
  String? locateError;

  /// An address search is open.
  bool _searching = false;
  final _noteKey = GlobalKey(debugLabel: 'location-found-note');

  /// A list that scrolls the picker away (a keyboard shrinking the page
  /// while the search is open) must not drop the search or its note (S1).
  @override
  bool get wantKeepAlive => _searching || found != null || fix != null;

  /// The marker still sits where the device put it, so its accuracy applies.
  bool get atFix =>
      fix != null &&
      distanceMeters(fix!.lat, fix!.lng, widget.lat, widget.lng) < 0.5;

  Future<void> locate() async {
    setState(() {
      locating = true;
      locateError = null;
    });
    try {
      final got = await widget.onLocate!();
      if (!mounted) return;
      setState(() => fix = got);
      widget.onChanged(got.lat, got.lng);
    } on LocationAccessError catch (e) {
      if (mounted) await showLocationPrompt(context, e.issue);
    } catch (_) {
      if (mounted) {
        setState(() => locateError = '抓不到目前位置。到空曠處再按一次，或直接拖曳標記。');
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> search() async {
    setState(() => _searching = true);
    updateKeepAlive();
    final AddressCandidate? picked;
    try {
      picked = await widget.onSearch!(context);
    } finally {
      if (mounted) {
        setState(() => _searching = false);
        updateKeepAlive();
      }
    }
    if (picked == null || !mounted) return;
    setState(() => found = picked);
    updateKeepAlive();
    widget.onChanged(picked.lat, picked.lng);
    // The note may land under a pinned action bar or off screen (S2).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final note = _noteKey.currentContext;
      if (note == null || !note.mounted) return;
      // Kept alive off screen, the note is not laid out yet; it shows when
      // the admin scrolls back.
      final box = note.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      Scrollable.ensureVisible(
        note,
        duration: const Duration(milliseconds: 200),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// The full-screen map behind「開地圖調整」; moves go to [onChanged] as
  /// they happen.
  Future<void> openMap() async {
    var lat = widget.lat, lng = widget.lng;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: StatefulBuilder(
          builder: (context, setLocal) => SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            '調整位置',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                      FilledButton(
                        key: const ValueKey('location-map-done'),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LocationPicker(
                    lat: lat,
                    lng: lng,
                    originLat: widget.originLat,
                    originLng: widget.originLng,
                    nudgeButtons: widget.nudgeButtons,
                    touchMarker: widget.touchMarker,
                    mapBuilder: widget.mapBuilder,
                    fills: widget.fills,
                    // The address search lives here while the form is
                    // short; its note shows on the form afterwards too.
                    onSearch: switch (widget.onSearch) {
                      final search? => (context) async {
                        final picked = await search(context);
                        if (picked != null && mounted) {
                          setState(() => found = picked);
                          updateKeepAlive();
                        }
                        return picked;
                      },
                      null => null,
                    },
                    height: (box.maxHeight - 260).clamp(200.0, 640.0),
                    onChanged: (a, b) {
                      setLocal(() {
                        lat = a;
                        lng = b;
                      });
                      widget.onChanged(a, b);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The marker still sits on the search result, so its note applies.
  bool get atFound =>
      found != null &&
      distanceMeters(found!.lat, found!.lng, widget.lat, widget.lng) < 0.5;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).colorScheme;
    final lat = widget.lat, lng = widget.lng;
    final originLat = widget.originLat, originLng = widget.originLng;
    if (widget.collapsed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(
            key: const ValueKey('location-open-map'),
            onPressed: openMap,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: AlignmentDirectional.centerStart,
            ),
            child: Row(
              children: [
                const Icon(Icons.map_outlined, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '位置：${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('開地圖調整'),
              ],
            ),
          ),
          if (atFound)
            KeyedSubtree(
              key: _noteKey,
              child: _FoundNote(found: found!, fills: widget.fills),
            ),
        ],
      );
    }
    final moved = originLat == null || originLng == null
        ? null
        : distanceMeters(originLat, originLng, lat, lng);
    final view = LocationMapView(
      lat: lat,
      lng: lng,
      originLat: originLat,
      originLng: originLng,
      onMove: widget.onChanged,
      touchMarker: widget.touchMarker,
    );
    void step({int north = 0, int east = 0}) {
      final (a, b) = nudge(lat, lng, north: north, east: east);
      widget.onChanged(a, b);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onSearch != null) ...[
          OutlinedButton.icon(
            key: const ValueKey('location-search'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: search,
            icon: const Icon(Icons.search),
            label: const Text('搜尋門牌、路段或路口'),
          ),
          if (atFound)
            KeyedSubtree(
              key: _noteKey,
              child: _FoundNote(found: found!, fills: widget.fills),
            ),
          const SizedBox(height: 8),
        ],
        Semantics(
          label: '位置地圖：拖曳標記選擇位置，拖曳地圖空白處可平移',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: widget.height,
              child: (widget.mapBuilder ?? googleLocationMap)(context, view),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (moved != null)
              Text(
                moved < 0.5
                    ? '在原位置'
                    : '距原位置 ${moved.toStringAsFixed(moved < 10 ? 1 : 0)} m',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
          ],
        ),
        if (widget.onLocate != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('location-locate'),
              onPressed: locating ? null : locate,
              icon: const Icon(Icons.my_location),
              label: Text(locating ? '定位中…' : '移到我的位置'),
            ),
          ),
        if (atFix)
          _FixAccuracy(fix: fix!)
        else if (locateError != null)
          LocationNote(
            icon: Icons.location_disabled,
            text: locateError!,
            tone: NoteTone.caution,
          ),
        if (widget.nudgeButtons) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              for (final (label, icon, north, east) in [
                ('往北 1 m', Icons.north, 1, 0),
                ('往南 1 m', Icons.south, -1, 0),
                ('往西 1 m', Icons.west, 0, -1),
                ('往東 1 m', Icons.east, 0, 1),
              ])
                IconButton(
                  tooltip: label,
                  onPressed: () => step(north: north, east: east),
                  icon: Icon(icon),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// What a search moved the marker to, what it filled, and what is left to
/// do: a road or intersection is only a starting point.
class _FoundNote extends StatelessWidget {
  const _FoundNote({required this.found, required this.fills});
  final AddressCandidate found;
  final Map<String, String> fills;

  @override
  Widget build(BuildContext context) {
    final filled = fills[found.field];
    final reminder = found.reminder;
    return LocationNote(
      icon: reminder == null
          ? Icons.check_circle_outline
          : Icons.pan_tool_alt_outlined,
      tone: reminder == null ? NoteTone.info : NoteTone.caution,
      text: [
        '已移到「${found.label}」',
        if (filled != null) '，並填入「$filled」',
        '。',
        ?reminder,
      ].join(),
    );
  }
}

/// How far off the device fix may be; above 20 m the rider is asked to
/// line the marker up by eye.
class _FixAccuracy extends StatelessWidget {
  const _FixAccuracy({required this.fix});
  final LocationFix fix;

  @override
  Widget build(BuildContext context) {
    final metres = fix.accuracy.round();
    return fix.rough
        ? LocationNote(
            icon: Icons.gps_not_fixed,
            text: 'GPS 誤差約 $metres m，超過 20 m。請拖曳標記對準停車格。',
            tone: NoteTone.caution,
          )
        : LocationNote(icon: Icons.gps_fixed, text: 'GPS 精準度約 ±$metres m');
  }
}

/// How much a [LocationNote] asks of the rider.
enum NoteTone {
  /// A fact, such as the county found.
  info,

  /// Worth checking before sending: a rough fix, a duplicate, other rules.
  caution,

  /// Blocks sending until fixed.
  error,
}

/// One line about the picked position, with an icon so the state never
/// rests on colour alone. Cautions use the map's conditional amber, kept
/// apart from the red of errors.
class LocationNote extends StatelessWidget {
  const LocationNote({
    super.key,
    required this.icon,
    required this.text,
    this.tone = NoteTone.info,
  });
  final IconData icon;
  final String text;
  final NoteTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final color = switch (tone) {
      NoteTone.info => colors.onSurfaceVariant,
      // Lightened in dark mode to keep AA contrast on the dark surface.
      NoteTone.caution => dark ? const Color(0xffe9c27a) : conditionalColor,
      NoteTone.error => colors.error,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

/// Map camera the [TouchMarkerLayer] projects through: an unrotated
/// Web Mercator view centred on ([lat], [lng]).
typedef MapCenter = ({double lat, double lng, double zoom});

/// The app's location marker: a pin with a 56×68 touch area drawn above the
/// map. While dragged it rides 24 px above the finger, so the tip that sets
/// the position stays visible, with a ring on the ground below it.
///
/// Its own eager recognizer claims the pointer, so dragging the pin never
/// scrolls the form or pans the map; the rest of the map pans as usual.
class TouchMarkerLayer extends StatefulWidget {
  const TouchMarkerLayer({
    super.key,
    required this.camera,
    required this.lat,
    required this.lng,
    required this.onMove,
  });

  /// Updated as the map moves, so the pin stays on its point.
  final ValueListenable<MapCenter> camera;
  final double lat, lng;
  final void Function(double lat, double lng) onMove;

  static const size = Size(56, 68);

  /// How far above the finger the tip rides while dragging.
  static const lift = 24.0;

  @override
  State<TouchMarkerLayer> createState() => _TouchMarkerLayerState();
}

class _TouchMarkerLayerState extends State<TouchMarkerLayer> {
  int? pointer;
  Offset finger = Offset.zero, start = Offset.zero;

  /// Horizontal distance from the finger to the tip, kept while dragging.
  double grabX = 0;

  /// Where the tip is while dragging; null when resting on its point.
  Offset? tip;

  Offset restingTip(MapCenter c, Size area) {
    final (dx, dy) = offsetFromCenter(
      centerLat: c.lat,
      centerLng: c.lng,
      zoom: c.zoom,
      lat: widget.lat,
      lng: widget.lng,
    );
    return area.center(Offset(dx, dy));
  }

  void reset() => setState(() {
    pointer = null;
    tip = null;
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final area = constraints.biggest;
      return ValueListenableBuilder<MapCenter>(
        valueListenable: widget.camera,
        builder: (context, camera, _) {
          final at = tip ?? restingTip(camera, area);
          const size = TouchMarkerLayer.size;
          final colors = Theme.of(context).colorScheme;
          Widget pin = Semantics(
            label: '停車點標記',
            hint: '拖曳調整位置，也可以點地圖選位置',
            child: RawGestureDetector(
              gestures: {
                EagerGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      EagerGestureRecognizer
                    >(EagerGestureRecognizer.new, (_) {}),
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (pointer != null) return;
                  pointer = e.pointer;
                  // The box's top left plus where in it the finger landed.
                  finger = start =
                      at -
                      Offset(size.width / 2, size.height) +
                      e.localPosition;
                  grabX = at.dx - finger.dx;
                },
                onPointerMove: (e) {
                  if (e.pointer != pointer) return;
                  finger += e.delta;
                  if (tip == null && (finger - start).distance <= kTouchSlop) {
                    return;
                  }
                  setState(() {
                    tip = Offset(
                      (finger.dx + grabX).clamp(0, area.width),
                      (finger.dy - TouchMarkerLayer.lift).clamp(0, area.height),
                    );
                  });
                },
                onPointerUp: (e) {
                  if (e.pointer != pointer) return;
                  final dropped = tip;
                  reset();
                  if (dropped == null) return;
                  final off = dropped - area.center(Offset.zero);
                  final (lat, lng) = pointAtOffset(
                    centerLat: camera.lat,
                    centerLng: camera.lng,
                    zoom: camera.zoom,
                    dx: off.dx,
                    dy: off.dy,
                  );
                  widget.onMove(lat, lng);
                },
                onPointerCancel: (e) {
                  if (e.pointer == pointer) reset();
                },
                child: CustomPaint(
                  size: size,
                  painter: _PinPainter(
                    fill: colors.primary,
                    edge: colors.surface,
                    lifted: tip != null,
                  ),
                ),
              ),
            ),
          );
          // HTML maps take pointer events from Flutter widgets above them.
          if (kIsWeb) pin = PointerInterceptor(child: pin);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (tip != null)
                Positioned(
                  left: at.dx - 8,
                  top: at.dy - 8,
                  width: 16,
                  height: 16,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: const ValueKey('touch-marker-ground'),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.primary, width: 2),
                        color: colors.surface.withValues(alpha: .6),
                      ),
                    ),
                  ),
                ),
              Positioned(
                key: const ValueKey('touch-marker'),
                left: at.dx - size.width / 2,
                top: at.dy - size.height,
                width: size.width,
                height: size.height,
                child: pin,
              ),
            ],
          );
        },
      );
    },
  );
}

/// A teardrop pin whose tip is the bottom centre of its box.
class _PinPainter extends CustomPainter {
  const _PinPainter({
    required this.fill,
    required this.edge,
    required this.lifted,
  });
  final Color fill, edge;
  final bool lifted;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    const r = 18.0;
    const cy = r + 4;
    final tip = Offset(cx, size.height - 2);
    final body = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(cx - r * .9, cy + r * 1.1, cx - r, cy)
      ..arcToPoint(Offset(cx + r, cy), radius: const Radius.circular(r))
      ..quadraticBezierTo(cx + r * .9, cy + r * 1.1, tip.dx, tip.dy)
      ..close();
    if (lifted) {
      canvas.drawShadow(body, const Color(0xff000000), 6, false);
    }
    canvas.drawPath(body, Paint()..color = fill);
    canvas.drawPath(
      body,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(Offset(cx, cy), 6.5, Paint()..color = edge);
  }

  @override
  bool shouldRepaint(_PinPainter old) =>
      old.fill != fill || old.edge != edge || old.lifted != lifted;
}

Future<void>? _sdk;

/// The gestures the picker's Google map takes inside a scrolling form (iOS
/// and Android alike). A swipe decides by its direction: up or down scrolls
/// the form, as anywhere else on it, so the fields below the map are one
/// swipe away; sideways pans the map, and two fingers pan and zoom it. A
/// tap still picks a point and the touch marker still drags (it claims its
/// own pointers). Taking every drag instead (an eager recognizer) left
/// riders stuck on a map a third of the screen tall.
final pickerMapGestures = <Factory<OneSequenceGestureRecognizer>>{
  Factory<OneSequenceGestureRecognizer>(HorizontalDragGestureRecognizer.new),
  Factory<OneSequenceGestureRecognizer>(ScaleGestureRecognizer.new),
  // Without a tap of its own, a tap nobody claims would not reach the map.
  Factory<OneSequenceGestureRecognizer>(TapGestureRecognizer.new),
};

Widget googleLocationMap(BuildContext context, LocationMapView view) =>
    _GoogleLocationMap(view: view);

/// The app's picker map without Google Maps keys: the OpenStreetMap
/// preview the main map also falls back to, with the same touch marker.
Widget osmLocationMap(BuildContext context, LocationMapView view) =>
    _OsmLocationMap(view: view);

/// The street level adjusting happens at.
const _pickZoom = 19.0;

class _GoogleLocationMap extends StatefulWidget {
  const _GoogleLocationMap({required this.view});
  final LocationMapView view;
  @override
  State<_GoogleLocationMap> createState() => _GoogleLocationMapState();
}

class _GoogleLocationMapState extends State<_GoogleLocationMap> {
  late Future<void> ready = _sdk ??= initializeMapsSdk();
  gm.GoogleMapController? _map;
  late final camera = ValueNotifier<MapCenter>((
    lat: widget.view.lat,
    lng: widget.view.lng,
    zoom: _pickZoom,
  ));

  @override
  void didUpdateWidget(covariant _GoogleLocationMap old) {
    super.didUpdateWidget(old);
    final v = widget.view;
    if (v.lat != old.view.lat || v.lng != old.view.lng) {
      // Follow drops, nudges and lookups; adjusting happens at street level.
      _map?.animateCamera(gm.CameraUpdate.newLatLng(gm.LatLng(v.lat, v.lng)));
    }
  }

  @override
  void dispose() {
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final here = gm.LatLng(v.lat, v.lng);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => ready = _sdk = initializeMapsSdk()),
              child: const Text('地圖無法載入，重新載入'),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final map = gm.GoogleMap(
          initialCameraPosition: gm.CameraPosition(
            target: here,
            zoom: _pickZoom,
          ),
          style: dark ? darkGoogleMapStyle : null,
          onMapCreated: (c) => _map = c,
          onTap: (p) => v.onMove(p.latitude, p.longitude),
          onCameraMove: (c) => camera.value = (
            lat: c.target.latitude,
            lng: c.target.longitude,
            zoom: c.zoom,
          ),
          // Inside a scrolling form, see [pickerMapGestures].
          gestureRecognizers: v.touchMarker ? pickerMapGestures : const {},
          // The touch marker projects through an unrotated, flat camera.
          rotateGesturesEnabled: !v.touchMarker,
          tiltGesturesEnabled: !v.touchMarker,
          zoomControlsEnabled: true,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          webGestureHandling: gm.WebGestureHandling.greedy,
          circles: {
            gm.Circle(
              circleId: const gm.CircleId('duplicate'),
              center: here,
              radius: duplicateMeters,
              strokeWidth: 1,
              strokeColor: const Color(0xff1f5fa8),
              fillColor: const Color(0x141f5fa8),
            ),
            if (v.originLat != null && v.originLng != null)
              gm.Circle(
                circleId: const gm.CircleId('origin'),
                center: gm.LatLng(v.originLat!, v.originLng!),
                radius: 3,
                strokeWidth: 2,
                strokeColor: dark
                    ? const Color(0xffe8edf0)
                    : const Color(0xff2a2e33),
                fillColor: const Color(0x00000000),
              ),
          },
          markers: {
            if (!v.touchMarker)
              gm.Marker(
                markerId: const gm.MarkerId('picked'),
                position: here,
                draggable: true,
                onDragEnd: (p) => v.onMove(p.latitude, p.longitude),
              ),
          },
        );
        if (!v.touchMarker) return map;
        return Stack(
          children: [
            Positioned.fill(child: map),
            Positioned.fill(
              child: TouchMarkerLayer(
                camera: camera,
                lat: v.lat,
                lng: v.lng,
                onMove: v.onMove,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OsmLocationMap extends StatefulWidget {
  const _OsmLocationMap({required this.view});
  final LocationMapView view;
  @override
  State<_OsmLocationMap> createState() => _OsmLocationMapState();
}

class _OsmLocationMapState extends State<_OsmLocationMap> {
  final controller = fm.MapController();
  bool ready = false;
  late final camera = ValueNotifier<MapCenter>((
    lat: widget.view.lat,
    lng: widget.view.lng,
    zoom: _pickZoom,
  ));

  @override
  void didUpdateWidget(covariant _OsmLocationMap old) {
    super.didUpdateWidget(old);
    final v = widget.view;
    if (ready && (v.lat != old.view.lat || v.lng != old.view.lng)) {
      controller.move(ll.LatLng(v.lat, v.lng), controller.camera.zoom);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final here = ll.LatLng(v.lat, v.lng);
    return Stack(
      children: [
        Positioned.fill(
          child: fm.FlutterMap(
            mapController: controller,
            options: fm.MapOptions(
              initialCenter: here,
              initialZoom: _pickZoom,
              maxZoom: 19,
              backgroundColor: dark
                  ? const Color(0xff142130)
                  : const Color(0xffe6eee9),
              // The touch marker projects through an unrotated camera.
              interactionOptions: const fm.InteractionOptions(
                flags: fm.InteractiveFlag.all & ~fm.InteractiveFlag.rotate,
              ),
              onMapReady: () => ready = true,
              onPositionChanged: (c, _) => camera.value = (
                lat: c.center.latitude,
                lng: c.center.longitude,
                zoom: c.zoom,
              ),
              onTap: (_, p) => v.onMove(p.latitude, p.longitude),
            ),
            children: [
              if (AppConfig.showsOsmTiles) OsmTiles(dark: dark),
              fm.CircleLayer(
                circles: [
                  fm.CircleMarker(
                    point: here,
                    radius: duplicateMeters,
                    useRadiusInMeter: true,
                    color: const Color(0x141f5fa8),
                    borderColor: const Color(0xff1f5fa8),
                    borderStrokeWidth: 1,
                  ),
                  if (v.originLat != null && v.originLng != null)
                    fm.CircleMarker(
                      point: ll.LatLng(v.originLat!, v.originLng!),
                      radius: 3,
                      useRadiusInMeter: true,
                      color: const Color(0x00000000),
                      borderColor: colors.onSurface,
                      borderStrokeWidth: 2,
                    ),
                ],
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: TouchMarkerLayer(
            camera: camera,
            lat: v.lat,
            lng: v.lng,
            onMove: v.onMove,
          ),
        ),
      ],
    );
  }
}
