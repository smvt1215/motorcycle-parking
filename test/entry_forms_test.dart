import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/report/entry_drafts.dart';
import 'package:motorcycle_parking/features/report/entry_pages.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/models/zone_entries.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store extends AppStore {
  _Store(LocalRepository local) : super(local, null);
  final sent = <Map<String, dynamic>>[];
  Object? refuse;
  bool signedIn = true;

  @override
  bool get canReport => signedIn;

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    if (refuse case final e?) throw e;
    sent.add(body);
    return '已送交審核';
  }
}

ParkingZone _zone(
  String id,
  String name,
  ParkingAccess? access, {
  ParkingCondition? condition,
}) => ParkingZone(id: id, name: name, access: access, condition: condition);

final _lot = ParkingSpot(
  id: 'official:lot',
  name: '松壽地下停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  entranceNote: '松壽路側車道下坡',
  zones: [
    _zone(
      'b1',
      'B1 機車區',
      ParkingAccess.scooterOnly,
      condition: const ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        allow: ZoneAllow(scooter: true, heavy: false),
      ),
    ),
    _zone(
      'b2',
      'B2 重機專區',
      null,
      condition: const ParkingCondition(
        bay: Bay.heavy,
        use: BayUse.usual,
        allow: ZoneAllow(scooterNotStated: true, heavy: true),
      ),
    ),
  ],
);

const _segment = ParkingSegment(
  id: 's1',
  name: '北側・一般機車格',
  side: RoadSide.north,
  range: '建國北路口至松江路口',
  total: 18,
  condition: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    limits: [
      ParkingLimit(
        LimitKind.noParking,
        periods: [
          LimitPeriod(days: ['mon'], from: '06:00', to: '08:00'),
        ],
      ),
    ],
    allow: ZoneAllow(scooter: true, heavy: true),
  ),
);

const _street = ParkingSpot(
  id: 'official:street',
  name: '南京東路三段路邊機車格',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'official',
  segments: [_segment],
);

const _tdx = ParkingSpot(
  id: 'tdx:lot',
  name: '市府停車場',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'tdx',
  scooterAllowed: true,
  heavyAllowed: true,
);

const _bare = ParkingSpot(
  id: 'official:bare',
  name: '巷口機車格',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.freeMotorcycle,
  source: 'official',
  scooterAllowed: true,
  heavyAllowed: false,
);

void main() {
  Future<_Store> open(
    WidgetTester tester,
    ParkingSpot spot, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      return _Store(LocalRepository(await SharedPreferences.getInstance()));
    }))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpotSuggestions(context, store, spot),
              child: const Text('開啟'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟'));
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final target = find.text(text).last;
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  group('EntryDraft', () {
    test('C3 留空自動命名：側＋格位、沒有側只用格位、同名加序號', () {
      expect(
        autoSegmentName(RoadSide.north, SpaceKind.motorcycle, const []),
        '北側・一般機車格',
      );
      expect(autoSegmentName(null, SpaceKind.car, const []), '汽車格');
      expect(autoSegmentName(null, SpaceKind.car, const ['汽車格']), '汽車格 2');
      expect(
        autoSegmentName(null, SpaceKind.car, const ['汽車格', '汽車格 2']),
        '汽車格 3',
      );
    });

    test('C4 從到合成與拆開，舊資料整串放從', () {
      expect(composeRange('建國北路口', '松江路口'), '建國北路口至松江路口');
      expect(composeRange('建國北路口', ''), '建國北路口起');
      expect(composeRange('', '松江路口'), '至松江路口');
      expect(composeRange(' ', ''), '');
      expect(splitRange('建國北路口至松江路口'), ('建國北路口', '松江路口'));
      expect(splitRange('建國北路口起'), ('建國北路口', ''));
      expect(splitRange('至松江路口'), ('', '松江路口'));
      expect(splitRange('松江路口前 40 公尺'), ('松江路口前 40 公尺', ''));
      expect(splitRange('全段'), ('全段', ''));
    });

    test('沒改到的舊 range 不會因為拆開而變動', () {
      const old = ParkingSegment(
        id: 's',
        name: '南側',
        range: '松江路口前 40 公尺',
        condition: ParkingCondition(
          bay: Bay.car,
          allow: ZoneAllow(scooter: false, heavy: true),
        ),
      );
      final d = EntryDraft.ofSegment(old);
      expect(d.from, '松江路口前 40 公尺');
      expect(entriesPatchOf([d]), isEmpty);
      expect(d.changed, isFalse);
    });

    test('只有重機專用格開放普機是矛盾；其他組合都寫得進 contract（#356）', () {
      expect(
        bayAllowProblem(SpaceKind.heavy, Eligible.allowed),
        contains('重機專用格'),
      );
      for (final kind in BayKindGrid.kinds) {
        for (final s in Eligible.values) {
          for (final h in Eligible.values) {
            if (bayAllowProblem(kind, s) != null) continue;
            final zone =
                (EntryDraft.create(EntryType.zone)
                      ..name = 'B1'
                      ..kind = kind
                      ..scooter = s
                      ..heavy = h)
                    .toJson(const []);
            expect(validZoneList([zone]), isTrue, reason: '$kind $s $h');
            final derived = legacyAccess(
              ParkingCondition.fromJson(zone['condition'], zone: true),
            );
            expect(zone['access'], derived?.name, reason: '$kind $s $h');
            expect(zone.containsKey('access'), derived != null);
            if (s == Eligible.notStated || h == Eligible.notStated) continue;
            final segment =
                (EntryDraft.create(EntryType.segment)
                      ..kind = kind
                      ..scooter = s
                      ..heavy = h)
                    .toJson(const []);
            expect(validSegmentList([segment]), isTrue, reason: '$kind $s $h');
          }
        }
      }
    });

    test('B3 汽機車共用格、普機可停：舊資料的 access 清掉，沒有就不帶', () {
      final stored =
          EntryDraft.ofZone(
              const ParkingZone(
                id: 'b3',
                name: 'B3 汽車區',
                access: ParkingAccess.heavyCar,
                condition: ParkingCondition(
                  bay: Bay.car,
                  use: BayUse.usual,
                  allow: ZoneAllow(scooter: false, heavy: true),
                ),
              ),
            )
            ..kind = SpaceKind.carMotorcycle
            ..scooter = Eligible.allowed;
      final cleared = entriesPatchOf([stored]).single;
      expect(cleared.containsKey('access'), isTrue);
      expect(cleared['access'], isNull);
      final fresh = EntryDraft.ofZone(
        const ParkingZone(
          id: 'b4',
          name: 'B4',
          condition: ParkingCondition(
            bay: Bay.car,
            use: BayUse.share,
            share: ShareKind.carMotorcycle,
            allow: ZoneAllow(scooterNotStated: true, heavy: true),
          ),
        ),
      )..scooter = Eligible.allowed;
      expect(entriesPatchOf([fresh]).single.containsKey('access'), isFalse);
    });

    test('整段當第一個路段時帶上點位的限時與共用時段，不帶 basis', () {
      final d = EntryDraft.ofSpot(
        const ParkingSpot(
          id: 'official:timed',
          name: '巷口',
          lat: 25,
          lng: 121,
          city: '臺北市',
          spaceType: SpaceType.timedMotorcycle,
          scooterAllowed: true,
          heavyAllowed: false,
          condition: ParkingCondition(
            bay: Bay.motorcycle,
            use: BayUse.usual,
            limits: [
              ParkingLimit(
                LimitKind.timeLimit,
                periods: [
                  LimitPeriod(days: 'all', maxMinutes: 20, extensions: 1),
                ],
              ),
            ],
            basis: ConditionBasis(sourceUrl: 'https://example.com/a'),
          ),
        ),
      )..total = '6';
      final patch = entriesPatchOf([d]).single;
      expect(validSegmentList([patch]), isTrue);
      final c = patch['condition'] as Map;
      expect((c['limits'] as List).single, containsPair('kind', 'time_limit'));
      expect(c.containsKey('basis'), isFalse);
      expect(c['allow'], {'scooter': true, 'heavy': false});
    });

    test('改分區資格帶上 access；改成官方未標示清掉 access', () {
      final d = EntryDraft.ofZone(_lot.zones[0])..heavy = Eligible.allowed;
      final patch = entriesPatchOf([d]).single;
      expect(patch['id'], 'b1');
      expect(patch['access'], 'scooterHeavy');
      expect((patch['condition'] as Map)['allow'], {
        'scooter': true,
        'heavy': true,
      });
      d.heavy = Eligible.notStated;
      final cleared = entriesPatchOf([d]).single;
      expect(cleared.containsKey('access'), isTrue);
      expect(cleared['access'], isNull);
    });

    test('只改指引時 patch 只有 guide；撤除只送 id 和 removed', () {
      final d = EntryDraft.ofZone(_lot.zones[0])..guide = '電梯旁';
      expect(entriesPatchOf([d]).single, {'id': 'b1', 'guide': '電梯旁'});
      d.removed = true;
      expect(entriesPatchOf([d]).single, {'id': 'b1', 'removed': true});
    });

    test('換格位時保留限時與禁停，只有汽機車共用格留共用時段；不送 basis', () {
      const stored = ParkingCondition(
        bay: Bay.car,
        use: BayUse.share,
        share: ShareKind.carMotorcycle,
        limits: [
          ParkingLimit(
            LimitKind.timeLimit,
            periods: [LimitPeriod(days: 'all', maxMinutes: 120, extensions: 0)],
          ),
        ],
        schedule: [
          ScheduleSlot(
            days: 'all',
            from: '20:00',
            to: '08:00',
            vehicles: [SlotVehicle.scooter],
          ),
        ],
        basis: ConditionBasis(sourceUrl: 'https://example.com/a'),
        allow: ZoneAllow(scooter: true, heavy: false),
      );
      final d = EntryDraft.ofSegment(
        const ParkingSegment(id: 's', name: '南側', condition: stored),
      );
      d.heavy = Eligible.allowed;
      var c = d.condition;
      expect(c.schedule, hasLength(1));
      expect(c.limits.single.kind, LimitKind.timeLimit);
      expect(c.basis, isNull);
      d.kind = SpaceKind.motorcycle;
      c = d.condition;
      expect(c.schedule, isEmpty);
      expect(c.share, isNull);
      expect(c.limits.single.kind, LimitKind.timeLimit);
    });

    test('沒改的路段不進 patch，也不補 allow（Codex #360）', () {
      final untouched = EntryDraft.ofSegment(
        const ParkingSegment(id: 'a', name: '舊段'),
      );
      final edited =
          EntryDraft.ofSegment(const ParkingSegment(id: 'b', name: '改的段'))
            ..kind = SpaceKind.carMotorcycle
            ..scooter = Eligible.allowed
            ..heavy = Eligible.notAllowed;
      final patch = entriesPatchOf([untouched, edited]);
      expect(patch.map((e) => e['id']), ['b']);
      expect(entriesPatchOf([untouched]), isEmpty);
    });

    test('沒動整段也新增路段時，整段一起成為第一段，不失效', () {
      final whole = EntryDraft.ofSpot(_bare);
      final added = EntryDraft.create(EntryType.segment)
        ..side = RoadSide.north
        ..kind = SpaceKind.carMotorcycle
        ..scooter = Eligible.allowed
        ..heavy = Eligible.notAllowed;
      final drafts = [whole, added];
      expect(whole.changed, isFalse);
      expect(entrySent(whole, drafts), isTrue);
      final lines = entryLines(whole, drafts);
      expect(lines.single.label, '第一段');
      final patch = entriesPatchOf(drafts);
      expect(patch, hasLength(2));
      expect(patch.first.containsKey('id'), isFalse);
      expect(patch.first['condition'], isNotNull);
      expect(patch.map((e) => e['name']).toSet(), hasLength(2));
      // A removed new segment, or nothing new, leaves the spot as it is.
      added.removed = true;
      expect(entrySent(whole, drafts), isFalse);
      expect(entryLines(whole, drafts), isEmpty);
      expect(entriesPatchOf([whole]), isEmpty);
    });

    test('沒有路段的路邊點當一段：沒改不送，改了以新增一段送出', () {
      final d = EntryDraft.ofSpot(_bare);
      expect(d.kind, SpaceKind.motorcycle);
      expect(d.changed, isFalse);
      expect(entriesPatchOf([d]), isEmpty);
      d.total = '12';
      final patch = entriesPatchOf([d]).single;
      expect(patch.containsKey('id'), isFalse);
      expect(patch['name'], '一般機車格');
      expect(patch['total'], 12);
    });

    group('路段繼承點位條件（Codex #360）', () {
      const noParking = ParkingLimit(
        LimitKind.noParking,
        periods: [LimitPeriod(days: 'all', from: '07:00', to: '09:00')],
      );
      const inherited = ParkingSpot(
        id: 'official:inherit',
        name: '巷口',
        lat: 25,
        lng: 121,
        city: '臺北市',
        spaceType: SpaceType.paidMotorcycle,
        condition: ParkingCondition(
          bay: Bay.motorcycle,
          use: BayUse.usual,
          charge: Charge.toll,
          limits: [noParking],
        ),
        segments: [
          ParkingSegment(
            id: 's',
            name: '北側',
            total: 8,
            condition: ParkingCondition(
              allow: ZoneAllow(scooter: true, heavy: false),
            ),
          ),
        ],
      );

      test('格位讀繼承值；沒改不送，只改格數不寫 condition', () {
        final d = draftsOf(inherited, EntryType.segment).single;
        expect(d.kind, SpaceKind.motorcycle);
        expect(d.changed, isFalse);
        expect(entriesPatchOf([d]), isEmpty);
        expect(entryProblems(d), isEmpty);
        d.total = '9';
        expect(d.changeLines().map((l) => l.label), ['共幾格']);
        expect(entriesPatchOf([d]).single, {'id': 's', 'total': 9});
      });

      test('改車種時繼承的限制寫進路段，不因帶了 bay 而消失', () {
        final d = draftsOf(inherited, EntryType.segment).single
          ..heavy = Eligible.allowed;
        final patch = entriesPatchOf([d]).single;
        expect(
          validSegmentList([
            {'name': '北側', ...patch},
          ]),
          isTrue,
        );
        final c = ParkingCondition.fromJson(patch['condition'], zone: true)!;
        const after = ParkingSpot(
          id: 'official:inherit',
          name: '巷口',
          lat: 25,
          lng: 121,
          city: '臺北市',
          spaceType: SpaceType.paidMotorcycle,
        );
        final read = segmentConditionOf(
          ParkingSegment(id: 's', name: '北側', condition: c),
          after,
        )!;
        expect(read.bay, Bay.motorcycle);
        expect(read.charge, Charge.toll);
        expect(read.hasLimit(LimitKind.noParking), isTrue);
      });

      test('不帶點位時仍只讀路段自己的條件', () {
        final d = EntryDraft.ofSegment(inherited.segments.single);
        expect(d.kind, isNull);
      });
    });

    group('路段費率寫成 charge（Codex #360）', () {
      const hourly = Rate(FeeMode.hourly, amount: 20, perMinutes: 60);
      const free = Rate(FeeMode.free);
      EntryDraft fresh(SpaceKind kind) => EntryDraft.create(EntryType.segment)
        ..kind = kind
        ..scooter = Eligible.allowed
        ..heavy = Eligible.allowed;

      test('新路段依自己的費率，沒有再依整條路費率', () {
        const road = Fee(
          scooter: free,
          heavy: free,
          car: Rate(FeeMode.notApplicable),
        );
        final own = fresh(SpaceKind.motorcycle)
          ..fee = const Fee(
            scooter: hourly,
            heavy: Rate(FeeMode.sameAsScooter),
            car: Rate(FeeMode.notApplicable),
          );
        final plain = fresh(SpaceKind.scooterHeavy)..side = RoadSide.north;
        final sent = entriesOf([own, plain], spotFee: road);
        final charges = [
          for (final e in sent) (e['condition'] as Map)['charge'],
        ];
        expect(charges, ['toll', 'free']);
        expect(validSegmentList(sent), isTrue);
        final read = ParkingCondition.fromJson(
          sent.first['condition'],
          zone: true,
        )!;
        expect(ruleKindsOf(read), [SpaceType.paidMotorcycle]);
      });

      test('說不準時不寫：沒費率、兩車不同、不是機車格', () {
        expect(fresh(SpaceKind.motorcycle).condition.charge, isNull);
        expect(chargeOfFee(const Fee()), isNull);
        expect(chargeOfFee(const Fee(scooter: free, heavy: hourly)), isNull);
        final car = fresh(SpaceKind.carMotorcycle)
          ..fee = const Fee(scooter: hourly);
        expect(car.conditionUnder(null).charge, isNull);
      });

      test('依時段的費率只要有一段收費就是收費格；比照汽車看汽車費率', () {
        const byTime = Rate(
          FeeMode.byTime,
          periods: [
            FeePeriod(days: 'all', from: '08:00', to: '20:00', rate: hourly),
            FeePeriod(days: 'all', from: '20:00', to: '08:00', rate: free),
          ],
        );
        expect(chargeOfFee(const Fee(scooter: byTime)), Charge.toll);
        expect(
          chargeOfFee(
            const Fee(
              scooter: Rate(FeeMode.notApplicable),
              heavy: Rate(FeeMode.sameAsCar),
              car: free,
            ),
          ),
          Charge.free,
        );
      });

      test('已存的 charge 不被費率蓋過；S4 新增段用點位費率', () {
        final d = EntryDraft.ofSpot(_bare)..fee = const Fee(scooter: hourly);
        expect(d.condition.charge, Charge.free);
        final added = fresh(SpaceKind.motorcycle);
        final patch = entriesPatchOf([
          added,
        ], spotFee: const Fee(scooter: hourly)).single;
        expect((patch['condition'] as Map)['charge'], 'toll');
      });
    });

    test('格位沒變時保留 ev_only 等非時間限制，換格位才用新格位的（Codex #360）', () {
      final d = EntryDraft.ofSegment(
        const ParkingSegment(
          id: 's',
          name: '南側',
          condition: ParkingCondition(
            bay: Bay.motorcycle,
            limits: [
              ParkingLimit(
                LimitKind.specialVehicle,
                vehicle: SpecialVehicle.disabledModified,
              ),
              ParkingLimit(LimitKind.evOnly),
            ],
            allow: ZoneAllow(scooter: true, heavy: false),
          ),
        ),
      )..heavy = Eligible.allowed;
      expect(d.kind, SpaceKind.disabled);
      final c = ParkingCondition.fromJson(
        entriesPatchOf([d]).single['condition'],
        zone: true,
      )!;
      expect(c.hasLimit(LimitKind.specialVehicle), isTrue);
      expect(c.hasLimit(LimitKind.evOnly), isTrue);
      d.kind = SpaceKind.motorcycle;
      expect(d.condition.limits, isEmpty);
    });

    group('整段帶入點位的條件與格數（Codex #360）', () {
      const counted = ParkingSpot(
        id: 'official:counted',
        name: '巷口機車格',
        lat: 25.05,
        lng: 121.54,
        city: '臺北市',
        spaceType: SpaceType.freeMotorcycle,
        source: 'official',
        scooterAllowed: true,
        heavyAllowed: false,
        scooterTotal: 12,
      );

      test('沒改不算改動，只改指引時第一段帶原格數與收費性質', () {
        final d = EntryDraft.ofSpot(counted);
        expect(d.total, '12');
        expect(d.changed, isFalse);
        expect(d.changeLines(), isEmpty);
        expect(entriesPatchOf([d]), isEmpty);
        expect(d.storedDetail, contains('共 12 格'));
        d.guide = '騎樓旁';
        expect(d.changeLines().map((l) => l.label), ['指引']);
        final patch = entriesPatchOf([d]).single;
        expect(patch['total'], 12);
        expect((patch['condition'] as Map)['charge'], 'free');
        expect(validSegmentList([patch]), isTrue);
      });

      test('沒動整段也新增路段時第一段照樣帶格數', () {
        final whole = EntryDraft.ofSpot(counted);
        final added = EntryDraft.create(EntryType.segment)
          ..kind = SpaceKind.carMotorcycle
          ..scooter = Eligible.allowed
          ..heavy = Eligible.notAllowed;
        final drafts = [whole, added];
        expect(entryLines(whole, drafts).single.label, '第一段');
        expect(entriesPatchOf(drafts).first['total'], 12);
      });

      test('改格數或清掉都算改動；複本保留比對基準', () {
        final d = EntryDraft.ofSpot(counted).copy();
        expect(d.changed, isFalse);
        d.total = '';
        final line = d.changeLines().single;
        expect((line.label, line.from, line.to), ('共幾格', '12', '未填'));
        expect(entriesPatchOf([d]).single.containsKey('total'), isFalse);
        d.total = '15';
        expect(d.changeLines().single.from, '12');
      });

      test('路段裝不下的格數不帶入，整段仍可送', () {
        final d = EntryDraft.ofSpot(
          const ParkingSpot(
            id: 'official:zero',
            name: '巷口',
            lat: 25,
            lng: 121,
            city: '臺北市',
            spaceType: SpaceType.paidMotorcycle,
            scooterTotal: 0,
          ),
        );
        expect(d.total, isEmpty);
        expect(d.changed, isFalse);
      });
    });

    test('沒有 id 的舊條目不進 patch，不會被當成新增', () {
      final old = EntryDraft.ofZone(
        const ParkingZone(name: '舊區', access: ParkingAccess.scooterOnly),
      )..guide = '改了也不送';
      expect(old.editable, isFalse);
      expect(entriesPatchOf([old]), isEmpty);
    });

    test('地圖上目前寫的讀載入值，編輯中不跟著變', () {
      final d = EntryDraft.ofSegment(_segment);
      final before = d.storedDetail;
      d
        ..scooter = Eligible.notAllowed
        ..total = '3'
        ..from = '別處';
      expect(d.storedDetail, before);
      expect(before, contains('建國北路口至松江路口'));
      expect(before, contains('共 18 格'));
      final zone = EntryDraft.ofZone(_lot.zones[0])..kind = SpaceKind.car;
      expect(zone.storedLabel, 'B1 機車區（一般機車格）');
    });

    test('收合列用側別，有自訂名稱才用名稱；入口取第一個逗號前', () {
      final d = EntryDraft.create(EntryType.segment)
        ..side = RoadSide.north
        ..kind = SpaceKind.carMotorcycle
        ..total = '6';
      expect(d.rowLabel, '北側　汽機車共用格・6 格');
      d.name = '靠松江路口';
      expect(d.rowLabel, '北側　靠松江路口　汽機車共用格・6 格');
      // A name that only repeats the bay is not said twice.
      d.name = '汽機車共用格';
      expect(d.rowLabel, '北側　汽機車共用格・6 格');
      d.side = null;
      expect(d.rowLabel, '汽機車共用格・6 格');
      expect(entranceHead('松壽路側車道下坡，機車走右側'), '松壽路側車道下坡');
      expect(entranceHead('一二三四五六七八九十一二'), '一二三四五六七八九十…');
    });

    test('新增多段時自動命名不重複', () {
      EntryDraft bay() => EntryDraft.create(EntryType.segment)
        ..kind = SpaceKind.car
        ..scooter = Eligible.notAllowed
        ..heavy = Eligible.allowed;
      expect(
        [
          for (final e in entriesOf([bay(), bay()])) e['name'],
        ],
        ['汽車格', '汽車格 2'],
      );
    });
  });

  group('S1、S3 清單', () {
    testWidgets('路外依四面路牌分組，備註在最後，社群點同版面', (tester) async {
      await open(tester, _lot);
      for (final header in ['基本資料', '能不能停', '怎麼算錢', '停哪裡', '這裡不能停車了', '其他']) {
        await tester.ensureVisible(find.text(header));
        expect(find.text(header), findsOneWidget);
      }
      expect(find.text('松壽路側車道下坡・2 區'), findsOneWidget);
      expect(find.text('可停車種'), findsNothing);
      expect(find.text('場站型式'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('路邊有可停車種列，費率與路段的摘要', (tester) async {
      await open(tester, _street);
      expect(find.text('可停車種'), findsOneWidget);
      expect(find.text('路段與格位'), findsOneWidget);
      expect(find.text('1 段'), findsOneWidget);
      expect(find.text('場站型式'), findsNothing);
      expect(find.text('入口、分區與格位、可停車種'), findsNothing);
    });

    testWidgets('未登入顯示登入卡；子頁送出開 P11、內容保留（C2）', (tester) async {
      final store = await open(tester, _lot);
      store.signedIn = false;
      store.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('送出前需要登入，建議會由管理員審核。'), findsOneWidget);
      await tapKey(tester, 'suggest-where');
      await tapText(tester, 'B1 機車區');
      expect(find.text('停哪裡・松壽地下停車場'), findsOneWidget);
      await tapKey(tester, 'entry-heavy-allowed');
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(store.sent, isEmpty);
      await tester.tap(find.byTooltip('關閉').last);
      await tester.pumpAndSettle();
      expect(find.text('送出 1 項建議'), findsOneWidget);
    });
  });

  group('全區與整條路（Z1）', () {
    const sameCond = ParkingCondition(
      bay: Bay.motorcycle,
      use: BayUse.usual,
      allow: ZoneAllow(scooter: true, heavy: false),
    );
    ParkingSpot lotOf(String source) => ParkingSpot(
      id: source == 'official' ? 'official:same' : 'same',
      name: '松壽地下停車場',
      lat: 25.03,
      lng: 121.56,
      city: '臺北市',
      spaceType: SpaceType.offStreet,
      source: source,
      zones: [
        _zone('b1', 'B1 機車區', null, condition: sameCond),
        _zone('b2', 'B2 機車區', null, condition: sameCond),
      ],
    );

    test('全區依各區的值是否相同判斷：相同讀出、不同或都沒寫就沒有', () {
      final same = draftsOf(lotOf('official'), EntryType.zone);
      final whole = entryWholeOf(same)!;
      expect(whole, const EntryWhole(Eligible.allowed, Eligible.notAllowed));
      expect(whole.summary, '普機 可停，重機 不可停');
      expect(entryFollows(same.first, whole), isTrue);
      expect(entryWholeOf(draftsOf(_lot, EntryType.zone)), isNull);
      expect(entryWholeOf(const []), isNull);
      // A zone not stating anything takes 全區 and does not change it.
      final drafts = draftsOf(lotOf('official'), EntryType.zone)
        ..add(EntryDraft.ofZone(_zone('b3', '空白區', null)));
      expect(entryWholeOf(drafts), whole);
      expect(entryFollows(drafts.last, whole), isTrue);
      // An edit keeps the 全區 that was loaded.
      drafts.first.heavy = Eligible.allowed;
      expect(entryWholeOf(drafts), whole);
      expect(entryFollows(drafts.first, whole), isFalse);
    });

    test('全區套到重機專用格時，普機維持不可開放（validCondition）', () {
      final d = EntryDraft.create(EntryType.zone)..kind = SpaceKind.heavy;
      const EntryWhole(Eligible.allowed, Eligible.allowed).applyTo(d);
      expect(d.scooter, Eligible.notAllowed);
      expect(d.heavy, Eligible.allowed);
      expect(d.vehiclesEdited, isTrue);
    });

    Future<void> tapSend(WidgetTester tester, String label) async {
      final button = find.widgetWithText(AdaptiveButton, label);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    for (final (name, size) in const [
      ('手機', Size(390, 844)),
      ('平板', Size(820, 1180)),
    ]) {
      testWidgets('$name：全區列與編輯頁，展開成各區的值送出', (tester) async {
        final store = await open(tester, lotOf('official'), size: size);
        await tapKey(tester, 'suggest-where');
        expect(find.text('普機 可停，重機 不可停\n沒有另設的分區沿用全區'), findsOneWidget);
        expect(find.text('沿用全區'), findsNWidgets(2));
        await tapKey(tester, 'entry-whole-row');
        expect(find.text('全區'), findsOneWidget);
        expect(find.text('官方未標示'), findsNWidgets(2));
        expect(find.text('這次會影響'), findsOneWidget);
        expect(find.byKey(const ValueKey('whole-overwrite')), findsNothing);
        await tapKey(tester, 'whole-heavy-allowed');
        expect(find.text('沿用全區'), findsNWidgets(2));
        await tapSend(tester, '送出 2 項建議');
        final body = store.sent.single;
        expect(body['field'], 'zones');
        final patch = ((body['proposed'] as Map)['parking_zones'] as List);
        expect([for (final p in patch) p['id']], ['b1', 'b2']);
        for (final p in patch) {
          expect(
            (p as Map)['condition'],
            containsPair('allow', {'scooter': true, 'heavy': true}),
          );
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.mobile());
    }

    testWidgets('社群點只有可停、不可停；官方未標示不出現', (tester) async {
      await open(tester, lotOf('community'));
      await tapKey(tester, 'suggest-where');
      await tapKey(tester, 'entry-whole-row');
      expect(find.text('官方未標示'), findsNothing);
    });

    testWidgets('各區不同：全區尚未設定，另設的區靠開關才改', (tester) async {
      final store = await open(tester, _lot);
      await tapKey(tester, 'suggest-where');
      expect(find.text('尚未設定，各區各自填\n一次設定普機、重機能不能停'), findsOneWidget);
      expect(find.text('沿用全區'), findsNothing);
      await tapKey(tester, 'entry-whole-row');
      await tapKey(tester, 'whole-scooter-allowed');
      await tapKey(tester, 'whole-heavy-allowed');
      expect(find.text('已另設，不會改'), findsNWidgets(2));
      expect(
        tester
            .widget<AdaptiveButton>(
              find.widgetWithText(AdaptiveButton, '送出 0 項建議'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('另設的 2 區也一起改成全區'), findsOneWidget);
      await tapKey(tester, 'whole-overwrite');
      expect(find.text('會一起改成全區'), findsOneWidget);
      // B2 is a heavy bay: scooters stay out.
      expect(find.text('會一起改，重機專用格普機不會改'), findsOneWidget);
      // B2 keeps scooters out and already says heavy: nothing changes there.
      await tapSend(tester, '送出 1 項建議');
      final patch =
          ((store.sent.single['proposed'] as Map)['parking_zones'] as List)
              .single;
      expect(patch['id'], 'b1');
      expect((patch['condition'] as Map)['allow'], {
        'scooter': true,
        'heavy': true,
      });
    });

    testWidgets('一區打開：沿用全區→另設→改回沿用', (tester) async {
      await open(tester, lotOf('official'));
      await tapKey(tester, 'suggest-where');
      await tapText(tester, 'B1 機車區');
      expect(find.byKey(const ValueKey('entry-follows-whole')), findsOneWidget);
      expect(find.text('沿用全區：普機 可停，重機 不可停'), findsOneWidget);
      expect(find.byKey(const ValueKey('entry-heavy-allowed')), findsNothing);
      await tapKey(tester, 'entry-set-apart');
      expect(find.byKey(const ValueKey('entry-heavy-allowed')), findsOneWidget);
      await tapKey(tester, 'entry-heavy-allowed');
      expect(find.text('另設中，和全區不同'), findsOneWidget);
      await tapKey(tester, 'entry-back-to-whole');
      expect(find.byKey(const ValueKey('entry-follows-whole')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('路段用「整條路」，排在整條路費率上方', (tester) async {
      final store = await open(
        tester,
        const ParkingSpot(
          id: 'official:road',
          name: '路',
          lat: 25.05,
          lng: 121.54,
          city: '臺北市',
          spaceType: SpaceType.paidMotorcycle,
          source: 'official',
          segments: [
            ParkingSegment(
              id: 's1',
              name: '北側',
              condition: ParkingCondition(
                bay: Bay.motorcycle,
                use: BayUse.usual,
                allow: ZoneAllow(scooter: true, heavy: true),
              ),
            ),
            ParkingSegment(
              id: 's2',
              name: '南側',
              condition: ParkingCondition(
                bay: Bay.motorcycle,
                use: BayUse.usual,
                allow: ZoneAllow(scooter: true, heavy: true),
              ),
            ),
          ],
        ),
      );
      await tapKey(tester, 'suggest-where');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('entry-whole-row'))).dy,
        lessThan(tester.getTopLeft(find.text('整條路費率')).dy),
      );
      await tapKey(tester, 'entry-whole-row');
      expect(find.text('另設的 0 段也一起改成整條路'), findsNothing);
      await tapKey(tester, 'whole-heavy-notAllowed');
      await tapSend(tester, '送出 2 項建議');
      expect(store.sent.single['field'], 'segments');
    });

    testWidgets('N1 還沒有分區：先設全區，新增的分區帶入', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        return _Store(LocalRepository(await SharedPreferences.getInstance()));
      }))!;
      addTearDown(store.dispose);
      final drafts = <EntryDraft>[];
      EntryWhole? whole;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: FormFlow(
              child: EntryListPage(
                args: EntryListArgs(
                  store: store,
                  type: EntryType.zone,
                  subtitle: '新增停車點',
                  city: '臺北市',
                  drafts: drafts,
                  fee: () => const Fee(),
                  whole: () => whole,
                  onWhole: (v) => whole = v,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('entry-whole-row')), findsOneWidget);
      await tapKey(tester, 'entry-whole-row');
      await tapKey(tester, 'whole-scooter-allowed');
      await tapKey(tester, 'whole-heavy-notAllowed');
      await tester.tap(find.widgetWithText(AdaptiveButton, '完成'));
      await tester.pumpAndSettle();
      expect(whole, const EntryWhole(Eligible.allowed, Eligible.notAllowed));
      expect(find.text('普機 可停，重機 不可停\n新增的區沿用這裡，也可以在該區另設'), findsOneWidget);
      await tester.tap(find.text('新增一區'));
      await tester.pumpAndSettle();
      expect(find.text('沿用全區：普機 可停，重機 不可停'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('S1b、S2', () {
    Future<void> openZone(WidgetTester tester, String name) async {
      await tapKey(tester, 'suggest-where');
      await tapText(tester, name);
    }

    Future<void> badLinkScrolls(WidgetTester tester, _Store store) async {
      final link = find.byKey(const ValueKey('evidence-url'));
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.enterText(link, '松壽路公告');
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(
            find.ancestor(of: link, matching: find.byType(Scrollable)).first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(link).dy, greaterThan(844));
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent, isEmpty);
      expect(find.text('這看起來不是網址，請貼上公告頁的網址'), findsOneWidget);
      expect(tester.getTopLeft(link).dy, lessThan(800));
    }

    testWidgets('S2 連結錯誤按送出時捲到欄位，不送出', (tester) async {
      final store = await open(tester, _lot);
      await openZone(tester, 'B2 重機專區');
      await badLinkScrolls(tester, store);
    });

    testWidgets('S4 連結錯誤按送出時捲到欄位，不送出', (tester) async {
      final store = await open(tester, _street);
      await tapKey(tester, 'suggest-where');
      await tapText(tester, '一般機車格');
      await badLinkScrolls(tester, store);
    });

    testWidgets('S1b 列出入口、分區標籤、新增一區和說明', (tester) async {
      await open(tester, _lot);
      await tapKey(tester, 'suggest-where');
      expect(find.text('入口'), findsOneWidget);
      expect(find.text('普機 可停'), findsOneWidget);
      expect(find.text('重機 不能停'), findsOneWidget);
      expect(find.text('普機 官方未標示'), findsOneWidget);
      expect(find.text('重機 可停'), findsOneWidget);
      expect(find.text('新增一區'), findsOneWidget);
      expect(find.textContaining('進該區選「這區已撤除」'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('S2 差異摘要、項目數、其他區沒有改；送出分區 patch', (tester) async {
      final store = await open(tester, _lot);
      await openZone(tester, 'B2 重機專區');
      expect(find.text('修改中'), findsOneWidget);
      expect(find.text('沒有改'), findsOneWidget);
      expect(
        tester.widget<AdaptiveButton>(find.byType(AdaptiveButton)).onPressed,
        isNull,
      );
      await tapKey(tester, 'entry-scooter-notAllowed');
      await tester.enterText(
        find.byKey(const ValueKey('entry-guide')),
        '電梯旁，地面標「重機」',
      );
      await tester.pumpAndSettle();
      expect(find.text('你要改的內容'), findsOneWidget);
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 2 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['action'], 'flag');
      expect(body['source_id'], 'official:lot');
      expect(body['field'], 'zones');
      final patch = ((body['proposed'] as Map)['parking_zones'] as List).single;
      expect(patch['id'], 'b2');
      expect(patch['guide'], '電梯旁，地面標「重機」');
      expect(patch['access'], 'heavyOnly');
      expect(find.text('範例模式：建議沒有實際送出，只用來測試流程。'), findsOneWidget);
      expect(find.byType(FormFlow), findsNothing);
    });

    testWidgets('重機專用格開放普機時行內說明並擋下', (tester) async {
      final store = await open(tester, _lot);
      await openZone(tester, 'B1 機車區');
      await tapKey(tester, 'bay-heavy');
      expect(find.byKey(const ValueKey('entry-bay-problem')), findsOneWidget);
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent, isEmpty);
    });

    testWidgets('B3 汽機車共用格、普機可停可以送出，不帶 access（#356）', (tester) async {
      final store = await open(tester, _lot);
      await openZone(tester, 'B1 機車區');
      await tapKey(tester, 'bay-carMotorcycle');
      await tapKey(tester, 'entry-heavy-allowed');
      expect(find.byKey(const ValueKey('entry-bay-problem')), findsNothing);
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 2 項建議'));
      await tester.pumpAndSettle();
      final patch =
          ((store.sent.single['proposed'] as Map)['parking_zones'] as List)
              .single;
      expect((patch['condition'] as Map)['share'], 'car_motorcycle');
      expect((patch['condition'] as Map)['allow'], {
        'scooter': true,
        'heavy': true,
      });
      expect(patch['access'], isNull);
    });

    testWidgets('這區已撤除可取消，算一項；新增一區要填名稱和兩種車', (tester) async {
      final store = await open(tester, _lot);
      await openZone(tester, 'B1 機車區');
      await tapText(tester, '這區已撤除');
      expect(find.text('將撤除'), findsOneWidget);
      await tapText(tester, '取消撤除');
      expect(find.text('送出 0 項建議'), findsOneWidget);
      await tapText(tester, '新增一區');
      expect(find.text('送出 1 項建議'), findsOneWidget);
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent, isEmpty);
      expect(find.text('請填寫分區名稱，或刪除此分區'), findsOneWidget);
      expect(find.text('請選地面畫的格位'), findsOneWidget);
      expect(find.text('請選擇普通機車能不能停'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('entry-name')), 'B3');
      await tapKey(tester, 'bay-car');
      await tapKey(tester, 'entry-scooter-notAllowed');
      await tapKey(tester, 'entry-heavy-allowed');
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      final patch =
          ((store.sent.single['proposed'] as Map)['parking_zones'] as List)
              .single;
      expect(patch.containsKey('id'), isFalse);
      expect(patch['name'], 'B3');
      expect(patch['access'], 'heavyCar');
    });

    testWidgets('停權時開共用面板，內容保留（#331）', (tester) async {
      final store = await open(tester, _lot);
      store.refuse = const AccountSuspended(null);
      await openZone(tester, 'B1 機車區');
      await tapKey(tester, 'entry-heavy-allowed');
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.byType(SuspendedPanel), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('送出 1 項建議'), findsOneWidget);
    });

    testWidgets('網路失敗時內容保留並顯示可重送', (tester) async {
      final store = await open(tester, _lot);
      store.refuse = Exception('offline');
      await openZone(tester, 'B1 機車區');
      await tapKey(tester, 'entry-heavy-allowed');
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.text('建議沒有送出，內容還在，請確認網路後再送一次。'), findsOneWidget);
      expect(find.text('送出 1 項建議'), findsOneWidget);
    });
  });

  group('S3b、S4', () {
    testWidgets('S3b 依側分組，段卡帶範圍、標籤和費率列', (tester) async {
      await open(tester, _street);
      await tapKey(tester, 'suggest-where');
      expect(find.text('北側'), findsOneWidget);
      expect(find.text('一般機車格'), findsOneWidget);
      expect(find.text('建國北路口至松江路口・共 18 格'), findsOneWidget);
      expect(find.text('普機・重機可停'), findsOneWidget);
      expect(find.textContaining('06:00–08:00'), findsOneWidget);
      expect(find.text('整條路費率'), findsOneWidget);
      expect(find.text('新增一段'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TDX 點沒有分區，可停車種走點位層表單（Codex #360）', (tester) async {
      final store = await open(tester, _tdx);
      expect(find.byKey(const ValueKey('suggest-vehicles')), findsNothing);
      await tapKey(tester, 'suggest-eligibility');
      await tapKey(tester, 'suggestion-heavy-notAllowed');
      await tapText(tester, '送出修改建議');
      expect(store.sent.single['field'], 'eligibility');
      expect((store.sent.single['proposed'] as Map)['heavy_allowed'], isFalse);
    });

    testWidgets('大字級的格位清單同樣只有七種，沒有停車場（Codex #360）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: BayKindGrid(value: null, onChanged: (_) {}),
              ),
            ),
          ),
        ),
      );
      for (final kind in BayKindGrid.kinds) {
        expect(find.byKey(ValueKey('bay-${kind.name}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('bay-offStreet')), findsNothing);
    });

    testWidgets('沒有路段的路邊點顯示整段，進 S4 新增', (tester) async {
      final store = await open(tester, _bare);
      await tapKey(tester, 'suggest-where');
      expect(find.textContaining(firstSegmentNote), findsOneWidget);
      // 費率沒寫一律未提供.
      expect(find.textContaining('未提供'), findsNWidgets(2));
      await tapText(tester, '一般機車格');
      await tester.enterText(find.byKey(const ValueKey('entry-total')), '8');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent.single['field'], 'segments');
      final patch =
          ((store.sent.single['proposed'] as Map)['parking_segments'] as List)
              .single;
      expect(patch['total'], 8);
      expect(patch.containsKey('id'), isFalse);
      expect((patch['condition'] as Map)['allow'], {
        'scooter': true,
        'heavy': false,
      });
    });

    testWidgets('S4 停權時開共用面板，內容保留（#331）', (tester) async {
      final store = await open(tester, _street);
      store.refuse = const AccountSuspended(null);
      await tapKey(tester, 'suggest-where');
      await tapText(tester, '一般機車格');
      await tester.enterText(
        find.byKey(const ValueKey('entry-guide')),
        '靠建國北路口',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.byType(SuspendedPanel), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(SuspendedPanel), findsNothing);
      expect(find.text('靠建國北路口'), findsOneWidget);
      expect(find.text('送出 1 項建議'), findsOneWidget);
      expect(store.sent, isEmpty);
    });

    testWidgets('S4 只有可停、不可停；改範圍合成字串；留空沿用自動名稱', (tester) async {
      final store = await open(tester, _street);
      await tapKey(tester, 'suggest-where');
      await tapText(tester, '一般機車格');
      expect(
        find.byKey(const ValueKey('entry-scooter-notStated')),
        findsNothing,
      );
      // No disabled photo cell: only the notice link is left.
      expect(find.byKey(const ValueKey('evidence-url')), findsOneWidget);
      expect(find.byIcon(Icons.add_a_photo_outlined), findsNothing);
      expect(find.text('照片'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('entry-name')))
            .controller!
            .text,
        '',
      );
      await tester.enterText(find.byKey(const ValueKey('entry-to')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AdaptiveButton, '送出 1 項建議'));
      await tester.pumpAndSettle();
      final patch =
          ((store.sent.single['proposed'] as Map)['parking_segments'] as List)
              .single;
      expect(patch, {'id': 's1', 'range': '建國北路口起'});
    });
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final (size, scale) in const [
      (Size(320, 640), 1.0),
      (Size(390, 844), 1.0),
      (Size(390, 844), 1.6),
      (Size(700, 1000), 1.0),
      (Size(1040, 800), 1.0),
    ]) {
      final label =
          '${size.width.toInt()}×${size.height.toInt()}、$scale 倍、${platform.name}';
      testWidgets('S2 在 $label 不溢出，觸控達標', (tester) async {
        await open(tester, _lot, size: size, scale: scale);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'suggest-where');
        expect(tester.takeException(), isNull);
        await tapText(tester, 'B1 機車區');
        expect(tester.takeException(), isNull);
        final min = platform == TargetPlatform.iOS ? 44.0 : 48.0;
        expect(
          tester
              .getSize(find.byKey(const ValueKey('entry-heavy-allowed')))
              .height,
          greaterThanOrEqualTo(min),
        );
        if (scale == 1) {
          expect(
            tester.getSize(find.byKey(const ValueKey('bay-motorcycle'))).height,
            greaterThanOrEqualTo(92),
          );
        }
      }, variant: TargetPlatformVariant({platform}));
      testWidgets('S4 在 $label 不溢出', (tester) async {
        await open(tester, _street, size: size, scale: scale);
        await tapKey(tester, 'suggest-where');
        expect(tester.takeException(), isNull);
        await tapText(tester, '一般機車格');
        expect(tester.takeException(), isNull);
        final scooter = tester.getCenter(
          find.byKey(const ValueKey('entry-scooter-allowed')),
        );
        final heavy = tester.getCenter(
          find.byKey(const ValueKey('entry-heavy-allowed')),
        );
        // Side by side once there is room (S4); stacked at 320 and large text.
        expect(scooter.dy == heavy.dy, size.width > 320 && scale == 1);
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
