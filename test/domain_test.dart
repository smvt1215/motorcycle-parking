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
    String district = '',
    TrustStatus status = TrustStatus.confirmed,
    bool? heavy,
    DateTime? last,
    bool dated = true,
  }) => ParkingSpot(
    id: 'test',
    name: 'test',
    lat: 25,
    lng: 121,
    city: city,
    district: district,
    spaceType: type,
    status: status,
    heavyAllowed: heavy,
    lastConfirmedAt:
        last ??
        (dated ? DateTime.now().subtract(const Duration(days: 1)) : null),
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
        EligibilityStatus.unverified,
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
      EligibilityStatus.unverified,
    );
  });
  test('2026 重機規則：新北收費格與板橋新店免費格可停，桃園全部開放，台中限標示，高雄路邊不開放', () {
    Eligibility judge(String city, SpaceType type) => eligibility(
      spot(type, city: city),
      VehicleType.heavy,
      rule(city, VehicleType.heavy),
    );
    expect(
      judge('新北市', SpaceType.paidMotorcycle).status,
      EligibilityStatus.allowed,
    );
    // New Taipei opens free bays by whole district: Banqiao and Xindian
    // only.
    Eligibility free(String district) => eligibility(
      spot(SpaceType.freeMotorcycle, city: '新北市', district: district),
      VehicleType.heavy,
      rule('新北市', VehicleType.heavy),
    );
    for (final district in ['板橋區', '新店區']) {
      expect(
        free(district).status,
        EligibilityStatus.allowed,
        reason: district,
      );
    }
    expect(free('中和區').status, EligibilityStatus.notAllowed);
    expect(free('中和區').reason, contains('板橋區、新店區'));
    // Without a district the app cannot tell.
    expect(free('').status, EligibilityStatus.unverified);
    // A pending report in an open district is still unverified.
    expect(
      eligibility(
        spot(
          SpaceType.freeMotorcycle,
          city: '新北市',
          district: '板橋區',
          status: TrustStatus.pending,
        ),
        VehicleType.heavy,
        rule('新北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.unverified,
    );
    for (final type in [SpaceType.paidMotorcycle, SpaceType.freeMotorcycle]) {
      expect(judge('桃園市', type).status, EligibilityStatus.allowed);
      // Kaohsiung only trials five lots; its street bays are closed.
      expect(judge('高雄市', type).status, EligibilityStatus.notAllowed);
    }
    // Taichung: only bays marked 大重機共用, paid or free.
    for (final type in [SpaceType.paidMotorcycle, SpaceType.freeMotorcycle]) {
      final taichung = judge('臺中市', type);
      expect(taichung.status, EligibilityStatus.conditional);
      expect(taichung.restriction, RuleRestriction.signage);
    }
  });
  test('路外未知重機資格與普通機車專用限制', () {
    expect(
      eligibility(
        spot(SpaceType.offStreet),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.unverified,
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
      EligibilityStatus.unverified,
    );
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle, last: DateTime(2020)),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.unverified,
    );
  });
  test('有條件只用於法規已知的限制；資料不足一律待確認', () {
    final heavy = rule('臺中市', VehicleType.heavy);
    final marked = eligibility(
      spot(SpaceType.paidMotorcycle, city: '臺中市'),
      VehicleType.heavy,
      heavy,
    );
    expect(marked.status, EligibilityStatus.conditional);
    expect(marked.reason, heavy.exceptions);
    // An unchecked report inside a city with marked bays is still unverified.
    expect(
      eligibility(
        spot(
          SpaceType.paidMotorcycle,
          city: '臺中市',
          status: TrustStatus.pending,
        ),
        VehicleType.heavy,
        heavy,
      ).status,
      EligibilityStatus.unverified,
    );
    // Law closes the space even to unchecked reports.
    expect(
      eligibility(
        spot(SpaceType.freeMotorcycle, status: TrustStatus.pending),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.notAllowed,
    );
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle),
        VehicleType.scooter,
        null,
      ).status,
      EligibilityStatus.unverified,
    );
  });
  test('普通機車停汽車格屬車種不依規定，除非城市規則開放', () {
    // Car bays are painted for small cars and heavy bikes (§190).
    for (final rule in [rule('臺北市', VehicleType.scooter), null]) {
      final result = eligibility(
        spot(SpaceType.car),
        VehicleType.scooter,
        rule,
      );
      expect(result.status, EligibilityStatus.notAllowed);
      expect(result.reason, contains('車種不依規定'));
    }
    // Even a report claiming scooters may park there cannot open it.
    expect(
      eligibility(
        ParkingSpot(
          id: 'claim',
          name: 'claim',
          lat: 25,
          lng: 121,
          city: '臺北市',
          spaceType: SpaceType.car,
          status: TrustStatus.confirmed,
          scooterAllowed: true,
        ),
        VehicleType.scooter,
        rule('臺北市', VehicleType.scooter),
      ).status,
      EligibilityStatus.notAllowed,
    );
    // A city's special rule (§112, last paragraph) can open them.
    final opened = CityRule(
      city: '臺北市',
      vehicle: VehicleType.scooter,
      allowedSpaceTypes: const [SpaceType.paidMotorcycle, SpaceType.car],
      feeNote: '依汽車費率',
      exceptions: '試辦開放',
      sourceUrl: 'https://example.test',
      version: 9,
      effectiveDate: DateTime(2026),
    );
    expect(
      eligibility(spot(SpaceType.car), VehicleType.scooter, opened).status,
      EligibilityStatus.allowed,
    );
  });
  test('確認存在不等於社群填寫的車種資格已核實', () {
    // Two riders confirming the lot exists do not verify "heavy bikes OK".
    expect(
      eligibility(
        spot(SpaceType.offStreet, heavy: true),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.unverified,
    );
    // Official lot data still opens it.
    expect(
      eligibility(
        ParkingSpot(
          id: 'official:lot',
          name: 'lot',
          lat: 25,
          lng: 121,
          city: '臺北市',
          spaceType: SpaceType.offStreet,
          source: 'official',
          status: TrustStatus.confirmed,
          heavyAllowed: true,
        ),
        VehicleType.heavy,
        rule('臺北市', VehicleType.heavy),
      ).status,
      EligibilityStatus.allowed,
    );
    // A confirmed community "不可停" stays the cautious answer.
    expect(
      eligibility(
        spot(SpaceType.offStreet, heavy: false),
        VehicleType.heavy,
        null,
      ).status,
      EligibilityStatus.notAllowed,
    );
  });
  test('沒有確認時間的社群資料視為未知，不當成新鮮證據', () {
    final heavy = rule('臺北市', VehicleType.heavy);
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle, dated: false),
        VehicleType.heavy,
        heavy,
      ).status,
      EligibilityStatus.unverified,
    );
    expect(
      eligibility(
        spot(SpaceType.paidMotorcycle, heavy: false, dated: false),
        VehicleType.heavy,
        heavy,
      ).status,
      EligibilityStatus.unverified,
    );
    // Freshness is judged against the given clock, not the device's.
    final today = DateTime.now();
    final recent = spot(
      SpaceType.paidMotorcycle,
      last: today.subtract(const Duration(days: 30)),
    );
    expect(
      eligibility(recent, VehicleType.heavy, heavy, now: today).status,
      EligibilityStatus.allowed,
    );
    expect(
      eligibility(
        recent,
        VehicleType.heavy,
        heavy,
        now: today.add(const Duration(days: 200)),
      ).status,
      EligibilityStatus.unverified,
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
