import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/parking.dart';

/// Sparse groups remain individual parking markers.
const minimumClusterSize = 5;

class SpotCluster {
  SpotCluster(this.spots);
  final List<ParkingSpot> spots;
  LatLng get center => LatLng(
    spots.fold(0.0, (sum, spot) => sum + spot.lat) / spots.length,
    spots.fold(0.0, (sum, spot) => sum + spot.lng) / spots.length,
  );
}

/// Stable world-space anchors keep groups unchanged while panning.
/// At detail zoom, all spots are individually selectable.
List<SpotCluster> clusterSpots(List<ParkingSpot> spots, double zoom) {
  if (zoom >= 20) {
    return [
      for (final spot in spots) SpotCluster([spot]),
    ];
  }
  const distance = 56.0;
  final scale = 256 * math.pow(2, zoom);
  final cells = <(int, int), List<(double, double, SpotCluster)>>{};
  final result = <SpotCluster>[];
  final ordered = [...spots]..sort((a, b) => a.id.compareTo(b.id));
  for (final spot in ordered) {
    final sine = math.sin(spot.lat.clamp(-85.0511, 85.0511) * math.pi / 180);
    final x = (spot.lng + 180) / 360 * scale;
    final y = (.5 - math.log((1 + sine) / (1 - sine)) / (4 * math.pi)) * scale;
    final cellX = (x / distance).floor(), cellY = (y / distance).floor();
    SpotCluster? closest;
    var best = distance * distance;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final (anchorX, anchorY, group)
            in cells[(cellX + dx, cellY + dy)] ??
                <(double, double, SpotCluster)>[]) {
          final squared =
              (x - anchorX) * (x - anchorX) + (y - anchorY) * (y - anchorY);
          if (squared < best) {
            closest = group;
            best = squared;
          }
        }
      }
    }
    if (closest != null) {
      closest.spots.add(spot);
    } else {
      final cluster = SpotCluster([spot]);
      result.add(cluster);
      (cells[(cellX, cellY)] ??= []).add((x, y, cluster));
    }
  }
  return [
    for (final group in result)
      if (group.spots.length >= minimumClusterSize)
        group
      else
        for (final spot in group.spots) SpotCluster([spot]),
  ];
}
