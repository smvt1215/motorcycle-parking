import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/core/geo.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/models/parking.dart';

void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
          .toList();
  ParkingSpot spot(
    SpaceType type, {
    String city = '臺北市',
    TrustStatus status = TrustStatus.confirmed,
    bool? heavy,
    DateTime? last,
  }) => ParkingSpot(
    id: 'test',
    name: 'test',
    lat: 25,
    lng: 121,
    city: city,
    spaceType: type,
    status: status,
    heavyAllowed: heavy,
    lastConfirmedAt: last,
  );
  CityRule rule(String city, VehicleType vehicle) =>
      rules.firstWhere((r) => r.city == city && r.vehicle == vehicle);
  test('台北收費格開放但免費格不適用', () {
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.allowed,
    );
    expect(
      eligibility(
        spot(SpaceType.freeMotorcycle, heavy: true),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.notAllowed,
    );
  });
  test('待確認或過時的社群「不可停」不能蓋過規則', () {
    final heavy = rule('臺北市', VehicleType.heavy);
    for (final claim in [
      spot(SpaceType.paidMotorcycle, status: TrustStatus.pending, heavy: false),
      spot(
        SpaceType.paidMotorcycle,
        heavy: false,
        last: DateTime.now().subtract(const Duration(days: 200)),
      ),
    ]) {
      expect(
        eligibility(claim, VehicleType.heavy, heavy).status,
        EligibilityStatus.conditional,
      );
    }
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle, heavy: false),
        VehicleType.heavy,
        heavy,
      ).status,
      EligibilityStatus.notAllowed,
    );
  });
  test('尚未生效的規則不套用', () {
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
        now: DateTime(2026, 10, 5),
      ).status,
      EligibilityStatus.conditional,
    );
  });
  test('新北與台中試辦範圍不能擴大為全市開放', () {
    for (final city in ['新北市', '桃園市', '臺中市', '高雄市']) {
      expect(
        eligibility(
          spot(SpaceType.paidMotorcycle, city: city),
          VehicleType.heavy,
          rule(city, VehicleType.heavy),
        ).status,
        EligibilityStatus.conditional,
      );
    }
  });
  test('路外未知重機資格與普通機車專用限制', () {
    expect(
      eligibility(
        spot(SpaceType.offStreet),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.conditional,
    );
    expect(
      eligibility(
        spot(SpaceType.heavyOnly),
        VehicleType.scooter,
        rule('臺北市', VehicleType.scooter),
      ).status,
      EligibilityStatus.notAllowed,
    );
    expect(
      eligibility(
        spot(SpaceType.offStreet, heavy: false),
        VehicleType.heavy,
        null,
      ).status,
      EligibilityStatus.notAllowed,
    );
  });
  test('待確認／過時社群資訊不能顯示無條件可停', () {
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle, status: TrustStatus.pending),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.conditional,
    );
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle, last: DateTime(2020)),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.conditional,
    );
  });
  test('六地區 × 兩車種規則可解析且具官方來源', () {
    expect(rules.length, 12);
    for (final r in rules) {
      expect(Uri.parse(r.sourceUrl).scheme, 'https');
      expect(r.version, greaterThan(0));
      expect(r.exceptions, isNotEmpty);
    }
  });
  test('距離與停車紀錄 JSON 往返', () {
    expect(distanceMeters(25, 121, 25, 121), 0);
    expect(distanceMeters(25, 121, 25.0001, 121), closeTo(11.12, .1));
    final parked = ParkedRecord(
      lat: 25,
      lng: 121,
      at: DateTime.utc(2026),
      floor: 'B2',
      note: '入口右側',
    );
    expect(ParkedRecord.fromJson(parked.toJson()).floor, 'B2');
    final p = spot(SpaceType.offStreet);
    expect(ParkingSpot.fromJson(p.toJson()).spaceType, p.spaceType);
  });
}
