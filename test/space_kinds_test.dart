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

  test('機慢車停放區比照免費機車格', () {
    expect(
      judge(SpaceType.scooterArea, VehicleType.scooter).status,
      EligibilityStatus.allowed,
    );
    // Taipei opens paid bays to heavy bikes, not free ones.
    expect(
      judge(SpaceType.scooterArea, VehicleType.heavy).status,
      EligibilityStatus.notAllowed,
    );
  });

  test('身障機車專用格對一般騎士一律不可停', () {
    for (final vehicle in VehicleType.values) {
      final result = judge(SpaceType.disabledMotorcycle, vehicle);
      expect(result.status, EligibilityStatus.notAllowed);
      expect(result.reason, contains('識別證明'));
    }
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

  test('身障機車格帶角落圖示', () {
    expect(spaceBadge(spot(SpaceType.disabledMotorcycle)), SpaceBadge.disabled);
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
