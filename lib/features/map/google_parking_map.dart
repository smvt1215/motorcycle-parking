import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../domain/eligibility.dart';
import '../../domain/map_viewport.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
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
    this.sheetInset = 0,
    this.panelVisible = false,
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

  /// Height of the spot sheet over the map's bottom edge; the camera centers
  /// above it.
  final double sheetInset;

  @override
  State<GoogleParkingMap> createState() => GoogleParkingMapState();
}

class GoogleParkingMapState extends State<GoogleParkingMap> {
  static const clusterId = gm.ClusterManagerId('parking');
  gm.GoogleMapController? controller;
  late gm.CameraPosition camera;
  late Future<Map<(MarkerLook, bool), gm.BitmapDescriptor>> ready;

  /// A fixed-size dot: a ground circle in meters vanishes at street zoom.
  gm.BitmapDescriptor? locationIcon;
  int viewportGeneration = 0;
  Size? lastSize;
  (LatLng, double?)? pendingMove;
  bool viewportFailed = false;

  @override
  void initState() {
    super.initState();
    camera = gm.CameraPosition(target: _googlePoint(widget.center), zoom: 16);
    ready = _prepare();
    unawaited(
      _locationIcon().then((icon) {
        if (mounted) setState(() => locationIcon = icon);
      }),
    );
  }

  Future<Map<(MarkerLook, bool), gm.BitmapDescriptor>> _prepare() async {
    await initializeMapsSdk();
    final variants = [
      for (final status in EligibilityStatus.values)
        for (final restriction in [
          null,
          if (status == EligibilityStatus.conditional) ...[
            RuleRestriction.pilotArea,
            RuleRestriction.signage,
          ],
        ])
          for (final selected in [false, true])
            ((status, restriction), selected),
    ];
    final icons = await Future.wait(
      variants.map((variant) => _markerIcon(variant.$1, variant.$2)),
    );
    return Map.fromIterables(variants, icons);
  }

  /// Keeps the current zoom when [zoom] is null.
  Future<void> moveTo(LatLng point, double? zoom) async {
    final active = controller;
    if (active == null) {
      pendingMove = (point, zoom);
      return;
    }
    await active.animateCamera(
      zoom == null
          ? gm.CameraUpdate.newLatLng(_googlePoint(point))
          : gm.CameraUpdate.newLatLngZoom(_googlePoint(point), zoom),
    );
  }

  @override
  void didUpdateWidget(GoogleParkingMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Padding changes move no camera, so no idle event reports the region it
    // uncovers: back from a tab panel, the map would keep only the spots in
    // the strip the panel left open.
    if (oldWidget.panelVisible != widget.panelVisible ||
        oldWidget.interactive != widget.interactive ||
        oldWidget.sheetInset != widget.sheetInset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_publishViewport());
      });
    }
  }

  Future<void> _publishViewport() async {
    final active = controller;
    // Under a tab panel or a modal sheet only part of the map shows; keep
    // the last full region.
    if (active == null || widget.panelVisible || !widget.interactive) return;
    final generation = ++viewportGeneration;
    final target = camera.target;
    try {
      final bounds = await active.getVisibleRegion();
      if (!mounted || generation != viewportGeneration) return;
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
      await moveTo(move.$1, move.$2);
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
                style: dark ? _darkMapStyle : null,
                padding: EdgeInsets.only(
                  top: widget.panelVisible ? 0 : 108,
                  bottom: widget.panelVisible
                      ? size.height * .92
                      // The open spot sheet covers the tab bar; the logo
                      // and camera center sit just above it.
                      : widget.sheetInset > 0
                      ? widget.sheetInset
                      // A modal sheet (legend, vehicle, report) would cover
                      // the logo.
                      : !widget.interactive
                      ? size.height * .55
                      // Lift the Google logo above the iOS floating tab bar.
                      : 8 + MediaQuery.paddingOf(context).bottom,
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
                onCameraIdle: () => unawaited(_publishViewport()),
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
                clusterManagers: {
                  gm.ClusterManager(
                    clusterManagerId: clusterId,
                    onClusterTap: !widget.interactive
                        ? null
                        : (cluster) => unawaited(
                            moveTo(
                              LatLng(
                                cluster.position.latitude,
                                cluster.position.longitude,
                              ),
                              (camera.zoom + 2).clamp(0, 20).toDouble(),
                            ),
                          ),
                  ),
                },
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
                  for (final spot in [
                    ...widget.spots.where((s) => s.id != widget.selected?.id),
                    ?widget.selected,
                  ])
                    _marker(icons, spot, selected: spot == widget.selected),
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
  /// spot alike. The selected spot leaves its cluster so it never hides.
  gm.Marker _marker(
    Map<(MarkerLook, bool), gm.BitmapDescriptor> icons,
    ParkingSpot spot, {
    required bool selected,
  }) => gm.Marker(
    markerId: gm.MarkerId(spot.id),
    position: gm.LatLng(spot.lat, spot.lng),
    icon: icons[(markerLook(widget.eligibility(spot)), selected)]!,
    anchor: const Offset(.5, .5),
    clusterManagerId: selected ? null : GoogleParkingMapState.clusterId,
    zIndexInt: selected ? 500 : 0,
    consumeTapEvents: true,
    onTap: widget.interactive ? () => widget.onSpotTap(spot) : null,
  );
}

gm.LatLng _googlePoint(LatLng point) =>
    gm.LatLng(point.latitude, point.longitude);

/// Drawn at 2x like [SpotMarker]; a selected marker is [selectedScale]
/// larger with a blue ring.
Future<gm.BitmapDescriptor> _markerIcon(MarkerLook look, bool selected) async {
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

const _darkMapStyle = '''[
 {"elementType":"geometry","stylers":[{"color":"#172838"}]},
 {"elementType":"labels.text.fill","stylers":[{"color":"#bdcbd1"}]},
 {"elementType":"labels.text.stroke","stylers":[{"color":"#172838"}]},
 {"featureType":"road","elementType":"geometry","stylers":[{"color":"#30465a"}]},
 {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#536477"}]},
 {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0a1c2b"}]},
 {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#193e34"}]}
]''';
