import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
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
                // car bay.
                SpaceType.flexShared =>
                  vehicle == VehicleType.scooter
                      ? got.status == EligibilityStatus.unverified
                      : got.reason ==
                            eligibility(
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
                            ).reason,
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
      expect(flex([], VehicleType.heavy).status, EligibilityStatus.allowed);
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
      final firstFree = priceAnswer({
        'heavy': {
          'mode': 'per_visit',
          'amount': 0,
          'max_minutes': 20,
          'extension': {'amount': 40, 'max_times': 1},
        },
      }, VehicleType.heavy);
      expect(firstFree.gaps, ['延長時長']);
      final followed = priceAnswer({
        'scooter': {'mode': 'hourly', 'amount': 15, 'per_minutes': 60},
        'heavy': {'mode': 'same_as_scooter', 'factor_pct': 150},
      }, VehicleType.heavy);
      expect(followed.kind, PriceKind.known);
      expect(followed.rate!['amount'], 22.5);
      final missing = priceAnswer({
        'heavy': {'mode': 'same_as_car'},
      }, VehicleType.heavy);
      expect(missing.kind, PriceKind.unknown);
      expect(missing.text, '大型重機費率未提供');
      expect(priceAnswer(null, VehicleType.scooter).kind, PriceKind.unknown);
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

  test('舊版 App：過期列的保守投影覆蓋內建開放規則後為待確認', () {
    // As the `city_rules` view serves an expired Taipei heavy rule.
    final projected = CityRule.fromJson({
      'city': '臺北市',
      'vehicle': 'heavy',
      'allowed_space_types': <String>[],
      'conditional_space_types': [
        'car',
        'heavyOnly',
        'offStreet',
        'paidMotorcycle',
      ],
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
      expect(
        old.status,
        type == SpaceType.freeMotorcycle
            ? EligibilityStatus.notAllowed
            : EligibilityStatus.unverified,
        reason: type.name,
      );
    }
  });
}
