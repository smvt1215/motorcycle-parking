import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
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
      expect(sourceSummary(spot, demo: false), '由管理員自其他社群統整後匯入');
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
    const open = {EligibilityStatus.allowed, EligibilityStatus.conditional};
    for (final spot in spots) {
      expect(spot.isOfficial, isTrue);
      expect(sourceSummary(spot, demo: false), endsWith('政府'));
      final heavy = eligibility(spot, VehicleType.heavy, null).status;
      // Zones may then narrow it (§3.2 step 3), never open a lot.
      if (spot.heavyAllowed != true) {
        expect(open.contains(heavy), isFalse, reason: spot.name);
      } else if (spot.zones.every((z) => z.access == null)) {
        expect(heavy, EligibilityStatus.allowed, reason: spot.name);
      }
      expect(heavy, isNot(EligibilityStatus.notAllowed), reason: spot.name);
      if (spot.scooterAllowed == true &&
          spot.zones.every((z) => z.access == null)) {
        expect(
          eligibility(spot, VehicleType.scooter, null).status,
          EligibilityStatus.allowed,
        );
      }
    }
    expect(spots.where((s) => s.heavyAllowed == true), isNotEmpty);
  });

  test('官方停車場的分區（C4 §3.2 第 3 步）：只有重機分區時普通機車待確認，有重機分區時重機可停', () {
    final spots = load('data/imports/official/spots.json');
    bool heavyZone(ParkingZone z) => const {
      ParkingAccess.heavyOnly,
      ParkingAccess.heavyCar,
      ParkingAccess.scooterHeavy,
    }.contains(z.access);
    bool scooterZone(ParkingZone z) => const {
      ParkingAccess.scooterOnly,
      ParkingAccess.scooterHeavy,
    }.contains(z.access);
    final heavyOnlyLots = spots.where(
      (s) =>
          s.scooterAllowed == true &&
          s.zones.any((z) => z.access != null) &&
          !s.zones.any(scooterZone),
    );
    expect(heavyOnlyLots, isNotEmpty);
    for (final spot in heavyOnlyLots) {
      final d = decideParking(spot, VehicleType.scooter, const []);
      expect(d.status, EligibilityStatus.unverified, reason: spot.name);
      expect(d.gaps, contains(DecisionGap.zonesIncomplete), reason: spot.name);
    }
    final heavyLots = spots.where(
      (s) => s.heavyAllowed == true && s.zones.any(heavyZone),
    );
    expect(heavyLots, isNotEmpty);
    for (final spot in heavyLots) {
      expect(
        eligibility(spot, VehicleType.heavy, null).status,
        EligibilityStatus.allowed,
        reason: spot.name,
      );
    }
  });
}
