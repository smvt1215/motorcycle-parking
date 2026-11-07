import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/report/entry_drafts.dart';
import 'package:motorcycle_parking/features/report/entry_pages.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
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
      expect(d.rowLabel, '靠松江路口　汽機車共用格・6 格');
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
      // The rest of a lot's limits wait for S5.
      expect(
        tester
            .widget<EntryRow>(find.byKey(const ValueKey('suggest-limits')))
            .onTap,
        isNull,
      );
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

  group('S1b、S2', () {
    Future<void> openZone(WidgetTester tester, String name) async {
      await tapKey(tester, 'suggest-where');
      await tapText(tester, name);
    }

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

    testWidgets('沒有路段的路邊點顯示整段，進 S4 新增', (tester) async {
      final store = await open(tester, _bare);
      await tapKey(tester, 'suggest-where');
      expect(find.textContaining(firstSegmentNote), findsOneWidget);
      // 費率沒寫一律未提供.
      expect(find.text('未提供'), findsNWidgets(2));
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
