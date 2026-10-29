import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/models/condition_text.dart';
import 'package:motorcycle_parking/models/holiday_calendar.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';

/// 時段性禁停（決定 62）：禁停時段內不可停，詳情寫「現在禁停，X 起可停」。
void main() {
  final rules = [
    for (final r in jsonDecode(
      File('assets/rules/parking_rules.json').readAsStringSync(),
    ) as List)
      CityRule.fromJson(r as Map<String, dynamic>),
  ];
  DateTime at(int y, int m, int d, int h, [int min = 0]) =>
      DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));
  const morning = TimePeriod(days: 'weekday', from: '07:00', to: '09:00');
  const lateNight = TimePeriod(days: 'all', from: '22:00', to: '06:00');

  ParkingCondition cond(Map<String, Object?> json, {bool zone = false}) =>
      ParkingCondition.fromJson(json, zone: zone)!;
  final ban = {
    'kind': 'no_parking',
    'periods': [
      {'days': 'weekday', 'from': '07:00', 'to': '09:00'},
    ],
  };

  ParkingSpot street(
    ParkingCondition condition, {
    SpaceType type = SpaceType.heavyOnly,
    String source = 'official',
  }) => ParkingSpot(
    id: 'ban',
    name: 'ban',
    lat: 25,
    lng: 121,
    city: '臺北市',
    spaceType: type,
    condition: condition,
    source: source,
    status: TrustStatus.confirmed,
    lastConfirmedAt: DateTime.utc(2026, 10, 26),
    heavyAllowed: true,
  );

  group('banNowText', () {
    test('禁停時段內寫何時起可停，時段外為 null', () {
      // 2026-10-27 is a working Tuesday.
      expect(banNowText([morning], at(2026, 10, 27, 8)), '現在禁停，09:00 起可停');
      expect(banNowText([morning], at(2026, 10, 27, 9)), isNull);
      expect(banNowText([morning], at(2026, 10, 27, 6, 59)), isNull);
      // 2026-10-26 is a Monday off (補假): 平日禁停 does not apply.
      expect(banNowText([morning], at(2026, 10, 26, 8)), isNull);
    });

    test('跨午夜的禁停到隔天結束；相連的時段合併', () {
      expect(
        banNowText([lateNight], at(2026, 10, 27, 23)),
        '現在禁停，明天 06:00 起可停',
      );
      expect(banNowText([lateNight], at(2026, 10, 27, 3)), '現在禁停，06:00 起可停');
      const early = TimePeriod(days: 'all', from: '06:00', to: '08:00');
      expect(
        banNowText([lateNight, early], at(2026, 10, 27, 23)),
        '現在禁停，明天 08:00 起可停',
      );
    });

    test('假日全天禁停：週六寫週一 00:00 起可停', () {
      const holiday = TimePeriod(days: 'holiday');
      expect(banNowText([holiday], at(2026, 10, 31, 10)), '現在禁停，週一 00:00 起可停');
    });

    test('沒有日曆的年份退回週六日並標示', () {
      expect(
        banNowText(
          [morning],
          at(2026, 10, 27, 8),
          calendar: HolidayCalendar.none,
        ),
        '現在禁停，09:00 起可停（$holidayFallbackNote）',
      );
    });
  });

  group('decideParking', () {
    final heavyBan = cond({
      'bay': 'heavy',
      'use': 'usual',
      'limits': [ban],
    });

    test('禁停時段內不可停，時段外有條件並寫禁停時段', () {
      final inside = decideParking(
        street(heavyBan),
        VehicleType.heavy,
        rules,
        now: at(2026, 10, 27, 8),
      );
      expect(inside.status, EligibilityStatus.notAllowed);
      expect(inside.reason, '現在禁停，09:00 起可停；禁停時段：平日 07:00–09:00，請看現場牌面');
      final outside = decideParking(
        street(heavyBan),
        VehicleType.heavy,
        rules,
        now: at(2026, 10, 27, 12),
      );
      expect(outside.status, EligibilityStatus.conditional);
      expect(outside.restriction, RuleRestriction.timeLimited);
      expect(outside.reason, contains('禁停時段：平日 07:00–09:00'));
    });

    test('未查核的社群資料不因禁停而判不可停，只在理由寫出', () {
      final d = decideParking(
        ParkingSpot(
          id: 'c',
          name: 'c',
          lat: 25,
          lng: 121,
          city: '臺北市',
          spaceType: SpaceType.heavyOnly,
          condition: heavyBan,
          source: 'community',
          status: TrustStatus.pending,
        ),
        VehicleType.heavy,
        const [],
        now: at(2026, 10, 27, 8),
      );
      expect(d.status, isNot(EligibilityStatus.notAllowed));
      expect(d.reason, contains('現在禁停，09:00 起可停'));
    });

    test('汽機共用格的禁停時段也適用', () {
      final shared = cond({
        'bay': 'car',
        'use': 'share',
        'share': 'car_motorcycle',
        'limits': [ban],
        'schedule': [
          {
            'days': 'all',
            'vehicles': ['scooter', 'heavy', 'car'],
          },
        ],
      });
      final d = decideParking(
        street(shared, type: SpaceType.flexShared),
        VehicleType.scooter,
        const [],
        now: at(2026, 10, 27, 8),
      );
      expect(d.status, EligibilityStatus.notAllowed);
      expect(d.reason, startsWith('現在禁停，09:00 起可停'));
    });

    test('分區禁停時段內不可停', () {
      final zone = ParkingZone.fromJson({
        'name': 'B1',
        'access': 'scooterOnly',
        'condition': {
          'bay': 'motorcycle',
          'use': 'usual',
          'allow': {'scooter': true, 'heavy': false},
          'limits': [ban],
        },
      });
      final lot = ParkingSpot(
        id: 'lot',
        name: 'lot',
        lat: 25,
        lng: 121,
        city: '臺北市',
        spaceType: SpaceType.offStreet,
        source: 'official',
        status: TrustStatus.confirmed,
        scooterAllowed: true,
        zones: [zone],
      );
      final inside = decideParking(
        lot,
        VehicleType.scooter,
        const [],
        now: at(2026, 10, 27, 8),
      );
      expect(inside.zones.single.status, EligibilityStatus.notAllowed);
      expect(inside.zones.single.reason, startsWith('現在禁停，09:00 起可停'));
      final outside = decideParking(
        lot,
        VehicleType.scooter,
        const [],
        now: at(2026, 10, 27, 12),
      );
      expect(outside.zones.single.status, EligibilityStatus.conditional);
      expect(outside.zones.single.reason, contains('禁停時段：平日 07:00–09:00'));
    });
  });

  group('condition text', () {
    test('摘要與標題寫出禁停時段與汽機共用的專用時段', () {
      final c = cond({
        'bay': 'car',
        'use': 'share',
        'share': 'car_motorcycle',
        'charge': 'toll',
        'limits': [ban],
        'schedule': [
          {
            'days': 'weekday',
            'from': '08:00',
            'to': '20:00',
            'vehicles': ['car'],
          },
          {
            'days': 'weekday',
            'from': '20:00',
            'to': '08:00',
            'vehicles': ['scooter', 'heavy', 'car'],
          },
        ],
      });
      expect(
        conditionHeadline(SpaceType.flexShared, c),
        '有條件・平日 07:00–09:00 禁停、平日 08:00–20:00 汽車專用',
      );
      expect(conditionSummary(c), contains('平日 07:00–09:00 禁停'));
    });
  });
}
