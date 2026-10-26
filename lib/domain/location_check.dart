import 'dart:math';

import '../core/geo.dart';

/// Same-type spots inside this radius count as duplicates (`apply_report`).
const duplicateMeters = 15.0;

/// A move farther than this asks whether it is still the same spot.
const farMoveMeters = 150.0;

/// One metre north or east of ([lat], [lng]), for the nudge buttons.
(double, double) nudge(double lat, double lng, {int north = 0, int east = 0}) {
  const metresPerDegree = 111320.0;
  return (
    lat + north / metresPerDegree,
    lng + east / (metresPerDegree * cos(lat * pi / 180)),
  );
}

class NearbySpot {
  const NearbySpot({
    required this.sourceId,
    required this.name,
    required this.spaceType,
    required this.lat,
    required this.lng,
  });
  final String sourceId, name, spaceType;
  final double lat, lng;
}

/// What the admin or rider should know before moving a spot to a position.
class LocationNotes {
  const LocationNotes({
    this.moved,
    this.duplicates = const [],
    this.cityChanged = false,
  });

  /// Metres from where the spot was; null for a new spot.
  final double? moved;
  final List<NearbySpot> duplicates;

  /// The new position lies in another county or city, whose rules apply.
  final bool cityChanged;

  bool get far => (moved ?? 0) > farMoveMeters;
}

LocationNotes checkLocation({
  required double lat,
  required double lng,
  double? originLat,
  double? originLng,
  String? spaceType,
  String? selfId,
  List<NearbySpot> nearby = const [],
  String? originCity,
  String? newCity,
}) => LocationNotes(
  moved: originLat == null || originLng == null
      ? null
      : distanceMeters(originLat, originLng, lat, lng),
  duplicates: [
    for (final s in nearby)
      if (s.sourceId != selfId &&
          s.spaceType == spaceType &&
          distanceMeters(s.lat, s.lng, lat, lng) <= duplicateMeters)
        s,
  ],
  cityChanged:
      originCity != null &&
      newCity != null &&
      originCity.isNotEmpty &&
      newCity != originCity,
);

/// A device fix is too rough to place a spot by when its error is above this.
const gpsWarnMeters = 20.0;

/// A device position with its horizontal error in metres.
class LocationFix {
  const LocationFix(this.lat, this.lng, this.accuracy);
  final double lat, lng, accuracy;

  bool get rough => accuracy > gpsWarnMeters;
}

const _maxMercatorLat = 85.05112878;

/// Web Mercator pixels of the whole world at [zoom]: 256 per tile, as both
/// Google Maps (dp / points) and flutter_map lay out their tiles.
(double, double) _world(double lat, double lng, double zoom) {
  final size = 256 * pow(2, zoom);
  final sine = sin(lat.clamp(-_maxMercatorLat, _maxMercatorLat) * pi / 180);
  return (
    (lng + 180) / 360 * size,
    (.5 - log((1 + sine) / (1 - sine)) / (4 * pi)) * size,
  );
}

/// Where ([lat], [lng]) sits relative to the centre of an unrotated map
/// centred on ([centerLat], [centerLng]), in logical pixels.
(double, double) offsetFromCenter({
  required double centerLat,
  required double centerLng,
  required double zoom,
  required double lat,
  required double lng,
}) {
  final (cx, cy) = _world(centerLat, centerLng, zoom);
  final (x, y) = _world(lat, lng, zoom);
  return (x - cx, y - cy);
}

/// The inverse of [offsetFromCenter]: the position [dx], [dy] logical
/// pixels from the centre.
(double, double) pointAtOffset({
  required double centerLat,
  required double centerLng,
  required double zoom,
  required double dx,
  required double dy,
}) {
  final size = 256 * pow(2, zoom);
  final (cx, cy) = _world(centerLat, centerLng, zoom);
  final x = cx + dx, y = (cy + dy).clamp(0.0, size.toDouble());
  final lat = atan(exp(pi * (1 - 2 * y / size))) * 360 / pi - 90;
  return (lat, x / size * 360 - 180);
}
