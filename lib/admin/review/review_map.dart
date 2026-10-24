import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:material_ui/material_ui.dart';

import '../../features/map/maps_sdk.dart';
import '../admin_theme.dart';

/// Where a report points: the spot and, for a location suggestion, the
/// proposed position.
class ReviewMapData {
  const ReviewMapData({
    required this.lat,
    required this.lng,
    this.proposedLat,
    this.proposedLng,
  });
  final double lat, lng;
  final double? proposedLat, proposedLng;

  bool get moved => proposedLat != null && proposedLng != null;
}

typedef ReviewMapBuilder = Widget Function(BuildContext, ReviewMapData);

/// Duplicate radius of `apply_report`: same-type spots inside it merge.
const duplicateRadius = 15.0;

Future<void>? _sdk;

/// The spot with its 15 m duplicate circle. Tests swap in a placeholder.
Widget googleReviewMap(BuildContext context, ReviewMapData data) =>
    _GoogleReviewMap(data: data);

class _GoogleReviewMap extends StatefulWidget {
  const _GoogleReviewMap({required this.data});
  final ReviewMapData data;
  @override
  State<_GoogleReviewMap> createState() => _GoogleReviewMapState();
}

class _GoogleReviewMapState extends State<_GoogleReviewMap> {
  late Future<void> ready = _sdk ??= initializeMapsSdk();
  gm.GoogleMapController? _map;

  @override
  void didUpdateWidget(covariant _GoogleReviewMap old) {
    super.didUpdateWidget(old);
    final d = widget.data;
    if (d.lat != old.data.lat || d.lng != old.data.lng) {
      _map?.moveCamera(gm.CameraUpdate.newLatLng(gm.LatLng(d.lat, d.lng)));
    }
  }

  void _retry() => setState(() => ready = _sdk = initializeMapsSdk());

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final spot = gm.LatLng(d.lat, d.lng);
    return FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _MapUnavailable(onRetry: _retry);
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return gm.GoogleMap(
          initialCameraPosition: gm.CameraPosition(target: spot, zoom: 18),
          onMapCreated: (c) => _map = c,
          zoomControlsEnabled: true,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          webGestureHandling: gm.WebGestureHandling.cooperative,
          circles: {
            gm.Circle(
              circleId: const gm.CircleId('duplicate'),
              center: spot,
              radius: duplicateRadius,
              strokeWidth: 2,
              strokeColor: AdminColors.white,
              fillColor: AdminColors.blue.withValues(alpha: .18),
            ),
          },
          markers: {
            gm.Marker(markerId: const gm.MarkerId('spot'), position: spot),
            if (d.moved)
              gm.Marker(
                markerId: const gm.MarkerId('proposed'),
                position: gm.LatLng(d.proposedLat!, d.proposedLng!),
                icon: gm.BitmapDescriptor.defaultMarkerWithHue(
                  gm.BitmapDescriptor.hueYellow,
                ),
              ),
          },
        );
      },
    );
  }
}

class _MapUnavailable extends StatelessWidget {
  const _MapUnavailable({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '地圖無法載入，可先依座標確認位置。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AdminColors.white),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: AdminColors.white),
            child: const Text('重新載入地圖'),
          ),
        ],
      ),
    ),
  );
}
