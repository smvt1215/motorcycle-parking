import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/models/holiday_calendar.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';

/// decideParking() and ruleVerdict() (design §3.2–§3.3, C4).
void main() {
  final bundledJson = (jsonDecode(
    File('assets/rules/parking_rules.json').readAsStringSync(),
  ) as List<dynamic>).cast<Map<String, dynamic>>();
  final bundled = bundledJson.map(CityRule.fromJson).toList();
  CityRule rule(String city, VehicleType vehicle) =>
      bundled.firstWhere((r) => r.city == city && r.vehicle == vehicle);
  final now = DateTime.utc(2026, 10, 27, 4);
  final recent = now.subtract(const Duration(days: 1));

  ParkingSpot street(
    SpaceType type, {
    ParkingCondition? condition,
    String city = '臺北市',
    String district = '',
    TrustStatus status = TrustStatus.confirmed,
    String source = 'community',
    bool? scooter,
    bool? heavy,
    DateTime? confirmed,
  }) => ParkingSpot(
    id: 'test',
    name: 'test',
    lat: 25,
    lng: 121,
    city: city,
    district: district,
    spaceType: type,
    condition: condition,
    source: source,
    status: status,
    scooterAllowed: scooter,
    heavyAllowed: heavy,
    lastConfirmedAt: confirmed ?? recent,
  );

  group('ruleVerdict：§5.7 共同向量（Dart／SQL／Deno）', () {
    final vectors = jsonDecode(
      File('supabase/functions/_shared/rule_verdict_cases.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final rules = (vectors['rules'] as Map<String, dynamic>)
        .cast<String, Map<String, dynamic>>();

    test('bundled:* 與 assets/rules/parking_rules.json 完全相同', () {
      final ids = rules.keys.where((k) => k.startsWith('bundled:')).toList();
      expect(ids, hasLength(bundledJson.length));
      for (final id in ids) {
        final r = rules[id]!;
        final match = bundledJson.firstWhere(
          (b) => b['city'] == r['city'] && b['vehicle'] == r['vehicle'],
        );
        expect(jsonEncode(r), jsonEncode(match), reason: id);
      }
    });

    test('每個向量的結論與限制一致', () {
      final cases = vectors['cases'] as List<dynamic>;
      expect(cases, isNotEmpty);
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final v = ruleVerdict(
          [
            for (final id in (c['rules'] as List).cast<String>())
              CityRule.fromJson(rules[id]!),
          ],
          SpaceType.values.byName(c['kind'] as String),
          c['district'] as String,
          now: DateTime.parse(c['now'] as String),
        );
        expect(v.kind.name, c['verdict'], reason: c['name'] as String);
        expect(
          v.restriction?.key,
          c['restriction'],
          reason: c['name'] as String,
        );
      }
    });

    test('覆蓋七種結論', () {
      final kinds = {
        for (final c in (vectors['cases'] as List).cast<Map<String, dynamic>>())
          c['verdict'],
      };
      expect(kinds, {for (final k in RuleVerdictKind.values) k.name});
    });
  });

  group('eligibility() 包裝與舊實作一致（除設計列出的修正）', () {
    // Every legacy street kind (no condition) × vehicle × trust × rule ×
    // district × date. The only differences allowed are the design's:
    // a timed bay whose charge is unconfirmed (§3.1 item 3) and the shared
    // car bay (§7 item 1).
    final rulesUnderTest = <CityRule?>[
      null,
      ...bundled,
      CityRule.fromJson({
        'city': '臺北市',
        'vehicle': 'scooter',
        'allowed_space_types': ['paidMotorcycle'],
        'district_space_types': {
          'car': ['中山區'],
        },
        'districts': ['中山區', '大安區'],
        'fee_note': 'x',
        'exceptions': '測試',
        'source_url': 'https://example.test',
        'version': 2,
        'effective_date': '2026-01-01',
      }),
    ];
    final spots = <ParkingSpot>[
      for (final type in SpaceType.values)
        if (type != SpaceType.offStreet)
          for (final city in ['臺北市', '新北市', '臺中市', '高雄市'])
            for (final district in ['', '板橋區', '中山區'])
              for (final (status, source, confirmed) in [
                (TrustStatus.confirmed, 'community', recent),
                (TrustStatus.pending, 'community', recent),
                (TrustStatus.confirmed, 'community', DateTime(2020)),
                (TrustStatus.confirmed, 'official', recent),
              ])
                for (final flag in [null, true, false])
                  ParkingSpot(
                    id: 's',
                    name: 's',
                    lat: 25,
                    lng: 121,
                    city: city,
                    district: district,
                    spaceType: type,
                    source: source,
                    status: status,
                    lastConfirmedAt: confirmed,
                    scooterAllowed: flag,
                    heavyAllowed: flag,
                  ),
    ];

    test('路邊格位窮舉', () {
      var compared = 0;
      final differences = <String>{};
      for (final spot in spots) {
        for (final vehicle in VehicleType.values) {
          for (final r in rulesUnderTest) {
            // As the app picks them (AppStore.ruleFor): the vehicle's rule
            // of the spot's city, else the national one.
            if (r != null &&
                (r.vehicle != vehicle ||
                    (r.city != spot.city && r.city != '全國'))) {
              continue;
            }
            for (final at in [DateTime(2026, 9, 1), now]) {
              compared++;
              final old = legacyEligibility(spot, vehicle, r, now: at);
              final got = eligibility(spot, vehicle, r, now: at);
              if (old.status == got.status &&
                  old.restriction == got.restriction &&
                  old.reason == got.reason) {
                continue;
              }
              final kind = spot.spaceType;
              final expected = switch (kind) {
                // The charge decides; when paid and free bays differ, it is
                // unverified (§3.2 ruleKindOf).
                SpaceType.timedMotorcycle =>
                  got.status == EligibilityStatus.unverified &&
                      got.reason == '無法確認此格是收費格或免費格，請看現場牌面',
                // Scooters only in the posted slots; heavy bikes as on any
                // car bay (a legacy shared bay has no slots on file), told
                // to follow the sign's slots where they may park
                // (PM_ANS_20261031_21).
                SpaceType.flexShared =>
                  vehicle == VehicleType.scooter
                      ? got.status == EligibilityStatus.unverified
                      : () {
                          final car = eligibility(
                            street(
                              SpaceType.car,
                              city: spot.city,
                              district: spot.district,
                              status: spot.status,
                              source: spot.source,
                              confirmed: spot.lastConfirmedAt,
                              heavy: spot.heavyAllowed,
                              scooter: spot.scooterAllowed,
                            ),
                            vehicle,
                            r,
                            now: at,
                          );
                          final open =
                              car.status == EligibilityStatus.allowed ||
                              car.status == EligibilityStatus.conditional;
                          return got.status == car.status &&
                              got.restriction == car.restriction &&
                              got.reason ==
                                  (open
                                      ? '${car.reason}；汽機車共用格請依現場牌面時段停放'
                                      : car.reason);
                        }(),
                _ => false,
              };
              expect(
                expected,
                isTrue,
                reason:
                    '$kind ${spot.city}${spot.district} ${spot.status.name} '
                    '${spot.source} ${vehicle.name} ${r?.city}: '
                    '${old.status.name}/${old.reason} → '
                    '${got.status.name}/${got.reason}',
              );
              differences.add('${kind.name}:${vehicle.name}');
            }
          }
        }
      }
      expect(compared, greaterThan(10000));
      // Only these change, and they do change.
      expect(differences, {
        // The test rule opens paid bays to scooters, not free ones.
        'timedMotorcycle:scooter',
        'timedMotorcycle:heavy',
        'flexShared:scooter',
        'flexShared:heavy',
      });
    });

    test('沒有分區的路外停車場窮舉', () {
      for (final source in ['official', 'community', 'import']) {
        for (final flag in [null, true, false]) {
          for (final verifiedAt in [null, recent, DateTime(2020)]) {
            final lot = ParkingSpot(
              id: 'lot',
              name: 'lot',
              lat: 25,
              lng: 121,
              city: '臺北市',
              spaceType: SpaceType.offStreet,
              source: source,
              status: TrustStatus.confirmed,
              lastConfirmedAt: recent,
              scooterAllowed: flag,
              heavyAllowed: flag,
              scooterVerifiedAt: verifiedAt,
              heavyVerifiedAt: verifiedAt,
            );
            for (final vehicle in VehicleType.values) {
              final old = legacyEligibility(lot, vehicle, null, now: now);
              final got = eligibility(lot, vehicle, null, now: now);
              expect(
                (got.status, got.reason, got.restriction),
                (old.status, old.reason, old.restriction),
                reason: '$source $flag $verifiedAt ${vehicle.name}',
              );
            }
          }
        }
      }
    });

    test('切回舊實作的開關存在（保留一版）', () {
      expect(useParkingDecision, isTrue);
      expect(
        legacyEligibility(
          street(SpaceType.paidMotorcycle),
          VehicleType.heavy,
          rule('臺北市', VehicleType.heavy),
          now: now,
        ).status,
        EligibilityStatus.allowed,
      );
    });
  });

  group('路邊：條件 × 車種 × 規則 × 期限', () {
    ParkingCondition c(Map<String, Object?> json) =>
        ParkingCondition.fromJson(json)!;
    const basisOk = {
      'source_url': 'https://example.test/notice',
      'effective_date': '2026-04-06',
      'expires_on': '2026-12-31',
    };
    const basisEnded = {
      'source_url': 'https://example.test/notice',
      'effective_date': '2026-04-06',
      'expires_on': '2026-10-05',
    };
    final shareToll = {
      'bay': 'motorcycle',
      'use': 'share',
      'share': 'scooter_heavy',
      'charge': 'toll',
    };

    test('限時格依收費屬性比對規則，不再一律當收費格', () {
      ParkingDecision timed(String? charge, VehicleType v) => decideParking(
        street(
          SpaceType.timedMotorcycle,
          condition: c({
            'bay': 'motorcycle',
            'use': 'usual',
            'charge': ?charge,
            'limits': [
              {'kind': 'time_limit', 'max_minutes': 20},
            ],
          }),
        ),
        v,
        bundled,
        now: now,
      );
      final heavy = VehicleType.heavy;
      expect(timed('toll', heavy).status, EligibilityStatus.conditional);
      expect(timed('toll', heavy).restriction, RuleRestriction.timeLimited);
      // Taipei opens paid bays to heavy bikes, not free ones.
      expect(timed('free', heavy).status, EligibilityStatus.notAllowed);
      expect(timed(null, heavy).status, EligibilityStatus.unverified);
      expect(timed(null, heavy).gaps, {DecisionGap.chargeUnknown});
      // Scooters park on both, so the charge does not matter.
      expect(
        timed(null, VehicleType.scooter).status,
        EligibilityStatus.conditional,
      );
    });

    test('限時分時段：說出現在的限停時長與延長次數，不在時段內也說（#188 第 2 層）', () {
      ParkingDecision at(DateTime when) => decideParking(
        street(
          SpaceType.timedMotorcycle,
          condition: c({
            'bay': 'motorcycle',
            'use': 'usual',
            'charge': 'toll',
            'limits': [
              {
                'kind': 'time_limit',
                'periods': [
                  {
                    'days': 'all',
                    'from': '07:00',
                    'to': '20:00',
                    'max_minutes': 120,
                    'extensions': 1,
                  },
                ],
              },
            ],
          }),
        ),
        VehicleType.heavy,
        bundled,
        now: when,
      );
      // 12:00 and 22:00 Taipei.
      final noon = at(DateTime.utc(2026, 10, 27, 4));
      expect(noon.status, EligibilityStatus.conditional);
      expect(noon.restriction, RuleRestriction.timeLimited);
      expect(noon.reason, contains('現在每次限停 2 小時，可延長 1 次'));
      expect(noon.reason, contains('限時時段：每天 07:00–20:00 每次限停 2 小時，可延長 1 次'));
      expect(at(DateTime.utc(2026, 10, 27, 14)).reason, contains('現在不在限時時段'));
    });

    test('時段性禁停：禁停時段內說明現在不可停（#188 第 2 層）', () {
      ParkingDecision at(DateTime when) => decideParking(
        street(
          SpaceType.paidMotorcycle,
          condition: c({
            'bay': 'motorcycle',
            'use': 'usual',
            'charge': 'toll',
            'limits': [
              {
                'kind': 'no_parking',
                'periods': [
                  {
                    'days': ['tue'],
                    'from': '11:00',
                    'to': '13:00',
                  },
                ],
              },
            ],
          }),
        ),
        VehicleType.scooter,
        bundled,
        now: when,
      );
      final during = at(DateTime.utc(2026, 10, 27, 4));
      expect(during.status, EligibilityStatus.conditional);
      expect(during.restriction, RuleRestriction.timeLimited);
      expect(during.reason, contains('現在是禁停時段，不可停放'));
      expect(during.reason, contains('禁停時段：週二 11:00–13:00'));
      final after = at(DateTime.utc(2026, 10, 27, 8));
      expect(after.reason, isNot(contains('現在是禁停時段')));
      expect(after.reason, contains('禁停時段：週二 11:00–13:00'));
    });

    test('路邊逐段判斷：資格跟格位走，點位結論取最開放的一段（#188 第 2 層）', () {
      ParkingSegment seg(String name, Map<String, Object?> condition) =>
          ParkingSegment.fromJson({'name': name, 'condition': condition});
      final spot = ParkingSpot(
        id: 'segments',
        name: 'segments',
        lat: 25,
        lng: 121,
        city: '臺北市',
        spaceType: SpaceType.paidMotorcycle,
        condition: c({'bay': 'motorcycle', 'use': 'usual', 'charge': 'toll'}),
        source: 'official',
        segments: [
          seg('北側', {
            'allow': {'scooter': true, 'heavy': false},
          }),
          seg('南側', {
            ...shareToll,
            'allow': {'scooter': true, 'heavy': true},
          }),
          seg('西側', {
            'allow': {'scooter': true, 'heavy': 'not_stated'},
          }),
        ],
      );
      final heavy = decideParking(spot, VehicleType.heavy, bundled, now: now);
      expect(
        [for (final z in heavy.segments) z.status],
        [
          EligibilityStatus.notAllowed,
          EligibilityStatus.allowed,
          EligibilityStatus.unverified,
        ],
      );
      expect(heavy.segments.first.reason, '此路段標示不開放大型重機');
      expect(heavy.segments.last.gaps, {DecisionGap.notStated});
      expect(heavy.status, EligibilityStatus.allowed);
      final closed = ParkingSpot.fromJson({
        ...spot.toJson(),
        'parking_segments': [
          {
            'name': '北側',
            'condition': {
              'allow': {'scooter': true, 'heavy': false},
            },
          },
        ],
      });
      expect(
        decideParking(closed, VehicleType.heavy, bundled, now: now).status,
        EligibilityStatus.notAllowed,
      );
    });

    test('普大共用標示是公告；有效時比縣市規則具體，到期回到規則或待確認', () {
      ParkingDecision share(Map<String, Object?>? basis, String city) =>
          decideParking(
            street(
              SpaceType.paidMotorcycle,
              city: city,
              condition: c({...shareToll, 'basis': ?basis}),
            ),
            VehicleType.heavy,
            bundled,
            now: now,
          );
      // Kaohsiung closes street bays to heavy bikes; the sign opens this one.
      expect(share(null, '高雄市').status, EligibilityStatus.allowed);
      final open = share(basisOk, '高雄市');
      expect(open.status, EligibilityStatus.allowed);
      expect(
        open.basis.where((b) => b.kind == BasisKind.notice).single.expiresOn,
        '2026-12-31',
      );
      // Ended: Kaohsiung's rule does not cover it → unverified.
      final ended = share(basisEnded, '高雄市');
      expect(ended.status, EligibilityStatus.unverified);
      expect(ended.gaps, contains(DecisionGap.noticeExpired));
      expect(ended.reason, contains('2026-10-05 到期'));
      expect(
        ended.basis.where((b) => b.kind == BasisKind.notice).single.expired,
        isTrue,
      );
      // Ended, but Taipei's rule opens paid bays anyway.
      final taipei = share(basisEnded, '臺北市');
      expect(taipei.status, EligibilityStatus.allowed);
      expect(taipei.gaps, contains(DecisionGap.noticeExpired));
      // Unchecked reports never open it.
      expect(
        decideParking(
          street(
            SpaceType.paidMotorcycle,
            city: '高雄市',
            status: TrustStatus.pending,
            condition: c(shareToll),
          ),
          VehicleType.heavy,
          bundled,
          now: now,
        ).status,
        EligibilityStatus.unverified,
      );
      // Scooters are unaffected by the sign.
      expect(
        decideParking(
          street(
            SpaceType.paidMotorcycle,
            city: '高雄市',
            condition: c(shareToll),
          ),
          VehicleType.scooter,
          bundled,
          now: now,
        ).status,
        EligibilityStatus.allowed,
      );
    });

    test('汽機共用格：普通機車只在公告寫明的時段，大型重機依法可停', () {
      ParkingDecision flex(List<String> vehicles, VehicleType v) =>
          decideParking(
            street(
              SpaceType.flexShared,
              condition: c({
                'bay': 'car',
                'use': 'share',
                'share': 'car_motorcycle',
                'schedule': [
                  {
                    'days': 'weekday',
                    'from': '07:00',
                    'to': '20:00',
                    'vehicles': ['car'],
                  },
                  {
                    'days': 'holiday',
                    'vehicles': ['car', ...vehicles],
                  },
                ],
              }),
            ),
            v,
            bundled,
            now: now,
          );
      final scooter = flex(['scooter'], VehicleType.scooter);
      expect(scooter.status, EligibilityStatus.conditional);
      expect(scooter.restriction, RuleRestriction.timeLimited);
      expect(scooter.reason, contains('假日全天'));
      final none = flex([], VehicleType.scooter);
      expect(none.status, EligibilityStatus.unverified);
      expect(none.gaps, {DecisionGap.scheduleUnknown});
      expect(none.reason, '公告沒有列出普通機車的開放時段，請看現場牌面');
      // Heavy bikes park in the car slots (PM_ANS_20261031_21): a working
      // Tuesday noon is inside 平日 07:00–20:00.
      final heavy = flex([], VehicleType.heavy);
      expect(heavy.status, EligibilityStatus.conditional);
      expect(heavy.restriction, RuleRestriction.timeLimited);
      expect(heavy.reason, contains('現在可停'));
      expect(heavy.reason, contains('平日 07:00–20:00'));
      expect(heavy.reason, contains('假日全天'));
    });

    group('大型重機停汽機車共用格：汽車時段＋縣市規則開放的機車時段＋公告寫明的時段（PM_ANS_20261031_21）', () {
      DateTime at(int y, int m, int d, int h) =>
          DateTime.utc(y, m, d, h).subtract(const Duration(hours: 8));
      final dayCar = {
        'days': 'weekday',
        'from': '07:00',
        'to': '20:00',
        'vehicles': ['car'],
      };
      final nightScooter = {
        'days': 'all',
        'from': '20:00',
        'to': '07:00',
        'vehicles': ['scooter'],
      };
      ParkingDecision shared(
        VehicleType v,
        DateTime when, {
        String? charge = 'toll',
        List<Map<String, Object>>? schedule,
        List<Map<String, Object>> limits = const [],
        List<CityRule>? rules,
      }) => decideParking(
        street(
          SpaceType.flexShared,
          condition: c({
            'bay': 'car',
            'use': 'share',
            'share': 'car_motorcycle',
            'charge': ?charge,
            if (limits.isNotEmpty) 'limits': limits,
            if ((schedule ?? [dayCar, nightScooter]) case final slots
                when slots.isNotEmpty)
              'schedule': slots,
          }),
        ),
        v,
        rules ?? bundled,
        now: when,
      );

      test('臺北收費共用格、重機規則已生效：重機白天夜間都可停並列出兩段，普通機車只列夜間', () {
        final noon = at(2026, 10, 27, 12), night = at(2026, 10, 27, 22);
        for (final when in [noon, night]) {
          final d = shared(VehicleType.heavy, when);
          expect(d.status, EligibilityStatus.conditional);
          expect(d.restriction, RuleRestriction.timeLimited);
          expect(d.reason, contains('現在可停'));
          expect(d.reason, contains('平日 07:00–20:00'));
          expect(d.reason, contains('每天 20:00–隔日 07:00'));
          final kinds = d.basis.map((b) => b.kind).toList();
          expect(kinds, contains(BasisKind.cityRule));
        }
        final scooter = shared(VehicleType.scooter, noon);
        expect(scooter.status, EligibilityStatus.conditional);
        expect(scooter.reason, contains('現在不可停，20:00 起可停'));
        expect(scooter.reason, contains('每天 20:00–隔日 07:00'));
        expect(scooter.reason, isNot(contains('07:00–20:00')));
      });

      test('臺中共用格：機車時段依有條件規則納入，保留「限標示車格」與規則說明（Codex #226）', () {
        ParkingDecision taichung(String charge) => decideParking(
          street(
            SpaceType.flexShared,
            city: '臺中市',
            condition: c({
              'bay': 'car',
              'use': 'share',
              'share': 'car_motorcycle',
              'charge': charge,
              'schedule': [dayCar, nightScooter],
            }),
          ),
          VehicleType.heavy,
          bundled,
          now: at(2026, 10, 27, 22),
        );
        for (final charge in ['toll', 'free']) {
          final d = taichung(charge);
          expect(d.status, EligibilityStatus.conditional, reason: charge);
          expect(d.restriction, RuleRestriction.signage, reason: charge);
          expect(d.reason, contains('現在可停'), reason: charge);
          expect(d.reason, contains('每天 20:00–隔日 07:00'), reason: charge);
          expect(d.reason, contains('機車時段：'), reason: charge);
          expect(d.reason, contains('大重機共用'), reason: charge);
        }
        // Taipei's toll bays open without that limit.
        final taipei = shared(VehicleType.heavy, at(2026, 10, 27, 22));
        expect(taipei.restriction, RuleRestriction.timeLimited);
        expect(taipei.reason, isNot(contains('機車時段：')));
        expect(taipei.reason, isNot(contains('大重機共用')));
      });

      test('heavyShareSlotsOf：四面路牌與 decideParking 用同一份時段（#188 第 2 層）', () {
        ParkingCondition shareOf(
          String charge,
          List<Map<String, Object>> slots,
        ) => c({
          'bay': 'car',
          'use': 'share',
          'share': 'car_motorcycle',
          'charge': charge,
          if (slots.isNotEmpty) 'schedule': slots,
        });
        final taipei = heavyShareSlotsOf(
          shareOf('toll', [dayCar, nightScooter]),
          [rule('臺北市', VehicleType.heavy)],
          district: '',
          now: at(2026, 10, 27, 22),
        );
        expect(taipei.slots, hasLength(2));
        expect(taipei.ruleLimit, isNull);
        expect(taipei.scheduleUnknown, isFalse);
        expect(
          taipei.basis.map((b) => b.kind),
          containsAll([BasisKind.law, BasisKind.cityRule]),
        );
        final taichung = heavyShareSlotsOf(
          shareOf('toll', [dayCar, nightScooter]),
          [rule('臺中市', VehicleType.heavy)],
          district: '',
          now: at(2026, 10, 27, 22),
        );
        expect(taichung.ruleLimit?.restriction, RuleRestriction.signage);
        expect(taichung.ruleLimit?.reason, contains('大重機共用'));
        // Free bays: Taipei's rule opens no scooter slot.
        final free = heavyShareSlotsOf(
          shareOf('free', [nightScooter]),
          [rule('臺北市', VehicleType.heavy)],
          district: '',
          now: at(2026, 10, 27, 22),
        );
        expect(free.scheduleUnknown, isTrue);
      });

      test('重機規則尚未生效（2026-10-05）：重機只列汽車時段，夜間現在不可停並給下一段', () {
        // The rule Taipei heavy bikes had before 2026-10-06: car and heavy
        // bays only, no motorcycle bays.
        final before = CityRule.fromJson({
          ...bundledJson.firstWhere(
            (r) => r['city'] == '臺北市' && r['vehicle'] == 'heavy',
          ),
          'allowed_space_types': ['heavyOnly', 'car'],
          'effective_date': '2026-01-01',
          'can_use_two_spaces': false,
        });
        final rules = [before, rule('臺北市', VehicleType.heavy)];
        final d = shared(VehicleType.heavy, at(2026, 10, 5, 22), rules: rules);
        expect(d.status, EligibilityStatus.conditional);
        expect(d.reason, contains('現在不可停，明天 07:00 起可停'));
        expect(d.reason, contains('平日 07:00–20:00'));
        expect(d.reason, isNot(contains('20:00–隔日 07:00')));
        expect(d.basis.map((b) => b.kind), contains(BasisKind.law));
      });

      test('免費共用格：臺北重機規則不含免費機車格，重機只列汽車時段', () {
        final d = shared(
          VehicleType.heavy,
          at(2026, 10, 27, 22),
          charge: 'free',
        );
        expect(d.status, EligibilityStatus.conditional);
        expect(d.reason, contains('現在不可停'));
        expect(d.reason, contains('平日 07:00–20:00'));
        expect(d.reason, isNot(contains('20:00–隔日 07:00')));
      });

      test('收費或免費未確認：兩種格的規則不一致，機車時段不納入', () {
        final d = shared(VehicleType.heavy, at(2026, 10, 27, 22), charge: null);
        expect(d.reason, isNot(contains('20:00–隔日 07:00')));
        expect(d.reason, contains('平日 07:00–20:00'));
      });

      test('公告直接寫大型重機的時段照公告納入', () {
        final d = shared(
          VehicleType.heavy,
          at(2026, 10, 27, 22),
          charge: 'free',
          schedule: [
            dayCar,
            {
              'days': 'all',
              'from': '20:00',
              'to': '07:00',
              'vehicles': ['scooter', 'heavy'],
            },
          ],
        );
        expect(d.status, EligibilityStatus.conditional);
        expect(d.reason, contains('現在可停'));
        expect(d.reason, contains('每天 20:00–隔日 07:00'));
        expect(d.basis.map((b) => b.kind), contains(BasisKind.notice));
      });

      test('只有機車時段、規則未對重機開放：重機待確認', () {
        final d = shared(
          VehicleType.heavy,
          at(2026, 10, 27, 22),
          charge: 'free',
          schedule: [nightScooter],
        );
        expect(d.status, EligibilityStatus.unverified);
        expect(d.gaps, contains(DecisionGap.scheduleUnknown));
        expect(d.reason, contains('開放的機車時段'));
      });

      test('沒有時段資料：重機照汽車格依法可停，提醒依現場牌面時段', () {
        final d = shared(
          VehicleType.heavy,
          at(2026, 10, 27, 22),
          schedule: const [],
        );
        expect(d.status, EligibilityStatus.allowed);
        expect(d.reason, endsWith('汽機車共用格請依現場牌面時段停放'));
      });

      test('身障／充電共用格：重機維持有條件，限制與時段都保留（P7 回歸）', () {
        for (final limit in [
          {'kind': 'special_vehicle', 'vehicle': 'disabled_modified'},
          {'kind': 'ev_only'},
        ]) {
          for (final schedule in [
            const <Map<String, Object>>[],
            [dayCar, nightScooter],
          ]) {
            final d = shared(
              VehicleType.heavy,
              at(2026, 10, 27, 22),
              schedule: schedule,
              limits: [limit],
            );
            expect(d.status, EligibilityStatus.conditional, reason: '$limit');
            expect(
              d.reason,
              contains(limit['kind'] == 'ev_only' ? '限電動機車' : '特製機車'),
            );
            if (schedule.isNotEmpty) {
              expect(d.reason, contains('每天 20:00–隔日 07:00'));
            }
          }
        }
      });
    });

    test('時段：目前車種沒有出現在任何時段就是待確認', () {
      ParkingDecision slotted(List<String> vehicles) => decideParking(
        street(
          SpaceType.heavyOnly,
          condition: c({
            'bay': 'heavy',
            'use': 'usual',
            'schedule': [
              {
                'days': 'all',
                'from': '22:00',
                'to': '06:00',
                'vehicles': vehicles,
              },
            ],
          }),
        ),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(slotted(['heavy']).status, EligibilityStatus.conditional);
      expect(slotted(['heavy']).reason, contains('每天 22:00–隔日 06:00'));
      expect(slotted(['car']).status, EligibilityStatus.unverified);
      expect(slotted(['car']).gaps, {DecisionGap.scheduleUnknown});
    });

    group('時段依目前時間判斷可不可停（#120、決定 61）', () {
      DateTime at(int y, int m, int d, int h, [int min = 0]) =>
          DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));
      const night = ScheduleSlot(
        days: 'weekday',
        from: '20:00',
        to: '07:00',
        vehicles: [SlotVehicle.scooter],
      );
      const holiday = ScheduleSlot(
        days: 'holiday',
        vehicles: [SlotVehicle.scooter],
      );

      test('時段內現在可停，時段外寫下一段何時開始', () {
        // 2026-11-03 is a Tuesday after a working Monday.
        expect(slotNowText([night], at(2026, 11, 3, 21)), '現在可停');
        expect(slotNowText([night], at(2026, 11, 3, 6, 59)), '現在可停');
        expect(slotNowText([night], at(2026, 11, 3, 7)), '現在不可停，20:00 起可停');
        // 2026-10-26 is a Monday off (補假): its night is not 平日.
        expect(slotNowText([night], at(2026, 10, 27, 6)), '現在不可停，20:00 起可停');
      });

      test('跨午夜依開始那天：週五晚到週六 07:00 可停，之後到週一 20:00', () {
        // 2026-10-30 Friday night belongs to Friday (decision 47).
        expect(slotNowText([night], at(2026, 10, 31, 3)), '現在可停');
        expect(slotNowText([night], at(2026, 10, 31, 8)), '現在不可停，週一 20:00 起可停');
        expect(slotNowText([night], at(2026, 11, 1, 8)), '現在不可停，明天 20:00 起可停');
      });

      test('國定假日算假日：端午週五白天依假日時段可停', () {
        expect(slotNowText([holiday], at(2026, 6, 19, 10)), '現在可停');
        // Thursday's night ends at 07:00 on 端午; Friday night is not 平日.
        expect(slotNowText([night], at(2026, 6, 19, 6)), '現在可停');
        expect(slotNowText([night], at(2026, 6, 19, 8)), '現在不可停，週一 20:00 起可停');
        expect(
          slotNowText(
            [holiday],
            at(2026, 6, 19, 10),
            calendar: HolidayCalendar.none,
          ),
          '現在不可停，明天 00:00 起可停（$holidayFallbackNote）',
        );
      });

      test('沒有日曆的年份退回週六日並標示', () {
        expect(
          slotNowText([night], at(2030, 6, 19, 21)),
          '現在可停（$holidayFallbackNote）',
        );
        const every = ScheduleSlot(
          days: 'all',
          from: '08:00',
          to: '10:00',
          vehicles: [SlotVehicle.scooter],
        );
        expect(slotNowText([every], at(2030, 6, 19, 11)), '現在不可停，明天 08:00 起可停');
      });

      test('詳情的理由寫現在可不可停，狀態仍是有條件・限時段', () {
        ParkingDecision decide(DateTime when) => decideParking(
          street(
            SpaceType.heavyOnly,
            condition: c({
              'bay': 'heavy',
              'use': 'usual',
              'schedule': [
                {
                  'days': 'weekday',
                  'from': '20:00',
                  'to': '07:00',
                  'vehicles': ['heavy'],
                },
              ],
            }),
          ),
          VehicleType.heavy,
          bundled,
          now: when,
        );
        final day = decide(at(2026, 10, 27, 12));
        expect(day.status, EligibilityStatus.conditional);
        expect(day.restriction, RuleRestriction.timeLimited);
        expect(day.reason, '現在不可停，20:00 起可停；大型重機可停時段：平日 20:00–隔日 07:00，請看現場牌面');
        expect(decide(at(2026, 10, 27, 22)).reason, startsWith('現在可停；'));
      });
    });

    test('身障特製機車與限電動：有條件，未查核為待確認', () {
      for (final v in VehicleType.values) {
        final disabled = decideParking(
          street(SpaceType.disabledMotorcycle),
          v,
          bundled,
          now: now,
        );
        expect(disabled.status, EligibilityStatus.conditional);
        expect(disabled.reason, contains('特製機車'));
        expect(disabled.basis.map((b) => b.kind), contains(BasisKind.law));
      }
    });

    test('汽機共用格加附加限制、沒有時段：普通機車待確認（#155 第 16 項）', () {
      for (final limit in ['ev_only', 'special_vehicle']) {
        Map<String, Object?> json({List<Object?>? schedule}) => {
          'bay': 'car',
          'use': 'share',
          'share': 'car_motorcycle',
          'limits': [
            limit == 'special_vehicle'
                ? {'kind': limit, 'vehicle': 'disabled_modified'}
                : {'kind': limit},
          ],
          'schedule': ?schedule,
        };
        final d = decideParking(
          street(SpaceType.flexShared, condition: c(json())),
          VehicleType.scooter,
          bundled,
          now: now,
        );
        expect(d.status, EligibilityStatus.unverified, reason: limit);
        expect(d.gaps, {DecisionGap.scheduleUnknown}, reason: limit);
        expect(d.reason, contains('開放時段'), reason: limit);
        // With the scooter's slots listed, the limit and the slots both hold.
        final listed = decideParking(
          street(
            SpaceType.flexShared,
            condition: c(
              json(
                schedule: [
                  {
                    'days': 'all',
                    'from': '20:00',
                    'to': '07:00',
                    'vehicles': ['scooter'],
                  },
                ],
              ),
            ),
          ),
          VehicleType.scooter,
          bundled,
          now: now,
        );
        expect(listed.status, EligibilityStatus.conditional, reason: limit);
        expect(listed.reason, contains('20:00–隔日 07:00'), reason: limit);
        // Heavy bikes park on car bays by law; the limit still applies.
        expect(
          decideParking(
            street(SpaceType.flexShared, condition: c(json())),
            VehicleType.heavy,
            bundled,
            now: now,
          ).status,
          EligibilityStatus.conditional,
          reason: limit,
        );
      }
    });

    test('格位車種先判斷，限制全部保留並繼續檢查時段（Codex #157）', () {
      ParkingDecision judge(Map<String, Object?> json, VehicleType v) =>
          decideParking(
            street(SpaceType.evMotorcycle, condition: c(json)),
            v,
            bundled,
            now: now,
          );
      // A heavy bay limited to electric bikes is still closed to scooters.
      expect(
        judge({
          'bay': 'heavy',
          'limits': [
            {'kind': 'ev_only'},
          ],
        }, VehicleType.scooter).status,
        EligibilityStatus.notAllowed,
      );
      final both = judge({
        'bay': 'motorcycle',
        'limits': [
          {'kind': 'time_limit', 'max_minutes': 30},
          {'kind': 'ev_only'},
        ],
      }, VehicleType.scooter);
      expect(both.status, EligibilityStatus.conditional);
      expect(both.restriction, RuleRestriction.evOnly);
      expect(both.reason, contains('限電動機車'));
      expect(both.reason, contains('限時停車'));
      final unlisted = judge({
        'bay': 'motorcycle',
        'limits': [
          {'kind': 'ev_only'},
        ],
        'schedule': [
          {
            'days': 'all',
            'vehicles': ['car'],
          },
        ],
      }, VehicleType.scooter);
      expect(unlisted.status, EligibilityStatus.unverified);
      expect(unlisted.gaps, {DecisionGap.scheduleUnknown});
      final listed = judge({
        'bay': 'motorcycle',
        'limits': [
          {'kind': 'ev_only'},
        ],
        'schedule': [
          {
            'days': 'weekday',
            'from': '08:00',
            'to': '18:00',
            'vehicles': ['scooter'],
          },
        ],
      }, VehicleType.scooter);
      expect(listed.status, EligibilityStatus.conditional);
      expect(listed.reason, contains('限電動機車'));
      expect(listed.reason, contains('平日 08:00–18:00'));
    });

    test('開放時段不覆蓋縣市規則的必要限制（臺中限標示車格）', () {
      final d = decideParking(
        street(
          SpaceType.paidMotorcycle,
          city: '臺中市',
          condition: c({
            'bay': 'motorcycle',
            'use': 'usual',
            'charge': 'toll',
            'schedule': [
              {
                'days': 'all',
                'from': '08:00',
                'to': '20:00',
                'vehicles': ['heavy', 'scooter'],
              },
            ],
          }),
        ),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(d.status, EligibilityStatus.conditional);
      expect(d.restriction, RuleRestriction.signage);
      expect(d.reason, startsWith(rule('臺中市', VehicleType.heavy).exceptions));
      expect(d.reason, contains('每天 08:00–20:00'));
    });

    test('縣市規則過期：待確認，不回落到全國規則', () {
      final expired = CityRule.fromJson({
        ...bundledJson.firstWhere(
          (r) => r['city'] == '臺北市' && r['vehicle'] == 'heavy',
        ),
        'expires_on': '2026-10-20',
      });
      final national = rule('全國', VehicleType.heavy);
      final d = decideParking(
        street(SpaceType.paidMotorcycle),
        VehicleType.heavy,
        [expired, national],
        now: now,
      );
      expect(d.status, EligibilityStatus.unverified);
      expect(d.reason, ruleExpiredReason);
      expect(d.gaps, {DecisionGap.noticeExpired});
      final ruleBasis = d.basis.firstWhere((b) => b.kind == BasisKind.cityRule);
      expect(ruleBasis.expired, isTrue);
      // The day before, in Taiwan, it still holds.
      expect(
        decideParking(street(SpaceType.paidMotorcycle), VehicleType.heavy, [
          expired,
        ], now: DateTime.utc(2026, 10, 19, 15, 59)).status,
        EligibilityStatus.allowed,
      );
      // The law still closes a heavy bay to scooters, rule or not.
      expect(
        decideParking(street(SpaceType.heavyOnly), VehicleType.scooter, [
          expired,
        ], now: now).status,
        EligibilityStatus.notAllowed,
      );
    });

    test('規則到期只讓靠公告開放的格位失效；依法可停的照原本判斷（決定 44）', () {
      final now = DateTime.utc(2026, 10, 27, 4);
      final expired = CityRule.fromJson({
        ...bundledJson.firstWhere(
          (r) => r['city'] == '臺北市' && r['vehicle'] == 'heavy',
        ),
        'expires_on': '2026-10-20',
      });
      for (final type in [SpaceType.heavyOnly, SpaceType.car]) {
        final d = decideParking(street(type), VehicleType.heavy, [
          expired,
        ], now: now);
        expect(d.status, EligibilityStatus.allowed, reason: type.name);
        expect(d.reason, lawfulReason, reason: type.name);
        expect(d.gaps, isEmpty, reason: type.name);
        // The ended rule is not the basis; the law is.
        final kinds = [for (final b in d.basis) b.kind];
        expect(kinds, contains(BasisKind.law), reason: type.name);
        expect(kinds, isNot(contains(BasisKind.cityRule)), reason: type.name);
      }
      // What only the rule opened ends with it.
      expect(
        decideParking(street(SpaceType.paidMotorcycle), VehicleType.heavy, [
          expired,
        ], now: now).reason,
        ruleExpiredReason,
      );
      // A scooter rule opening car bays is a notice too.
      final scooterCars = CityRule.fromJson({
        ...bundledJson.firstWhere(
          (r) => r['city'] == '臺北市' && r['vehicle'] == 'scooter',
        ),
        'allowed_space_types': ['paidMotorcycle', 'freeMotorcycle', 'car'],
        'expires_on': '2026-10-20',
      });
      final car = decideParking(street(SpaceType.car), VehicleType.scooter, [
        scooterCars,
      ], now: now);
      expect(car.status, EligibilityStatus.unverified);
      expect(car.reason, ruleExpiredReason);
    });

    test('兩份同城規則矛盾：公告不一致', () {
      final a = rule('臺北市', VehicleType.heavy);
      final b = CityRule.fromJson({
        ...bundledJson.firstWhere(
          (r) => r['city'] == '臺北市' && r['vehicle'] == 'heavy',
        ),
        'allowed_space_types': ['heavyOnly', 'car'],
      });
      final d = decideParking(
        street(SpaceType.paidMotorcycle),
        VehicleType.heavy,
        [a, b],
        now: now,
      );
      expect(d.status, EligibilityStatus.unverified);
      expect(d.reason, noticeConflictReason);
      expect(d.gaps, {DecisionGap.noticeConflict});
    });

    test('行政區未知', () {
      final d = decideParking(
        street(SpaceType.freeMotorcycle, city: '新北市'),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(d.status, EligibilityStatus.unverified);
      expect(d.gaps, {DecisionGap.districtUnknown});
    });
  });

  group('路外：場站 × 分區 × 分區完整度 × 期限（§3.2 第 3 步）', () {
    ParkingZone zone(
      String name, {
      ParkingAccess? access,
      Map<String, Object?>? condition,
    }) => ParkingZone.fromJson({
      'name': name,
      'access': ?access?.name,
      'condition': ?condition,
    });
    ParkingSpot lot(
      List<ParkingZone> zones, {
      bool? heavy = true,
      bool? scooter = true,
      bool complete = false,
      String source = 'official',
      DateTime? verifiedAt,
    }) => ParkingSpot(
      id: 'lot',
      name: 'lot',
      lat: 25,
      lng: 121,
      city: '臺北市',
      spaceType: SpaceType.offStreet,
      source: source,
      status: TrustStatus.confirmed,
      lastConfirmedAt: recent,
      heavyAllowed: heavy,
      scooterAllowed: scooter,
      heavyVerifiedAt: verifiedAt,
      scooterVerifiedAt: verifiedAt,
      zones: zones,
      zonesComplete: complete,
    );
    ParkingDecision heavy(ParkingSpot s) =>
        decideParking(s, VehicleType.heavy, bundled, now: now);

    test('官方場站開放大型重機、已知分區都是普機專用：待確認，不推定全場禁停', () {
      final d = heavy(lot([zone('B1', access: ParkingAccess.scooterOnly)]));
      expect(d.status, EligibilityStatus.unverified);
      expect(d.gaps, contains(DecisionGap.zonesIncomplete));
      expect(d.reason, '場站開放大型重機，但已知分區沒有標示可停區域，請依入口公告');
      expect(d.zones.single.status, EligibilityStatus.notAllowed);
      expect(d.zones.single.reason, '此分區標示不開放大型重機');
    });

    test('官方未標示（#201）：場站不是可停也不是不可停，判為待確認', () {
      final s = ParkingSpot.fromJson({
        'id': 'official:lot',
        'name': 'lot',
        'lat': 25,
        'lng': 121,
        'city': '臺北市',
        'source': 'official',
        'space_type': 'offStreet',
        'scooter_allowed': true,
        'heavy_allowed': null,
        'heavy_not_stated': true,
        'status': 'confirmed',
        'updated_at': recent.toIso8601String(),
      });
      expect(s.heavyNotStated, isTrue);
      expect(s.notStated(VehicleType.scooter), isFalse);
      final d = heavy(s);
      expect(d.status, EligibilityStatus.unverified);
      expect(d.gaps, {DecisionGap.notStated});
      expect(d.reason, '場站官方未標示是否開放大型重機，請以入口公告為準');
      expect(s.toJson()['heavy_not_stated'], isTrue);
      expect(s.toJson().containsKey('scooter_not_stated'), isFalse);
    });

    test('分區官方未標示（#201）：該區待確認，另一區可停時場站仍可停', () {
      final d = heavy(
        lot([
          zone(
            'B1',
            condition: {
              'allow': {'scooter': true, 'heavy': 'not_stated'},
            },
          ),
          zone('重機區', access: ParkingAccess.heavyOnly),
        ]),
      );
      expect(d.zones.first.status, EligibilityStatus.unverified);
      expect(d.zones.first.gaps, {DecisionGap.notStated});
      expect(d.zones.first.reason, '此分區官方未標示是否開放大型重機，請以入口公告為準');
      expect(d.status, EligibilityStatus.allowed);
      final only = heavy(
        lot([
          zone(
            'B1',
            condition: {
              'allow': {'scooter': 'not_stated', 'heavy': 'not_stated'},
            },
          ),
        ]),
      );
      expect(only.status, isNot(EligibilityStatus.allowed));
      expect(only.status, isNot(EligibilityStatus.notAllowed));
    });

    test('分區涵蓋全場而都不開放：場站與分區資料不一致', () {
      final d = heavy(
        lot([zone('B1', access: ParkingAccess.scooterOnly)], complete: true),
      );
      expect(d.status, EligibilityStatus.unverified);
      expect(d.gaps, {DecisionGap.zonesConflict});
    });

    test('至少一區開放：可停並列出逐區資格；推導不出的分區是待確認', () {
      final d = heavy(
        lot([
          zone('機車區', access: ParkingAccess.scooterOnly),
          zone('重機區', access: ParkingAccess.heavyOnly),
          zone('另一區'),
        ]),
      );
      expect(d.status, EligibilityStatus.allowed);
      expect(d.openZones.map((z) => z.name), ['重機區']);
      expect(d.zones.map((z) => z.status), [
        EligibilityStatus.notAllowed,
        EligibilityStatus.allowed,
        EligibilityStatus.unverified,
      ]);
      // Unknown is not closed (#155 item 7).
      expect(d.zones.last.hasData, isFalse);
    });

    test('分區都沒有資料：維持場站資料的結論', () {
      expect(
        heavy(lot([zone('A'), zone('B')])).status,
        EligibilityStatus.allowed,
      );
    });

    test('場站未確認開放：分區開放也不能推出可停', () {
      for (final flag in [null]) {
        final d = heavy(
          lot([zone('重機區', access: ParkingAccess.heavyOnly)], heavy: flag),
        );
        expect(d.status, EligibilityStatus.unverified);
        expect(d.zones.single.status, EligibilityStatus.allowed);
      }
      // A trusted 「不開放」 closes the lot whatever the zones say.
      expect(
        heavy(lot([zone('重機區', access: ParkingAccess.heavyOnly)], heavy: false))
            .status,
        EligibilityStatus.notAllowed,
      );
    });

    test('試辦分區：期限內有條件並帶期限，到期該區待確認', () {
      Map<String, Object?> trial(String ends) => {
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'charge': 'toll',
        'allow': {'scooter': true, 'heavy': true},
        'basis': {
          'source_url': 'https://example.test/pilot',
          'effective_date': '2026-04-06',
          'expires_on': ends,
        },
      };
      final open = heavy(
        lot([
          zone(
            '機車區',
            access: ParkingAccess.scooterHeavy,
            condition: trial('2026-12-31'),
          ),
          zone('汽車區', access: ParkingAccess.heavyCar),
        ]),
      );
      expect(open.status, EligibilityStatus.conditional);
      expect(open.zones.first.status, EligibilityStatus.conditional);
      expect(open.zones.first.reason, '試辦至 2026-12-31');
      expect(open.basis.last.zone, '機車區');
      final ended = heavy(
        lot([
          zone(
            '機車區',
            access: ParkingAccess.scooterHeavy,
            condition: trial('2026-10-05'),
          ),
          zone('汽車區', access: ParkingAccess.heavyCar),
        ]),
      );
      expect(ended.zones.first.status, EligibilityStatus.unverified);
      expect(ended.zones.first.gaps, {DecisionGap.noticeExpired});
      // The car zone still opens the lot.
      expect(ended.status, EligibilityStatus.allowed);
      expect(ended.gaps, contains(DecisionGap.noticeExpired));
    });

    test('有條件的場站理由寫出分區與限制；分區的限制與時段一起保留', () {
      final d = heavy(
        lot([
          zone(
            '重機區',
            access: ParkingAccess.heavyOnly,
            condition: {
              'bay': 'heavy',
              'use': 'usual',
              'allow': {'scooter': false, 'heavy': true},
              'limits': [
                {'kind': 'ev_only'},
                {'kind': 'time_limit'},
              ],
            },
          ),
        ]),
      );
      expect(d.status, EligibilityStatus.conditional);
      expect(d.restriction, RuleRestriction.evOnly);
      expect(d.zones.single.reason, contains('限電動機車'));
      expect(d.zones.single.reason, contains('限時停車'));
      expect(d.reason, startsWith('重機區：限電動機車'));
      expect(d.reason, endsWith('場站資料標示可停，請確認現場公告'));
    });

    test('分區公告到期只讓「開放」失效：不開放的分區仍是不開放', () {
      final closed = zone(
        '普機區',
        access: ParkingAccess.scooterOnly,
        condition: {
          'bay': 'motorcycle',
          'use': 'usual',
          'charge': 'toll',
          'allow': {'scooter': true, 'heavy': false},
          'basis': {
            'source_url': 'https://example.test/notice',
            'effective_date': '2026-04-06',
            'expires_on': '2026-10-05',
          },
        },
      );
      final d = heavy(lot([closed], complete: true));
      expect(d.zones.single.status, EligibilityStatus.notAllowed);
      expect(d.gaps, {DecisionGap.zonesConflict});
      // Scooters it opened are unconfirmed once it ends.
      final s = decideParking(
        lot([closed], complete: true),
        VehicleType.scooter,
        bundled,
        now: now,
      );
      expect(s.zones.single.status, EligibilityStatus.unverified);
      expect(s.zones.single.gaps, {DecisionGap.noticeExpired});
    });

    test('窮舉：場站旗標 × 分區組合 × 完整度 × 車種的不變式', () {
      final kinds = <ParkingZone>[
        zone('無資料'),
        for (final a in ParkingAccess.values) zone(a.name, access: a),
      ];
      for (final source in ['official', 'community']) {
        for (final flag in [null, true, false]) {
          for (final verifiedAt in [null, recent]) {
            for (var i = 0; i < kinds.length; i++) {
              for (var j = i; j < kinds.length; j++) {
                for (final complete in [false, true]) {
                  final s = lot(
                    [kinds[i], kinds[j]],
                    heavy: flag,
                    scooter: flag,
                    complete: complete,
                    source: source,
                    verifiedAt: verifiedAt,
                  );
                  for (final v in VehicleType.values) {
                    final d = decideParking(s, v, bundled, now: now);
                    final why =
                        '$source $flag $verifiedAt '
                        '${kinds[i].name}+${kinds[j].name} $complete ${v.name}';
                    final trustedOpen =
                        flag == true &&
                        (source == 'official' || verifiedAt != null);
                    final anyData = d.zones.any((z) => z.hasData);
                    final anyOpen = d.zones.any((z) => z.open);
                    // A confirmed, recent community lot may deny too.
                    if (flag == false) {
                      expect(
                        d.status,
                        EligibilityStatus.notAllowed,
                        reason: why,
                      );
                    } else if (!trustedOpen) {
                      expect(
                        d.status,
                        EligibilityStatus.unverified,
                        reason: why,
                      );
                    } else if (!anyData || anyOpen) {
                      expect(
                        d.eligibility.status,
                        EligibilityStatus.allowed,
                        reason: why,
                      );
                    } else {
                      expect(
                        d.status,
                        EligibilityStatus.unverified,
                        reason: why,
                      );
                      expect(
                        d.gaps.intersection({
                          DecisionGap.zonesIncomplete,
                          DecisionGap.zonesConflict,
                        }),
                        hasLength(1),
                        reason: why,
                      );
                      final allClosed = d.zones.every(
                        (z) => z.status == EligibilityStatus.notAllowed,
                      );
                      expect(
                        d.gaps.contains(DecisionGap.zonesConflict),
                        complete && allClosed,
                        reason: why,
                      );
                    }
                    // Zones never inherit: a zone without data is unknown.
                    for (final z in d.zones) {
                      if (!z.hasData) {
                        expect(z.status, EligibilityStatus.unverified);
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    });
  });

  group('價格與資格分開（§3.2 第 4 步）', () {
    test('known／partial／unknown 與比照', () {
      final known = priceAnswer({
        'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
      }, VehicleType.heavy);
      expect(known.kind, PriceKind.known);
      expect(known.text, '每小時 20 元');
      final partial = priceAnswer({
        'heavy': {'mode': 'per_visit', 'amount': 40},
      }, VehicleType.heavy);
      expect(partial.kind, PriceKind.partial);
      expect(partial.gaps, ['隔日是否另計']);
      final followed = priceAnswer({
        'scooter': {'mode': 'hourly', 'amount': 15, 'per_minutes': 60},
        'heavy': {'mode': 'same_as_scooter'},
      }, VehicleType.heavy);
      expect(followed.kind, PriceKind.known);
      expect(followed.rate!['amount'], 15);
      final posted = priceAnswer({
        'heavy': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
            },
          ],
        },
      }, VehicleType.heavy);
      expect(posted.kind, PriceKind.partial);
      expect(posted.gaps, contains('部分時段費率'));
      // #155 item 17: a time no period covers is as unconfirmed as a
      // posted one.
      Map<String, Object?> period(Object days, String? from, String? to) => {
        'days': days,
        'from': ?from,
        'to': ?to,
        'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
      };
      PriceAnswer byTime(List<Object?> periods) => priceAnswer({
        'heavy': {'mode': 'by_time', 'periods': periods},
      }, VehicleType.heavy);
      final daytime = byTime([period('all', '08:00', '20:00')]);
      expect(daytime.kind, PriceKind.partial);
      expect(daytime.gaps, ['部分時段費率']);
      expect(daytime.rate, isNotNull);
      expect(
        byTime([
          period('all', '08:00', '20:00'),
          period('all', '20:00', '08:00'),
        ]).kind,
        PriceKind.known,
      );
      // Decision 47: 平日 20:00–08:00 ends Saturday 08:00, so Monday
      // 00:00–08:00 needs Sunday's night period.
      final weekNights = [
        period('weekday', '08:00', '20:00'),
        period('weekday', '20:00', '08:00'),
        period('holiday', '08:00', '20:00'),
      ];
      expect(byTime(weekNights).gaps, ['部分時段費率']);
      expect(
        byTime([...weekNights, period('holiday', '20:00', '08:00')]).kind,
        PriceKind.known,
      );
      expect(
        byTime([period('weekday', null, null), period('holiday', null, null)])
            .kind,
        PriceKind.known,
      );
      final missing = priceAnswer({
        'heavy': {'mode': 'same_as_car'},
      }, VehicleType.heavy);
      expect(missing.kind, PriceKind.unknown);
      expect(missing.text, '大型重機費率未提供');
      expect(priceAnswer(null, VehicleType.scooter).kind, PriceKind.unknown);
    });

    test('decideParking 的價格：路邊點與沒有分區的停車場讀點位 fee，沒有時退回舊文字', () {
      ParkingSpot withFee(String type, Object? fee, String note) =>
          ParkingSpot.fromJson({
            'id': 's',
            'name': 's',
            'lat': 25,
            'lng': 121,
            'city': '臺北市',
            'space_type': type,
            'source': 'official',
            'heavy_allowed': true,
            'fee_note': note,
            'fee': ?fee,
          });
      const fee = {
        'heavy': {'mode': 'per_visit', 'amount': 40, 'renew': 'midnight'},
      };
      for (final type in ['paidMotorcycle', 'offStreet']) {
        final known = decideParking(
          withFee(type, fee, '大型重機每次 40 元，隔日另計'),
          VehicleType.heavy,
          bundled,
          now: now,
        ).price!;
        expect(known.kind, PriceKind.known, reason: type);
        expect(known.text, '每次 40 元，隔日另計', reason: type);
        final legacy = decideParking(
          withFee(type, null, '每小時 20 元'),
          VehicleType.heavy,
          bundled,
          now: now,
        ).price!;
        expect(legacy.kind, PriceKind.unknown, reason: type);
        expect(legacy.text, '每小時 20 元', reason: type);
      }
    });

    test('結構化費率沒有此車種：未知且不帶整段 fee_note（決定 29）', () {
      final answer = priceAnswer(
        {
          'scooter': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
        },
        VehicleType.heavy,
        legacyText: '機車每小時 20 元；大型重機費率未提供',
      );
      expect(answer.kind, PriceKind.unknown);
      expect(answer.text, isNull);
    });

    test('沒有分區有結構化費率時，分區先讀自己的文字，沒有才用場站的', () {
      final d = decideParking(
        ParkingSpot.fromJson({
          'id': 'lot',
          'name': 'lot',
          'lat': 25,
          'lng': 121,
          'city': '臺北市',
          'space_type': 'offStreet',
          'source': 'official',
          'heavy_allowed': true,
          'fee_note': '依場站公告',
          'parking_zones': [
            {'name': '重機區', 'access': 'heavyOnly', 'heavy_fee_note': '每次 50 元'},
            {'name': '汽車區', 'access': 'heavyCar'},
          ],
        }),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(d.zones.first.price?.text, '每次 50 元');
      expect(d.zones.last.price?.text, '依場站公告');
    });

    test('場站有結構化費率、分區都沒有時，分區用場站費率而不是自己的舊文字', () {
      final d = decideParking(
        ParkingSpot.fromJson({
          'id': 'lot',
          'name': 'lot',
          'lat': 25,
          'lng': 121,
          'city': '臺北市',
          'space_type': 'offStreet',
          'source': 'official',
          'heavy_allowed': true,
          'fee': {
            'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
          },
          'parking_zones': [
            {'name': '重機區', 'access': 'heavyOnly', 'heavy_fee_note': '舊文字'},
          ],
        }),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(d.zones.single.price?.kind, PriceKind.known);
      expect(d.zones.single.price?.text, '每小時 20 元');
    });

    test('分區有費率時，沒有費率的分區退回該分區的舊文字', () {
      final d = decideParking(
        ParkingSpot.fromJson({
          'id': 'lot',
          'name': 'lot',
          'lat': 25,
          'lng': 121,
          'city': '臺北市',
          'space_type': 'offStreet',
          'source': 'official',
          'heavy_allowed': true,
          'parking_zones': [
            {
              'name': '機車區',
              'access': 'scooterHeavy',
              'fee': {
                'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
              },
            },
            {'name': '重機區', 'access': 'heavyOnly', 'fee_note': '每次 50 元'},
          ],
        }),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(d.zones.last.price?.kind, PriceKind.unknown);
      expect(d.zones.last.price?.text, '每次 50 元');
    });

    test('價格未知不讓資格變差，分區費率只給開放的分區', () {
      final d = decideParking(
        ParkingSpot.fromJson({
          'id': 'lot',
          'name': 'lot',
          'lat': 25,
          'lng': 121,
          'city': '臺北市',
          'space_type': 'offStreet',
          'source': 'official',
          'heavy_allowed': true,
          'parking_zones': [
            {
              'name': '機車區',
              'access': 'scooterOnly',
              'fee': {
                'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
              },
            },
            {'name': '重機區', 'access': 'heavyOnly'},
          ],
        }),
        VehicleType.heavy,
        bundled,
        now: now,
      );
      expect(d.status, EligibilityStatus.allowed);
      expect(d.zones.first.price, isNull);
      // Another zone has a fee, so the lot's is not borrowed.
      expect(d.zones.last.price?.kind, PriceKind.unknown);
    });
  });

  test('舊版 App：過期列的保守投影覆蓋內建開放規則後為待確認，依法可停的仍可停（決定 44）', () {
    // As the `city_rules` view serves an expired Taipei heavy rule
    // (202610270070): heavyOnly and car stay allowed.
    final projected = CityRule.fromJson({
      'city': '臺北市',
      'vehicle': 'heavy',
      'allowed_space_types': ['car', 'heavyOnly'],
      'conditional_space_types': ['offStreet', 'paidMotorcycle'],
      'districts': <String>[],
      'district_space_types': <String, Object>{},
      'fee_note': '請依現場收費公告',
      'exceptions': '此地區的規則已過期，請以現場標誌標線為準',
      'can_use_two_spaces': false,
      'effective_date': '2026-10-06',
      'source_url': 'https://example.test',
      'version': rule('臺北市', VehicleType.heavy).version,
      'restriction': 'unverified',
    });
    for (final type in [
      SpaceType.paidMotorcycle,
      SpaceType.freeMotorcycle,
      SpaceType.heavyOnly,
      SpaceType.car,
    ]) {
      final old = legacyEligibility(
        street(type, source: 'official'),
        VehicleType.heavy,
        projected,
        now: now,
      );
      expect(old.status, switch (type) {
        SpaceType.freeMotorcycle => EligibilityStatus.notAllowed,
        SpaceType.heavyOnly || SpaceType.car => EligibilityStatus.allowed,
        _ => EligibilityStatus.unverified,
      }, reason: type.name);
      // The new app reads the stored row and agrees on the lawful bays.
      if (type != SpaceType.heavyOnly && type != SpaceType.car) continue;
      final stored = CityRule.fromJson({
        ...bundledJson.firstWhere(
          (r) => r['city'] == '臺北市' && r['vehicle'] == 'heavy',
        ),
        'expires_on': '2026-10-20',
      });
      final current = decideParking(
        street(type, source: 'official'),
        VehicleType.heavy,
        [stored],
        now: now,
      );
      expect(current.status, old.status, reason: type.name);
    }
  });
}
