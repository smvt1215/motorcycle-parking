import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/four_sign.dart';
import 'package:motorcycle_parking/domain/four_sign_display.dart';
import 'package:motorcycle_parking/domain/segment_decision.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';

/// The four signs (canvas Ver.143 Main, A3, A6, A11) on the demo data of
/// FIX-DECISIONS: 松壽地下停車場 and 南京東路三段路邊機車格.
void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CityRule.fromJson)
          .toList();
  // 2026-11-03 (Tuesday) 14:20 and 21:00 in Taiwan.
  final day = DateTime.utc(2026, 11, 3, 6, 20);
  final night = DateTime.utc(2026, 11, 3, 13);

  final lotJson = <String, dynamic>{
    'id': 'songshou',
    'name': '松壽地下停車場',
    'lat': 25.03,
    'lng': 121.56,
    'city': '臺北市',
    'district': '信義區',
    'space_type': 'offStreet',
    'facility_type': 'underground',
    'source': 'official',
    'scooter_allowed': true,
    'heavy_allowed': true,
    'entrance_note': '松壽路側車道下坡，機車走右側',
    'fee': {
      'scooter': {
        'mode': 'hourly',
        'amount': 20,
        'per_minutes': 60,
        'daily_cap': 100,
        'cap_reset': 'calendar_day',
      },
      'heavy': {
        'mode': 'hourly',
        'amount': 20,
        'per_minutes': 60,
        'daily_cap': 100,
        'cap_reset': 'calendar_day',
      },
    },
    'parking_zones': [
      {
        'id': 'b1',
        'name': 'B1 機車區',
        'area': 'motorcycle',
        'condition': {
          'bay': 'motorcycle',
          'use': 'usual',
          'allow': {'scooter': true, 'heavy': false},
        },
      },
      {
        'id': 'b2',
        'name': 'B2 重機專區',
        'area': 'heavy',
        'condition': {
          'bay': 'heavy',
          'use': 'usual',
          'allow': {'heavy': true},
        },
      },
      {
        'id': 'b3',
        'name': 'B3 汽車區',
        'area': 'car',
        'condition': {
          'bay': 'car',
          'use': 'share',
          'share': 'car_motorcycle',
          'allow': {'heavy': true},
          'schedule': [
            {
              'days': 'all',
              'from': '20:00',
              'to': '23:00',
              'vehicles': ['heavy'],
            },
          ],
        },
      },
    ],
  };
  final lot = ParkingSpot.fromJson(lotJson);

  final street = ParkingSpot.fromJson({
    'id': 'nanjing',
    'name': '南京東路三段路邊機車格',
    'lat': 25.05,
    'lng': 121.54,
    'city': '臺北市',
    'district': '中山區',
    'space_type': 'paidMotorcycle',
    'facility_type': 'roadside',
    'source': 'official',
    'fee': {
      'scooter': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
      'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    },
    'parking_segments': [
      {
        'id': 'n1',
        'name': '北側一般機車格',
        'side': 'north',
        'total': 18,
        'condition': {'bay': 'motorcycle', 'use': 'usual', 'charge': 'toll'},
      },
      {
        'id': 'n2',
        'name': '北側汽機車共用格',
        'side': 'north',
        'total': 6,
        'condition': {
          'bay': 'car',
          'use': 'share',
          'share': 'car_motorcycle',
          'schedule': [
            {
              'days': 'all',
              'from': '20:00',
              'to': '08:00',
              'vehicles': ['scooter'],
            },
          ],
        },
      },
      {
        'id': 's1',
        'name': '南側汽機車共用格',
        'side': 'south',
        'total': 12,
        'condition': {
          'bay': 'car',
          'use': 'share',
          'share': 'car_motorcycle',
          'schedule': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'vehicles': ['scooter', 'heavy'],
            },
          ],
        },
      },
    ],
  });

  AvailabilitySnapshot count(
    AvailabilityVehicle vehicle,
    int available,
    DateTime at, {
    int total = 40,
  }) => AvailabilitySnapshot(
    spotId: 'songshou',
    vehicle: vehicle,
    provider: '臺北市停管處',
    window: AvailabilityWindow.taipei,
    total: total,
    available: available,
    sourceUpdatedAt: at,
  );

  List<SignPlate> plates(
    ParkingSpot spot,
    VehicleType vehicle,
    DateTime now, {
    SpotAvailability availability = SpotAvailability.none,
    RiderSeats riders = noRiderSeats,
  }) => fourSignPlates(
    fourSign(
      spot,
      vehicle,
      rules,
      now: now,
      availability: availability,
      riders: riders,
    ),
    now,
  );

  test('解析示範資料：分區與路段條件都讀得到', () {
    expect(lot.zones.map((z) => z.condition), everyElement(isNotNull));
    expect(street.segments.map((s) => s.condition), everyElement(isNotNull));
  });

  group('路外：松壽地下停車場', () {
    test('Main：大型重機白天只有 B2 可停，路牌照順序、停哪裡寫單區', () {
      final p = plates(lot, VehicleType.heavy, day);
      expect(p.map((x) => x.question), ['能不能停', '有沒有位', '怎麼算錢', '停哪裡']);
      expect(
        (p[0].main, p[0].note, p[0].tone),
        ('可停', '政府資料', PlateTone.allowed),
      );
      expect(
        (p[1].main, p[1].note, p[1].tone),
        ('空位未知', '到場再找', PlateTone.dashed),
      );
      expect((p[2].main, p[2].note), ('20/時', '上限 100'));
      expect((p[3].main, p[3].note), ('B2', '重機專區'));
      expect(p[3].semantics, '停哪裡：B2 重機專區');
    });

    test('A11 卡 1：21:00 多區官方新鮮，挑最多的區並寫另 N 區有位', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        night,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            4,
            night.subtract(const Duration(minutes: 2)),
          ),
          count(
            AvailabilityVehicle.car,
            9,
            night.subtract(const Duration(minutes: 1)),
          ),
        ]),
      );
      // B2 is open all day beside B3 by the hour: 可停 (A11 card 1).
      expect(p[0].main, '可停');
      expect(
        (p[1].main, p[1].note, p[1].tag),
        ('剩 9 格', 'B3 汽車區\n1 分鐘前', '另 1 區有位'),
      );
      expect(p[1].semantics, contains('B3 汽車區剩 9 格'));
      expect(p[1].semantics, endsWith('另 1 區有位'));
      expect((p[2].main, p[2].note), ('20/時', '全場同價\n上限 100'));
      expect((p[3].main, p[3].note), ('2 區', 'B2、B3'));
    });

    test('A11 卡 2：每區都延遲時挑最新的區，維持琥珀色', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        night,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            4,
            night.subtract(const Duration(minutes: 15)),
          ),
          count(
            AvailabilityVehicle.car,
            9,
            night.subtract(const Duration(minutes: 18)),
          ),
        ]),
      );
      expect(p[1].tone, PlateTone.delayed);
      expect(p[1].main, '剩 4 格');
      expect(p[1].note, 'B2 重機專區\n更新延遲\n15 分鐘前');
      expect(p[1].tag, '另 1 區有位');
    });

    test('單區時有沒有位不寫區名，朗讀仍唸', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        day,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            12,
            day.subtract(const Duration(minutes: 3)),
          ),
        ]),
      );
      expect((p[1].main, p[1].note), ('剩 12 格', '3 分鐘前'));
      expect(p[1].semantics, contains('B2 重機專區剩 12 格'));
    });

    test('只有靜態格數時寫共 N 格、空位未知（虛框）', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        day,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            12,
            day.subtract(const Duration(hours: 2)),
          ),
        ]),
      );
      expect(
        (p[1].main, p[1].note, p[1].tone),
        ('共 40 格', '空位未知', PlateTone.dashed),
      );
    });

    test('現在沒有可停的區時，能不能停寫幾點起，停哪裡寫之後開放的區', () {
      final onlyB3 = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': [
          for (final z in lotJson['parking_zones'] as List)
            if ((z as Map)['id'] != 'b2') z,
        ],
      });
      final p = plates(onlyB3, VehicleType.heavy, day);
      expect(
        (p[0].main, p[0].note, p[0].tone),
        ('限時段', '20:00 起', PlateTone.conditional),
      );
      expect(p[3].main, 'B3');
      final evening = plates(onlyB3, VehicleType.heavy, night);
      expect((evening[0].main, evening[0].note), ('限時段', '到 23:00'));
    });

    test('到幾點用分鐘比，隔天 02:00 比 23:00 晚', () {
      final late = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': [
          for (final z in lotJson['parking_zones'] as List)
            if ((z as Map)['id'] == 'b3') z,
          {
            'id': 'b4',
            'name': 'B4 夜間區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'allow': {'heavy': true},
              'schedule': [
                {
                  'days': 'all',
                  'from': '20:00',
                  'to': '02:00',
                  'vehicles': ['heavy'],
                },
              ],
            },
          },
        ],
      });
      final p = plates(late, VehicleType.heavy, night);
      expect((p[0].main, p[0].note), ('限時段', '到 02:00'));
    });

    test('幾點起取最早開放的那一區，限制也取那一區', () {
      final later = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': [
          {
            'id': 'b5',
            'name': 'B5 充電區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'limits': [
                {'kind': 'ev_only'},
              ],
              'allow': {'heavy': true},
              'schedule': [
                {
                  'days': 'all',
                  'from': '22:00',
                  'to': '23:00',
                  'vehicles': ['heavy'],
                },
              ],
            },
          },
          for (final z in lotJson['parking_zones'] as List)
            if ((z as Map)['id'] == 'b3') z,
        ],
      });
      final sign = fourSign(later, VehicleType.heavy, rules, now: day);
      expect(sign.verdict.opensAt, '20:00');
      expect(sign.verdict.restriction, RuleRestriction.timeLimited);
    });

    test('沒有分區的停車場依自己的時段寫幾點起', () {
      final noZones = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': null,
        'condition': {
          'bay': 'car',
          'use': 'usual',
          'schedule': [
            {
              'days': 'all',
              'from': '20:00',
              'to': '23:00',
              'vehicles': ['heavy'],
            },
          ],
        },
      });
      expect(noZones.condition, isNotNull);
      final p = plates(noZones, VehicleType.heavy, day);
      expect((p[0].main, p[0].note), ('限時段', '20:00 起'));
    });

    test('沒有分區的停車場只在 20:00–23:00 開放：21:00 寫到 23:00，19:00 寫 20:00 起', () {
      final hours = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': null,
        'condition': {
          'bay': 'car',
          'use': 'usual',
          'schedule': [
            {
              'days': 'all',
              'from': '20:00',
              'to': '23:00',
              'vehicles': ['heavy'],
            },
          ],
        },
      });
      final at21 = plates(hours, VehicleType.heavy, night);
      expect(
        (at21[0].main, at21[0].note, at21[0].tone),
        ('限時段', '到 23:00', PlateTone.conditional),
      );
      // 19:00 on the same Tuesday in Taiwan.
      final at19 = plates(
        hours,
        VehicleType.heavy,
        DateTime.utc(2026, 11, 3, 11),
      );
      expect((at19[0].main, at19[0].note), ('限時段', '20:00 起'));
    });

    test('普通機車：只有 B1 可停；重機格、汽車格不算', () {
      final p = plates(lot, VehicleType.scooter, day);
      expect(p[0].main, '可停');
      expect((p[3].main, p[3].note), ('B1', '機車區'));
    });

    test('沒有費率資料寫官方未標示（虛框）', () {
      final bare = ParkingSpot.fromJson({
        ...lotJson,
        'fee': null,
        'fee_note': '請依現場公告',
      });
      final p = plates(bare, VehicleType.heavy, day);
      expect((p[2].main, p[2].note, p[2].tone), ('未提供', '', PlateTone.dashed));
    });

    test('多區車友回報：小字寫區名與「車友回報・時間」', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        night,
        riders: _Riders([
          RiderSeat(
            level: 2,
            at: night.subtract(const Duration(minutes: 8)),
            areaId: 'b2',
          ),
        ]),
      );
      expect(p[1].note, 'B2 重機專區\n車友回報・8 分鐘前');
    });

    test('車友回報：沒有官方數字時用量表與車友回報小字', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        day,
        riders: _Riders([
          RiderSeat(
            level: 2,
            at: day.subtract(const Duration(minutes: 8)),
            areaId: 'b2',
          ),
        ]),
      );
      expect(
        (p[1].main, p[1].note, p[1].tone),
        ('還有一些', '車友回報\n8 分鐘前', PlateTone.rider),
      );
      expect(p[1].meters, [2]);
    });
  });

  group('路邊：南京東路三段（逐段判定）', () {
    test('逐段：白天普通機車北側一般機車格、南側共用格可停，北側共用格不算', () {
      final segments = decideSegments(
        street,
        VehicleType.scooter,
        rules,
        now: day,
      );
      expect([for (final s in segments) s.openNow], [true, false, true]);
    });

    test('大型重機白天：北側一般機車格與南側共用格可停，北側共用格不算（#226：共用格依時段）', () {
      final segments = decideSegments(
        street,
        VehicleType.heavy,
        rules,
        now: day,
      );
      expect([for (final s in segments) s.openNow], [true, false, true]);
      final p = plates(street, VehicleType.heavy, day);
      expect((p[3].main, p[3].note), ('2 段', '北側、南側'));
    });

    test('A6 卡 2：普通機車白天 2 段共 30 格，分 2 段', () {
      final p = plates(street, VehicleType.scooter, day);
      expect(p[0].tone, isNot(PlateTone.denied));
      expect((p[1].main, p[1].note), ('共 30 格', '分 2 段\n空位未知'));
      expect(p[1].semantics, '有沒有位：共 30 格，分 2 段，空位未知');
      expect((p[3].main, p[3].note), ('2 段', '北側、南側'));
      expect(p[3].semantics, '停哪裡：2 段，北側一般機車格、南側汽機車共用格');
    });

    test('單段時停哪裡寫段名，有沒有位不重複段名', () {
      final one = ParkingSpot.fromJson({
        ...street.toJson(),
        'parking_segments': [street.segments.first.toJson()],
      });
      final p = plates(one, VehicleType.scooter, day);
      expect((p[0].main, p[0].tone), ('可停', PlateTone.allowed));
      expect(p[0].note, '臺北市規則');
      expect((p[1].main, p[1].note), ('共 18 格', '空位未知'));
      expect(p[1].semantics, contains('北側一般機車格共 18 格'));
      expect((p[2].main, p[2].note), ('20/時', ''));
      expect((p[3].main, p[3].note), ('北側', '一般機車格'));
    });

    test('沒有路段資料的路邊點，整個點當成一段', () {
      final bare = ParkingSpot.fromJson({
        ...street.toJson(),
        'parking_segments': null,
      });
      final p = plates(bare, VehicleType.scooter, day);
      expect(p, hasLength(4));
      expect(p[3].main, '一般機車格');
      expect(p[1].main, '空位未知');
    });

    test('段條件未確認的段不借用點位條件', () {
      final unknown = ParkingSpot.fromJson({
        ...street.toJson(),
        'parking_segments': [
          {'id': 'x', 'name': '東側'},
        ],
      });
      final segments = decideSegments(
        unknown,
        VehicleType.scooter,
        rules,
        now: day,
      );
      expect(segments.single.status, EligibilityStatus.unverified);
      expect(plates(unknown, VehicleType.scooter, day)[0].main, '待確認');
    });
  });

  group('審查修正（#222）', () {
    test('停車場開放此車種但列出的分區都不准：維持待確認，不判不能停', () {
      final closedZones = ParkingSpot.fromJson({
        ...lotJson,
        'zones_complete': true,
        'parking_zones': [
          for (final z in lotJson['parking_zones'] as List)
            if ((z as Map)['id'] == 'b1') z,
        ],
      });
      final p = plates(closedZones, VehicleType.heavy, day);
      expect(p, hasLength(4));
      expect((p[0].main, p[0].tone), ('待確認', PlateTone.unverified));
    });

    test('有新鮮資料時，延遲的區不算「另 N 區有位」', () {
      final p = plates(
        lot,
        VehicleType.heavy,
        night,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            0,
            night.subtract(const Duration(minutes: 2)),
          ),
          count(
            AvailabilityVehicle.car,
            9,
            night.subtract(const Duration(minutes: 15)),
          ),
        ]),
      );
      expect(p[1].main, '已滿');
      expect(p[1].tag, isNull);
      expect(p[1].semantics, isNot(contains('另')));
    });

    test('比照倍率有兩位小數：保留 41.25、123.75（parking_contract_cases）', () {
      final cases =
          (jsonDecode(
                File('supabase/functions/_shared/parking_contract_cases.json')
                    .readAsStringSync(),
              ) as Map<String, dynamic>).values
              .whereType<List<dynamic>>()
              .expand((l) => l)
              .whereType<Map<String, dynamic>>()
              .where((c) => c['name'] == '比照倍率有兩位小數');
      final fee = cases.single['fee'] as Map<String, dynamic>;
      final spot = ParkingSpot.fromJson({...lotJson, 'fee': fee});
      final p = plates(spot, VehicleType.heavy, day);
      expect((p[2].main, p[2].note), ('41.25/時', '上限 123.75'));
      expect(p[2].semantics, contains('每小時 41.25 元'));
      expect(p[2].semantics, contains('當日上限 123.75 元'));
    });

    ParkingCondition notice(
      List<Object> days,
      String from,
      String to, {
      String? effective,
      String? expires,
    }) => ParkingCondition.fromJson({
      'bay': 'car',
      'use': 'share',
      'share': 'car_motorcycle',
      'allow': {'heavy': true},
      'schedule': [
        {
          'days':
              days.length == 1 && days.single is String && days.single == 'all'
              ? 'all'
              : days,
          'from': from,
          'to': to,
          'vehicles': ['heavy'],
        },
      ],
      'basis': {
        'source_url': 'https://example.com/notice',
        'effective_date': ?effective,
        'expires_on': ?expires,
      },
    }, zone: true)!;

    test('公告在下次開放前到期：不寫「週一 20:00 起」', () {
      // Tuesday 2026-11-03; the next Monday is 11-09.
      final open = openWindow(
        EligibilityStatus.conditional,
        notice(['mon'], '20:00', '23:00'),
        VehicleType.heavy,
        day,
      );
      expect(open.opensAt, '週一 20:00');
      final ended = openWindow(
        EligibilityStatus.conditional,
        notice(['mon'], '20:00', '23:00', expires: '2026-11-08'),
        VehicleType.heavy,
        day,
      );
      expect((ended.now, ended.opensAt), (false, null));
    });

    test('到期日當天不算；跨夜時段截在到期之前', () {
      final night20 = openWindow(
        EligibilityStatus.conditional,
        notice(['all'], '20:00', '02:00', expires: '2026-11-04'),
        VehicleType.heavy,
        night,
      );
      expect(night20.now, isTrue);
      expect((night20.until, night20.untilMinute), ('00:00', 1440));
      final notYet = openWindow(
        EligibilityStatus.conditional,
        notice(['all'], '20:00', '23:00', effective: '2026-11-05'),
        VehicleType.heavy,
        night,
      );
      expect((notYet.now, notYet.opensAt), (false, '週四 20:00'));
    });
  });

  group('審查修正（#222 第二輪）', () {
    Map<String, dynamic> contractFee(String name) =>
        ((jsonDecode(
                  File('supabase/functions/_shared/parking_contract_cases.json')
                      .readAsStringSync(),
                ) as Map<String, dynamic>).values
                .whereType<List<dynamic>>()
                .expand((l) => l)
                .whereType<Map<String, dynamic>>()
                .firstWhere((c) => c['name'] == name && c['fee'] is Map)['fee']
            as Map<String, dynamic>);

    test('官方路邊點明確不開放此車種：沒有條件的段仍判不能停', () {
      final closed = ParkingSpot.fromJson({
        ...street.toJson(),
        'heavy_allowed': false,
        'parking_segments': [
          {'id': 'x', 'name': '東側'},
        ],
      });
      final segments = decideSegments(
        closed,
        VehicleType.heavy,
        rules,
        now: day,
      );
      expect(segments.single.status, EligibilityStatus.notAllowed);
      final p = plates(closed, VehicleType.heavy, day);
      expect(p, hasLength(1));
      expect(p.single.main, '大型重機不能停');
    });

    test('只有共用機車區開放時，不借用整場的重機數字', () {
      final shared = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': [
          {
            'id': 'b1',
            'name': 'B1 普大共用區',
            'area': 'motorcycle',
            'condition': {
              'bay': 'motorcycle',
              'use': 'share',
              'share': 'scooter_heavy',
              'allow': {'scooter': true, 'heavy': true},
            },
          },
          {
            'id': 'b2',
            'name': 'B2 重機專區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'allow': {'heavy': true},
              'schedule': [
                {
                  'days': 'all',
                  'from': '20:00',
                  'to': '23:00',
                  'vehicles': ['heavy'],
                },
              ],
            },
          },
        ],
      });
      final p = plates(
        shared,
        VehicleType.heavy,
        day,
        availability: SpotAvailability([
          count(
            AvailabilityVehicle.heavy,
            5,
            day.subtract(const Duration(minutes: 2)),
          ),
        ]),
      );
      expect(p[3].main, 'B1');
      expect(p[1].main, '空位未知');
      expect(p[1].tone, PlateTone.dashed);
    });

    test('完整費率不同時不寫全場同價（免費時長不同）', () {
      final zones = [
        for (final z in lotJson['parking_zones'] as List)
          if ((z as Map<String, dynamic>)['id'] != 'b1')
            <String, dynamic>{
              ...z,
              'fee': {
                'heavy': {
                  'mode': 'hourly',
                  'amount': 20,
                  'per_minutes': 60,
                  if (z['id'] == 'b3') 'free_minutes': 30,
                },
              },
            },
      ];
      final p = plates(
        ParkingSpot.fromJson({...lotJson, 'parking_zones': zones}),
        VehicleType.heavy,
        night,
      );
      expect(p[3].main, '2 區');
      expect(p[2].note, isNot(contains('全場同價')));
    });

    test('沒有分區的停車場：時段只列其他車種時，不判全天可停', () {
      final spot = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': null,
        'condition': {
          'bay': 'car',
          'use': 'usual',
          'schedule': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'vehicles': ['scooter'],
            },
          ],
        },
      });
      expect(spot.condition, isNotNull);
      final p = plates(spot, VehicleType.heavy, day);
      expect(p[0].main, isNot('可停'));
    });

    test('首段 0 元寫「首 20 分鐘 0 元」與付費延長（parking_contract_cases）', () {
      final fee = contractFee('臺北限時格首段 0 元可延長一次（§2.4）');
      final spot = ParkingSpot.fromJson({...street.toJson(), 'fee': fee});
      final one = ParkingSpot.fromJson({
        ...spot.toJson(),
        'parking_segments': [street.segments.first.toJson()],
      });
      final p = plates(one, VehicleType.heavy, day);
      expect((p[2].main, p[2].note), ('首 20 分鐘 0 元', '可付 40 元延長 1 次'));
      expect(p[2].semantics, '怎麼算錢：首 20 分鐘 0 元，可付 40 元延長 1 次');
    });
  });

  group('審查修正（#222 第六輪）', () {
    test('資格來自有到期日的縣市規則：時段截在規則到期之前', () {
      // The Taipei heavy rule ends on 2026-11-08 (Sunday).
      final ending = [
        for (final r in rules)
          if (r.city == '臺北市' && r.vehicle == VehicleType.heavy)
            CityRule(
              city: r.city,
              vehicle: r.vehicle,
              allowedSpaceTypes: r.allowedSpaceTypes,
              conditionalSpaceTypes: r.conditionalSpaceTypes,
              feeNote: r.feeNote,
              exceptions: r.exceptions,
              sourceUrl: r.sourceUrl,
              version: r.version,
              effectiveDate: r.effectiveDate,
              canUseTwoSpaces: r.canUseTwoSpaces,
              expiresOn: DateTime(2026, 11, 8),
            )
          else
            r,
      ];
      ParkingSpot monday(Map<String, dynamic>? schedule) =>
          ParkingSpot.fromJson({
            ...street.toJson(),
            'parking_segments': [
              {
                'id': 'm',
                'name': '北側收費機車格',
                'condition': {
                  'bay': 'motorcycle',
                  'use': 'usual',
                  'charge': 'toll',
                  'schedule': ?schedule == null ? null : [schedule],
                },
              },
            ],
          });
      final slotted = monday({
        'days': ['mon'],
        'from': '20:00',
        'to': '23:00',
        'vehicles': ['heavy'],
      });
      final kept = decideSegments(slotted, VehicleType.heavy, rules, now: day);
      expect(kept.single.window.opensAt, '週一 20:00');
      final ended = decideSegments(
        slotted,
        VehicleType.heavy,
        ending,
        now: day,
      ).single;
      expect(
        ended.decision.basis.map((b) => b.rule?.expiresOn),
        contains(DateTime(2026, 11, 8)),
      );
      expect((ended.window.now, ended.window.opensAt), (false, null));

      // A bay open all day reads 到 00:00 on the rule's last day; the day
      // it ends is not part of it.
      final allDay = monday(null);
      final lastNight = DateTime.utc(2026, 11, 7, 13);
      final last = decideSegments(
        allDay,
        VehicleType.heavy,
        ending,
        now: lastNight,
      ).single;
      expect(
        (last.window.now, last.window.until, last.window.untilMinute),
        (true, '00:00', 1440),
      );
      final before = decideSegments(
        allDay,
        VehicleType.heavy,
        ending,
        now: day,
      ).single;
      expect((before.window.now, before.window.until), (true, null));

      // A heavy-bike bay the law opens stays open past the rule's end: no
      // 到 00:00 the night before, as 可停 after midnight.
      final heavyBay = ParkingSpot.fromJson({
        ...street.toJson(),
        'parking_segments': [
          {
            'id': 'h',
            'name': '北側重機專用格',
            'condition': {'bay': 'heavy', 'use': 'usual', 'charge': 'toll'},
          },
        ],
      });
      final lawful = decideSegments(
        heavyBay,
        VehicleType.heavy,
        ending,
        now: lastNight,
      ).single;
      expect(
        lawful.decision.basis.map((b) => b.rule?.expiresOn),
        contains(DateTime(2026, 11, 8)),
      );
      expect((lawful.window.now, lawful.window.until), (true, null));
      final p = fourSignPlates(
        fourSign(heavyBay, VehicleType.heavy, ending, now: lastNight),
        lastNight,
      );
      expect(p[0].main, '可停');
      expect(p[0].note, isNot(contains('00:00')));
    });

    test('場站車種開放待確認：不以場站 20/時蓋過分區 50/時', () {
      final spot = ParkingSpot.fromJson({
        ...lotJson,
        'heavy_allowed': null,
        'parking_zones': [
          {
            'id': 'h',
            'name': 'B2 重機專區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'allow': {'heavy': true},
            },
            'fee': {
              'heavy': {'mode': 'hourly', 'amount': 50, 'per_minutes': 60},
            },
          },
        ],
      });
      final sign = fourSign(spot, VehicleType.heavy, rules, now: day);
      expect(sign.verdict.status, isNot(EligibilityStatus.allowed));
      final p = plates(spot, VehicleType.heavy, day);
      final fee = p.firstWhere((x) => x.semantics.startsWith('怎麼算錢'));
      expect(fee.main, isNot('20/時'));
      expect(fee.main, '50/時');
    });

    test('各分區限制不同：不以一區的「限電動」代表整場', () {
      final spot = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': [
          {
            'id': 'a',
            'name': 'A 充電區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'limits': [
                {'kind': 'ev_only'},
              ],
              'allow': {'heavy': true},
            },
          },
          {
            'id': 'b',
            'name': 'B 重機區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'allow': {'heavy': true},
              'schedule': [
                {
                  'days': 'all',
                  'from': '20:00',
                  'to': '23:00',
                  'vehicles': ['heavy'],
                },
              ],
            },
          },
        ],
      });
      final sign = fourSign(spot, VehicleType.heavy, rules, now: night);
      expect(sign.verdict.status, EligibilityStatus.conditional);
      expect(sign.verdict.restriction, isNull);
      final p = plates(spot, VehicleType.heavy, night);
      expect(p[0].main, isNot(contains('電動')));
      expect(p[0].semantics, isNot(contains('電動')));
    });
  });

  group('官方未標示（#201、A3 不確定）', () {
    test('場站官方未標示大型重機：能不能停寫不確定／官方未標示（虛框），其他三面照常', () {
      final unstated = ParkingSpot.fromJson({
        ...lotJson,
        'heavy_allowed': null,
        'heavy_not_stated': true,
        'parking_zones': null,
      });
      final p = plates(unstated, VehicleType.heavy, day);
      expect(p, hasLength(4));
      expect(
        (p[0].main, p[0].note, p[0].tone),
        ('不確定', '官方未標示', PlateTone.dashed),
      );
      expect(p[0].semantics, '能不能停：不確定，官方與營運業者都沒有標示大型重機能不能停');
      // 普通機車 stays as stated.
      expect(plates(unstated, VehicleType.scooter, day)[0].main, '可停');
    });

    test('分區官方未標示：沒有其他可停分區時寫不確定', () {
      final zoned = ParkingSpot.fromJson({
        ...lotJson,
        'parking_zones': [
          for (final z in lotJson['parking_zones'] as List)
            if ((z as Map)['id'] == 'b1') z,
          {
            'id': 'b2',
            'name': 'B2 重機專區',
            'area': 'heavy',
            'condition': {
              'bay': 'heavy',
              'use': 'usual',
              'allow': {'heavy': 'not_stated'},
            },
          },
        ],
      });
      expect(zoned.zones.last.condition?.allow?.heavyNotStated, isTrue);
      final p = plates(zoned, VehicleType.heavy, day);
      expect((p[0].main, p[0].note), ('不確定', '官方未標示'));
    });

    test('沒有官方未標示的待確認仍寫待確認（實色灰）', () {
      final community = ParkingSpot.fromJson({
        ...lotJson,
        'source': 'community',
        'parking_zones': null,
      });
      final p = plates(community, VehicleType.heavy, day);
      expect((p[0].main, p[0].tone), ('待確認', PlateTone.unverified));
    });
  });

  test('目前車種不能停：只剩一面路牌', () {
    final heavyBay = ParkingSpot.fromJson({
      'id': 'h',
      'name': '重機格',
      'lat': 25,
      'lng': 121,
      'city': '臺北市',
      'space_type': 'heavyOnly',
      'facility_type': 'roadside',
      'source': 'official',
    });
    final p = plates(heavyBay, VehicleType.scooter, day);
    expect(p, hasLength(1));
    expect((p.single.main, p.single.tone), ('普通機車不能停', PlateTone.denied));
  });
}

class _Riders implements RiderSeats {
  const _Riders(this.seats);
  final List<RiderSeat> seats;
  @override
  List<RiderSeat> of(String spotId) => seats;
}
