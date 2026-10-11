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
    this.location,
    this.panelVisible = false,
  });

  final LatLng center;
  final List<ParkingSpot> spots;
  final Eligibility Function(ParkingSpot) eligibility;
  final void Function(MapViewport, LatLng) onViewport;
  final ValueChanged<ParkingSpot> onSpotTap;
  final ValueChanged<LatLng>? onLongPress;
  final LatLng? location;
  final bool interactive, panelVisible;

  @override
  State<GoogleParkingMap> createState() => GoogleParkingMapState();
}

class GoogleParkingMapState extends State<GoogleParkingMap> {
  static const clusterId = gm.ClusterManagerId('parking');
  gm.GoogleMapController? controller;
  late gm.CameraPosition camera;
  late Future<Map<(EligibilityStatus, bool), gm.BitmapDescriptor>> ready;
  int viewportGeneration = 0;
  Size? lastSize;
  (LatLng, double)? pendingMove;
  bool viewportFailed = false;

  @override
  void initState() {
    super.initState();
    camera = gm.CameraPosition(target: _googlePoint(widget.center), zoom: 16);
    ready = _prepare();
  }

  Future<Map<(EligibilityStatus, bool), gm.BitmapDescriptor>> _prepare() async {
    await initializeMapsSdk();
    final variants = [
      for (final status in EligibilityStatus.values)
        for (final pending in [false, true]) (status, pending),
    ];
    final icons = await Future.wait(
      variants.map((variant) => _markerIcon(variant.$1, variant.$2)),
    );
    return Map.fromIterables(variants, icons);
  }

  Future<void> moveTo(LatLng point, double zoom) async {
    final active = controller;
    if (active == null) {
      pendingMove = (point, zoom);
      return;
    }
    await active.animateCamera(
      gm.CameraUpdate.newLatLngZoom(_googlePoint(point), zoom),
    );
  }

  Future<void> _publishViewport() async {
    final active = controller;
    if (active == null) return;
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
                  top: widget.panelVisible ? 0 : 132,
                  bottom: widget.panelVisible
                      ? size.height * .92
                      : widget.interactive
                      ? 8
                      : size.height * .55,
                ),
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
                  for (final spot in widget.spots)
                    gm.Marker(
                      markerId: gm.MarkerId(spot.id),
                      position: gm.LatLng(spot.lat, spot.lng),
                      icon:
                          icons[(
                            widget.eligibility(spot).status,
                            spot.status == TrustStatus.pending,
                          )]!,
                      anchor: const Offset(.5, .5),
                      clusterManagerId: clusterId,
                      infoWindow: gm.InfoWindow(
                        title: spot.name,
                        snippet: widget.eligibility(spot).label,
                      ),
                      onTap: widget.interactive
                          ? () => widget.onSpotTap(spot)
                          : null,
                    ),
                },
                circles: {
                  if (widget.location case final point?)
                    gm.Circle(
                      circleId: const gm.CircleId('my-location'),
                      center: _googlePoint(point),
                      radius: 7,
                      fillColor: const Color(0xff2879ef),
                      strokeColor: Colors.white,
                      strokeWidth: 3,
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

gm.LatLng _googlePoint(LatLng point) =>
    gm.LatLng(point.latitude, point.longitude);

Future<gm.BitmapDescriptor> _markerIcon(
  EligibilityStatus status,
  bool pending,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final color = pending
      ? const Color(0xff59646c)
      : switch (status) {
          EligibilityStatus.allowed => allowedColor,
          EligibilityStatus.conditional => conditionalColor,
          EligibilityStatus.notAllowed => deniedColor,
        };
  final radius = switch (status) {
    EligibilityStatus.allowed => 40.0,
    EligibilityStatus.conditional => 20.0,
    EligibilityStatus.notAllowed => 8.0,
  };
  final shape = RRect.fromRectAndRadius(
    const Rect.fromLTWH(8, 8, 80, 80),
    Radius.circular(radius),
  );
  canvas.drawRRect(shape, Paint()..color = color);
  canvas.drawRRect(
    shape,
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6,
  );
  final icon = switch (status) {
    EligibilityStatus.allowed => Icons.local_parking,
    EligibilityStatus.conditional => Icons.priority_high,
    EligibilityStatus.notAllowed => Icons.close,
  };
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
  final image = await picture.toImage(96, 96);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return gm.BitmapDescriptor.bytes(
    bytes!.buffer.asUint8List(),
    imagePixelRatio: 2,
    width: 48,
    height: 48,
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
