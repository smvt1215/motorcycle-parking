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
