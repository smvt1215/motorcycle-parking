import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/features/rules/rules_page.dart';
import 'package:motorcycle_parking/models/parking.dart';

void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
          .toList();
  CityRule rule(String city, VehicleType vehicle) =>
      rules.firstWhere((r) => r.city == city && r.vehicle == vehicle);
  Map<(EligibilityStatus, RuleRestriction?), List<SpaceType>> groups(
    String city,
    VehicleType vehicle,
  ) => {
    for (final (look, types) in ruleGroups(rule(city, vehicle), vehicle))
      look: types,
  };

  test('規則頁依地圖相同的判斷分組，由可停排到不可停', () {
    final taipei = groups('臺北市', VehicleType.heavy);
    expect(taipei[(EligibilityStatus.allowed, null)], [
      SpaceType.paidMotorcycle,
      SpaceType.heavyOnly,
      SpaceType.car,
    ]);
    expect(taipei[(EligibilityStatus.notAllowed, null)], [
      SpaceType.freeMotorcycle,
    ]);
    // A lot's own data decides, never the city rule alone.
    expect(taipei[(EligibilityStatus.unverified, null)], [SpaceType.offStreet]);
    final order = ruleGroups(
      rule('臺北市', VehicleType.heavy),
      VehicleType.heavy,
    ).map((g) => g.$1.$1.index).toList();
    expect(order, [...order]..sort());

    final newTaipei = groups('新北市', VehicleType.heavy);
    expect(
      newTaipei[(EligibilityStatus.conditional, RuleRestriction.pilotArea)],
      [SpaceType.paidMotorcycle, SpaceType.freeMotorcycle],
    );
    final scooter = groups('臺北市', VehicleType.scooter);
    expect(scooter[(EligibilityStatus.notAllowed, null)], [
      SpaceType.heavyOnly,
    ]);
    expect(scooter[(EligibilityStatus.unverified, null)], [
      SpaceType.car,
      SpaceType.offStreet,
    ]);
  });
}
