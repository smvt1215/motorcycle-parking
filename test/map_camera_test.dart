import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorcycle_parking/domain/map_camera.dart';

double worldY(double latitude, double zoom) {
  final sine = math.sin(latitude * math.pi / 180);
  return (.5 - math.log((1 + sine) / (1 - sine)) / (4 * math.pi)) *
      256 *
      math.pow(2, zoom);
}

void main() {
  test('選取點一次置中於面板上方，相機不依賴底圖padding', () {
    const spot = LatLng(25.03, 121.56);
    for (final zoom in [12.0, 16.0, 20.0]) {
      final target = centerAbovePanel(spot, zoom, 170);
      expect(target.longitude, spot.longitude);
      expect(target.latitude, lessThan(spot.latitude));
      expect(
        worldY(target.latitude, zoom) - worldY(spot.latitude, zoom),
        closeTo(170, .000001),
      );
    }
    expect(centerAbovePanel(spot, 16, 0), spot);
  });
}
