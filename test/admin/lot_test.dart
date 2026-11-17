import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/review/shared_plan_dialog.dart';
import 'package:motorcycle_parking/admin/spots/lot_models.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/admin/spots/spots_controller.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_admin_gateway.dart';
import 'fold_helpers.dart';

/// A lot's fee plans and zones in the admin spot form (C6b; design §2.6,
/// canvas AdminSpotForm) and fees reaching a shared plan on the review page
/// (canvas AdminSharedPlan).
void main() {
  const scooterHourly = {
    'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
  };
  const heavyHourly = {
    'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
  };
  const plans = [
    {'id': 'p1', 'name': '機車計時', 'fee': scooterHourly},
    {'id': 'p2', 'name': '重機計時', 'fee': heavyHourly},
  ];
  final zones = [
    {
      'name': '機車區',
      'area': 'motorcycle',
      'access': 'scooterHeavy',
      'fee_plan': 'p1',
      'fee': scooterHourly,
    },
    {
      'name': '機車區',
      'area': 'motorcycle',
      'access': 'heavyOnly',
      'condition': {
        'bay': 'heavy',
        'use': 'usual',
        'allow': {'scooter': false, 'heavy': true},
      },
      'fee_plan': 'p2',
      'fee': heavyHourly,
    },
    {
      'name': 'B2',
      'area': 'motorcycle',
      'access': 'scooterOnly',
      'fee_plan': 'p1',
      'fee': scooterHourly,
    },
  ];

  Map<String, dynamic> lotRow(FakeAdminGateway gateway) => {
    ...gateway.spotRows[officialId]!,
    'fee_plans': plans,
    'fee_plan': 'p1',
    'fee': scooterHourly,
    'fee_note': feeNoteOf(Fee.fromJson(scooterHourly)),
    'parking_zones': zones,
    'zones_complete': false,
    'fee_source_text': '機車每小時10元，重機每小時20元',
  };

  group('計費規則與分區的資料', () {
    test('同區域多種格位合成一張卡', () {
      final cards = areaCards(zones);
      expect(cards.map((c) => c.name), ['機車區', 'B2']);
      expect(cards.first.indexes, [0, 1]);
    });

    test('仍被引用的規則不能刪除，並寫明幾個分區在用', () {
      expect(planInUse('p1', 'p1', zones), '全場費率和 2 個分區在用，先改掉引用');
      expect(planInUse('p2', 'p1', zones), '1 個分區在用，先改掉引用');
      expect(planInUse('p3', 'p1', zones), isNull);
      expect(
        planInUseRefusal(
          '{"plans":[{"id":"p1","name":"機車計時","zones":2,"spot":false}]}',
        ),
        '「機車計時」2 個分區在用，先改掉引用',
      );
      expect(planInUseRefusal(null), isNull);
    });

    test('分區條件一律寫 allow，access 由轉換層推導（決定 32）', () {
      final z = zoneWithCondition(
        {'name': 'A'},
        const ParkingCondition(
          bay: Bay.motorcycle,
          allow: ZoneAllow(scooter: true, heavy: true),
        ),
      );
      expect(z['access'], 'scooterHeavy');
      expect(zoneProblem(z), isNull);
      // Nothing to write back (#190): saved without an access.
      final noAccess = zoneWithCondition(
        {'name': 'A', 'access': 'scooterOnly'},
        const ParkingCondition(
          bay: Bay.car,
          allow: ZoneAllow(scooter: true, heavy: true),
        ),
      );
      expect(noAccess.containsKey('access'), isFalse);
      expect(zoneProblem(noAccess), isNull);
      expect(zoneConditionConsistent(noAccess), isTrue);
      final bad = zoneWithCondition(
        {'name': 'A'},
        const ParkingCondition(
          bay: Bay.heavy,
          allow: ZoneAllow(scooter: true, heavy: true),
        ),
      );
      expect(zoneProblem(bad), contains('格式不正確'), reason: '重機格不開放普機');
      final unknown = zoneWithCondition(
        {'name': 'A'},
        const ParkingCondition(
          bay: Bay.motorcycle,
          allow: ZoneAllow(scooter: true),
        ),
      );
      expect(zoneProblem(unknown), contains('可不可停'));
      expect(zoneWithCondition({'name': 'A'}, const ParkingCondition()), {
        'name': 'A',
      });
    });

    test('依據輸入到一半不合格式時，限時與共用時段照樣保留', () {
      const zone = {
        'name': 'A',
        'access': 'scooterOnly',
        'condition': {
          'bay': 'motorcycle',
          'use': 'usual',
          'charge': 'toll',
          'limits': [
            {'kind': 'time_limit', 'max_minutes': 120},
          ],
          'allow': {'scooter': true, 'heavy': false},
        },
      };
      var z = zoneWithBasis({...zone}, {'source_url': 'h'});
      expect(zoneProblem(z), contains('https://'));
      z = zoneWithBasis(z, {'source_url': 'ht'});
      z = zoneWithBasis(z, {'source_url': 'https://example.test/n'});
      expect(zoneProblem(z), isNull);
      expect((z['condition'] as Map)['limits'], [
        {'kind': 'time_limit', 'max_minutes': 120},
      ]);
      // A bay edit meanwhile keeps the basis as typed.
      final half = zoneWithBasis({...zone}, {'source_url': 'h'});
      final edited = zoneWithCondition(
        half,
        const ParkingCondition(
          bay: Bay.motorcycle,
          charge: Charge.free,
          allow: ZoneAllow(scooter: true, heavy: false),
        ),
      );
      expect((edited['condition'] as Map)['basis'], {'source_url': 'h'});
    });

    group('只有舊 access 的分區（#494）', () {
      const legacy = {
        'name': '機車區',
        'access': 'scooterHeavy',
        'fee_plan': 'p1',
        'fee': scooterHourly,
      };
      // The bay pill as the form writes it (lot_editor.dart _BayRow).
      ParkingCondition pick(
        ParkingCondition c, {
        Bay? bay,
        bool? share,
        Charge? charge,
      }) => ParkingCondition(
        bay: bay ?? c.bay,
        use: share == null
            ? c.use
            : share
            ? BayUse.share
            : BayUse.usual,
        share: share == true ? ShareKind.scooterHeavy : c.share,
        charge: charge ?? c.charge,
        limits: c.limits,
        schedule: c.schedule,
        basis: c.basis,
        allow: c.allow,
      );

      test('起始值只有誰能停，格位與共用未確認', () {
        final start = zoneCondition(legacy);
        expect(start.toJson(), {
          'allow': {'scooter': true, 'heavy': true},
        });
        expect(start.bay, isNull);
        expect(start.share, isNull);
        // The table everything else reads stays as it was.
        expect(zoneConditionOf(ParkingAccess.scooterHeavy)?.share, isNotNull);
      });

      test('補依據或收費：access 不變、不寫格位與共用，存檔要先選格位', () {
        final based = zoneWithBasis(
          {...legacy},
          {'source_url': 'https://example.test/n'},
        );
        expect(based['access'], 'scooterHeavy');
        expect(based['condition'], {
          'allow': {'scooter': true, 'heavy': true},
          'basis': {'source_url': 'https://example.test/n'},
        });
        expect(zoneProblem(based), contains('請先選格位種類'));
        expect(zoneProblem(based), contains('普大共用'));
        final charged = zoneWithCondition({
          ...legacy,
        }, pick(zoneCondition(legacy), charge: Charge.toll));
        expect(charged['access'], 'scooterHeavy');
        expect((charged['condition'] as Map).keys, {'charge', 'allow'});
        expect(zoneProblem(charged), contains('請先選格位種類'));
        // 未確認 picked again for the bay changes nothing either.
        final unknown = zoneWithCondition(based, zoneCondition(based));
        expect(unknown['access'], 'scooterHeavy');
        expect(zoneProblem(unknown), contains('請先選格位種類'));
        // A basis typed halfway names the link first, then asks for the bay.
        var half = zoneWithBasis({...legacy}, {'source_url': 'h'});
        expect(half['access'], 'scooterHeavy');
        expect(zoneProblem(half), contains('https://'));
        half = zoneWithBasis(half, {'source_url': 'https://example.test/n'});
        expect(zoneProblem(half), contains('請先選格位種類'));
        // Taking the edit back leaves the zone as it was stored.
        expect(zoneWithBasis(based, null), legacy);
        expect(
          zoneWithCondition(charged, zoneCondition(legacy)),
          legacy,
          reason: '收費改回未確認',
        );
      });

      test('condition 明寫 null 的也一樣先選格位', () {
        final based = zoneWithBasis(
          {...legacy, 'condition': null},
          {'source_url': 'https://example.test/n'},
        );
        expect(based['access'], 'scooterHeavy');
        expect((based['condition'] as Map).containsKey('bay'), isFalse);
        expect(zoneProblem(based), contains('請先選格位種類'));
        expect(
          unpickedBayProblem(
            [
              {...legacy, 'condition': null},
            ],
            [
              {
                ...legacy,
                'condition': {
                  'allow': {'scooter': true, 'heavy': true},
                },
              }..remove('access'),
            ],
          ),
          contains('請先選格位種類'),
        );
      });

      test('選了機車格才寫格位；選了普大共用才寫 share', () {
        final based = zoneWithBasis(
          {...legacy},
          {'source_url': 'https://example.test/n'},
        );
        final bay = zoneWithCondition(
          based,
          pick(zoneCondition(based), bay: Bay.motorcycle),
        );
        expect(bay['access'], 'scooterHeavy');
        expect(bay['condition'], {
          'bay': 'motorcycle',
          'allow': {'scooter': true, 'heavy': true},
          'basis': {'source_url': 'https://example.test/n'},
        });
        expect(zoneProblem(bay), isNull);
        expect(zoneConditionConsistent(bay.cast()), isTrue);
        final usual = zoneWithCondition(
          bay,
          pick(zoneCondition(bay), share: false),
        );
        expect((usual['condition'] as Map)['use'], 'usual');
        expect((usual['condition'] as Map).containsKey('share'), isFalse);
        final shared = zoneWithCondition(
          bay,
          pick(zoneCondition(bay), share: true),
        );
        expect((shared['condition'] as Map)['share'], 'scooter_heavy');
        expect(shared['access'], 'scooterHeavy');
        expect(zoneProblem(shared), isNull);
        // A heavy bay from scooterHeavy: scooters out, access follows.
        final heavy = zoneWithCondition(
          based,
          ParkingCondition(
            bay: Bay.heavy,
            basis: zoneCondition(based).basis,
            allow: const ZoneAllow(scooter: false, heavy: true),
          ),
        );
        expect(heavy['access'], 'heavyOnly');
        expect(zoneProblem(heavy), isNull);
      });

      test('其他舊 access 照舊預填，補依據照存', () {
        for (final access in [
          ParkingAccess.scooterOnly,
          ParkingAccess.heavyCar,
          ParkingAccess.heavyOnly,
          ParkingAccess.noMotorcycle,
        ]) {
          final zone = {'name': 'A', 'access': access.name};
          expect(
            zoneCondition(zone),
            zoneConditionOf(access),
            reason: access.name,
          );
          final based = zoneWithBasis(
            {...zone},
            {'source_url': 'https://example.test/n'},
          );
          expect(based['access'], access.name, reason: access.name);
          expect(zoneProblem(based), isNull, reason: access.name);
          expect(zoneConditionConsistent(based.cast()), isTrue);
          // 未確認 picked for the bay: the access goes, as before (#190).
          final unknown = zoneWithCondition(
            based,
            ParkingCondition(
              basis: zoneCondition(based).basis,
              allow: zoneCondition(based).allow,
            ),
          );
          expect(zoneProblem(unknown), isNull, reason: access.name);
        }
      });

      test('選計費規則不寫 condition', () {
        final z = zoneWithPlan({...legacy}, 'p2', [...plans]);
        expect(z.containsKey('condition'), isFalse);
        expect(z['access'], 'scooterHeavy');
        expect(zoneProblem(z), isNull);
        expect(
          zonesFollowingPlans([z], [...plans]).single.containsKey('condition'),
          isFalse,
        );
      });

      test('本來就有 condition 的分區照舊', () {
        // Without a bay and without an access: saved as before.
        const open = {
          'name': 'C',
          'condition': {
            'allow': {'scooter': true, 'heavy': true},
          },
        };
        final based = zoneWithBasis(
          {...open},
          {'source_url': 'https://example.test/n'},
        );
        expect(based.containsKey('access'), isFalse);
        expect(zoneProblem(based), isNull);
        // A stored shared bay keeps its share and access.
        const stored = {
          'name': 'B1',
          'access': 'scooterHeavy',
          'condition': {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'allow': {'scooter': true, 'heavy': true},
          },
        };
        final kept = zoneWithBasis(
          {...stored},
          {'source_url': 'https://example.test/n'},
        );
        expect(kept['access'], 'scooterHeavy');
        expect((kept['condition'] as Map)['share'], 'scooter_heavy');
        expect(zoneProblem(kept), isNull);
        // Its bay cleared: no access to write back, as before (#190).
        final cleared = zoneWithCondition(
          stored,
          const ParkingCondition(allow: ZoneAllow(scooter: true, heavy: true)),
        );
        expect(cleared.containsKey('access'), isFalse);
        expect(zoneProblem(cleared), isNull);
      });
    });

    test('分區選規則時一併帶上規則的費率（#155 決定 51）', () {
      final z = zoneWithPlan({'name': 'A'}, 'p2', [...plans]);
      expect(z['fee_plan'], 'p2');
      expect(z['fee'], heavyHourly);
      final none = zoneWithPlan(z, null, [...plans]);
      expect(none.containsKey('fee_plan'), isFalse);
      expect(none.containsKey('fee'), isFalse);
    });

    test('規則名稱、數量與比照缺值都會擋（#155 第 13 項）', () {
      // Stored plans are old data; a new or changed one is written whole
      // (#188 layer 2).
      expect(plansProblem([...plans], plans), isNull);
      expect(plansProblem([...plans]), contains('三個車種都要選收費方式'));
      expect(
        plansProblem([
          ...plans,
          {'id': 'p3', 'name': '機車計時', 'fee': heavyHourly},
        ], plans),
        contains('重複'),
      );
      expect(
        plansProblem([
          {
            'id': 'p1',
            'name': '比照汽車',
            'fee': {
              'heavy': {'mode': 'same_as_car'},
            },
          },
        ]),
        contains('大型重機比照汽車費率，但還沒填汽車費率'),
      );
      expect(
        planNameOf(Fee.fromJson({...scooterHourly, ...heavyHourly})),
        '機車重機計時',
      );
    });

    test('只改規則內容時不送全場 fee，由資料庫同步', () {
      final out = lotChanges(
        {'fee_plans': plans, 'fee': scooterHourly, 'fee_note': 'x'},
        {'fee_plans': plans, 'fee_plan': 'p1', 'parking_zones': zones},
      );
      expect(out.containsKey('fee'), isFalse);
      expect(out.containsKey('fee_note'), isFalse);
      expect(out['parking_zones'], hasLength(3));
      final picked = lotChanges(
        {'fee_plan': 'p2'},
        {'fee_plans': plans, 'fee_plan': 'p2', 'parking_zones': zones},
      );
      expect(picked['fee'], heavyHourly);
      expect(picked['fee_note'], feeNoteOf(Fee.fromJson(heavyHourly)));
    });
  });

  group('點位表單', () {
    late FakeAdminGateway gateway;
    late SpotsController spots;

    setUp(() async {
      gateway = FakeAdminGateway(access: adminAal2);
      gateway.spotRows[officialId] = lotRow(gateway);
      spots = SpotsController(gateway);
    });
    tearDown(() => gateway.dispose());

    test('改規則：用它的分區跟著改，送出 fee_plans 與分區，不送全場 fee', () async {
      await spots.open(officialId);
      expect(spots.lot, isTrue);
      expect(spots.dirty, isFalse);
      const fifteen = Fee(
        scooter: Rate(FeeMode.hourly, amount: 15, perMinutes: 60),
        // Its zones let heavy bikes park: never 不適用 (PM_ANS_20261101_55).
        heavy: Rate(FeeMode.sameAsScooter),
        car: Rate(FeeMode.notApplicable),
      );
      spots.setPlan('p1', '機車計時', fifteen);
      expect(spots.zones[2]['fee'], fifteen.toJson());
      expect(await spots.save(''), isTrue);
      final sent = gateway.spotUpdates.single.$2;
      expect(sent.keys.toSet(), {'fee_plans', 'parking_zones'});
      expect((sent['parking_zones'] as List)[0]['fee'], fifteen.toJson());
    });

    test('分區改用另一條規則、新增區域與格位', () async {
      await spots.open(officialId);
      spots.setZone(2, zoneWithPlan(spots.zones[2], 'p2', spots.plans));
      spots.setCard(
        areaCards(spots.zones).first,
        basis: {
          'source_url': 'https://example.test/n',
          'expires_on': '2026-12-31',
        },
      );
      // The access-only bay takes a basis once its bay is picked (#494).
      expect(spots.errors['parking_zones'], contains('請先選格位種類'));
      final start = zoneCondition(spots.zones[0]);
      spots.setZone(
        0,
        zoneWithCondition(
          spots.zones[0],
          ParkingCondition(
            bay: Bay.motorcycle,
            use: BayUse.usual,
            basis: start.basis,
            allow: start.allow,
          ),
        ),
      );
      spots.addZone(like: spots.zones[0]);
      expect(areaCards(spots.zones).first.indexes, [0, 1, 3]);
      // The new bay rests on the area's notice too.
      expect((spots.zones[3]['condition'] as Map)['basis'], {
        'source_url': 'https://example.test/n',
        'expires_on': '2026-12-31',
      });
      // A new bay knows nothing yet: it needs both vehicles before saving.
      spots.setZone(
        3,
        zoneWithCondition(
          spots.zones[3],
          const ParkingCondition(
            bay: Bay.motorcycle,
            allow: ZoneAllow(scooter: true),
          ),
        ),
      );
      expect(spots.errors['parking_zones'], contains('可不可停'));
      expect(await spots.save(''), isFalse);
      spots.setZone(
        3,
        zoneWithCondition(
          spots.zones[3],
          const ParkingCondition(
            bay: Bay.motorcycle,
            allow: ZoneAllow(scooter: true, heavy: false),
          ),
        ),
      );
      expect(spots.errors, isEmpty);
      expect(await spots.save(''), isTrue);
      final sent = gateway.spotUpdates.single.$2;
      expect((sent['parking_zones'] as List)[2]['fee'], heavyHourly);
      expect((sent['parking_zones'] as List)[3]['access'], 'scooterOnly');
    });

    test('只有舊 access 的分區：改名稱照原樣送；補依據先選格位，選了普大共用才寫 share（#494）', () async {
      await spots.open(officialId);
      // Zone 0 is the access-only scooterHeavy one: a new name and another
      // plan leave everything else as stored.
      spots.setCard(areaCards(spots.zones).first, name: '機車區 B1');
      spots.setZone(0, zoneWithPlan(spots.zones[0], 'p2', spots.plans));
      expect(spots.errors, isEmpty);
      expect(await spots.save(''), isTrue);
      final renamed =
          (gateway.spotUpdates.last.$2['parking_zones'] as List)[0] as Map;
      expect(
        renamed,
        {...zones[0], 'name': '機車區 B1', 'fee_plan': 'p2', 'fee': heavyHourly}
          ..remove('area'),
      );

      await spots.open(officialId);
      final first = areaCards(spots.zones).first;
      spots.setCard(first, basis: {'source_url': 'https://example.test/n'});
      expect(spots.zones[0]['access'], 'scooterHeavy');
      expect(spots.errors['parking_zones'], contains('請先選格位種類'));
      final updates = gateway.spotUpdates.length;
      expect(await spots.save(''), isFalse);
      expect(gateway.spotUpdates, hasLength(updates));

      final c = zoneCondition(spots.zones[0]);
      ParkingCondition bay({bool shared = false}) => ParkingCondition(
        bay: Bay.motorcycle,
        use: shared ? BayUse.share : null,
        share: shared ? ShareKind.scooterHeavy : null,
        basis: c.basis,
        allow: c.allow,
      );
      spots.setZone(0, zoneWithCondition(spots.zones[0], bay()));
      expect(spots.errors, isEmpty);
      expect(
        (spots.zones[0]['condition'] as Map).containsKey('share'),
        isFalse,
      );
      spots.setZone(0, zoneWithCondition(spots.zones[0], bay(shared: true)));
      expect(await spots.save(''), isTrue);
      final sent =
          (gateway.spotUpdates.last.$2['parking_zones'] as List)[0] as Map;
      expect(sent['access'], 'scooterHeavy');
      expect((sent['condition'] as Map)['share'], 'scooter_heavy');
      expect((sent['condition'] as Map)['basis'], {
        'source_url': 'https://example.test/n',
      });
    });

    test('只有舊 access 的分區：選了格位又改回未確認，存檔仍要先選格位（#494）', () async {
      await spots.open(officialId);
      final start = zoneCondition(spots.zones[0]);
      spots.setZone(
        0,
        zoneWithCondition(
          spots.zones[0],
          ParkingCondition(bay: Bay.motorcycle, allow: start.allow),
        ),
      );
      expect(spots.errors, isEmpty);
      spots.setZone(
        0,
        zoneWithCondition(spots.zones[0], ParkingCondition(allow: start.allow)),
      );
      expect(spots.zones[0]['condition'], {'allow': start.allow!.toJson()});
      expect(spots.errors['parking_zones'], contains('請先選格位種類'));
      expect(await spots.save(''), isFalse);
      expect(gateway.spotUpdates, isEmpty);
    });

    test(
      '沒有分區、只有 parking_access=scooterHeavy 的停車場：編輯不寫出 condition（#494）',
      () async {
        gateway.spotRows[officialId] = {
          ...lotRow(gateway),
          'parking_zones': const <Object?>[],
          'parking_access': 'scooterHeavy',
          'condition': null,
        };
        await spots.open(officialId);
        expect(spots.lot, isTrue);
        spots.set('name', '濱江停車場');
        spots.set('parking_access', 'scooterHeavy');
        spots.setKind(SpaceKind.offStreet);
        expect(spots.draft['condition'], isNull);
        expect(spots.errors, isEmpty);
        expect(await spots.save(''), isTrue);
        final sent = gateway.spotUpdates.last.$2;
        expect(sent['name'], '濱江停車場');
        expect(sent['condition'], isNull);
        expect(jsonList(sent['parking_zones']), isEmpty);
      },
    );

    test('刪除仍被引用的規則：表單不刪；伺服器拒絕時顯示哪條規則在用', () async {
      await spots.open(officialId);
      spots.deletePlan('p2');
      expect(spots.plans, hasLength(2));
      spots.setPlan('p2', '重機', Fee.fromJson(heavyHourly));
      gateway.spotUpdateError = const PostgrestException(
        message: 'fee plan in use',
        code: '23503',
        details: '{"plans":[{"id":"p2","name":"重機計時","zones":1,"spot":false}]}',
      );
      expect(await spots.save(''), isFalse);
      expect(spots.saveError, contains('「重機計時」1 個分區在用，先改掉引用'));
    });

    test('沒有分區費率時，區域卡預覽 App 會顯示的全場費率', () async {
      gateway.spotRows[officialId] = {
        ...lotRow(gateway),
        'parking_zones': [
          for (final z in zones)
            {...z}
              ..remove('fee_plan')
              ..remove('fee'),
        ],
      };
      await spots.open(officialId);
      expect(spots.zones.any((z) => z['fee'] is Map), isFalse);
      expect(spots.draft['fee'], Fee.fromJson(scooterHourly));
    });

    test('全場費率改選規則時一併送 fee 與它的句子', () async {
      await spots.open(officialId);
      spots.setTopPlan('p2');
      expect(spots.changes, {
        'fee_plan': 'p2',
        'fee': heavyHourly,
        'fee_note': feeNoteOf(Fee.fromJson(heavyHourly)),
      });
    });
  });

  test('點位表單與審核頁擋「比照來源沒有費率」（#155 第 13 項）', () {
    const gap = Fee(
      heavy: Rate(FeeMode.sameAsCar),
      scooter: Rate(FeeMode.hourly, amount: 10, perMinutes: 60),
    );
    expect(validateSpotField(spotField('fee'), gap), contains('大型重機比照汽車費率'));
    expect(
      validatePatch({
        'fee': gap.toJson(),
        'fee_note': feeNoteOf(gap),
      }, sampleSpots()[communityId]!),
      contains('大型重機比照汽車費率'),
    );
    const ok = Fee(
      heavy: Rate(FeeMode.sameAsCar),
      car: Rate(FeeMode.hourly, amount: 40, perMinutes: 60),
    );
    expect(ok.followGap, isNull);
  });

  group('審核頁', () {
    final spot = ReviewSpot(
      sourceId: officialId,
      official: true,
      values: {
        ...sampleSpots()[officialId]!.values,
        'fee_plans': plans,
        'fee_plan': 'p1',
        'fee': scooterHourly,
        'parking_zones': zones,
      },
    );
    const visit = {
      'scooter': {'mode': 'per_visit', 'amount': 20},
    };

    group('只有舊 access: scooterHeavy 的分區（#494）', () {
      const legacy = {'id': 'z1', 'name': '機車區', 'access': 'scooterHeavy'};
      const sharedCondition = {
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'allow': {'scooter': true, 'heavy': true},
      };
      ReviewSpot lot(List<Map<String, Object?>> zones) => ReviewSpot(
        sourceId: officialId,
        official: true,
        values: {
          ...sampleSpots()[officialId]!.values,
          'space_type': 'offStreet',
          'parking_zones': zones,
        },
      );
      ReviewReport report(Map<String, dynamic> proposed) => ReviewReport(
        id: 'r-494',
        sourceId: officialId,
        reason: '分區',
        field: 'zones',
        proposed: proposed,
        createdAt: reportTime,
      );
      String? check(ReviewSpot spot, Map<String, dynamic> proposed) =>
          validatePatch(
            applicablePatch(initialProposal(report(proposed), spot), spot),
            spot,
          );
      // As a rider's build sends it: the access read as 普大共用格.
      const shared = {
        'parking_zones': [
          {'id': 'z1', 'condition': sharedCondition, 'access': 'scooterHeavy'},
        ],
      };

      test('套用建議與修改後套用都擋下，不送出', () async {
        final gateway = FakeAdminGateway(access: adminAal2);
        addTearDown(gateway.dispose);
        final r = report(shared);
        gateway
          ..reports = [r]
          ..spots = {
            officialId: lot([legacy]),
          };
        final review = ReviewController(gateway);
        await review.load();
        await review.decide(r, ReviewDecision.accept, '');
        expect(review.error, contains('請先到點位頁選格位種類'));
        expect(review.pending, isNull);
        review.startEdit(r);
        await review.decide(r, ReviewDecision.acceptEdited, '');
        expect(review.error, contains('請先到點位頁選格位種類'));
        expect(review.pending, isNull);
        await review.flush();
        expect(gateway.resolved, isEmpty);
      });

      test('採納會寫出 share: scooter_heavy 的建議被擋，請先到點位頁選格位種類', () {
        final spot = lot([legacy]);
        expect(check(spot, shared), contains('請先到點位頁選格位種類'));
        // A zone stored with an explicit null condition is the same.
        expect(
          check(
            lot([
              {...legacy, 'condition': null},
            ]),
            shared,
          ),
          contains('請先到點位頁選格位種類'),
        );
        // Only who may park, or only the guide: no shared use, adopted.
        expect(
          check(spot, {
            'parking_zones': [
              {
                'id': 'z1',
                'condition': {
                  'allow': {'scooter': true, 'heavy': false},
                },
                'access': null,
              },
            ],
          }),
          isNull,
        );
        expect(
          check(spot, {
            'parking_zones': [
              {'id': 'z1', 'guide': '入口右側'},
            ],
          }),
          isNull,
        );
        // A new zone is the rider's own pick.
        expect(
          check(spot, {
            'parking_zones': [
              {
                'name': 'B2',
                'condition': sharedCondition,
                'access': 'scooterHeavy',
              },
            ],
          }),
          isNull,
        );
        // Picked on the spot page first: the same suggestion is adopted.
        final picked = lot([
          {...legacy, 'condition': sharedCondition},
        ]);
        expect(check(picked, shared), isNull);
      });

      test('場站層級：停車場的頂層 condition 帶 share 會被現有檢查擋下', () {
        final spot = lot(const []);
        expect(
          check(spot, {
            'condition': {
              'bay': 'motorcycle',
              'use': 'share',
              'share': 'scooter_heavy',
              'charge': 'toll',
            },
          }),
          contains('停放條件和格位類型不一致'),
        );
      });
    });

    test('全場費率的規則有分區共用時要問改哪裡', () {
      final shared = sharedPlanOf({'fee': visit}, spot)!;
      expect(shared.plan['name'], '機車計時');
      expect(shared.zones, ['機車區', 'B2']);
      expect(sharedPlanOf({'fee': null}, spot), isNull);
    });

    test('只改全場費率：另開一條規則；改規則：不送 fee 與句子', () {
      final own = applySharedPlanChoice(
        {'fee': visit, 'fee_note': 'n'},
        spot,
        (scope: SharedPlanScope.onlyHere, name: '全場計次'),
      );
      expect(own['fee_plan'], 'p3');
      expect((own['fee_plans'] as List).last, {
        'id': 'p3',
        'name': '全場計次',
        'fee': visit,
      });
      expect(own['fee'], visit);
      final all = applySharedPlanChoice(
        {'fee': visit, 'fee_note': 'n'},
        spot,
        (scope: SharedPlanScope.plan, name: ''),
      );
      expect(all.keys.toSet(), {'fee_plans', 'fee_plans_seen'});
      // The server refuses it when the plans changed since the page loaded.
      expect(all['fee_plans_seen'], {'plans': plans});
      expect(own['fee_plans_seen'], {'plans': plans});
      expect((all['fee_plans'] as List).first['fee'], visit);
    });

    test('預檢標記與點位現值的組合衝突寫明原因（#155 第 19、20 項）', () {
      final report = ReviewReport.fromJson({
        'id': 'r',
        'source_id': communityId,
        'reason': 'x',
        'proposed': {'fee': visit},
        'created_at': '2026-10-27T00:00:00Z',
        'risk_flags': ['motorcycle_bay_car_fee', 'share_free_needs_basis'],
        'evidence_url': 'https://example.test/notice.pdf',
      });
      expect(report.evidenceUrl, 'https://example.test/notice.pdf');
      final lines = riskFlagLines(report);
      expect(lines.first, contains('建議只改費率，和點位目前的停放條件不一致'));
      expect(lines.last, contains('普大共用的免費格'));
    });
  });

  group('畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    setUp(() {
      gateway = FakeAdminGateway(access: adminAal2);
      gateway.spotRows[officialId] = lotRow(gateway);
    });
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    for (final size in const [
      Size(320, 640),
      Size(402, 874),
      Size(820, 1180),
      Size(1440, 960),
    ]) {
      testWidgets('路外點位表單在 ${size.width.round()} px 顯示計費規則與區域卡，不溢出、可點', (
        tester,
      ) async {
        controller = AdminController(gateway);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await controller.refresh();
        await tester.pumpWidget(
          AdminApp(
            controller: controller,
            initialLocation: '/spots/$officialId',
            reviewMapBuilder: (_, _) => const SizedBox(),
            locationMapBuilder: (_, _) => const SizedBox(),
            spotMapBuilder: (_, _) => const SizedBox(),
          ),
        );
        await tester.pumpAndSettle();
        final form = find
            .descendant(
              of: find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith('spot-form-'),
              ),
              matching: find.byType(Scrollable),
            )
            .first;
        Future<void> reach(Finder target) async {
          await tester.scrollUntilVisible(target, 200, scrollable: form);
          await Scrollable.ensureVisible(
            tester.element(target.first),
            alignment: .3,
          );
          await tester.pumpAndSettle();
        }

        expect(
          find.descendant(
            of: await revealFold(tester, '計費規則與區域'),
            matching: find.textContaining('計費規則 2 條'),
          ),
          findsOneWidget,
        );
        await openFold(tester, '計費規則與區域');
        await reach(find.byKey(const ValueKey('plan-p2')));
        expect(find.text('重機計時'), findsWidgets);
        // The plan a zone uses cannot be deleted.
        await tester.tap(
          find.byKey(const ValueKey('edit-plan-p2')).hitTestable(),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('plan-in-use')),
          200,
          scrollable: find
              .descendant(
                of: find.byType(Dialog).last,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.byKey(const ValueKey('plan-in-use')), findsOneWidget);
        expect(find.text('1 個分區在用，先改掉引用'), findsOneWidget);
        final delete = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('刪除規則'),
            matching: find.byWidgetPredicate((w) => w is OutlinedButton),
          ),
        );
        expect(delete.onPressed, isNull);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();

        await reach(find.byKey(const ValueKey('bay-1')));
        expect(find.text('重機格 ・ 收費未確認'), findsOneWidget);
        final unknown = find.byKey(const ValueKey('bay-1-大型重機-notStated'));
        await reach(unknown);
        expect(unknown.hitTestable(), findsOneWidget);
        // A heavy bay cannot open to scooters: the choice does nothing.
        final scooter = find.byKey(const ValueKey('bay-1-普通機車-allowed'));
        await reach(scooter);
        await tester.tap(scooter.hitTestable());
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('bay-problem-1')), findsNothing);
        expect(find.text('已修改'), findsNothing);
        // The access-only scooterHeavy zone (#494): bay 未確認, and a charge
        // set without a bay asks for the bay first.
        await reach(find.byKey(const ValueKey('bay-0')));
        expect(find.text('格位未確認 ・ 收費未確認'), findsOneWidget);
        final toll = find.byKey(const ValueKey('bay-0-charge-toll'));
        await reach(toll);
        await tester.tap(toll.hitTestable());
        await tester.pumpAndSettle();
        final prompt = find.byKey(const ValueKey('bay-problem-0'));
        await reach(prompt);
        expect(tester.widget<Text>(prompt).data, contains('請先選格位種類'));
        expect(tester.takeException(), isNull);
        await reach(find.byKey(const ValueKey('fee-source-text')));
        expect(find.textContaining('機車每小時10元'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final size in const [Size(402, 874), Size(1440, 960)]) {
      testWidgets('審核頁在 ${size.width.round()} px：預檢標記、依據連結、逐車種差異與共用規則', (
        tester,
      ) async {
        gateway.spots = {
          ...gateway.spots,
          officialId: ReviewSpot(
            sourceId: officialId,
            official: true,
            values: {
              ...lotRow(gateway),
              // The heavy rate follows the scooter's: same JSON, new price.
              'fee': {
                ...scooterHourly,
                'heavy': {'mode': 'same_as_scooter'},
              },
            },
          ),
        };
        gateway.reports = [
          ReviewReport(
            id: 'r-lot',
            sourceId: officialId,
            reason: '收費資訊',
            field: 'fee_note',
            proposed: const {
              'fee': {
                'scooter': {
                  'mode': 'per_visit',
                  'amount': 20,
                  'renew': 'midnight',
                },
                'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
              },
            },
            createdAt: reportTime,
            riskFlags: const ['motorcycle_bay_car_fee'],
            evidenceUrl: 'https://example.test/notice.pdf',
          ),
        ];
        controller = AdminController(gateway);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await controller.refresh();
        await tester.pumpWidget(
          AdminApp(
            controller: controller,
            initialLocation: '/review/r-lot',
            reviewMapBuilder: (_, _) => const SizedBox(),
            locationMapBuilder: (_, _) => const SizedBox(),
            spotMapBuilder: (_, _) => const SizedBox(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('risk-flags')), findsOneWidget);
        expect(find.textContaining('建議只改費率'), findsOneWidget);
        expect(find.byKey(const ValueKey('evidence-url')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('fee-diff')),
          200,
          scrollable: find
              .ancestor(
                of: find.byKey(const ValueKey('risk-flags')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          find.byKey(const ValueKey('fee-diff-scooter-change')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('fee-diff-car-change')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('fee-diff-heavy-change')),
          findsOneWidget,
        );
        expect(find.text('有變更'), findsNWidgets(3));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('套用建議').hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('「機車計時」有 3 處在用'), findsOneWidget);
        expect(find.text('・B2'), findsOneWidget);
        expect(find.text('套用到全場費率'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('confirm-scope')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        final patch = gateway.resolved.single.$3;
        expect(patch['fee_plan'], 'p3');
        expect((patch['fee_plans'] as List).last['name'], '機車重機汽車混合');
      });
    }
  });

  test('可停的車種不能存成「不適用」（PM_ANS_20261101_55）', () {
    const fee = {
      'scooter': {'mode': 'not_applicable'},
      'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
      'car': {'mode': 'not_applicable'},
    };
    expect(
      notApplicableProblem(fee, {'scooter': true, 'heavy': true}),
      '普通機車可以停，收費方式不能選「不適用」',
    );
    expect(
      notApplicableProblem(fee, {'scooter': false, 'heavy': true}),
      isNull,
    );
    expect(
      zoneProblem({
        'name': 'B1',
        'access': 'scooterHeavy',
        'condition': {
          'bay': 'motorcycle',
          'use': 'share',
          'share': 'scooter_heavy',
          'allow': {'scooter': true, 'heavy': true},
        },
        'fee': fee,
      }),
      '「B1」普通機車可以停，收費方式不能選「不適用」',
    );
  });
}
