import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/rules_display.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/zone_entries.dart';

void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
          .toList();
  CityRule rule(String city, VehicleType vehicle) =>
      rules.firstWhere((r) => r.city == city && r.vehicle == vehicle);
  Map<BayKind, (String, String)> rows(String city, VehicleType vehicle) => {
    for (final r in ruleRows(rule(city, vehicle), vehicle))
      r.kind: (r.pill, r.detail),
  };

  test('規則頁固定 7 類格位，一類一列，順序照定案', () {
    final list = ruleRows(rule('臺北市', VehicleType.heavy), VehicleType.heavy);
    expect(list.map((r) => r.label), [
      '一般機車格',
      '普大共用格',
      '重機專用格',
      '汽機車共用格',
      '汽車格',
      '身障格',
      '充電格',
    ]);
  });

  test('臺北市大型重機：一般機車格合併一列為有條件', () {
    final taipei = rows('臺北市', VehicleType.heavy);
    expect(taipei[BayKind.motorcycle], ('有條件', '收費格可停，免費巷弄格不能停'));
    expect(taipei[BayKind.scooterHeavy], ('可停', '標示普通機車與大型重機共用'));
    expect(taipei[BayKind.heavy], ('可停', '標示大型重機專用'));
    expect(taipei[BayKind.car], ('可停', '依規定可停，照汽車費率'));
    // Read from the same judgement as the map: heavy bikes park on car
    // bays by law, and permit or EV bays are conditional.
    expect(taipei[BayKind.carMotorcycle]!.$1, '可停');
    expect(taipei[BayKind.disabled], ('有條件', '限身障特製車輛，持識別證'));
    expect(taipei[BayKind.ev], ('有條件', '限電動機車充換電'));
  });

  test('臺北市普通機車：一般機車格可停，重機與汽車格不能停', () {
    final taipei = rows('臺北市', VehicleType.scooter);
    expect(taipei[BayKind.motorcycle], ('可停', '收費格、免費巷弄格都可停'));
    expect(taipei[BayKind.heavy]!.$1, '不能停');
    expect(taipei[BayKind.car], ('不能停', '小型車及大型重機停放線'));
    expect(taipei[BayKind.scooterHeavy]!.$1, '可停');
    // A shared car bay opens to scooters only in the slots its notice
    // names; with none listed it is unverified.
    expect(taipei[BayKind.carMotorcycle]!.$1, '待確認');
  });

  test('只在部分行政區開放的格位寫出行政區', () {
    final newTaipei = rows('新北市', VehicleType.heavy);
    expect(newTaipei[BayKind.motorcycle], ('有條件', '收費格可停，免費巷弄格僅板橋區、新店區可停'));
    final taichung = rows('臺中市', VehicleType.heavy);
    expect(taichung[BayKind.motorcycle], ('有條件', '收費格、免費巷弄格都有條件：限標示車格'));
  });

  test('規則補充說明放在一般機車格那一列，其他列沒有', () {
    final list = ruleRows(rule('臺北市', VehicleType.heavy), VehicleType.heavy);
    expect(list.first.kind, BayKind.motorcycle);
    expect(list.first.note, '僅公有路邊收費機車格；免費巷弄格不適用。可斜停兩格，勿阻礙通行。');
    expect(list.skip(1).every((r) => r.note.isEmpty), isTrue);
  });

  test('核對日期與版本照規則資料', () {
    expect(
      ruleCheckedLine(rule('臺北市', VehicleType.heavy)),
      '規則依臺北市公告整理。核對日期 2026-10-06，版本 1。',
    );
    expect(rulePillLabel(EligibilityStatus.notAllowed), '不能停');
  });
}
