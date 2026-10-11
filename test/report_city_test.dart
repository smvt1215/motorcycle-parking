import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';

ParkingSpot at(String city, double lat, double lng) => ParkingSpot(
  id: '$city-$lat',
  name: city,
  lat: lat,
  lng: lng,
  city: city,
  spaceType: SpaceType.paidMotorcycle,
);

void main() {
  test('回報縣市涵蓋全台 22 縣市', () {
    expect(taiwanCities, hasLength(22));
    expect(taiwanCities.toSet(), hasLength(22));
    expect(taiwanCities, containsAll(['臺南市', '花蓮縣', '連江縣']));
  });

  test('回報縣市依 1 公里內最近的點位預選，否則由使用者選擇', () {
    final spots = [at('新北市', 25.0130, 121.4650), at('臺南市', 22.9970, 120.2130)];
    expect(nearbyCity(spots, 22.9990, 120.2140), '臺南市');
    expect(nearbyCity(spots, 25.0339, 121.5623), isNull);
    expect(nearbyCity(const [], 25.0339, 121.5623), isNull);
  });
}
