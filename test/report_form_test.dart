import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/ui/fold_section.dart';
import 'package:motorcycle_parking/ui/location_picker.dart';
import 'package:motorcycle_parking/ui/option_pill.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'fee_editor_steps.dart';

class RecordingStore extends AppStore {
  RecordingStore(LocalRepository local) : super(local, null);
  final submissions = <Map<String, dynamic>>[];

  /// What the reverse lookup answers; null means at sea.
  Town? town = const Town('臺北市', '信義區');
  final lookups = <(double, double)>[];

  /// When set, lookups wait here until a test answers them.
  List<Completer<Town?>>? held;

  @override
  Future<Town?> townAt(double lat, double lng) async {
    lookups.add((lat, lng));
    if (held case final waiting?) {
      final answer = Completer<Town?>();
      waiting.add(answer);
      return answer.future;
    }
    return town;
  }

  /// What「移到我的位置」reads.
  LocationFix fix = const LocationFix(25.0343, 121.5623, 8);

  @override
  Future<LocationFix> currentFix() async => fix;

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

  /// Whether the test picked a bay kind; [send] picks 收費機車格 otherwise.
  var picked = false;

  Future<RecordingStore> openForm(
    WidgetTester tester, {
    List<CityRule> rules = const [],
    Size size = const Size(390, 844),
    Town? town = const Town('臺北市', '信義區'),
    double scale = 1,
    Brightness brightness = Brightness.light,
    double keyboard = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
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
        ..rules = rules
        ..town = town;
    }))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
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
    picked = false;
    return store;
  }

  // The form's own list: the first scrollable in the sheet.
  final form = find.byType(Scrollable).first;
  final nameField = find.widgetWithText(TextFormField, '停車點名稱');

  bool built(Finder target) {
    // A `.first` inside the finder throws until its parent is built.
    try {
      return target.evaluate().isNotEmpty;
    } on StateError {
      return false;
    }
  }

  /// Scrolls the form until [target] is built and on screen. It moves the
  /// list itself: a drag could land on the location map, which keeps drags.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    final position = tester.state<ScrollableState>(form).position;
    if (!built(target)) {
      // From the top down, so targets above the fold are found too.
      position.jumpTo(0);
      await tester.pump();
    }
    for (var i = 0; i < 40 && !built(target); i++) {
      position.jumpTo(
        (position.pixels + 200).clamp(0, position.maxScrollExtent),
      );
      await tester.pump();
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  /// The form's folding sections, in order (C6 canvas AppForm).
  const parts = ['位置', '名稱', '格位', '停車場（選填）', '可停車種', '收費（選填）', '補充（選填）'];

  /// Opens the section titled [title] unless it is open already.
  Future<void> openPart(WidgetTester tester, String title) async {
    final header = find.byKey(ValueKey('fold-$title'));
    await scrollTo(tester, header);
    final section = tester.widget<FoldSection>(
      find.ancestor(of: header, matching: find.byType(FoldSection)),
    );
    if (section.open) return;
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  /// Scrolls to [target], opening the section that holds it first.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    for (final title in parts) {
      if (built(target)) break;
      final header = find.byKey(ValueKey('fold-$title'));
      // The list builds lazily; 停車場 shows only for lots.
      final position = tester.state<ScrollableState>(form).position;
      if (!built(header)) {
        position.jumpTo(0);
        await tester.pump();
      }
      for (var i = 0; i < 40 && !built(header); i++) {
        position.jumpTo(
          (position.pixels + 200).clamp(0, position.maxScrollExtent),
        );
        await tester.pump();
      }
      if (!built(header)) continue;
      await openPart(tester, title);
    }
    await scrollTo(tester, target);
  }

  Future<void> pickKind(WidgetTester tester, SpaceKind kind) async {
    picked = true;
    await openPart(tester, '格位');
    final tile = find.byKey(ValueKey('report-space-${kind.name}'));
    await scrollTo(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  /// Picks the kind [type] reads as and what makes it [type]: 收費 or 免費
  /// for a 一般機車格, a time limit for a 限時 one (#188).
  Future<void> pickType(WidgetTester tester, SpaceType type) async {
    await pickKind(tester, SpaceKind.of(type, null));
    final follow = switch (type) {
      SpaceType.paidMotorcycle => 'condition-charge-toll',
      SpaceType.freeMotorcycle => 'condition-charge-free',
      SpaceType.timedMotorcycle => 'condition-limit-time_limit',
      _ => null,
    };
    if (follow == null) return;
    final target = find.byKey(ValueKey(follow));
    await scrollTo(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// Both vehicles are required (#201): picks 可停 for any the form has
  /// not filled in, leaving prefilled ones as they are.
  Future<void> fillUnpicked(WidgetTester tester) async {
    for (final (label, prefix) in [
      ('普通機車', 'report-scooter'),
      ('大型重機', 'report-heavy'),
    ]) {
      final choice = find.byWidgetPredicate(
        (w) => w is EligibilityChoice && w.label == label,
        skipOffstage: false,
      );
      if (choice.evaluate().isNotEmpty &&
          tester.widget<EligibilityChoice>(choice).value != null) {
        continue;
      }
      await openPart(tester, '可停車種');
      final target = find.byKey(ValueKey('$prefix-allowed'));
      await scrollTo(tester, target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }
  }

  Future<Map<String, dynamic>> send(
    WidgetTester tester,
    RecordingStore store, {
    bool fillVehicles = true,
  }) async {
    if (!picked) await pickType(tester, SpaceType.paidMotorcycle);
    if (fillVehicles) await fillUnpicked(tester);
    final name = find.widgetWithText(TextFormField, '停車點名稱');
    await reveal(tester, name);
    await tester.enterText(name, '測試點');
    await tester.pumpAndSettle();
    // The button sits below the fold of a lazily built list.
    await scrollTo(tester, find.text('送出'));
    await tester.tap(find.text('送出'));
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
    // Nothing is picked until the rider picks (C6 canvas AppFormLocation).
    await scrollTo(tester, find.byKey(const ValueKey('fold-格位')));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fold-格位')),
        matching: find.text('還沒填'),
      ),
      findsOneWidget,
    );
    await pickType(tester, SpaceType.paidMotorcycle);
    expect(find.text('地面畫的是哪一種？'), findsOneWidget);
    await scrollTo(
      tester,
      find.byKey(const ValueKey('report-space-motorcycle')),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('report-space-motorcycle')),
      ),
      matchesSemantics(
        label: '一般機車格',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
    await pickType(tester, SpaceType.offStreet);
    await openPart(tester, '可停車種');
    expect(find.textContaining('已依「停車場」帶入'), findsOneWidget);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'offStreet');
    // A lot's markings settle neither vehicle: the rider picks both.
    expect(spot['scooter_allowed'], true);
    expect(spot['heavy_allowed'], true);
  });

  testWidgets('收費以結構化選項填寫，三個車種都選，送出費率與組成的文字', (tester) async {
    final store = await openForm(tester);
    // The rider's vehicle (普通機車) opens first.
    final visit = find.byKey(const ValueKey('fee-mode-scooter-per_visit'));
    await reveal(tester, visit);
    await tapFee(tester, 'fee-mode-scooter-per_visit');
    await tester.enterText(feeField('amount', 'scooter'), '30');
    await tapFee(tester, 'fee-renew-scooter-midnight');
    await chooseFeeMode(tester, 'heavy', 'same_as');
    await chooseFeeMode(tester, 'car', 'not_applicable');
    final spot = await send(tester, store);
    expect(spot['fee'], {
      'scooter': {'mode': 'per_visit', 'amount': 30, 'renew': 'midnight'},
      'heavy': {'mode': 'same_as_scooter'},
      'car': {'mode': 'not_applicable'},
    });
    expect(spot['fee_note'], '機車每次 30 元，隔日另計；大型重機每次 30 元，隔日另計');
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
    await pickType(tester, SpaceType.paidMotorcycle);
    await reveal(tester, find.textContaining('與臺北市的停車規則帶入'));
    expect(find.textContaining('與臺北市的停車規則帶入'), findsOneWidget);
    await pickType(tester, SpaceType.freeMotorcycle);
    // The rule's value is a suggestion the rider confirms; both vehicles
    // are sent as shown (#201).
    await openPart(tester, '可停車種');
    expect(
      tester
          .widget<EligibilityChoice>(
            find.widgetWithText(EligibilityChoice, '大型重機'),
          )
          .value,
      Eligible.notAllowed,
    );
    expect(find.textContaining('大型重機是依臺北市規則算出的建議值'), findsOneWidget);
    // A street bay is 可停 or 不可停 only.
    expect(find.byKey(const ValueKey('report-heavy-notStated')), findsNothing);
    final spot = await send(tester, store);
    expect(spot['scooter_allowed'], true);
    expect(spot['heavy_allowed'], false);
    expect(spot.containsKey('heavy_not_stated'), isFalse);
  });

  testWidgets('路外停車場填型式、分類、入口與分區；路邊格只有指引', (tester) async {
    final store = await openForm(tester);
    expect(find.text('入口在哪裡'), findsNothing);
    await pickType(tester, SpaceType.offStreet);
    // A lot built two ways (decision 58): both ticked.
    for (final type in ['surface', 'underground']) {
      final row = find.byKey(ValueKey('facility-$type'));
      await reveal(tester, row);
      await tester.tap(row);
      await tester.pumpAndSettle();
    }
    final access = find.descendant(
      of: find.byType(ChoiceField<ParkingAccess?>).first,
      matching: find.text('普通機車與大型重機共用'),
    );
    await tester.ensureVisible(access);
    await tester.tap(access);
    await tester.pumpAndSettle();
    final add = find.text('新增分區');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '分區名稱'),
      'B2 機車區',
    );
    // Every zone a rider adds states who may park there (#201).
    final zoneNotStated = find.descendant(
      of: find.byType(ZoneAccessField),
      matching: find.text('官方未標示'),
    );
    await tester.ensureVisible(zoneNotStated);
    await tester.tap(zoneNotStated);
    await tester.pumpAndSettle();
    final entrance = find.widgetWithText(TextFormField, '入口在哪裡');
    await reveal(tester, entrance);
    await tester.enterText(entrance, '入口在松仁路側');
    final guide = find.widgetWithText(TextFormField, '停車指引');
    await reveal(tester, guide);
    await tester.ensureVisible(guide);
    await tester.enterText(guide, '靠電梯');
    final spot = await send(tester, store);
    // Stored in the contract's order; the first is the one old builds read.
    expect(spot['facility_type'], 'underground');
    expect(spot['facility_types'], ['underground', 'surface']);
    expect(spot['parking_access'], 'scooterHeavy');
    expect(spot['entrance_note'], '入口在松仁路側');
    expect(spot['parking_zones'], [
      {
        'name': 'B2 機車區',
        'condition': {
          'allow': {'scooter': 'not_stated', 'heavy': 'not_stated'},
        },
      },
    ]);
    expect(spot['parking_guide'], '靠電梯');
    expect(spot['note'], '');
  });

  testWidgets('分區名稱必填；切回路邊格後不送路外資料', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.offStreet);
    final add = find.text('新增分區');
    await reveal(tester, add);
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

  testWidgets('停車場可選官方未標示；改回路邊格時要重選（#201）', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.offStreet);
    await openPart(tester, '可停車種');
    expect(find.textContaining('選「官方未標示」'), findsOneWidget);
    final heavy = find.byKey(const ValueKey('report-heavy-notStated'));
    await scrollTo(tester, heavy);
    await tester.tap(heavy);
    await tester.pumpAndSettle();
    await pickType(tester, SpaceType.paidMotorcycle);
    await openPart(tester, '可停車種');
    expect(
      tester
          .widget<EligibilityChoice>(
            find.widgetWithText(EligibilityChoice, '大型重機'),
          )
          .value,
      isNull,
    );
    await pickType(tester, SpaceType.offStreet);
    await openPart(tester, '可停車種');
    await scrollTo(tester, heavy);
    await tester.tap(heavy);
    await tester.pumpAndSettle();
    final spot = await send(tester, store);
    expect(spot['heavy_allowed'], isNull);
    expect(spot['heavy_not_stated'], true);
    expect(spot['scooter_allowed'], true);
  });

  testWidgets('沒選車種不能送出（#201）', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.offStreet);
    final name = find.widgetWithText(TextFormField, '停車點名稱');
    await reveal(tester, name);
    await tester.enterText(name, '測試點');
    await scrollTo(tester, find.text('送出'));
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(store.submissions, isEmpty);
    expect(find.text('請選擇普通機車能不能停'), findsOneWidget);
    expect(find.text('請選擇大型重機能不能停'), findsOneWidget);
  });

  testWidgets('手動設定車種後，換格位不再覆蓋', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.heavyOnly);
    final heavyClosed = find.byKey(const ValueKey('report-heavy-notAllowed'));
    await reveal(tester, heavyClosed);
    // Heavy-only bays already read "heavy: allowed"; the reporter overrides it.
    await tester.tap(heavyClosed);
    await tester.pumpAndSettle();
    expect(find.textContaining('已依'), findsNothing);
    await pickType(tester, SpaceType.paidMotorcycle);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'paidMotorcycle');
    expect(spot['scooter_allowed'], false);
    expect(spot['heavy_allowed'], false);
  });

  testWidgets('依標記位置帶入縣市與行政區，並提醒 15 m 內同類型的點', (tester) async {
    final store = await openForm(tester);
    expect(store.lookups, [(25.0339, 121.5623)]);
    // Filled in from the lookup; the district lists only the city's.
    expect(find.text('信義區'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fold-位置')),
        matching: find.text('臺北市・信義區・25.0339, 121.5623'),
      ),
      findsNothing,
    );
    // The known spot sits at the same place with the same bay kind.
    await pickType(tester, SpaceType.paidMotorcycle);
    await openPart(tester, '位置');
    expect(find.byKey(const ValueKey('report-duplicate')), findsOneWidget);
    await pickType(tester, SpaceType.heavyOnly);
    await openPart(tester, '位置');
    expect(find.byKey(const ValueKey('report-duplicate')), findsNothing);
    final spot = await send(tester, store);
    expect(spot['city'], '臺北市');
    expect(spot['district'], '信義區');
    expect(spot['lat'], 25.0339);
  });

  testWidgets('移到另一個縣市時提醒規則改變，並依新縣市帶入車種', (tester) async {
    final store = await openForm(
      tester,
      rules: cityRules,
      town: const Town('新北市', '板橋區'),
    );
    expect(find.byKey(const ValueKey('report-city-changed')), findsOneWidget);
    expect(find.textContaining('適用新北市的停車規則'), findsOneWidget);
    final spot = await send(tester, store);
    expect(spot['city'], '新北市');
    expect(spot['district'], '板橋區');
  });

  testWidgets('查不到縣市時保留附近帶入的縣市並請騎士確認', (tester) async {
    final store = await openForm(tester, town: null);
    expect(find.textContaining('查不到縣市'), findsOneWidget);
    final spot = await send(tester, store);
    expect(spot['city'], '臺北市');
    expect(spot.containsKey('district'), isFalse);
  });

  testWidgets('移到我的位置送出 GPS 座標，誤差大時提醒', (tester) async {
    final store = await openForm(tester);
    store.fix = const LocationFix(25.0343, 121.5623, 32);
    await tester.tap(find.text('移到我的位置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GPS 誤差約 32 m'), findsOneWidget);
    // The marker moved, so the county is asked again.
    expect(store.lookups.last, (25.0343, 121.5623));
    final spot = await send(tester, store);
    expect(spot['lat'], 25.0343);
    expect(spot['lng'], 121.5623);
  });

  testWidgets('拖曳標記移動位置，地圖上的拖曳不捲動表單', (tester) async {
    final store = await openForm(tester);
    final list = tester.state<ScrollableState>(form).position;
    final pin = find.byKey(const ValueKey('touch-marker'));
    final before = list.pixels;
    final gesture = await tester.startGesture(tester.getCenter(pin));
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(list.pixels, before);
    final spot = await send(tester, store);
    // North-east of the start, by the lift and the drag.
    expect(spot['lat'] as double, greaterThan(25.0339));
    expect(spot['lng'] as double, greaterThan(121.5623));
  });

  for (final (width, height, scale, brightness, keyboard) in [
    (320.0, 568.0, 1.0, Brightness.light, 0.0),
    (320.0, 640.0, 1.6, Brightness.dark, 260.0),
    (390.0, 844.0, 1.6, Brightness.dark, 300.0),
    (700.0, 900.0, 1.0, Brightness.light, 0.0),
  ]) {
    testWidgets(
      '位置區塊在 ${width.toInt()} px、字級 $scale、鍵盤 ${keyboard.toInt()} 不溢出',
      (tester) async {
        await openForm(
          tester,
          size: Size(width, height),
          scale: scale,
          brightness: brightness,
          keyboard: keyboard,
        );
        expect(tester.takeException(), isNull);
        await reveal(tester, find.text('移到我的位置'));
        final locate = tester.getSize(
          find.byKey(const ValueKey('location-locate')),
        );
        expect(locate.height, greaterThanOrEqualTo(48));
        expect(find.text('移到我的位置').hitTestable(), findsOneWidget);
        expect(find.byKey(const ValueKey('touch-marker')), findsOneWidget);
        await scrollTo(tester, find.text('送出'));
        expect(find.text('送出').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<void> tapSegment(WidgetTester tester, int row, String label) async {
    // The list builds lazily; come back from wherever the last step left it.
    final segment = find.descendant(
      of: find.widgetWithText(EligibilityChoice, row == 0 ? '普通機車' : '大型重機'),
      matching: find.text(label),
    );
    await reveal(tester, segment);
    await tester.tap(segment);
    await tester.pumpAndSettle();
  }

  Future<void> trySend(WidgetTester tester) async {
    await scrollTo(tester, find.text('送出'));
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
  }

  for (final (width, scale, brightness) in [
    (390.0, 1.0, Brightness.light),
    (320.0, 1.6, Brightness.dark),
  ]) {
    testWidgets('重機專用格選普通機車可停時，在普通機車下方說明怎麼改（$width px、$scale 倍）', (
      tester,
    ) async {
      final store = await openForm(
        tester,
        size: Size(width, 844),
        scale: scale,
        brightness: brightness,
      );
      await pickType(tester, SpaceType.heavyOnly);
      final hint = find.byKey(const ValueKey('precheck-scooter_allowed'));
      expect(find.textContaining('大型重機專用格不能停普通機車'), findsNothing);
      await tapSegment(tester, 0, '可停');
      expect(
        find.descendant(
          of: hint,
          matching: find.textContaining('大型重機專用格不能停普通機車'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.error_outline), findsWidgets);
      // The sentence wraps inside the sheet instead of overflowing.
      expect(tester.takeException(), isNull);
      expect(tester.getRect(hint).right, lessThanOrEqualTo(width));
      await reveal(tester, nameField);
      await tester.enterText(nameField, '重機格');
      await trySend(tester);
      expect(store.submissions, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget);
      // Let the message go so it no longer covers the choices.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tapSegment(tester, 0, '不可停');
      expect(find.textContaining('大型重機專用格不能停普通機車'), findsNothing);
      await trySend(tester);
      expect(store.submissions.single['spot']['scooter_allowed'], false);
    });
  }

  testWidgets('名稱是占位詞、備註含電話時在欄位下方提示，不送出', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.paidMotorcycle);
    await reveal(tester, nameField);
    await tester.enterText(nameField, '測試');
    await tester.pumpAndSettle();
    expect(find.textContaining('「測試」看不出是哪個停車點'), findsOneWidget);
    final note = find.widgetWithText(TextFormField, '其他備註');
    await reveal(tester, note);
    await tester.enterText(note, '車主電話 0912-345-678');
    await tester.pumpAndSettle();
    expect(find.textContaining('內容含有電話號碼'), findsOneWidget);
    await trySend(tester);
    expect(store.submissions, isEmpty);
    await reveal(tester, note);
    await tester.enterText(note, '夜間有管理員');
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路機車格');
    await fillUnpicked(tester);
    await trySend(tester);
    expect(store.submissions.single['spot']['note'], '夜間有管理員');
  });

  testWidgets('計時金額填 0 元時在收費下方提示改選免費', (tester) async {
    final store = await openForm(tester);
    final mode = find.byKey(const ValueKey('fee-mode-scooter-hourly'));
    await reveal(tester, mode);
    await tapFee(tester, 'fee-mode-scooter-hourly');
    final amount = feeField('amount', 'scooter');
    await tester.ensureVisible(amount);
    await tester.enterText(amount, '0');
    await tester.pumpAndSettle();
    expect(find.textContaining('普通機車計時 0 元等於免費'), findsOneWidget);
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路機車格');
    await trySend(tester);
    expect(store.submissions, isEmpty);
  });

  testWidgets('標記移動後，前一個位置晚到的反查結果不會套用', (tester) async {
    final store = await openForm(tester);
    store.held = [];
    store.fix = const LocationFix(25.0343, 121.5623, 8);
    // Move once so a lookup for the first new position is in flight.
    await tester.tap(find.text('移到我的位置'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.held, hasLength(1));
    // Move again; the first answer arrives before the next lookup starts.
    store.fix = const LocationFix(25.0347, 121.5623, 8);
    await tester.tap(find.text('移到我的位置'));
    await tester.pump();
    store.held!.single.complete(const Town('新北市', '板橋區'));
    await tester.pump();
    expect(find.byKey(const ValueKey('report-city-changed')), findsNothing);
    expect(find.text('板橋區'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    store.held!.last.complete(const Town('臺北市', '大安區'));
    await tester.pumpAndSettle();
    expect(find.text('大安區'), findsOneWidget);
    store.held = null;
    final spot = await send(tester, store);
    expect(spot['lat'], 25.0347);
    expect(spot['city'], '臺北市');
    expect(spot['district'], '大安區');
  });

  Future<void> tapIn(WidgetTester tester, String key, String label) async {
    final target = find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.text(label),
    );
    await reveal(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('臺北限時格：收費、限停 20 分鐘可延長 1 次、計次 0 元不被預檢攔下，條件一起送出', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.timedMotorcycle);
    await tapIn(tester, 'condition-charge', '收費格');
    final minutes = find.byKey(const ValueKey('condition-max-minutes'));
    await reveal(tester, minutes);
    await tester.enterText(minutes, '20');
    await tester.enterText(
      find.byKey(const ValueKey('condition-extensions')),
      '1',
    );
    await tester.pumpAndSettle();
    await openPart(tester, '收費（選填）');
    for (final v in ['scooter', 'heavy']) {
      await chooseFeeMode(tester, v, 'per_visit');
      await tester.enterText(feeField('amount', v), '0');
      await tester.pumpAndSettle();
      await tapFee(tester, 'fee-renew-$v-none');
    }
    await chooseFeeMode(tester, 'car', 'not_applicable');
    expect(find.byIcon(Icons.error_outline), findsNothing);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'timedMotorcycle');
    expect(spot['condition'], {
      'bay': 'motorcycle',
      'use': 'usual',
      'charge': 'toll',
      'limits': [
        {
          'kind': 'time_limit',
          'periods': [
            {'days': 'all', 'max_minutes': 20, 'extensions': 1},
          ],
        },
      ],
    });
    expect((spot['fee'] as Map)['heavy'], {
      'mode': 'per_visit',
      'amount': 0,
      'renew': 'none',
    });
  });

  testWidgets('限時格要填最多停幾分鐘才能送出（#188 第 2 層）', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.timedMotorcycle);
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路限時格');
    await trySend(tester);
    expect(store.submissions, isEmpty);
    expect(find.text('填 1 到 1440'), findsOneWidget);
  });

  testWidgets('收費格選免費時說明改用首段 0 元，不能送出', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.paidMotorcycle);
    await reveal(tester, find.byKey(const ValueKey('fee-mode-scooter-free')));
    await openPart(tester, '收費（選填）');
    await chooseFeeMode(tester, 'scooter', 'free');
    expect(find.textContaining('這是收費格，普通機車的費率不能是「免費」'), findsOneWidget);
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路機車格');
    await trySend(tester);
    expect(store.submissions, isEmpty);
  });

  testWidgets('普大共用的免費格提示附公告連結，仍可送出並帶上連結', (tester) async {
    final store = await openForm(tester);
    await pickKind(tester, SpaceKind.scooterHeavy);
    await tapIn(tester, 'condition-charge', '免費格');
    expect(find.byKey(const ValueKey('condition-hold')), findsOneWidget);
    expect(find.textContaining('普大共用的免費格較少見'), findsOneWidget);
    final link = find.byKey(const ValueKey('evidence-url'));
    await reveal(tester, link);
    await tester.enterText(link, 'https://pma.gov.taipei/notice');
    await tester.pumpAndSettle();
    // Attached: nothing more to ask.
    expect(find.byKey(const ValueKey('condition-hold')), findsNothing);
    final spot = await send(tester, store);
    expect(spot['condition'], {
      'bay': 'motorcycle',
      'use': 'share',
      'share': 'scooter_heavy',
      'charge': 'free',
    });
    expect(
      store.submissions.single['evidence_url'],
      'https://pma.gov.taipei/notice',
    );
  });

  testWidgets('分區可停的車種不能選「不適用」（PM_ANS_20261101_55）', (tester) async {
    await openForm(tester);
    await pickType(tester, SpaceType.offStreet);
    await reveal(tester, find.text('新增分區'));
    await tester.tap(find.text('新增分區'));
    await tester.pumpAndSettle();
    final zoneName = find.widgetWithText(TextFormField, '分區名稱');
    await reveal(tester, zoneName);
    await tester.enterText(zoneName, 'B2 汽車區');
    // Zone areas are gone (#188 layer 2).
    expect(find.byKey(const ValueKey('zone-area')), findsNothing);
    final zoneAccess = find.descendant(
      of: find.byType(ZoneAccessField),
      matching: find.text('大型重機與汽車共用'),
    );
    await reveal(tester, zoneAccess);
    await tester.tap(zoneAccess);
    await tester.pumpAndSettle();
    await chooseFeeMode(tester, 'heavy', 'not_applicable');
    await tester.pumpAndSettle();
    expect(find.textContaining('大型重機在這裡可以停，收費方式不能選「不適用」'), findsOneWidget);
  });

  for (final (width, scale, brightness) in [
    (320.0, 1.6, Brightness.dark),
    (390.0, 1.0, Brightness.light),
    (700.0, 1.0, Brightness.light),
    (1280.0, 1.0, Brightness.dark),
  ]) {
    testWidgets('汽機共用時段在 ${width.toInt()} px、$scale 倍不溢出，觸控 ≥ 48', (
      tester,
    ) async {
      final store = await openForm(
        tester,
        size: Size(width, 900),
        scale: scale,
        brightness: brightness,
      );
      await pickType(tester, SpaceType.flexShared);
      await tapIn(tester, 'condition-charge', '收費格');
      await tapFee(tester, 'condition-slot-add');
      await tapFee(tester, 'condition-slot-0-days-weekday');
      await tapFee(tester, 'condition-slot-0-all-day-false');
      await tapFee(tester, 'condition-slot-0-vehicle-car');
      await tapFee(tester, 'condition-slot-0-vehicle-scooter');
      expect(tester.takeException(), isNull);
      for (final key in [
        'condition-slot-add',
        'condition-slot-0-remove',
        'condition-slot-0-days-weekday',
        'condition-slot-0-vehicle-car',
      ]) {
        final box = tester.getSize(find.byKey(ValueKey(key)));
        expect(box.height, greaterThanOrEqualTo(48), reason: key);
      }
      final spot = await send(tester, store);
      expect(spot['space_type'], 'flexShared');
      expect(spot['condition'], {
        'bay': 'car',
        'use': 'share',
        'share': 'car_motorcycle',
        'charge': 'toll',
        'schedule': [
          {
            'days': 'weekday',
            'from': '07:00',
            'to': '20:00',
            'vehicles': ['scooter', 'car'],
          },
        ],
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('分段收合：一次只展開一段，收起時寫目前填了什麼或還沒填', (tester) async {
    final store = await openForm(tester, rules: cityRules);
    Finder summaryOf(String title, String text) => find.descendant(
      of: find.byKey(ValueKey('fold-$title')),
      matching: find.text(text),
    );
    await openPart(tester, '名稱');
    // The position folded to its county, district and coordinates.
    await scrollTo(tester, find.byKey(const ValueKey('fold-位置')));
    expect(summaryOf('位置', '臺北市・信義區・25.0339, 121.5623'), findsOneWidget);
    expect(find.byKey(const ValueKey('touch-marker')), findsNothing);
    await tester.enterText(nameField, '市府路機車格');
    await tester.pumpAndSettle();
    await pickType(tester, SpaceType.paidMotorcycle);
    await scrollTo(tester, find.byKey(const ValueKey('fold-名稱')));
    expect(summaryOf('名稱', '市府路機車格'), findsOneWidget);
    expect(nameField, findsNothing);
    await scrollTo(tester, find.byKey(const ValueKey('fold-可停車種')));
    expect(summaryOf('可停車種', '普通機車可停・大型重機可停（已依格位與臺北市規則帶入）'), findsOneWidget);
    await scrollTo(tester, find.byKey(const ValueKey('fold-收費（選填）')));
    expect(summaryOf('收費（選填）', '還沒填'), findsOneWidget);
    expect(store.submissions, isEmpty);
  });

  testWidgets('送出時沒填的段落自動展開並標示要修正', (tester) async {
    final store = await openForm(tester);
    await trySend(tester);
    expect(store.submissions, isEmpty);
    // The name comes first among what is missing; the kind is flagged too.
    expect(find.text('請填寫名稱'), findsOneWidget);
    await scrollTo(tester, find.byKey(const ValueKey('fold-格位')));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fold-格位')),
        matching: find.text('有欄位要修正'),
      ),
      findsOneWidget,
    );
    await tester.enterText(nameField, '市府路機車格');
    await openPart(tester, '格位');
    expect(find.text('請選地面畫的格位'), findsOneWidget);
    await pickType(tester, SpaceType.freeMotorcycle);
    await fillUnpicked(tester);
    await trySend(tester);
    expect(store.submissions.single['spot']['space_type'], 'freeMotorcycle');
  });

  testWidgets('格位選後追問：限制可複選，App 會顯示預覽，送出的格位類型與條件一致', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.paidMotorcycle);
    await tapFee(tester, 'condition-limit-time_limit');
    final minutes = find.byKey(const ValueKey('condition-max-minutes'));
    await tester.enterText(minutes, '20');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('report-preview')),
        matching: find.textContaining('有條件・限停 20 分鐘，不能延長'),
      ),
      findsOneWidget,
    );
    // 電動 only is its own kind now (充電格, #188): not offered here.
    expect(find.byKey(const ValueKey('condition-limit-ev_only')), findsNothing);
    final spot = await send(tester, store);
    // The legacy type the condition converts to (§1.3), as validate.ts
    // checks.
    expect(spot['space_type'], 'timedMotorcycle');
    expect(spot['condition'], {
      'bay': 'motorcycle',
      'use': 'usual',
      'charge': 'toll',
      // A time limit is sent with its period (#188 layer 2).
      'limits': [
        {
          'kind': 'time_limit',
          'periods': [
            {'days': 'all', 'max_minutes': 20, 'extensions': 0},
          ],
        },
      ],
    });
  });

  testWidgets('普大共用機車格要選收費或免費才能送出', (tester) async {
    final store = await openForm(tester);
    await pickKind(tester, SpaceKind.scooterHeavy);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('condition-charge')),
        matching: find.text('未確認'),
      ),
      findsNothing,
    );
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路共用格');
    await trySend(tester);
    expect(store.submissions, isEmpty);
    expect(find.text('請選收費格或免費格'), findsOneWidget);
    await tapIn(tester, 'condition-charge', '收費格');
    await trySend(tester);
    final spot = store.submissions.single['spot'] as Map;
    expect(spot['space_type'], 'paidMotorcycle');
    expect(spot['condition'], {
      'bay': 'motorcycle',
      'use': 'share',
      'share': 'scooter_heavy',
      'charge': 'toll',
    });
    // Decision 60: 普大共用 brings heavy bikes in, 可停 by default.
    expect(spot['heavy_allowed'], true);
  });

  testWidgets('普大共用預設大型重機可停，騎士可改（決定 60）', (tester) async {
    final store = await openForm(tester);
    await pickKind(tester, SpaceKind.scooterHeavy);
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路共用格');
    await tapIn(tester, 'condition-charge', '收費格');
    await openPart(tester, '可停車種');
    expect(
      tester
          .widget<EligibilityChoice>(
            find.widgetWithText(EligibilityChoice, '大型重機'),
          )
          .value,
      Eligible.allowed,
    );
    final closed = find.byKey(const ValueKey('report-heavy-notAllowed'));
    await reveal(tester, closed);
    await tester.tap(closed);
    await tester.pumpAndSettle();
    await fillUnpicked(tester);
    await trySend(tester);
    final spot = store.submissions.single['spot'] as Map;
    expect(spot['heavy_allowed'], false);
  });

  testWidgets('位置段：區只列所選縣市的行政區，換縣市清掉區', (tester) async {
    final store = await openForm(tester);
    final district = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          '${w.key}'.contains('report-district'),
    );
    await scrollTo(tester, district);
    await tester.tap(district);
    await tester.pumpAndSettle();
    // Taipei's twelve districts, not New Taipei's.
    expect(find.text('大安區').last, findsOneWidget);
    expect(find.text('板橋區'), findsNothing);
    await tester.tap(find.text('大安區').last);
    await tester.pumpAndSettle();
    final city = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          '${w.key}'.contains('report-city'),
    );
    await tester.tap(city);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新北市').last);
    await tester.pumpAndSettle();
    expect(find.text('大安區'), findsNothing);
    await tester.tap(district);
    await tester.pumpAndSettle();
    expect(find.text('板橋區').last, findsOneWidget);
    await tester.tap(find.text('板橋區').last);
    await tester.pumpAndSettle();
    final spot = await send(tester, store);
    expect(spot['city'], '新北市');
    expect(spot['district'], '板橋區');
  });

  testWidgets('放大地圖調整：在大地圖移動標記，完成後帶回表單', (tester) async {
    final store = await openForm(tester);
    await scrollTo(tester, find.byKey(const ValueKey('location-expand')));
    await tester.tap(find.byKey(const ValueKey('location-expand')));
    await tester.pumpAndSettle();
    expect(find.text('調整位置'), findsOneWidget);
    // The full-screen map sits over the form's.
    final pin = find.byKey(const ValueKey('touch-marker')).last;
    expect(
      tester.getSize(find.byType(LocationPicker).last).height,
      greaterThan(500),
    );
    final gesture = await tester.startGesture(tester.getCenter(pin));
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('location-map-done')));
    await tester.pumpAndSettle();
    expect(find.text('調整位置'), findsNothing);
    final spot = await send(tester, store);
    expect(spot['lat'] as double, greaterThan(25.0339));
    expect(spot['lng'] as double, greaterThan(121.5623));
  });

  for (final size in const [
    Size(320, 640),
    Size(390, 844),
    Size(402, 874),
    Size(820, 1180),
    Size(1180, 820),
    Size(1024, 1366),
    Size(1440, 960),
  ]) {
    testWidgets(
      '分段表單在 ${size.width.toInt()}×${size.height.toInt()} 不溢出、觸控 ≥ 48',
      (tester) async {
        await openForm(tester, size: size, rules: cityRules);
        await pickType(tester, SpaceType.timedMotorcycle);
        for (final key in [
          'report-space-motorcycle',
          'report-space-offStreet',
          'condition-limit-time_limit',
          'condition-charge-toll',
        ]) {
          final box = tester.getSize(find.byKey(ValueKey(key)));
          expect(box.height, greaterThanOrEqualTo(48), reason: key);
        }
        await openPart(tester, '可停車種');
        final segment = tester.getSize(
          find.byKey(const ValueKey('report-heavy-allowed')),
        );
        expect(segment.height, greaterThanOrEqualTo(48));
        for (final title in parts) {
          if (title == '停車場（選填）') continue;
          await openPart(tester, title);
          expect(tester.takeException(), isNull, reason: title);
          final header = tester.getSize(find.byKey(ValueKey('fold-$title')));
          expect(header.height, greaterThanOrEqualTo(48), reason: title);
        }
      },
    );
  }

  testWidgets('收起格位段落後送出，追問的檢查仍會擋下並重新展開', (tester) async {
    final store = await openForm(tester);
    await pickKind(tester, SpaceKind.scooterHeavy);
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路共用格');
    // The rider folds the section without picking 收費 or 免費.
    await openPart(tester, '格位');
    await tester.tap(find.byKey(const ValueKey('fold-格位')));
    await tester.pumpAndSettle();
    await trySend(tester);
    expect(store.submissions, isEmpty);
    // The section holding the pick opened again with the error under it.
    expect(find.text('請選收費格或免費格'), findsOneWidget);
    expect(find.byKey(const ValueKey('condition-charge')), findsOneWidget);
    // A time limit out of range is checked the same way.
    await pickType(tester, SpaceType.timedMotorcycle);
    await tester.enterText(
      find.byKey(const ValueKey('condition-max-minutes')),
      '0',
    );
    await tester.pumpAndSettle();
    await trySend(tester);
    expect(store.submissions, isEmpty);
    expect(find.text('填 1 到 1440'), findsOneWidget);
  });

  testWidgets('矮螢幕（390×700）沒捲到的段落也會檢查：名稱空白送不出', (tester) async {
    final store = await openForm(tester, size: const Size(390, 700));
    await pickType(tester, SpaceType.paidMotorcycle);
    await trySend(tester);
    expect(store.submissions, isEmpty);
    expect(find.text('請填寫名稱'), findsOneWidget);
    // Fixed: the flag on its folded header goes away.
    await tester.enterText(nameField, '市府路機車格');
    await tester.pumpAndSettle();
    await openPart(tester, '格位');
    await scrollTo(tester, find.byKey(const ValueKey('fold-名稱')));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fold-名稱')),
        matching: find.text('有欄位要修正'),
      ),
      findsNothing,
    );
  });

  testWidgets('預檢擋下時展開問題所在的段落並標示要修正', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.heavyOnly);
    await openPart(tester, '可停車種');
    final scooter = find.byKey(const ValueKey('report-scooter-allowed'));
    await scrollTo(tester, scooter);
    await tester.tap(scooter);
    await tester.pumpAndSettle();
    await reveal(tester, nameField);
    await tester.enterText(nameField, '重機格');
    await tester.pumpAndSettle();
    await trySend(tester);
    expect(store.submissions, isEmpty);
    // 可停車種 opened again, its hint in view.
    expect(
      find.byKey(const ValueKey('report-scooter-allowed')),
      findsOneWidget,
    );
    expect(find.textContaining('大型重機專用格不能停普通機車'), findsWidgets);
  });
}
