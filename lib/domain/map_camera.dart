import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Moves the camera south in Mercator pixels so the selected point appears
/// above its usual center, independent of panel layout.
LatLng centerAbovePanel(LatLng point, double zoom, double pixels) {
  if (pixels == 0) return point;
  final world = 256 * math.pow(2, zoom);
  final sine = math.sin(
    point.latitude.clamp(-85.0511, 85.0511) * math.pi / 180,
  );
  final y = (.5 - math.log((1 + sine) / (1 - sine)) / (4 * math.pi)) * world;
  final shifted = ((y + pixels) / world).clamp(0.0, 1.0);
  final lat =
      math.atan(math.exp(math.pi * (1 - 2 * shifted))) * 360 / math.pi - 90;
  return LatLng(lat, point.longitude);
}
