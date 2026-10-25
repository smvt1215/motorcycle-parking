import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/features/map/spot_details.dart';
import 'package:motorcycle_parking/models/parking.dart';

List<ParkingSpot> load(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as List<dynamic>)
        .map((j) => ParkingSpot.fromJson(j as Map<String, dynamic>))
        .toList();

void main() {
  test('未通過核驗的我的地圖點位為社群點，維持待確認', () {
    final spots = load('data/imports/google-mymaps/spots.json');
    expect(spots, isNotEmpty);
    for (final spot in spots) {
      expect(spot.isOfficial, isFalse);
      expect(spot.status, TrustStatus.pending);
      expect(sourceSummary(spot, demo: false), '由管理員匯入整理');
      expect(trustSummary(spot, demo: false), '待確認');
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

  test('官方點以政府為來源，重機只在官方明載時可停', () {
    final spots = load('data/imports/official/spots.json');
    expect(spots, isNotEmpty);
    for (final spot in spots) {
      expect(spot.isOfficial, isTrue);
      expect(sourceSummary(spot, demo: false), endsWith('政府'));
      final heavy = eligibility(spot, VehicleType.heavy, null).status;
      expect(
        heavy == EligibilityStatus.allowed,
        spot.heavyAllowed == true,
        reason: spot.name,
      );
      expect(heavy, isNot(EligibilityStatus.notAllowed), reason: spot.name);
      if (spot.scooterAllowed == true) {
        expect(
          eligibility(spot, VehicleType.scooter, null).status,
          EligibilityStatus.allowed,
        );
      }
    }
    expect(spots.where((s) => s.heavyAllowed == true), isNotEmpty);
  });
}
