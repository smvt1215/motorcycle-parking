import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/four_sign.dart';
import 'package:motorcycle_parking/domain/four_sign_display.dart';
import 'package:motorcycle_parking/domain/spot_detail_display.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';

import 'spot_detail_fixtures.dart';

/// The full-page details' words (spot_detail_display.dart) where review on
/// #336 found them parting from the plates or the data.
void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CityRule.fromJson)
          .toList();

  FourSign sign(
    ParkingSpot spot,
    VehicleType vehicle,
    DateTime now, {
    SpotAvailability availability = SpotAvailability.none,
  }) => fourSign(spot, vehicle, rules, now: now, availability: availability);

  Map<String, dynamic> lot(List<Map<String, dynamic>> zones) => {
    ...detailLotJson,
    'parking_zones': zones,
  };

  test('分區只有費率、沒有開放資料：費率卡用分區費率，和路牌一致（Codex P2）', () {
    final spot = ParkingSpot.fromJson(
      lot([
        {
          'id': 'b2',
          'name': 'B2 重機專區',
          'fee': {
            'heavy': {'mode': 'hourly', 'amount': 50, 'per_minutes': 60},
          },
        },
      ]),
    );
    expect(spot.zones.single.condition, isNull);
    final s = sign(spot, VehicleType.heavy, detailDay);
    final cards = feeSection(s, spot, detailDay).cards;
    expect(cards.map((c) => c.main), ['每小時 50 元']);
    expect(cards.single.header, contains('B2 重機專區'));
  });

  group('費率不適用（騎士端不寫成未提供）', () {
    const na = {'mode': 'not_applicable'};
    const hourly = {'mode': 'hourly', 'amount': 20, 'per_minutes': 60};
    Map<String, dynamic> zone(
      String id, {
      Map<String, dynamic>? fee,
      Map<String, dynamic>? condition,
    }) => {'id': id, 'name': '$id 區', 'fee': ?fee, 'condition': ?condition};
    FeeSection section(ParkingSpot spot) =>
        feeSection(sign(spot, VehicleType.heavy, detailDay), spot, detailDay);
    ParkingSpot zoned(List<Map<String, dynamic>> zones) =>
        ParkingSpot.fromJson({...lot(zones), 'fee': null, 'fee_note': ''});

    test('單區：標成不適用寫不適用，用淡色；另一車種照常', () {
      final spot = ParkingSpot.fromJson({
        ...lot(const []),
        'fee': {'scooter': hourly, 'heavy': na},
      });
      final card = section(spot).cards.single;
      expect((card.main, card.unknown), ('不適用', true));
      final scooter = feeSection(
        sign(spot, VehicleType.scooter, detailDay),
        spot,
        detailDay,
      );
      expect(scooter.cards.single.main, '每小時 20 元');
    });

    test('比照到不適用：比照機車、比照汽車都寫不適用', () {
      for (final fee in const [
        {
          'scooter': na,
          'heavy': {'mode': 'same_as_scooter'},
        },
        {
          'scooter': hourly,
          'heavy': {'mode': 'same_as_car'},
          'car': na,
        },
      ]) {
        final spot = ParkingSpot.fromJson({...lot(const []), 'fee': fee});
        expect(section(spot).cards.single.main, '不適用');
      }
    });

    test('沒有資料維持未提供，比照到沒有資料也是', () {
      final none = ParkingSpot.fromJson({
        ...lot(const []),
        'fee': {'scooter': hourly},
      });
      final follow = ParkingSpot.fromJson({
        ...lot(const []),
        'fee': {
          'heavy': {'mode': 'same_as_scooter'},
        },
      });
      for (final spot in [none, follow]) {
        final card = section(spot).cards.single;
        expect((card.main, card.unknown), ('未提供', true));
      }
    });

    test('多區全部不適用：合成一張不適用', () {
      final spot = zoned([
        zone('A', fee: {'heavy': na}),
        zone(
          'B',
          fee: {
            'scooter': na,
            'heavy': {'mode': 'same_as_scooter'},
          },
        ),
      ]);
      final fees = section(spot);
      expect(fees.cards.map((c) => c.main), ['不適用']);
      expect(fees.cards.single.note, '', reason: '不適用不是同價');
    });

    test('只有一區開放、全場費率不適用：不寫全場同價', () {
      Map<String, dynamic> allow(bool heavy) => {
        'bay': 'motorcycle',
        'use': 'usual',
        'allow': {'scooter': true, 'heavy': heavy},
      };
      final spot = ParkingSpot.fromJson({
        ...lot([
          zone('A', condition: allow(true)),
          zone('B', condition: allow(false)),
        ]),
        'fee': {'scooter': hourly, 'heavy': na},
      });
      final fees = section(spot);
      expect(fees.cards.map((c) => c.main), ['不適用']);
      expect(fees.sameNote, '');
    });

    test('多區混合：不適用與未提供、費率各自成卡，不算同價', () {
      final missing = zoned([
        zone('A', fee: {'heavy': na}),
        zone('B', fee: {'scooter': hourly}),
      ]);
      final cards = section(missing).cards;
      expect(cards.map((c) => c.main), ['不適用', '未提供']);
      expect(cards.every((c) => c.note.isEmpty), isTrue);
      final priced = zoned([
        zone('A', fee: {'heavy': na}),
        zone('B', fee: {'heavy': hourly}),
      ]);
      expect(section(priced).cards.map((c) => c.main), ['不適用', '每小時 20 元']);
    });

    test('稍後開放的分區不適用：寫不適用，不寫費率未提供、也不說同樣', () {
      const open = {
        'bay': 'motorcycle',
        'use': 'usual',
        'allow': {'heavy': true},
      };
      final spot = zoned([
        zone('A', fee: {'heavy': hourly}, condition: open),
        zone(
          'B',
          fee: {'heavy': na},
          condition: {
            ...open,
            'schedule': [
              {
                'days': 'all',
                'from': '20:00',
                'to': '23:00',
                'vehicles': ['heavy'],
              },
            ],
          },
        ),
      ]);
      final later = section(spot).later.single;
      expect(later, endsWith('，不適用'));
      expect(later, isNot(contains('費率未提供')));
    });

    test('DetailPrice：不適用不等於未提供', () {
      const na = DetailPrice(notApplicable: true);
      expect(na.none, isFalse);
      expect(na, isNot(const DetailPrice()));
      expect(const DetailPrice().none, isTrue);
    });
  });

  test('同類別的分區共用一個官方數字：合成一列，不各列一次（Codex P2）', () {
    Map<String, dynamic> heavyZone(String id, String name) => {
      'id': id,
      'name': name,
      'condition': {
        'bay': 'heavy',
        'use': 'usual',
        'allow': {'heavy': true},
      },
    };
    final spot = ParkingSpot.fromJson(
      lot([heavyZone('h1', '甲重機區'), heavyZone('h2', '乙重機區')]),
    );
    final counts = SpotAvailability([
      AvailabilitySnapshot(
        spotId: spot.id,
        vehicle: AvailabilityVehicle.heavy,
        provider: '臺北市停管處',
        window: AvailabilityWindow.taipei,
        total: 40,
        available: 4,
        sourceUpdatedAt: detailDay.subtract(const Duration(minutes: 2)),
      ),
    ]);
    final s = sign(spot, VehicleType.heavy, detailDay, availability: counts);
    final rows = seatRows(s, counts, detailDay);
    expect(rows, hasLength(1));
    expect(rows.single.name, '甲重機區、乙重機區');
    expect(rows.single.official, '剩 4 格');
    expect(rows.single.sub, contains('2 區共用同一個官方數字'));
    expect(rows.single.areas, hasLength(2));
    // Without a count the shared total is not given twice either.
    final none = seatRows(
      sign(spot, VehicleType.heavy, detailDay),
      SpotAvailability.none,
      detailDay,
    );
    expect(none, hasLength(1));
  });

  test('同一費率但限停時間不同：保留逐段卡片（Codex P2）', () {
    Map<String, dynamic> segment(String id, String name, int minutes) => {
      'id': id,
      'name': name,
      'side': id == 'a' ? 'north' : 'south',
      'condition': {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'limits': [
          {
            'kind': 'time_limit',
            'periods': [
              {'days': 'all', 'max_minutes': minutes, 'extensions': 1},
            ],
          },
        ],
      },
    };
    final spot = ParkingSpot.fromJson({
      ...detailStreetJson,
      'fee': {
        'scooter': {'mode': 'per_visit', 'amount': 0, 'extension_amount': 40},
        'heavy': {'mode': 'same_as_scooter'},
      },
      'parking_segments': [
        segment('a', '北側一般機車格', 20),
        segment('b', '南側一般機車格', 60),
      ],
    });
    final s = sign(spot, VehicleType.heavy, detailDay);
    final cards = feeSection(s, spot, detailDay).cards;
    expect(cards.map((c) => c.main), ['首 20 分鐘 0 元', '首 1 小時 0 元']);
    expect(cards.every((c) => c.note.isEmpty), isTrue);
    // The same stays still merge.
    final same = ParkingSpot.fromJson({
      ...detailStreetJson,
      'fee': spot.fee!.toJson(),
      'parking_segments': [
        segment('a', '北側一般機車格', 20),
        segment('b', '南側一般機車格', 20),
      ],
    });
    final merged = feeSection(
      sign(same, VehicleType.heavy, detailDay),
      same,
      detailDay,
    ).cards;
    expect(merged.map((c) => c.main), ['首 20 分鐘 0 元']);
    expect(merged.single.note, '各路段同價');
  });

  test('其他時段保留上限與隔日另計（Codex P2）', () {
    final spot = ParkingSpot.fromJson({
      ...detailBayJson,
      'fee': {
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'rate': {
                'mode': 'hourly',
                'amount': 20,
                'per_minutes': 60,
                'daily_cap': 100,
                'cap_reset': 'calendar_day',
              },
            },
            {
              'days': 'all',
              'from': '20:00',
              'to': '08:00',
              'rate': {'mode': 'per_visit', 'amount': 30, 'renew': 'midnight'},
            },
          ],
        },
        'heavy': {'mode': 'same_as_scooter'},
      },
    });
    final day = feeSection(
      sign(spot, VehicleType.heavy, detailDay),
      spot,
      detailDay,
    ).cards.single;
    expect(day.others, [('20:00–隔日 08:00', '每次 30 元，隔日另計')]);
    final night = feeSection(
      sign(spot, VehicleType.heavy, detailNight),
      spot,
      detailNight,
    ).cards.single;
    expect(night.others, [('08:00–20:00', '每小時 20 元，當日上限 100 元（零時重算）')]);
  });

  group('延後開放的說明用實際的下一次可停時間（Codex P2）', () {
    test('開放時段裡有禁停：不把禁停的時間寫成可停', () {
      // Opens 10:00–12:00, 11:00–15:00 禁停; read at 11:30.
      final at = DateTime.utc(2026, 11, 3, 3, 30);
      final spot = ParkingSpot.fromJson({
        ...detailBayJson,
        'parking_segments': [
          {
            'id': 'x',
            'name': '測試汽機車共用格',
            'side': 'north',
            'condition': {
              'bay': 'car',
              'use': 'share',
              'share': 'car_motorcycle',
              'schedule': [
                {
                  'days': 'all',
                  'from': '10:00',
                  'to': '12:00',
                  'vehicles': ['scooter'],
                },
              ],
              'limits': [
                {
                  'kind': 'no_parking',
                  'periods': [
                    {'days': 'all', 'from': '11:00', 'to': '15:00'},
                  ],
                },
              ],
            },
          },
        ],
      });
      final s = sign(spot, VehicleType.scooter, at);
      final area = s.areas.single;
      expect(area.window.now, isFalse);
      final words = laterWords(area, VehicleType.scooter);
      expect(words, isNot(contains('10:00–12:00')));
      expect(words, area.window.opensAt == null ? '' : contains('起'));
      expect(openHours(area, VehicleType.scooter), isNot(contains('–')));
    });

    test('公告在下次開放前到期：沒有下一次可停時間就不顯示', () {
      // Tuesday 2026-11-03 14:20; opens Mondays 20:00–23:00, notice ends
      // 11-08, before the next Monday.
      final expiring = ParkingSpot.fromJson(
        lot([
          {
            'id': 'b3',
            'name': 'B3 汽車區',
            'condition': {
              'bay': 'car',
              'use': 'share',
              'share': 'car_motorcycle',
              'allow': {'heavy': true},
              'schedule': [
                {
                  'days': ['mon'],
                  'from': '20:00',
                  'to': '23:00',
                  'vehicles': ['heavy'],
                },
              ],
              'basis': {
                'source_url': 'https://example.com/notice',
                'expires_on': '2026-11-08',
              },
            },
          },
        ]),
      );
      final s = sign(expiring, VehicleType.heavy, detailDay);
      final b3 = s.areas.single;
      expect(b3.status, isNot(EligibilityStatus.notAllowed));
      expect(b3.window.opensAt, isNull);
      expect(laterWords(b3, VehicleType.heavy), '');
      expect(placeState(b3, VehicleType.heavy), '');
      for (final card in whereCards(s, expiring, detailDay)) {
        expect(card.state, '');
      }
    });

    test('沒有禁停也沒有到期：照公告時段寫起訖', () {
      final s = sign(detailLot, VehicleType.heavy, detailDay);
      final b3 = s.areas.firstWhere((a) => a.id == 'b3');
      expect(laterWords(b3, VehicleType.heavy), '20:00–23:00 才開放大型重機');
    });
  });

  test('稍後開放的分區另有費率時，不寫全場同價（Codex P2 第 2 輪）', () {
    // B2 on the lot's 20 元; B3 opens 20:00–23:00 at its own 50 元.
    final zones = [
      for (final z
          in (detailLotJson['parking_zones'] as List)
              .cast<Map<String, dynamic>>())
        z['id'] == 'b3'
            ? {
                ...z,
                'fee': {
                  'heavy': {'mode': 'hourly', 'amount': 50, 'per_minutes': 60},
                },
              }
            : z,
    ];
    final spot = ParkingSpot.fromJson(lot(zones));
    final fees = feeSection(
      sign(spot, VehicleType.heavy, detailDay),
      spot,
      detailDay,
    );
    expect(fees.cards.map((c) => c.main), ['每小時 20 元']);
    expect(fees.sameNote, '');
    expect(fees.later.single, contains('每小時 50 元'));
    expect(fees.later.single, isNot(contains('同樣')));
    // At night both are open: two cards, neither says 同價.
    final night = feeSection(
      sign(spot, VehicleType.heavy, detailNight),
      spot,
      detailNight,
    );
    expect(night.cards.map((c) => c.main), ['每小時 20 元', '每小時 50 元']);
    expect(night.cards.every((c) => c.note.isEmpty), isTrue);
    // The demo lot, one rate everywhere, still reads 全場同價.
    expect(
      feeSection(
        sign(detailLot, VehicleType.heavy, detailDay),
        detailLot,
        detailDay,
      ).sameNote,
      '全場同價',
    );
  });

  test('計次延長：沒有限停資料也寫延長每次金額，次數已知才寫次數（Codex P2 第 2 輪）', () {
    Map<String, dynamic> bay({Map<String, dynamic>? condition}) => {
      ...detailBayJson,
      'fee': {
        'scooter': {'mode': 'per_visit', 'amount': 0, 'extension_amount': 40},
        'heavy': {'mode': 'same_as_scooter'},
      },
      'condition': ?condition,
    };
    final plain = ParkingSpot.fromJson(bay());
    final card = feeSection(
      sign(plain, VehicleType.scooter, detailDay),
      plain,
      detailDay,
    ).cards.single;
    expect(card.detail, contains('延長每次 40 元'));
    expect(card.detail, isNot(contains('可付')));
    final limited = ParkingSpot.fromJson(
      bay(
        condition: {
          'bay': 'motorcycle',
          'use': 'usual',
          'charge': 'toll',
          'limits': [
            {
              'kind': 'time_limit',
              'periods': [
                {'days': 'all', 'max_minutes': 120, 'extensions': 1},
              ],
            },
          ],
        },
      ),
    );
    final known = feeSection(
      sign(limited, VehicleType.scooter, detailDay),
      limited,
      detailDay,
    ).cards.single;
    expect(known.main, '首 2 小時 0 元');
    expect(known.detail, contains('可付 40 元延長 1 次'));
    expect(known.detail, isNot(contains('延長每次')));
  });

  test('稍後開放的分區寫完整費率條件，白天看得到隔日另計（Codex P2 第 3 輪）', () {
    final zones = [
      for (final z
          in (detailLotJson['parking_zones'] as List)
              .cast<Map<String, dynamic>>())
        z['id'] == 'b3'
            ? {
                ...z,
                'fee': {
                  'heavy': {
                    'mode': 'per_visit',
                    'amount': 30,
                    'renew': 'midnight',
                    'extension_amount': 10,
                  },
                },
              }
            : z,
    ];
    final spot = ParkingSpot.fromJson(lot(zones));
    final later = feeSection(
      sign(spot, VehicleType.heavy, detailDay),
      spot,
      detailDay,
    ).later.single;
    expect(later, contains('每次 30 元，隔日另計，延長每次 10 元'));
  });

  test('時段費率沒涵蓋的時間寫其他時間未提供', () {
    final spot = ParkingSpot.fromJson({
      ...detailBayJson,
      'fee': {
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'weekday',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
            },
          ],
        },
        'heavy': {'mode': 'same_as_scooter'},
      },
    });
    final card = feeSection(
      sign(spot, VehicleType.scooter, detailDay),
      spot,
      detailDay,
    ).cards.single;
    expect(card.main, '每小時 20 元');
    expect(card.others, contains(('其他時間', '未提供')));
  });

  test('身障特製機車的資格限制留在規則列，說明只在規則列說完時才省略（Codex P2 第 3 輪）', () {
    final spot = ParkingSpot.fromJson({
      ...detailBayJson,
      'space_type': 'disabledMotorcycle',
      'condition': {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'free',
        'limits': [
          {'kind': 'special_vehicle', 'vehicle': 'disabled_modified'},
        ],
      },
    });
    final s = sign(spot, VehicleType.scooter, detailDay);
    final rules = detailRules(s, spot);
    expect(
      rules.where((r) => r.kind == DetailRuleKind.special).single.text,
      contains('身障特製機車'),
    );
    expect(rules.first.label, '限定');
    expect(rulesCover('身障專用格：須是經監理站檢驗合格的特製機車', rules), isTrue);
    // A reason the rows do not carry keeps the explanation.
    expect(rulesCover('身障專用格：須是特製機車；此路段施工中', rules), isFalse);
    expect(rulesCover('任何說明', const []), isFalse);
    // An unlabelled part continues the clause before it.
    final limits = detailRules(
      sign(detailLot, VehicleType.heavy, detailDay),
      detailLot,
    );
    expect(rulesCover('禁停時段：每天 23:00–隔日 07:00；假日 全天', limits), isTrue);
  });

  test('舊費率文字依車種隔離：只有普通機車的文字時，重機不借用（Codex P2 第 4 輪）', () {
    final spot = ParkingSpot.fromJson({
      ...detailLotJson,
      'fee': null,
      'fee_note': '',
      'parking_zones': [
        {
          'id': 'z',
          'name': '機車區',
          'scooter_fee_note': '每次 10 元',
          'fee_note': '每次 10 元',
          'condition': {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'allow': {'scooter': true, 'heavy': true},
          },
        },
      ],
    });
    String main(VehicleType v) =>
        feeSection(sign(spot, v, detailDay), spot, detailDay).cards.single.main;
    expect(main(VehicleType.scooter), '每次 10 元');
    expect(main(VehicleType.heavy), '未提供');
    // The plate keeps to the vehicle too.
    String plate(VehicleType v) => fourSignPlates(
      sign(spot, v, detailDay),
      detailDay,
    ).firstWhere((p) => p.face == FourSignFace.fee).main;
    expect(plate(VehicleType.scooter), '每次 10 元');
    expect(plate(VehicleType.heavy), isNot('每次 10 元'));
    // With no per-vehicle text, the zone's note stands for both.
    final general = ParkingSpot.fromJson({
      ...detailLotJson,
      'fee': null,
      'fee_note': '',
      'parking_zones': [
        {
          'id': 'z',
          'name': '機車區',
          'fee_note': '每次 15 元',
          'condition': {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'allow': {'scooter': true, 'heavy': true},
          },
        },
      ],
    });
    expect(
      feeSection(
        sign(general, VehicleType.heavy, detailDay),
        general,
        detailDay,
      ).cards.single.main,
      '每次 15 元',
    );
  });

  test('稍後開放分區的時段費率保留跨時段計費方式（Codex P2）', () {
    String later(String cross) {
      final zones = [
        for (final z
            in (detailLotJson['parking_zones'] as List)
                .cast<Map<String, dynamic>>())
          z['id'] == 'b3'
              ? {
                  ...z,
                  'fee': {
                    'heavy': {
                      'mode': 'by_time',
                      'cross_period': cross,
                      'periods': [
                        {
                          'days': 'all',
                          'from': '20:00',
                          'to': '22:00',
                          'rate': {'mode': 'per_visit', 'amount': 30},
                        },
                        {
                          'days': 'all',
                          'from': '22:00',
                          'to': '20:00',
                          'rate': {'mode': 'per_visit', 'amount': 30},
                        },
                      ],
                    },
                  },
                }
              : z,
      ];
      final spot = ParkingSpot.fromJson(lot(zones));
      return feeSection(
        sign(spot, VehicleType.heavy, detailDay),
        spot,
        detailDay,
      ).later.single;
    }

    final each = later('each_period'), entry = later('entry_only');
    expect(each, contains('跨時段分別計費'));
    expect(entry, contains('依進場時段計費'));
    expect(each, isNot(entry));
  });
}
