import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/precheck.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/report/entry_drafts.dart';
import 'package:motorcycle_parking/features/report/entry_pages.dart';
import 'package:motorcycle_parking/features/report/fee_forms.dart';
import 'package:motorcycle_parking/features/report/fee_suggestion.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/features/report/time_rules_page.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/models/zone_entries.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/fee_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fee_editor_steps.dart';

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

const _hourly = Rate(
  FeeMode.hourly,
  amount: 20,
  perMinutes: 60,
  dailyCap: 100,
  capReset: CapReset.calendarDay,
);
const _plain = Rate(FeeMode.hourly, amount: 20, perMinutes: 60);
const _na = Rate(FeeMode.notApplicable);

const _night = ParkingLimit(
  LimitKind.noParking,
  periods: [LimitPeriod(days: 'all', from: '23:00', to: '07:00')],
);

const _lot = ParkingSpot(
  id: 'official:lot',
  name: '松壽地下停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  feeNote: '每小時 20 元',
  fee: Fee(scooter: _plain, heavy: _plain, car: _plain),
  zones: [
    ParkingZone(
      id: 'b1',
      name: 'B1 機車區',
      fee: Fee(scooter: _plain, heavy: _na, car: _na),
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        allow: ZoneAllow(scooter: true, heavy: false),
      ),
    ),
    ParkingZone(
      id: 'b2',
      name: 'B2 重機專區',
      fee: Fee(scooter: _na, heavy: _hourly, car: _na),
      condition: ParkingCondition(
        bay: Bay.heavy,
        use: BayUse.usual,
        limits: [_night],
        allow: ZoneAllow(scooter: false, heavy: true),
      ),
    ),
    ParkingZone(
      id: 'b3',
      name: 'B3 汽車區',
      fee: Fee(scooter: _plain, heavy: _plain),
      condition: ParkingCondition(
        bay: Bay.car,
        use: BayUse.share,
        share: ShareKind.carMotorcycle,
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

const _street = ParkingSpot(
  id: 'official:street',
  name: '南京東路',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'official',
  segments: [
    ParkingSegment(
      id: 's1',
      name: '靠松江路口',
      side: RoadSide.north,
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        charge: Charge.toll,
        allow: ZoneAllow(scooter: true, heavy: false),
      ),
    ),
  ],
);

const _inherit = ParkingSpot(
  id: 'official:inherit',
  name: '沿用停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  fee: Fee(scooter: _plain, heavy: _plain, car: _plain),
  zones: [
    ParkingZone(
      id: 'b9',
      name: 'B9 沿用區',
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

const _mixedInherit = ParkingSpot(
  id: 'official:mixed',
  name: '沿用停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  fee: Fee(
    scooter: _plain,
    heavy: Rate(FeeMode.free),
    car: Rate(
      FeeMode.byTime,
      periods: [FeePeriod(days: 'all', rate: Rate(FeeMode.free))],
    ),
  ),
  zones: [
    ParkingZone(
      id: 'b3',
      name: 'B3 汽車區',
      condition: ParkingCondition(
        bay: Bay.car,
        use: BayUse.share,
        share: ShareKind.carMotorcycle,
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

const _ruleStreet = ParkingSpot(
  id: 'official:rules',
  name: '南京東路三段路邊機車格',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'official',
  segments: [
    ParkingSegment(
      id: 's1',
      name: '北側・一般機車格',
      side: RoadSide.north,
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        charge: Charge.toll,
        limits: [_night],
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
    ParkingSegment(
      id: 's2',
      name: '南側・汽機車共用格',
      side: RoadSide.south,
      condition: ParkingCondition(
        bay: Bay.car,
        use: BayUse.share,
        share: ShareKind.carMotorcycle,
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

const _noted = ParkingSpot(
  id: 'official:noted',
  name: '松壽地下停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  fee: Fee(scooter: _plain, heavy: _plain, car: _plain),
  zones: [
    ParkingZone(
      id: 'b1',
      name: 'B1 機車區',
      feeNote: '平日每小時 30 元；假日每小時 50 元；需按鈴或請管理員協助，平日每日 60 元；假日每次 80 元',
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

const _oneZone = ParkingSpot(
  id: 'official:one',
  name: '單區停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  zones: [
    ParkingZone(
      id: 'b1',
      name: 'B1',
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        limits: [_night],
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

const _ownSegment = ParkingSpot(
  id: 'official:own',
  name: '南京東路',
  lat: 25.05,
  lng: 121.54,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'official',
  segments: [
    ParkingSegment(
      id: 's1',
      name: '靠松江路口',
      side: RoadSide.north,
      fee: Fee(scooter: _plain, heavy: _na, car: _na),
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        charge: Charge.toll,
        allow: ZoneAllow(scooter: true, heavy: false),
      ),
    ),
  ],
);

/// 路邊、沒有路段、自己有限時（#365 Codex）。
const _timedStreet = ParkingSpot(
  id: 'official:timed',
  name: '忠孝東路',
  lat: 25.04,
  lng: 121.55,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'official',
  fee: Fee(scooter: _plain, heavy: _na, car: _na),
  condition: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    charge: Charge.toll,
    limits: [
      ParkingLimit(
        LimitKind.timeLimit,
        periods: [LimitPeriod(days: 'all', maxMinutes: 120)],
      ),
    ],
    allow: ZoneAllow(scooter: true, heavy: false),
  ),
);

/// 只有普通機車的舊全場費率，跨日規則沒選（#365 Codex）。
const _partialLot = ParkingSpot(
  id: 'official:partial',
  name: '部分費率停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
  fee: Fee(
    scooter: Rate(FeeMode.perVisit, amount: 30),
    heavy: Rate(FeeMode.perVisit, amount: 30),
  ),
  zones: [
    ParkingZone(
      id: 'b1',
      name: 'B1',
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        allow: ZoneAllow(scooter: true, heavy: true),
      ),
    ),
  ],
);

void main() {
  late _Store store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = _Store(LocalRepository(await SharedPreferences.getInstance()));
    addTearDown(store.dispose);
  });

  Future<void> pump(
    WidgetTester tester,
    ParkingSpot spot, {
    double width = 390,
    double scale = 1,
    double height = 844,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
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
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showSpotSuggestions(context, store, spot),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) => tapFee(tester, key);

  Future<void> tapText(WidgetTester tester, String text) async {
    final target = find.text(text).last;
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Finder submit(String label) => find.widgetWithText(AdaptiveButton, label);

  group('純函式', () {
    test('F0 標籤用短寫法，沒有值寫未提供（C10）', () {
      const fee = Fee(scooter: _plain, heavy: _hourly);
      expect(rateBrief(fee, FeeVehicle.scooter), '20/時');
      expect(rateBrief(fee, FeeVehicle.heavy), '20/時・上限 100');
      expect(rateBrief(fee, FeeVehicle.car), '未提供');
      expect(rateBrief(const Fee(car: _na), FeeVehicle.car), '不適用');
      expect(
        rateBrief(
          const Fee(
            scooter: Rate(FeeMode.perVisit, amount: 30),
            heavy: Rate(FeeMode.sameAsScooter),
          ),
          FeeVehicle.heavy,
        ),
        '30/次',
      );
    });

    test('沿用全場的分區起始值：格位沒有的車種是不適用', () {
      final d = EntryDraft.ofZone(
        const ParkingZone(
          id: 'b2',
          name: 'B2',
          condition: ParkingCondition(
            bay: Bay.heavy,
            use: BayUse.usual,
            allow: ZoneAllow(scooter: false, heavy: true),
          ),
        ),
      );
      final fee = startFee(d, _lot.fee!);
      expect(fee.scooter, _na);
      expect(fee.heavy, _plain);
      expect(fee.car, _na);
      expect(whyNotApplicable(d)[FeeVehicle.car], '這區沒有汽車格');
    });

    test('禁停算出非開放時段，沒有規定時不畫灰色（C7）', () {
      const c = ParkingCondition(
        bay: Bay.heavy,
        limits: [
          _night,
          ParkingLimit(
            LimitKind.noParking,
            periods: [LimitPeriod(days: 'holiday')],
          ),
        ],
      );
      final week = closedWeek(c, VehicleType.heavy, street: false);
      expect(feeClosedText(week), '23:00–07:00、假日');
      expect(week[5], [(0, 1440)]);
      expect(
        feeClosedText(
          closedWeek(
            const ParkingCondition(bay: Bay.heavy),
            VehicleType.heavy,
            street: false,
          ),
        ),
        isNull,
      );
    });

    test('各區禁停不同時，全場費率不畫灰色（C7）', () {
      final drafts = [for (final z in _lot.zones) EntryDraft.ofZone(z)];
      expect(closedFor(drafts, street: false, store: store), isEmpty);
    });
  });

  group('F1b 純函式', () {
    test('entriesPatch：{id, fee: null} 移除 fee 與 fee_plan，其他鍵不動', () {
      final out = entriesPatch(
        [
          {
            'id': 'b2',
            'name': 'B2',
            'guide': '走右側',
            'fee': _lot.zones[1].fee!.toJson(),
            'fee_plan': 'plan-1',
          },
          {
            'id': 'b3',
            'name': 'B3',
            'fee': {
              'scooter': {'mode': 'free'},
            },
          },
        ],
        [
          {'id': 'b2', 'fee': null},
        ],
      );
      expect(out, [
        {'id': 'b2', 'name': 'B2', 'guide': '走右側'},
        {
          'id': 'b3',
          'name': 'B3',
          'fee': {
            'scooter': {'mode': 'free'},
          },
        },
      ]);
    });

    test('沿用全場標籤帶實際費率；全場沒有費率寫未提供', () {
      final d = EntryDraft.ofZone(_lot.zones[1]);
      expect(followTag(d, _lot.fee!).text, '沿用全場：20/時');
      expect(followTag(d, const Fee()).text, '未提供');
      expect(
        followTag(
          EntryDraft.ofZone(_lot.zones[2]),
          const Fee(
            scooter: _plain,
            heavy: Rate(FeeMode.free),
            car: Rate(FeeMode.free),
          ),
        ).text,
        '沿用全場：普機 20/時、重機 免費、汽車 免費',
      );
    });

    test('toJson 沒有自己的費率時移除 fee，patch 是 fee: null', () {
      final d = EntryDraft.ofZone(_lot.zones[1])..fee = null;
      final others = EntryDraft.ofZone(_lot.zones[0]);
      expect(entriesPatchOf([others, d]), [
        {'id': 'b2', 'fee': null},
      ]);
    });

    test('比照的車種在這區不適用時，起始值解成實際費率（比照普機、比照汽車）', () {
      final bay = EntryDraft.ofZone(_lot.zones[1]);
      final d = bay.copy()..fee = null;
      final scooter = startFee(
        d,
        const Fee(
          scooter: _plain,
          heavy: Rate(FeeMode.sameAsScooter),
          car: _na,
        ),
      );
      expect(scooter.scooter, _na);
      expect(scooter.heavy, _plain);
      final car = startFee(
        d,
        const Fee(scooter: _na, heavy: Rate(FeeMode.sameAsCar), car: _plain),
      );
      expect(car.car, _na);
      expect(car.heavy, _plain);
      expect(precheckBlocking(precheckFee(car.toJson())), isEmpty);
    });

    test('全場同價：不適用以外相同就讀一次，比照算進去', () {
      expect(
        wholeFeeText(const Fee(scooter: _hourly, heavy: _hourly, car: _na), ''),
        '每小時 20 元，當日上限 100 元',
      );
      expect(
        wholeFeeText(
          const Fee(
            scooter: _plain,
            heavy: Rate(FeeMode.sameAsScooter),
            car: _plain,
          ),
          '',
        ),
        '每小時 20 元',
      );
      // A vehicle with no rate is not the same price.
      expect(
        wholeFeeText(const Fee(scooter: _plain, heavy: _plain), ''),
        contains('大型重機'),
      );
    });

    test('自己的費率依時段分行', () {
      expect(
        ownFeeLines(
          const Fee(
            scooter: _na,
            heavy: Rate(
              FeeMode.byTime,
              periods: [
                FeePeriod(
                  days: 'weekday',
                  from: '07:00',
                  to: '20:00',
                  rate: Rate(FeeMode.hourly, amount: 30, perMinutes: 60),
                ),
              ],
            ),
            car: _na,
          ),
        ),
        ['平日 07:00–20:00 每小時 30 元'],
      );
    });
  });

  group('F1b', () {
    Future<void> openZone(WidgetTester tester, String name) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, name);
    }

    testWidgets('按下後留在 F1，送出才算數，送 {id, fee: null}（C6）', (tester) async {
      await openZone(tester, 'B2 重機專區');
      expect(find.text('送出 0 項建議'), findsOneWidget);
      await tapKey(tester, 'fee-revert');
      expect(store.sent, isEmpty);
      expect(find.text('將改回沿用全場'), findsOneWidget);
      expect(find.text('目前自己的費率'), findsOneWidget);
      expect(find.text('全場費率'), findsOneWidget);
      expect(find.text('你要改的內容'), findsOneWidget);
      expect(find.byKey(const ValueKey('fee-revert')), findsNothing);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'zones');
      expect((body['proposed'] as Map)['parking_zones'], [
        {'id': 'b2', 'fee': null},
      ]);
      expect(body['reason'], '費率：B2 重機專區 自訂 → 沿用全場');
    });

    testWidgets('取消與返回都回到編輯，已改的內容不變', (tester) async {
      await openZone(tester, 'B2 重機專區');
      await chooseFeeMode(tester, 'heavy', 'free');
      expect(find.text('送出 1 項建議'), findsOneWidget);
      await tapKey(tester, 'fee-revert');
      await tapKey(tester, 'fee-revert-cancel');
      expect(find.text('將改回沿用全場'), findsNothing);
      expect(find.text('送出 1 項建議'), findsOneWidget);
      await tapKey(tester, 'fee-revert');
      await tester.tap(find.byKey(const ValueKey('form-header-leading')).last);
      await tester.pumpAndSettle();
      expect(find.byType(FeeEditor), findsOneWidget);
      expect(find.text('將改回沿用全場'), findsNothing);
      expect(find.text('送出 1 項建議'), findsOneWidget);
    });

    testWidgets('沒有自己費率的分區與全場卡都沒有這顆按鈕', (tester) async {
      await pump(tester, _inherit);
      await tapKey(tester, 'suggest-fee');
      expect(find.text('沿用全場：20/時'), findsOneWidget);
      await tapText(tester, 'B9 沿用區');
      expect(find.byType(FeeEditor), findsOneWidget);
      expect(find.byKey(const ValueKey('fee-revert')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('form-header-leading')).last);
      await tester.pumpAndSettle();
      await tapText(tester, '全場費率');
      expect(find.byKey(const ValueKey('fee-revert')), findsNothing);
    });

    testWidgets('路段寫沿用整條路；整條路沒有費率寫整條路未提供', (tester) async {
      await pump(tester, _ownSegment);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '費率');
      expect(find.text('改回沿用整條路費率'), findsOneWidget);
      await tapKey(tester, 'fee-revert');
      expect(find.text('將改回沿用整條路費率'), findsOneWidget);
      expect(find.text('整條路費率'), findsOneWidget);
      expect(find.text('整條路未提供'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'segments');
      expect((body['proposed'] as Map)['parking_segments'], [
        {'id': 's1', 'fee': null},
      ]);
      expect(body['reason'], contains('自訂 → 沿用整條路'));
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('F1b 在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _lot, width: width, scale: scale);
          await tapKey(tester, 'suggest-fee');
          await tapText(tester, 'B2 重機專區');
          await tapKey(tester, 'fee-revert');
          expect(tester.takeException(), isNull);
          final size = tester.getSize(
            find.byKey(const ValueKey('fee-revert-cancel')),
          );
          expect(
            size.height,
            greaterThanOrEqualTo(platform == TargetPlatform.iOS ? 44 : 48),
          );
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  });

  group('F1c', () {
    Future<void> changeCar(WidgetTester tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '全場費率');
    }

    final link = find.byKey(const ValueKey('evidence-url'));

    testWidgets('跟著摘要出現，文字保留；連結放頂層並補 https', (tester) async {
      await changeCar(tester);
      expect(link, findsNothing);
      await chooseFeeMode(tester, 'car', 'free');
      expect(link, findsOneWidget);
      expect(
        tester.getTopLeft(link).dy,
        lessThan(tester.getTopLeft(find.text('你要改的內容')).dy),
      );
      await tester.ensureVisible(link);
      await tester.enterText(link, 'a.gov.tw/x。');
      await tester.pumpAndSettle();
      await chooseFeeMode(tester, 'car', 'hourly');
      await tester.enterText(feeField('amount', 'car'), '20');
      await tester.pumpAndSettle();
      expect(find.text('送出 0 項建議'), findsOneWidget);
      expect(link, findsNothing);
      await chooseFeeMode(tester, 'car', 'free');
      expect(find.text('a.gov.tw/x。'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['evidence_url'], 'https://a.gov.tw/x');
      expect((body['proposed'] as Map).containsKey('evidence_url'), isFalse);
    });

    testWidgets('格式錯誤按送出不送，顯示錯誤', (tester) async {
      await changeCar(tester);
      await chooseFeeMode(tester, 'car', 'free');
      await tester.ensureVisible(link);
      await tester.enterText(link, '松壽路公告');
      await tester.pumpAndSettle();
      expect(find.text('這看起來不是網址，請貼上公告頁的網址'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent, isEmpty);
    });

    testWidgets('F1b 確認畫面也有連結', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B2 重機專區');
      await tapKey(tester, 'fee-revert');
      await tester.enterText(link, 'https://a.gov.tw/x');
      await tester.pumpAndSettle();
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent.single['evidence_url'], 'https://a.gov.tw/x');
    });

    testWidgets('S5 有改動才顯示，連結放頂層', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-limits');
      expect(link, findsNothing);
      await tapKey(tester, 'rule-card-0');
      await tapText(tester, '現場沒有這條規定了');
      await tester.ensureVisible(link);
      await tester.enterText(link, 'example.gov.tw:8080/x');
      await tester.pumpAndSettle();
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(
        store.sent.single['evidence_url'],
        'https://example.gov.tw:8080/x',
      );
    });

    for (final (scale, column) in const [(1.0, true), (1.6, false)]) {
      testWidgets('摘要 $scale 倍${column ? '用標籤欄' : '不用標籤欄'}', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const Scaffold(
                body: ChangeSummary(
                  lines: [ChangeLine(label: '費率', from: '每小時 20 元', to: '免費')],
                ),
              ),
            ),
          ),
        );
        expect(
          find.byWidgetPredicate((w) => w is SizedBox && w.width == 64),
          column ? findsOneWidget : findsNothing,
        );
      });
    }

    test('貼沒有協定的相同網址不算修改', () {
      final d = EntryDraft.ofZone(
        const ParkingZone(
          id: 'b1',
          name: 'B1',
          evidenceUrl: 'https://a.gov.tw/x',
          access: ParkingAccess.scooterOnly,
        ),
      )..evidence = 'a.gov.tw/x';
      expect(d.changeLines(), isEmpty);
      expect(d.changed, isFalse);
      d.evidence = 'a.gov.tw/y';
      expect(d.toJson(const [])['evidence_url'], 'https://a.gov.tw/y');
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('公告連結在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _lot, width: width, scale: scale);
          await tapKey(tester, 'suggest-fee');
          await tapText(tester, '全場費率');
          await chooseFeeMode(tester, 'car', 'free');
          await tester.ensureVisible(link);
          await tester.enterText(link, 'user@example.com');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  });

  group('不適用', () {
    testWidgets('F1 收合與預覽寫不適用，不含未確認', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B1 機車區');
      await tapKey(tester, 'fee-row-car');
      expect(find.textContaining('不適用'), findsWidgets);
      expect(find.textContaining('未確認'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('fee-preview')),
          matching: find.text('不適用'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('F0、F1b 不含未確認', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      expect(find.text('汽車 不適用'), findsWidgets);
      expect(find.textContaining('未確認'), findsNothing);
      await tapText(tester, 'B2 重機專區');
      await tapKey(tester, 'fee-revert');
      expect(find.textContaining('未確認'), findsNothing);
    });

    testWidgets('比照的來源不適用時寫不適用，不是費率未提供', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B3 汽車區');
      await chooseFeeMode(tester, 'car', 'not_applicable');
      await chooseFeeMode(tester, 'heavy', 'same_as');
      expect(find.text('不適用，不能選'), findsOneWidget);
    });

    test('差異摘要寫不適用', () {
      expect(rateText(const Fee(car: _na), FeeVehicle.car), '不適用');
      expect(rateText(const Fee(), FeeVehicle.car), '未提供');
    });
  });

  group('F1d', () {
    const long = '平日每小時 30 元；假日每小時 50 元；需按鈴或請管理員協助，平日每日 60 元；假日每次 80 元';

    test('預設字不算這區寫的；有費率時也不算', () {
      ParkingZone zone(String note, [Fee? fee]) => ParkingZone(
        id: 'z',
        name: 'Z',
        feeNote: note,
        fee: fee,
        access: ParkingAccess.scooterOnly,
      );
      String? of(ParkingZone z) => zoneFeeNote(EntryDraft.ofZone(z));
      expect(of(zone('免費')), '免費');
      expect(of(zone(' 需按鈴 ')), '需按鈴');
      for (final text in ['', '請依現場公告', '請以現場公告為準']) {
        expect(of(zone(text)), isNull, reason: text);
      }
      expect(of(zone('免費', _lot.fee)), isNull);
    });

    test('entriesPatch 與 precheck 接受 fee_note: null', () {
      final stored = [
        {
          'id': 'b1',
          'name': 'B1',
          'access': 'scooterOnly',
          'fee_note': long,
          'fee_plan': 'p',
        },
      ];
      expect(
        entriesPatch(stored, [
          {'id': 'b1', 'fee': null, 'fee_note': null},
        ]),
        [
          {'id': 'b1', 'name': 'B1', 'access': 'scooterOnly'},
        ],
      );
      final rate = _lot.fee!.toJson();
      expect(
        entriesPatch(stored, [
          {'id': 'b1', 'fee': rate, 'fee_note': null},
        ]),
        [
          {'id': 'b1', 'name': 'B1', 'access': 'scooterOnly', 'fee': rate},
        ],
      );
      for (final fee in [null, rate]) {
        final body = {
          'action': 'flag',
          'source_id': 'official:lot',
          'field': 'zones',
          'reason': '費率',
          'proposed': {
            'parking_zones': [
              {'id': 'b1', 'fee': fee, 'fee_note': null},
            ],
          },
        };
        expect(
          precheckBlocking(precheck(body, current: {'parking_zones': stored})),
          isEmpty,
        );
      }
    });

    testWidgets('F0 顯示這區寫，朗讀完整，不標沿用全場', (tester) async {
      await pump(tester, _noted);
      await tapKey(tester, 'suggest-fee');
      expect(find.textContaining('這區寫：'), findsOneWidget);
      expect(find.textContaining('沿用全場：'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == '這區寫，$long',
        ),
        findsOneWidget,
      );
    });

    testWidgets('F1 顯示完整文字；改費率送 fee 與 fee_note: null', (tester) async {
      await pump(tester, _noted);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B1 機車區');
      expect(find.byKey(const ValueKey('fee-note-block')), findsOneWidget);
      expect(find.text(long), findsOneWidget);
      expect(find.text('下面填好費率送出後，這段文字會移除。'), findsOneWidget);
      expect(find.text('送出 0 項建議'), findsOneWidget);
      await chooseFeeMode(tester, 'scooter', 'free');
      await chooseFeeMode(tester, 'heavy', 'free');
      expect(find.text('送出 1 項建議'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final patch =
          (store.sent.single['proposed'] as Map)['parking_zones'] as List;
      final entry = patch.single as Map;
      expect(entry['id'], 'b1');
      expect((entry['fee'] as Map)['scooter'], {'mode': 'free'});
      expect(entry.containsKey('fee_note'), isTrue);
      expect(entry['fee_note'], isNull);
    });

    testWidgets('改回沿用全場：確認卡寫明會移除，送 fee 與 fee_note 都 null', (tester) async {
      await pump(tester, _noted);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B1 機車區');
      await tapKey(tester, 'fee-revert');
      expect(find.text('目前這區寫的'), findsOneWidget);
      expect(find.text('整段文字都會移除，包含費率以外的說明。'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect((store.sent.single['proposed'] as Map)['parking_zones'], [
        {'id': 'b1', 'fee': null, 'fee_note': null},
      ]);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('F1d 在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _noted, width: width, scale: scale);
          await tapKey(tester, 'suggest-fee');
          expect(tester.takeException(), isNull);
          await tapText(tester, 'B1 機車區');
          expect(tester.takeException(), isNull);
          await tapKey(tester, 'fee-revert');
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  });

  group('F0', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('長的沿用標籤在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _mixedInherit, width: width, scale: scale);
          await tapKey(tester, 'suggest-fee');
          expect(find.text('沿用全場：普機 20/時、重機 免費、汽車 依時段'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }
    }

    testWidgets('每區三種車都有標籤，B3 補汽車 未提供，全場卡進 F1', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      expect(find.text('怎麼算錢・松壽地下停車場'), findsOneWidget);
      expect(find.text('目前全場同價：每小時 20 元。'), findsNothing);
      expect(find.text('重機 20/時・上限 100'), findsOneWidget);
      expect(find.text('汽車 未提供'), findsOneWidget);
      await tapText(tester, '全場費率');
      expect(find.byType(FeeEditor), findsOneWidget);
    });
  });

  group('F1', () {
    testWidgets('改全場費率：只送改到的車種，按鈕是送出 N 項建議', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '全場費率');
      expect(find.text('送出 0 項建議'), findsOneWidget);
      expect(find.text('修改中'), findsNothing);
      await chooseFeeMode(tester, 'car', 'free');
      expect(find.text('送出 1 項建議'), findsOneWidget);
      expect(find.text('修改中'), findsOneWidget);
      expect(find.text('你要改的內容'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'fee_note');
      final proposed = body['proposed'] as Map;
      expect(proposed['fee'], {
        'car': {'mode': 'free'},
      });
      expect(proposed['fee_note'], isA<String>());
      expect(find.textContaining('建議沒有實際送出'), findsOneWidget);
    });

    testWidgets('改全場費率只要求改到的車種完整，沒改的不必補（#365 Codex）', (tester) async {
      await pump(tester, _partialLot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '全場費率');
      await chooseFeeMode(tester, 'scooter', 'free');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.textContaining('的收費方式'), findsNothing);
      expect(find.textContaining('還有規則沒選'), findsNothing);
      final proposed = store.sent.single['proposed'] as Map;
      expect(proposed['fee'], {
        'scooter': {'mode': 'free'},
      });
    });

    testWidgets('改到的車種規則沒選仍擋下（#365 Codex）', (tester) async {
      await pump(tester, _partialLot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '全場費率');
      await chooseFeeMode(tester, 'car', 'per_visit');
      await tester.enterText(feeField('amount', 'car'), '20');
      await tester.pumpAndSettle();
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.textContaining('汽車還有規則沒選'), findsOneWidget);
      expect(store.sent, isEmpty);
    });

    testWidgets('沒有路段的路邊點：首次 0 元依點位自己的限時判斷（#365 Codex）', (tester) async {
      await pump(tester, _timedStreet);
      await tapKey(tester, 'suggest-fee');
      if (find.text('整條路費率').evaluate().isNotEmpty) {
        await tapText(tester, '整條路費率');
      }
      await chooseFeeMode(tester, 'scooter', 'per_visit');
      await tester.enterText(feeField('amount', 'scooter'), '0');
      await tester.pumpAndSettle();
      await tapKey(tester, 'fee-renew-scooter-none');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.textContaining('計次 0 元等於免費'), findsNothing);
      final proposed = store.sent.single['proposed'] as Map;
      expect((proposed['fee'] as Map)['scooter'], containsPair('amount', 0));
    });

    testWidgets('分區費率送 {id, fee}，三種車都有', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B2 重機專區');
      expect(find.text('怎麼算錢・松壽地下停車場 B2 重機專區'), findsOneWidget);
      await chooseFeeMode(tester, 'heavy', 'free');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'zones');
      expect((body['proposed'] as Map)['parking_zones'], [
        {
          'id': 'b2',
          'fee': {
            'scooter': {'mode': 'not_applicable'},
            'heavy': {'mode': 'free'},
            'car': {'mode': 'not_applicable'},
          },
        },
      ]);
    });

    testWidgets('依時段不同：色條、灰色與琥珀說明、必選的停到下一個時段時（C7、C8）', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, 'B2 重機專區');
      await chooseFeeMode(tester, 'heavy', 'by_time');
      expect(find.byType(FeeTimeline), findsOneWidget);
      expect(find.textContaining('是大型重機非開放時段'), findsOneWidget);
      expect(find.text('請以現場公告為準'), findsOneWidget);
      await tester.enterText(feeField('amount', 'heavy-p0'), '20');
      await tester.pumpAndSettle();
      await tapKey(tester, 'fee-period-add-heavy');
      expect(find.text('停到下一個時段時'), findsNothing);
      await tapKey(tester, 'fee-mode-heavy-p1-per_visit');
      expect(find.text('停到下一個時段時'), findsOneWidget);
      await tester.enterText(feeField('amount', 'heavy-p1'), '30');
      await tester.pumpAndSettle();
      expect(find.text('跨日怎麼收'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      // Neither has a default (C8).
      expect(store.sent, isEmpty);
      expect(find.textContaining('還有規則沒選'), findsOneWidget);
      await tapKey(tester, 'fee-renew-heavy-p1-none');
      await tapKey(tester, 'fee-cross-heavy-entry_only');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent, hasLength(1));
    });

    testWidgets('未登入按送出開 P11，內容保留（C2）', (tester) async {
      store.signedIn = false;
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '全場費率');
      await chooseFeeMode(tester, 'car', 'free');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(store.sent, isEmpty);
      expect(find.byType(SignInSheet), findsOneWidget);
    });

    testWidgets('停權開共用面板，內容保留', (tester) async {
      store.refuse = const AccountSuspended(null);
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-fee');
      await tapText(tester, '全場費率');
      await chooseFeeMode(tester, 'car', 'free');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.text('帳號暫時不能送出內容'), findsOneWidget);
    });

    testWidgets('路段的費率列開 F1：不適用寫出原因，送 {id, fee}', (tester) async {
      await pump(tester, _street);
      await tapKey(tester, 'suggest-fee');
      expect(find.text('路段與格位'), findsOneWidget);
      await tapText(tester, '費率');
      expect(find.byType(FeeEditor), findsOneWidget);
      expect(find.textContaining('這段沒有汽車格'), findsOneWidget);
      await chooseFeeMode(tester, 'scooter', 'free');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'segments');
      final patch = (body['proposed'] as Map)['parking_segments'] as List;
      expect((patch.single as Map).keys, ['id', 'fee']);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('F0、F1 在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _lot, width: width, scale: scale);
          await tapKey(tester, 'suggest-fee');
          expect(tester.takeException(), isNull);
          await tapText(tester, 'B2 重機專區');
          await chooseFeeMode(tester, 'heavy', 'by_time');
          await tester.enterText(feeField('amount', 'heavy-p0'), '20');
          await tester.pumpAndSettle();
          await tapKey(tester, 'fee-period-add-heavy');
          await tapKey(tester, 'fee-mode-heavy-p1-per_visit');
          await tapKey(tester, 'fee-more-heavy-p1');
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  });

  group('S5、S5b', () {
    testWidgets('S1 限時列開 S5，改規定送分區 condition', (tester) async {
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-limits');
      expect(find.text('限時／禁停／共用時段'), findsOneWidget);
      await tapKey(tester, 'rule-card-0');
      expect(find.text('管哪幾區？　可複選'), findsOneWidget);
      await tapKey(tester, 'rule-scope-all');
      expect(find.text('送出 1 項建議'), findsOneWidget);
      await tapText(tester, '現場沒有這條規定了');
      expect(find.text('將移除'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'zones');
      final patch = (body['proposed'] as Map)['parking_zones'] as List;
      expect((patch.single as Map)['id'], 'b2');
    });

    testWidgets('S3 限時列開 S5b，新增規定選全天後送路段 condition', (tester) async {
      await pump(tester, _street);
      await tapKey(tester, 'suggest-limits');
      await tapText(tester, '新增一條規定');
      expect(find.text('管哪幾段？　可複選'), findsOneWidget);
      expect(find.text('整條路'), findsOneWidget);
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-error-time')), findsOneWidget);
      await tapKey(tester, 'rule-all-day');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      final body = store.sent.single;
      expect(body['field'], 'segments');
      final patch = (body['proposed'] as Map)['parking_segments'] as List;
      final c = (patch.single as Map)['condition'] as Map;
      expect((c['limits'] as List).single['kind'], 'time_limit');
    });

    testWidgets('只有一區時點該區不算修改，按鈕維持 0 項', (tester) async {
      await pump(tester, _oneZone);
      await tapKey(tester, 'suggest-limits');
      await tapKey(tester, 'rule-card-0');
      await tapKey(tester, 'rule-scope-0');
      expect(find.text('送出 0 項建議'), findsOneWidget);
    });

    testWidgets('S5 停權開共用面板，內容保留', (tester) async {
      store.refuse = const AccountSuspended(null);
      await pump(tester, _lot);
      await tapKey(tester, 'suggest-limits');
      await tapKey(tester, 'rule-card-0');
      await tapText(tester, '現場沒有這條規定了');
      await tester.tap(submit('送出 1 項建議'));
      await tester.pumpAndSettle();
      expect(find.text('帳號暫時不能送出內容'), findsOneWidget);
      expect(store.sent, isEmpty);
    });

    testWidgets('沒有分區的路外點：限時列停用並說明', (tester) async {
      await pump(
        tester,
        const ParkingSpot(
          id: 'official:empty',
          name: '空',
          lat: 25,
          lng: 121,
          city: '臺北市',
          spaceType: SpaceType.offStreet,
          source: 'official',
        ),
      );
      expect(find.text('先新增分區'), findsOneWidget);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('S5b 在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _ruleStreet, width: width, scale: scale);
          await tapKey(tester, 'suggest-limits');
          expect(find.text('管哪幾段？　可複選'), findsNothing);
          await tapKey(tester, 'rule-card-0');
          expect(find.text('管哪幾段？　可複選'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tapText(tester, '新增一條規定');
          await tapKey(tester, 'rule-kind');
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final (width, scale) in const [
        (320.0, 1.6),
        (390.0, 1.6),
        (700.0, 1.0),
        (1040.0, 1.0),
      ]) {
        testWidgets('S5 在 $width 寬 $scale 倍 ${platform.name} 不溢出', (
          tester,
        ) async {
          await pump(tester, _lot, width: width, scale: scale);
          await tapKey(tester, 'suggest-limits');
          await tapText(tester, '新增一條規定');
          expect(tester.takeException(), isNull);
          expect(find.byType(TimeRulesPage), findsOneWidget);
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  });
}
