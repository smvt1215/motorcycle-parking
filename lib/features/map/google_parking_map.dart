import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../domain/eligibility.dart';
import '../../domain/map_viewport.dart';
import '../../domain/map_camera.dart';
import '../../domain/spot_clusters.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'cluster_badge.dart';
import 'map_legend.dart';
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

  @override
  State<GoogleParkingMap> createState() => GoogleParkingMapState();
}

class GoogleParkingMapState extends State<GoogleParkingMap> {
  final clusterIcons = <int, gm.BitmapDescriptor>{};
  final clusterLoads = <int, Future<void>>{};
  gm.GoogleMapController? controller;
  late gm.CameraPosition camera;
  late Future<Map<(MarkerLook, SpaceBadge?, bool), gm.BitmapDescriptor>> ready;

  /// A fixed-size dot: a ground circle in meters vanishes at street zoom.
  gm.BitmapDescriptor? locationIcon;
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
  }

  Future<Map<(MarkerLook, SpaceBadge?, bool), gm.BitmapDescriptor>>
  _prepare() async {
    await initializeMapsSdk();
    await Future.wait(clusterLoads.values);
    final variants = [
      for (final status in EligibilityStatus.values)
        for (final restriction in [
          null,
          if (status == EligibilityStatus.conditional) ...[
            RuleRestriction.signage,
            RuleRestriction.timeLimited,
            RuleRestriction.evOnly,
          ],
        ])
          for (final badge in [null, ...SpaceBadge.values])
            for (final selected in [false, true])
              ((status, restriction), badge, selected),
    ];
    final icons = await Future.wait(
      variants.map((v) => _markerIcon(v.$1, v.$2, v.$3)),
    );
    return Map.fromIterables(variants, icons);
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
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final icons = snapshot.data!;
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
                style: dark ? _darkMapStyle : null,
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
                        _marker(icons, spot, selected: false),
                  if (widget.selected case final spot?)
                    _marker(icons, spot, selected: true),
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
  gm.Marker _marker(
    Map<(MarkerLook, SpaceBadge?, bool), gm.BitmapDescriptor> icons,
    ParkingSpot spot, {
    required bool selected,
  }) => gm.Marker(
    markerId: gm.MarkerId(selected ? 'selected:${spot.id}' : spot.id),
    position: gm.LatLng(spot.lat, spot.lng),
    icon:
        icons[(
          markerLook(widget.eligibility(spot)),
          spaceBadge(spot),
          selected,
        )]!,
    anchor: const Offset(.5, .5),
    alpha: !selected && (widget.dimmed?.call(spot) ?? false) ? .45 : 1,
    zIndexInt: selected ? 500 : 0,
    consumeTapEvents: true,
    onTap: widget.interactive ? () => widget.onSpotTap(spot) : null,
  );
}

gm.LatLng _googlePoint(LatLng point) =>
    gm.LatLng(point.latitude, point.longitude);

/// Drawn at 2x like [SpotMarker]; a selected marker is [selectedScale]
/// larger with a blue ring.
Future<gm.BitmapDescriptor> _markerIcon(
  MarkerLook look,
  SpaceBadge? badge,
  bool selected,
) async {
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
  if (badge != null) _paintBadge(canvas, badge);
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

/// The corner badge of [SpaceBadgeDot], at the marker's bottom right.
void _paintBadge(Canvas canvas, SpaceBadge badge) {
  const center = Offset(78, 78), radius = 17.0;
  canvas.drawCircle(center, radius, Paint()..color = Colors.white);
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..color = badgeInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5,
  );
  final icon = spaceBadgeIcon(badge);
  final painter = TextPainter(
    text: TextSpan(
      text: icon != null ? String.fromCharCode(icon.codePoint) : '共',
      style: TextStyle(
        color: badgeInk,
        fontSize: icon != null ? 22 : 19,
        fontWeight: FontWeight.w800,
        height: 1,
        fontFamily: icon?.fontFamily,
        package: icon?.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  painter.dispose();
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

const _darkMapStyle = '''[
 {"elementType":"geometry","stylers":[{"color":"#172838"}]},
 {"elementType":"labels.text.fill","stylers":[{"color":"#bdcbd1"}]},
 {"elementType":"labels.text.stroke","stylers":[{"color":"#172838"}]},
 {"featureType":"road","elementType":"geometry","stylers":[{"color":"#30465a"}]},
 {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#536477"}]},
 {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0a1c2b"}]},
 {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#193e34"}]}
]''';
