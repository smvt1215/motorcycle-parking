import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

class RecordingStore extends AppStore {
  RecordingStore(LocalRepository local) : super(local, null);
  final submissions = <Map<String, dynamic>>[];

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    submissions.add(body);
    return '已送交審核';
  }
}

void main() {
  final cityRules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
          .toList();

  Future<RecordingStore> openForm(
    WidgetTester tester, {
    List<CityRule> rules = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      // A known spot nearby fills in the city.
      return RecordingStore(
          LocalRepository(await SharedPreferences.getInstance()),
        )
        ..spots = const [
          ParkingSpot(
            id: 'near',
            name: '附近',
            lat: 25.0339,
            lng: 121.5623,
            city: '臺北市',
            spaceType: SpaceType.paidMotorcycle,
          ),
        ]
        ..rules = rules;
    }))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReport(context, store, 25.0339, 121.5623),
              child: const Text('新增'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    return store;
  }

  // The form's own list: the first scrollable in the sheet.
  final form = find.byType(Scrollable).first;

  Future<void> pickType(WidgetTester tester, SpaceType type) async {
    final tile = find.byKey(ValueKey('report-space-${type.name}'));
    // Back to the top of the form, where the picker is, then onto the tile.
    await tester.fling(form, const Offset(0, 2000), 3000);
    await tester.pumpAndSettle();
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<Map<String, dynamic>> send(
    WidgetTester tester,
    RecordingStore store,
  ) async {
    // Back to the top, where the name is the first field in the list.
    await tester.fling(form, const Offset(0, 3000), 3000);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '測試點');
    await tester.pumpAndSettle();
    // The button sits below the fold of a lazily built list.
    await tester.scrollUntilVisible(find.text('送出回報'), 200, scrollable: form);
    // scrollUntilVisible stops once the button is built, maybe below the fold.
    await tester.ensureVisible(find.text('送出回報'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    return store.submissions.single['spot'] as Map<String, dynamic>;
  }

  test('格位標線帶入的資格只寫出標線能確定的部分', () {
    expect(markedEligibility(SpaceType.paidMotorcycle), (
      scooter: true,
      heavy: null,
    ));
    expect(markedEligibility(SpaceType.heavyOnly), (
      scooter: false,
      heavy: true,
    ));
    expect(markedEligibility(SpaceType.car), (scooter: false, heavy: null));
    for (final type in [
      SpaceType.offStreet,
      SpaceType.disabledMotorcycle,
      SpaceType.flexShared,
      SpaceType.evMotorcycle,
    ]) {
      expect(markedEligibility(type), (scooter: null, heavy: null));
    }
  });

  testWidgets('依地面標線選格位，並帶入可停車種', (tester) async {
    final store = await openForm(tester);
    expect(find.byType(DropdownButtonFormField<SpaceType>), findsNothing);
    expect(find.text('地面畫的是哪一種格位？'), findsOneWidget);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('report-space-paidMotorcycle')),
      ),
      matchesSemantics(
        label: '路邊收費機車格',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
    await pickType(tester, SpaceType.offStreet);
    expect(find.textContaining('已依「路外停車場」帶入'), findsOneWidget);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'offStreet');
    // A lot's markings settle neither vehicle.
    expect(spot['scooter_allowed'], isNull);
    expect(spot['heavy_allowed'], isNull);
  });

  testWidgets('收費以結構化選項填寫，送出費率與組成的文字', (tester) async {
    final store = await openForm(tester);
    final menu = find.byKey(const ValueKey('fee-mode-scooter'));
    await tester.scrollUntilVisible(menu, 200, scrollable: form);
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('每日').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '每日金額'), '30');
    final heavy = find.byKey(const ValueKey('fee-mode-heavy'));
    await tester.ensureVisible(heavy);
    await tester.tap(heavy);
    await tester.pumpAndSettle();
    await tester.tap(find.text('比照機車費率').last);
    await tester.pumpAndSettle();
    final spot = await send(tester, store);
    expect(spot['fee'], {
      'scooter': {'mode': 'daily', 'amount': 30},
      'heavy': {'mode': 'same_as_scooter'},
    });
    expect(spot['fee_note'], '每日 30 元（大型重機比照機車費率）');
  });

  testWidgets('沒有填收費時不送 fee，文字維持請依現場公告', (tester) async {
    final store = await openForm(tester);
    final spot = await send(tester, store);
    expect(spot.containsKey('fee'), isFalse);
    expect(spot['fee_note'], '請依現場公告');
  });

  test('資格先看標線，標線無法判斷時依縣市規則', () {
    // Taipei opens paid bays to heavy bikes and keeps free bays closed.
    expect(defaultEligibility(cityRules, SpaceType.paidMotorcycle, '臺北市'), (
      scooter: true,
      heavy: true,
    ));
    expect(defaultEligibility(cityRules, SpaceType.freeMotorcycle, '臺北市'), (
      scooter: true,
      heavy: false,
    ));
    // Markings win where they speak; no city means no rule.
    expect(defaultEligibility(cityRules, SpaceType.heavyOnly, '臺北市'), (
      scooter: false,
      heavy: true,
    ));
    expect(defaultEligibility(cityRules, SpaceType.paidMotorcycle, null), (
      scooter: true,
      heavy: null,
    ));
    // A lot has no rule of its own to read.
    expect(defaultEligibility(cityRules, SpaceType.offStreet, '臺北市'), (
      scooter: null,
      heavy: null,
    ));
  });

  testWidgets('資格依縣市規則帶入並說明來源', (tester) async {
    final store = await openForm(tester, rules: cityRules);
    expect(find.textContaining('與臺北市的停車規則帶入'), findsOneWidget);
    await pickType(tester, SpaceType.freeMotorcycle);
    // Shown as the rule decides, but only the markings are stored, so the
    // spot follows the rule if it changes.
    expect(
      tester
          .widget<ChoiceField<bool?>>(
            find.widgetWithText(ChoiceField<bool?>, '大型重機'),
          )
          .value,
      false,
    );
    final spot = await send(tester, store);
    expect(spot['scooter_allowed'], true);
    expect(spot['heavy_allowed'], isNull);
  });

  testWidgets('路外停車場填型式、分類、入口與分區；路邊格只有指引', (tester) async {
    final store = await openForm(tester);
    expect(find.text('入口在哪裡'), findsNothing);
    await pickType(tester, SpaceType.offStreet);
    final underground = find.descendant(
      of: find.byType(SegmentedButton<FacilityType?>),
      matching: find.text('地下'),
    );
    await tester.scrollUntilVisible(underground, 200, scrollable: form);
    await tester.ensureVisible(underground);
    await tester.pumpAndSettle();
    await tester.tap(underground);
    await tester.pumpAndSettle();
    final access = find.byType(DropdownButtonFormField<ParkingAccess?>).first;
    await tester.ensureVisible(access);
    await tester.tap(access);
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通機車與大型重機共用').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '入口在哪裡'),
      '入口在松仁路側',
    );
    final add = find.text('新增分區');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '分區名稱'),
      'B2 機車區',
    );
    final guide = find.widgetWithText(TextFormField, '停車指引');
    await tester.scrollUntilVisible(guide, 200, scrollable: form);
    await tester.ensureVisible(guide);
    await tester.enterText(guide, '靠電梯');
    final spot = await send(tester, store);
    expect(spot['facility_type'], 'underground');
    expect(spot['parking_access'], 'scooterHeavy');
    expect(spot['entrance_note'], '入口在松仁路側');
    expect(spot['parking_zones'], [
      {'name': 'B2 機車區'},
    ]);
    expect(spot['parking_guide'], '靠電梯');
    expect(spot['note'], '');
  });

  testWidgets('分區名稱必填；切回路邊格後不送路外資料', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.offStreet);
    final add = find.text('新增分區');
    await tester.scrollUntilVisible(add, 200, scrollable: form);
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '分區名稱'), findsOneWidget);
    await pickType(tester, SpaceType.paidMotorcycle);
    final spot = await send(tester, store);
    expect(spot.containsKey('parking_zones'), isFalse);
    expect(spot.containsKey('facility_type'), isFalse);
  });

  testWidgets('先改一個車種再換格位，另一個規則帶入的車種仍送未確認', (tester) async {
    final store = await openForm(tester, rules: cityRules);
    final scooterUnconfirmed = find.descendant(
      of: find.byType(SegmentedButton<bool?>).first,
      matching: find.text('未確認'),
    );
    await tester.scrollUntilVisible(scooterUnconfirmed, 200, scrollable: form);
    await tester.pumpAndSettle();
    await tester.tap(scooterUnconfirmed);
    await tester.pumpAndSettle();
    // The rule decides heavy bikes here only before the switch, so a flag
    // computed at submit time would wrongly send the shown value.
    await pickType(tester, SpaceType.evMotorcycle);
    expect(find.textContaining('大型重機依規則帶入，只當預設'), findsOneWidget);
    final spot = await send(tester, store);
    expect(spot['scooter_allowed'], isNull);
    expect(spot['heavy_allowed'], isNull);
  });

  testWidgets('手動設定車種後，換格位不再覆蓋', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.heavyOnly);
    // The heavy-bike segments, not the fee menus that also read 未確認.
    final heavyUnconfirmed = find.descendant(
      of: find.byType(SegmentedButton<bool?>).last,
      matching: find.text('未確認'),
    );
    await tester.ensureVisible(heavyUnconfirmed);
    // Heavy-only bays already read "heavy: allowed"; the reporter overrides it.
    await tester.tap(heavyUnconfirmed);
    await tester.pumpAndSettle();
    expect(find.textContaining('已依'), findsNothing);
    await pickType(tester, SpaceType.paidMotorcycle);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'paidMotorcycle');
    expect(spot['scooter_allowed'], false);
    expect(spot['heavy_allowed'], isNull);
  });
}
