import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/report/entry_drafts.dart';
import 'package:motorcycle_parking/features/report/fee_forms.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/features/report/time_rules_page.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
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

  group('F0', () {
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
