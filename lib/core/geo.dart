import 'dart:math';

double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  double rad(double x) => x * pi / 180;
  final a =
      pow(sin(rad(lat2 - lat1) / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(rad(lng2 - lng1) / 2), 2);
  return 6371000 * 2 * atan2(sqrt(a), sqrt(1 - a.clamp(0, 1)));
}
