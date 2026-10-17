import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/models/parking.dart';

void main() {
  test('Google 我的地圖匯入資料可解析且維持待確認', () {
    final spots =
        (jsonDecode(
              File('data/imports/google-mymaps/spots.json').readAsStringSync(),
            ) as List<dynamic>)
            .map((j) => ParkingSpot.fromJson(j as Map<String, dynamic>))
            .toList();
    expect(spots, isNotEmpty);
    for (final spot in spots) {
      expect(spot.source, 'import');
      expect(spot.status, TrustStatus.pending);
      // Pending imports never read as unconditional, whatever the source claims.
      for (final vehicle in VehicleType.values) {
        expect(
          eligibility(spot, vehicle, null).status,
          isNot(EligibilityStatus.allowed),
        );
      }
    }
    expect(spots.where((s) => s.zones.isNotEmpty), isNotEmpty);
    expect(spots.where((s) => s.roadSegment.isNotEmpty), isNotEmpty);
  });
}
