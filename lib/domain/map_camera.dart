import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:latlong2/latlong.dart';

/// Moves the camera south in Mercator pixels so the selected point appears
/// above its usual center, independent of panel layout.
LatLng centerAbovePanel(LatLng point, double zoom, double pixels) =>
    shiftCenter(point, zoom, dy: pixels);

/// The camera target that shows [point] [dx] pixels left of and [dy] pixels
/// above the map's center at [zoom]. Maps JavaScript ignores the map padding
/// that native SDKs apply to the camera, so panels covering part of the map
/// shift the target instead.
LatLng shiftCenter(LatLng point, double zoom, {double dx = 0, double dy = 0}) {
  if (dx == 0 && dy == 0) return point;
  final world = 256 * math.pow(2, zoom);
  final sine = math.sin(
    point.latitude.clamp(-85.0511, 85.0511) * math.pi / 180,
  );
  final y = (.5 - math.log((1 + sine) / (1 - sine)) / (4 * math.pi)) * world;
  final shifted = ((y + dy) / world).clamp(0.0, 1.0);
  final lat =
      math.atan(math.exp(math.pi * (1 - 2 * shifted))) * 360 / math.pi - 90;
  final lng = point.longitude + dx / world * 360;
  return LatLng(lat, lng);
}

/// [point]'s position in Web Mercator pixels at [zoom], the plane a
/// north-up, untilted map draws on: two points' difference is their
/// distance on screen.
Offset worldPixel(LatLng point, double zoom) {
  final world = 256 * math.pow(2, zoom);
  final sine = math.sin(
    point.latitude.clamp(-85.0511, 85.0511) * math.pi / 180,
  );
  return Offset(
    (point.longitude + 180) / 360 * world,
    (.5 - math.log((1 + sine) / (1 - sine)) / (4 * math.pi)) * world,
  );
}
