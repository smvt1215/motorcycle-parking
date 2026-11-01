import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../domain/availability_display.dart';
import '../../domain/capsule_layout.dart';
import '../../domain/eligibility.dart';
import '../../domain/map_viewport.dart';
import '../../domain/map_camera.dart';
import '../../domain/spot_clusters.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'availability_capsule.dart';
import 'cluster_badge.dart';
import 'heavy_glyph.dart';
import 'map_legend.dart';
import 'google_map_style.dart';
import 'maps_sdk.dart';

class GoogleParkingMap extends StatefulWidget {
  const GoogleParkingMap({
    super.key,
    required this.center,
    required this.spots,
    required this.eligibility,
    required this.onViewport,
    required this.onSpotTap,
    required this.interactive,
    this.onLongPress,
    this.onMapTap,
    this.location,
    this.selected,
    this.panelVisible = false,
    this.mapType = gm.MapType.normal,
    this.dimmed,
    this.capsules,
    this.primaryCapsules,
    this.excluded = const [],
  });

  final LatLng center;
  final List<ParkingSpot> spots;
  final Eligibility Function(ParkingSpot) eligibility;
  final void Function(MapViewport, LatLng) onViewport;
  final ValueChanged<ParkingSpot> onSpotTap;
  final ValueChanged<LatLng>? onLongPress;
  final VoidCallback? onMapTap;
  final LatLng? location;
  final bool interactive, panelVisible;

  /// The spot whose details are open: drawn enlarged, outside any cluster,
  /// even when it is no longer in [spots].
  final ParkingSpot? selected;

  /// The admin site switches to satellite imagery; the app keeps the default.
  final gm.MapType mapType;

  /// Spots drawn faded, such as hidden ones on the admin site.
  final bool Function(ParkingSpot)? dimmed;

  /// A spot's availability pills ([markerCapsules]), drawn above its
  /// marker; none when null, as on the admin site.
  final List<AvailabilityCapsule> Function(ParkingSpot)? capsules;

  /// The one pill a crowded marker keeps ([primaryCapsules]), given the
  /// spot's full set; crowded markers keep none when null.
  final List<AvailabilityCapsule> Function(
    ParkingSpot,
    List<AvailabilityCapsule>,
  )?
  primaryCapsules;

  /// Spots the availability filter leaves out: grey dots in place (A0
  /// 被篩掉), still tappable.
  final List<ParkingSpot> excluded;

  @override
  State<GoogleParkingMap> createState() => GoogleParkingMapState();
}

class GoogleParkingMapState extends State<GoogleParkingMap> {
  final clusterIcons = <int, gm.BitmapDescriptor>{};
  final clusterLoads = <int, Future<void>>{};
  gm.GoogleMapController? controller;
  late gm.CameraPosition camera;
  late Future<void> ready;

  /// Marker bitmaps, drawn the first time a look is on screen: with six
  /// badges the full set is a hundred PNG encodes, too many for launch.
  final markerIcons = <MarkerKey, gm.BitmapDescriptor>{};
  final markerLoads = <MarkerKey, Future<void>>{};

  /// Pill rows, drawn the first time a row is on screen: the number layer
  /// is its own marker, so a count that changes redraws only its pills
  /// and the eligibility marker never blinks.
  final capsuleIcons = <CapsuleKey, gm.BitmapDescriptor>{};
  final capsuleLoads = <CapsuleKey, Future<void>>{};

  /// A fixed-size dot: a ground circle in meters vanishes at street zoom.
  gm.BitmapDescriptor? locationIcon;

  /// The grey dot of a spot the filter leaves out.
  gm.BitmapDescriptor? excludedIcon;
  int viewportGeneration = 0;
  Size? lastSize;
  (LatLng, double?, double, double)? pendingMove;
  bool viewportFailed = false;

  @override
  void initState() {
    super.initState();
    camera = gm.CameraPosition(target: _googlePoint(widget.center), zoom: 16);
    _loadClusterIcons();
    ready = _prepare();
    unawaited(
      _locationIcon().then((icon) {
        if (mounted) setState(() => locationIcon = icon);
      }),
    );
    unawaited(
      _excludedIcon().then((icon) {
        if (mounted) setState(() => excludedIcon = icon);
      }),
    );
  }

  /// The bitmap for [key], or null while it is drawn, as [_markerIconFor].
  gm.BitmapDescriptor? _capsuleIconFor(CapsuleKey key) {
    if (capsuleIcons[key] case final icon?) return icon;
    capsuleLoads.putIfAbsent(key, () async {
      try {
        final icon = await capsuleIcon(key);
        if (!mounted) return;
        setState(() => capsuleIcons[key] = icon);
      } catch (_) {
        capsuleLoads.remove(key);
      }
    });
    return null;
  }

  Future<void> _prepare() async {
    await initializeMapsSdk();
    await Future.wait(clusterLoads.values);
  }

  /// The bitmap for [key], or null while it is drawn; the map rebuilds with
  /// the marker once it is ready. A failed draw is retried on a later build.
  gm.BitmapDescriptor? _markerIconFor(MarkerKey key) {
    if (markerIcons[key] case final icon?) return icon;
    markerLoads.putIfAbsent(key, () async {
      try {
        final icon = await markerIcon(key.$1, key.$2, key.$3);
        if (!mounted) return;
        setState(() => markerIcons[key] = icon);
      } catch (_) {
        markerLoads.remove(key);
      }
    });
    return null;
  }

  /// Keeps the current zoom when [zoom] is null. [abovePanel] and
  /// [leftOfCenter] show the point that many pixels above and left of the
  /// map's center, clear of panels covering the map.
  Future<void> moveTo(
    LatLng point,
    double? zoom, {
    double abovePanel = 0,
    double leftOfCenter = 0,
  }) async {
    final active = controller;
    if (active == null) {
      pendingMove = (point, zoom, abovePanel, leftOfCenter);
      return;
    }
    final target = shiftCenter(
      point,
      zoom ?? camera.zoom,
      dx: leftOfCenter,
      dy: abovePanel,
    );
    await active.animateCamera(
      zoom == null
          ? gm.CameraUpdate.newLatLng(_googlePoint(target))
          : gm.CameraUpdate.newLatLngZoom(_googlePoint(target), zoom),
    );
  }

  @override
  void didUpdateWidget(GoogleParkingMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadClusterIcons();
    // Resume viewport queries after a modal/tab panel closes, even when the
    // user did not move the map (so no camera-idle event will arrive).
    if ((oldWidget.panelVisible || !oldWidget.interactive) &&
        !widget.panelVisible &&
        widget.interactive) {
      unawaited(_publishViewport());
    }
  }

  List<SpotCluster> get _clusters => clusterSpots(
    widget.spots.where((spot) => spot.id != widget.selected?.id).toList(),
    camera.zoom,
  );
  void _loadClusterIcons() {
    for (final group in _clusters) {
      final count = group.spots.length;
      if (count < 2) continue;
      clusterLoads.putIfAbsent(count, () => _loadClusterIcon(count));
    }
  }

  Future<void> _loadClusterIcon(int count) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2);
    ClusterBadgePainter(count)
        .paint(canvas, const Size.square(clusterBadgeSize));
    final picture = recorder.endRecording();
    final image = await picture.toImage(112, 112);
    picture.dispose();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (!mounted) return;
    setState(
      () => clusterIcons[count] = gm.BitmapDescriptor.bytes(
        bytes!.buffer.asUint8List(),
        imagePixelRatio: 2,
        width: clusterBadgeSize,
        height: clusterBadgeSize,
      ),
    );
  }

  Future<void> _publishViewport() async {
    final active = controller;
    // Covered maps keep the last full region until they become interactive.
    if (active == null || widget.panelVisible || !widget.interactive) return;
    final generation = ++viewportGeneration;
    final target = camera.target;
    try {
      final bounds = await active.getVisibleRegion();
      if (!mounted ||
          generation != viewportGeneration ||
          widget.panelVisible ||
          !widget.interactive) {
        return;
      }
      widget.onViewport(
        MapViewport(
          south: bounds.southwest.latitude,
          west: bounds.southwest.longitude,
          north: bounds.northeast.latitude,
          east: bounds.northeast.longitude,
        ),
        LatLng(target.latitude, target.longitude),
      );
      if (viewportFailed) setState(() => viewportFailed = false);
    } catch (_) {
      if (mounted && generation == viewportGeneration) {
        setState(() => viewportFailed = true);
      }
    }
  }

  Future<void> _onCreated(gm.GoogleMapController value) async {
    controller = value;
    if (pendingMove case final move?) {
      pendingMove = null;
      await moveTo(
        move.$1,
        move.$2,
        abovePanel: move.$3,
        leftOfCenter: move.$4,
      );
    }
    await _publishViewport();
  }

  @override
  void dispose() {
    viewportGeneration++;
    // GoogleMap owns and disposes its platform controller.
    controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: ready,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _MapLoadMessage(
          onRetry: () => setState(() => ready = _prepare()),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final dark = Theme.of(context).brightness == Brightness.dark;
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (lastSize != size) {
            lastSize = size;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) unawaited(_publishViewport());
            });
          }
          return Stack(
            children: [
              gm.GoogleMap(
                initialCameraPosition: camera,
                mapType: widget.mapType,
                style: dark ? darkGoogleMapStyle : null,
                padding: EdgeInsets.only(
                  // Sheet transitions must not change the map's projection.
                  top: 108,
                  bottom: 8 + MediaQuery.paddingOf(context).bottom,
                ),
                onTap: widget.onMapTap == null
                    ? null
                    : (_) => widget.onMapTap!(),
                onMapCreated: (value) => unawaited(_onCreated(value)),
                onCameraMoveStarted: () => viewportGeneration++,
                onCameraMove: (position) {
                  camera = position;
                  viewportGeneration++;
                },
                onCameraIdle: () {
                  _loadClusterIcons();
                  setState(() {});
                  unawaited(_publishViewport());
                },
                scrollGesturesEnabled: widget.interactive,
                zoomGesturesEnabled: widget.interactive,
                rotateGesturesEnabled: false,
                tiltGesturesEnabled: false,
                zoomControlsEnabled: false,
                compassEnabled: false,
                myLocationButtonEnabled: false,
                mapToolbarEnabled: false,
                webCameraControlEnabled: false,
                webGestureHandling: gm.WebGestureHandling.greedy,
                onLongPress: !widget.interactive || widget.onLongPress == null
                    ? null
                    : (point) => widget.onLongPress!(
                        LatLng(point.latitude, point.longitude),
                      ),
                markers: {
                  if ((widget.location, locationIcon) case (
                    final point?,
                    final icon?,
                  ))
                    gm.Marker(
                      markerId: const gm.MarkerId('my-location'),
                      position: _googlePoint(point),
                      icon: icon,
                      anchor: const Offset(.5, .5),
                      zIndexInt: 1000,
                      consumeTapEvents: true,
                    ),
                  for (final group in _clusters)
                    if (group.spots.length > 1 &&
                        clusterIcons.containsKey(group.spots.length))
                      gm.Marker(
                        markerId: gm.MarkerId(
                          'cluster:${group.spots.first.id}',
                        ),
                        position: _googlePoint(group.center),
                        icon: clusterIcons[group.spots.length]!,
                        anchor: const Offset(.5, .5),
                        consumeTapEvents: true,
                        onTap: !widget.interactive
                            ? null
                            : () => unawaited(
                                moveTo(
                                  group.center,
                                  (camera.zoom + 2).clamp(0, 20).toDouble(),
                                ),
                              ),
                      )
                    else
                      for (final spot in group.spots)
                        ?_marker(spot, selected: false),
                  if (widget.selected case final spot?)
                    ?_marker(spot, selected: true),
                  ..._capsuleMarkers(),
                  if (excludedIcon case final icon?)
                    for (final spot in widget.excluded)
                      if (spot.id != widget.selected?.id)
                        gm.Marker(
                          markerId: gm.MarkerId('excluded:${spot.id}'),
                          position: gm.LatLng(spot.lat, spot.lng),
                          icon: icon,
                          anchor: const Offset(.5, .5),
                          zIndexInt: -2,
                          consumeTapEvents: true,
                          onTap: widget.interactive
                              ? () => widget.onSpotTap(spot)
                              : null,
                        ),
                },
              ),
              if (kIsWeb && !widget.interactive)
                Positioned.fill(
                  child: PointerInterceptor(child: const SizedBox.expand()),
                ),
              if (viewportFailed)
                Center(
                  child: _MapLoadMessage(
                    onRetry: () => unawaited(_publishViewport()),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}

extension on GoogleParkingMapState {
  /// No info window: the spot sheet carries the name and status for every
  /// spot alike. Selected spots remain separate from count markers and keep
  /// a distinct id while their appearance changes.
  gm.Marker? _marker(ParkingSpot spot, {required bool selected}) {
    final icon = _markerIconFor((
      markerLook(widget.eligibility(spot)),
      spaceBadge(spot),
      selected,
    ));
    if (icon == null) return null;
    return _spotMarker(spot, icon, selected: selected);
  }

  /// Pills above the single spots and the selected one, laid out by the
  /// density rules ([layoutCapsules]) on the camera's Mercator plane: a
  /// crowded marker keeps its primary pill, and pills that would touch the
  /// selected spot's set hide. Each row is a marker of its own, anchored at
  /// its spot and drawn under every eligibility marker but the selected
  /// one's, so the marker always wins a tap or a clash.
  List<gm.Marker> _capsuleMarkers() {
    final of = widget.capsules;
    if (of == null) return const [];
    final open = widget.selected;
    final pills = {
      for (final spot in [
        for (final group in _clusters)
          if (group.spots.length == 1) ...group.spots,
        ?open,
      ])
        spot.id: (spot, of(spot)),
    };
    if (pills.values.every((p) => p.$2.isEmpty)) return const [];
    List<AvailabilityCapsule> primary(ParkingSpot spot) =>
        widget.primaryCapsules?.call(spot, pills[spot.id]!.$2) ?? const [];
    final zoom = camera.zoom;
    final layout = layoutCapsules([
      for (final (spot, capsules) in pills.values)
        if (spot.id == open?.id)
          CapsuleItem(
            id: spot.id,
            center: worldPixel(LatLng(spot.lat, spot.lng), zoom),
            fullWidth: capsuleRowWidth(capsules, scale: 26 / 24),
            markerSize: googleMarkerSize * selectedScale,
            height: 26,
          )
        else
          CapsuleItem(
            id: spot.id,
            center: worldPixel(LatLng(spot.lat, spot.lng), zoom),
            fullWidth: capsuleRowWidth(capsules),
            primaryWidth: capsuleRowWidth(primary(spot)),
            markerSize: googleMarkerSize,
          ),
    ], selected: open?.id);
    return [
      for (final (spot, capsules) in pills.values)
        if (switch (layout[spot.id]) {
              CapsuleShow.primary => primary(spot),
              CapsuleShow.none => const <AvailabilityCapsule>[],
              _ => capsules,
            }
            case final shown when shown.isNotEmpty)
          if (_capsuleIconFor(CapsuleKey(shown, selected: spot.id == open?.id))
              case final icon?)
            gm.Marker(
              markerId: gm.MarkerId(
                spot.id == open?.id
                    ? 'selected-capsules:${spot.id}'
                    : 'capsules:${spot.id}',
              ),
              position: gm.LatLng(spot.lat, spot.lng),
              icon: icon,
              anchor: const Offset(.5, 1),
              zIndexInt: spot.id == open?.id ? 501 : -1,
              consumeTapEvents: true,
              // Tapping the pills is tapping the marker.
              onTap: widget.interactive ? () => widget.onSpotTap(spot) : null,
            ),
    ];
  }

  gm.Marker _spotMarker(
    ParkingSpot spot,
    gm.BitmapDescriptor icon, {
    required bool selected,
  }) => gm.Marker(
    markerId: gm.MarkerId(selected ? 'selected:${spot.id}' : spot.id),
    position: gm.LatLng(spot.lat, spot.lng),
    icon: icon,
    anchor: const Offset(.5, .5),
    alpha: !selected && (widget.dimmed?.call(spot) ?? false) ? .45 : 1,
    zIndexInt: selected ? 500 : 0,
    consumeTapEvents: true,
    onTap: widget.interactive ? () => widget.onSpotTap(spot) : null,
  );
}

gm.LatLng _googlePoint(LatLng point) =>
    gm.LatLng(point.latitude, point.longitude);

/// A row of pills above a marker, and whether that marker is selected
/// (larger pills, set higher above its larger marker).
@immutable
class CapsuleKey {
  CapsuleKey(List<AvailabilityCapsule> capsules, {required this.selected})
    : capsules = List.unmodifiable(capsules);
  final List<AvailabilityCapsule> capsules;
  final bool selected;

  @override
  bool operator ==(Object other) =>
      other is CapsuleKey &&
      other.selected == selected &&
      listEquals(other.capsules, capsules);

  @override
  int get hashCode => Object.hash(selected, Object.hashAll(capsules));
}

/// The Google marker's side: [markerIcon]'s 80 of 96 at 2x.
const googleMarkerSize = 40.0;

/// [key]'s pills as a bitmap whose bottom centre is its spot: the row,
/// with room for its shadow, then [capsuleGap] and half the marker
/// transparent below it (MapBadges board), drawn at 2x.
@visibleForTesting
Future<gm.BitmapDescriptor> capsuleIcon(CapsuleKey key) async {
  final scale = key.selected ? 26 / 24 : 1.0;
  final marker = key.selected
      ? googleMarkerSize * selectedScale
      : googleMarkerSize;
  final width =
      (capsuleRowWidth(key.capsules, scale: scale) + capsuleShadowRoom * 2)
          .ceilToDouble();
  final height = (capsuleShadowRoom + 24 * scale + capsuleGap + marker / 2)
      .ceilToDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(2);
  paintCapsuleRow(
    canvas,
    Offset(capsuleShadowRoom, height - marker / 2 - capsuleGap - 24 * scale),
    key.capsules,
    scale: scale,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (width * 2).toInt(),
    (height * 2).toInt(),
  );
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return gm.BitmapDescriptor.bytes(
    bytes!.buffer.asUint8List(),
    imagePixelRatio: 2,
    width: width,
    height: height,
  );
}

/// A grey dot 10 across in a 24 box, so it stays tappable.
Future<gm.BitmapDescriptor> _excludedIcon() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawCircle(const Offset(24, 24), 10, Paint()..color = excludedDotColor);
  final picture = recorder.endRecording();
  final image = await picture.toImage(48, 48);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return gm.BitmapDescriptor.bytes(
    bytes!.buffer.asUint8List(),
    imagePixelRatio: 2,
    width: 24,
    height: 24,
  );
}

/// A marker bitmap's look: status and limit, corner badge, selected.
typedef MarkerKey = (MarkerLook, SpaceBadge?, bool);

/// Drawn at 2x like [SpotMarker]; a selected marker is [selectedScale]
/// larger with a blue ring. A heavy-bike badge waits for the silhouette to
/// settle, so a bitmap is never cached with the fallback by mistake.
@visibleForTesting
Future<gm.BitmapDescriptor> markerIcon(
  MarkerLook look,
  SpaceBadge? badge,
  bool selected,
) async {
  if (badge == SpaceBadge.heavyOnly || badge == SpaceBadge.shared) {
    await heavyGlyphSettled;
  }
  final scale = selected ? selectedScale : 1.0;
  final side = (96 * scale).roundToDouble();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(side / 96);
  final shape = RRect.fromRectAndRadius(
    const Rect.fromLTWH(8, 8, 80, 80),
    Radius.circular(spotMarkerRadius(look.$1) * 80 / 38),
  );
  canvas.drawRRect(shape, Paint()..color = spotMarkerColor(look.$1));
  canvas.drawRRect(
    shape,
    Paint()
      ..color = selected ? selectedRingColor : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 8 : 6,
  );
  final icon = spotMarkerIcon(look);
  final painter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        color: Colors.white,
        fontSize: 48,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(
    canvas,
    Offset((96 - painter.width) / 2, (96 - painter.height) / 2),
  );
  painter.dispose();
  if (badge != null) {
    // A0's 19 at a 38 marker, overhanging its corner; kept inside the
    // bitmap.
    paintSpaceBadge(
      canvas,
      Rect.fromCircle(center: const Offset(78, 78), radius: 18),
      badge,
      glyph: heavyGlyph.value,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(side.toInt(), side.toInt());
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return gm.BitmapDescriptor.bytes(
    bytes!.buffer.asUint8List(),
    imagePixelRatio: 2,
    width: side / 2,
    height: side / 2,
  );
}

/// Blue location dot with a white ring and soft halo, 40dp across, matching
/// the dot drawn on the OpenStreetMap preview.
Future<gm.BitmapDescriptor> _locationIcon() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const center = Offset(40, 40);
  canvas.drawCircle(center, 40, Paint()..color = const Color(0x332879ef));
  canvas.drawCircle(center, 22, Paint()..color = Colors.white);
  canvas.drawCircle(center, 16, Paint()..color = const Color(0xff2879ef));
  final picture = recorder.endRecording();
  final image = await picture.toImage(80, 80);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return gm.BitmapDescriptor.bytes(
    bytes!.buffer.asUint8List(),
    imagePixelRatio: 2,
    width: 40,
    height: 40,
  );
}

class _MapLoadMessage extends StatelessWidget {
  const _MapLoadMessage({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => PointerInterceptor(
    intercepting: kIsWeb,
    child: Material(
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('地圖暫時無法載入'),
            const SizedBox(height: 12),
            AdaptiveButton(label: '重試', onPressed: onRetry),
          ],
        ),
      ),
    ),
  );
}
