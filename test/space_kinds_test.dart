import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/models/parking.dart';

void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
          .toList();
  CityRule rule(String city, VehicleType vehicle) =>
      rules.firstWhere((r) => r.city == city && r.vehicle == vehicle);
  ParkingSpot spot(
    SpaceType type, {
    TrustStatus status = TrustStatus.confirmed,
  }) => ParkingSpot(
    id: 'test',
    name: 'test',
    lat: 25,
    lng: 121,
    city: '臺北市',
    spaceType: type,
    status: status,
  );
  Eligibility judge(
    SpaceType type,
    VehicleType vehicle, {
    TrustStatus? status,
  }) => eligibility(
    spot(type, status: status ?? TrustStatus.confirmed),
    vehicle,
    rule('臺北市', vehicle),
  );

  test('身障機車專用格為有條件・其他限制，限持識別證明者', () {
    for (final vehicle in VehicleType.values) {
      final result = judge(SpaceType.disabledMotorcycle, vehicle);
      expect(result.status, EligibilityStatus.conditional);
      expect(result.restriction, isNull);
      expect(result.reason, contains('識別證明'));
    }
    expect(
      judge(
        SpaceType.disabledMotorcycle,
        VehicleType.scooter,
        status: TrustStatus.pending,
      ).status,
      EligibilityStatus.unverified,
    );
  });

  test('限時機車格在可停處改為有條件・限時段，不可停處維持不可停', () {
    final scooter = judge(SpaceType.timedMotorcycle, VehicleType.scooter);
    expect(scooter.status, EligibilityStatus.conditional);
    expect(scooter.restriction, RuleRestriction.timeLimited);
    // A closed bay never opens because it has a clock.
    expect(
      eligibility(
        spot(SpaceType.timedMotorcycle),
        VehicleType.heavy,
        rule('全國', VehicleType.heavy),
      ).status,
      EligibilityStatus.notAllowed,
    );
  });

  test('彈性共用與電動機車格為有條件；未查核的社群回報為待確認', () {
    expect(
      judge(SpaceType.flexShared, VehicleType.scooter).restriction,
      RuleRestriction.timeLimited,
    );
    final ev = judge(SpaceType.evMotorcycle, VehicleType.scooter);
    expect(ev.status, EligibilityStatus.conditional);
    expect(ev.restriction, RuleRestriction.evOnly);
    for (final type in [SpaceType.flexShared, SpaceType.evMotorcycle]) {
      expect(
        judge(type, VehicleType.scooter, status: TrustStatus.pending).status,
        EligibilityStatus.unverified,
      );
    }
  });

  test('資料庫裡舊的 pilot_area 讀成一般條件，不讓規則解析失敗', () {
    expect(RuleRestriction.parse('pilot_area'), isNull);
    expect(RuleRestriction.parse('signage'), RuleRestriction.signage);
  });

  test('身障機車格帶角落圖示', () {
    expect(spaceBadge(spot(SpaceType.disabledMotorcycle)), SpaceBadge.disabled);
  });

  test('收藏快照對舊版保守：新格位降為路外停車場且無可停旗標，新版完整還原', () {
    const original = {
      'paidMotorcycle',
      'freeMotorcycle',
      'heavyOnly',
      'car',
      'offStreet',
    };
    for (final type in SpaceType.values) {
      for (final source in ['community', 'official', 'tdx']) {
        final exact = ParkingSpot(
          id: 'fav',
          name: 'fav',
          lat: 25,
          lng: 121,
          city: '臺北市',
          source: source,
          spaceType: type,
          status: TrustStatus.confirmed,
          scooterAllowed: true,
          heavyAllowed: true,
        );
        final json = exact.toJson();
        final reason = '${type.name}/$source';
        expect(original, contains(json['space_type']), reason: reason);
        // This build restores the exact kind, flags and status.
        final restored = ParkingSpot.fromJson(json);
        expect(restored.spaceType, type, reason: reason);
        expect(restored.scooterAllowed, isTrue, reason: reason);
        expect(restored.status, TrustStatus.confirmed, reason: reason);
        if (original.contains(type.name)) continue;
        // An older build ignores `exact`; the lot branch it then takes is
        // the same as here, and never says parkable.
        final asOld = ParkingSpot.fromJson({...json}..remove('exact'));
        for (final vehicle in VehicleType.values) {
          expect(
            eligibility(asOld, vehicle, rule('臺北市', vehicle)).status,
            EligibilityStatus.unverified,
            reason: '$reason/${vehicle.name}',
          );
        }
      }
    }
  });

  test('不認得的格位種類只略過該筆，不讓整批資料失敗', () {
    Map<String, dynamic> row(String type) => {
      'id': type,
      'name': type,
      'lat': 25.0,
      'lng': 121.0,
      'city': '臺北市',
      'space_type': type,
    };
    final spots = [
      row('paidMotorcycle'),
      row('busOnly'),
      row('evMotorcycle'),
    ].expand(ParkingSpot.known).toList();
    expect(spots.map((s) => s.id), ['paidMotorcycle', 'evMotorcycle']);
  });
}
