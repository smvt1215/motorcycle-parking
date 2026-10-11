class MapViewport {
  const MapViewport({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south, west, north, east;
  bool get canQuery =>
      [south, west, north, east].every((n) => n.isFinite) &&
      south >= -90 &&
      north <= 90 &&
      west >= -180 &&
      east <= 180 &&
      north > south &&
      east > west &&
      north - south <= .5 &&
      east - west <= .5;
  bool get intersectsTaiwan =>
      north >= 20 && south <= 27 && east >= 118 && west <= 123;
  bool contains(double lat, double lng) =>
      lat >= south && lat <= north && lng >= west && lng <= east;
  Map<String, double> toJson() => {
    'south': south,
    'west': west,
    'north': north,
    'east': east,
  };

  @override
  bool operator ==(Object other) =>
      other is MapViewport &&
      south == other.south &&
      west == other.west &&
      north == other.north &&
      east == other.east;
  @override
  int get hashCode => Object.hash(south, west, north, east);
}
