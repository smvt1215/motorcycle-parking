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
    return store;
  }

  // The form's own list: the first scrollable in the sheet.
  final form = find.byType(Scrollable).first;
  final nameField = find.widgetWithText(TextFormField, '停車點名稱');

  /// Scrolls the form until [target] is built and on screen. It moves the
  /// list itself: a drag could land on the location map, which keeps drags.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    final position = tester.state<ScrollableState>(form).position;
    // A `.first` inside the finder throws until its parent is built.
    bool built() {
      try {
        return target.evaluate().isNotEmpty;
      } on StateError {
        return false;
      }
    }

    if (!built()) {
      // From the top down, so targets above the fold are found too.
      position.jumpTo(0);
      await tester.pump();
    }
    for (var i = 0; i < 40 && !built(); i++) {
      position.jumpTo(
        (position.pixels + 200).clamp(0, position.maxScrollExtent),
      );
      await tester.pump();
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> pickType(WidgetTester tester, SpaceType type) async {
    final tile = find.byKey(ValueKey('report-space-${type.name}'));
    await reveal(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<Map<String, dynamic>> send(
    WidgetTester tester,
    RecordingStore store,
  ) async {
    // Back up to the name, the first field in the list.
    final name = find.widgetWithText(TextFormField, '停車點名稱');
    await reveal(tester, name);
    await tester.enterText(name, '測試點');
    await tester.pumpAndSettle();
    // The button sits below the fold of a lazily built list.
    await reveal(tester, find.text('送出回報'));
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
    await reveal(
      tester,
      find.byKey(const ValueKey('report-space-paidMotorcycle')),
    );
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
    // The rider's vehicle (普通機車) opens first.
    final daily = find.byKey(const ValueKey('fee-mode-scooter-daily'));
    await reveal(tester, daily);
    await tapFee(tester, 'fee-mode-scooter-daily');
    await tester.enterText(feeField('amount', 'scooter'), '30');
    await chooseFeeMode(tester, 'heavy', 'same_as');
    final spot = await send(tester, store);
    expect(spot['fee'], {
      'scooter': {'mode': 'daily', 'amount': 30},
      'heavy': {'mode': 'same_as_scooter'},
    });
    expect(spot['fee_note'], '機車每日 30 元；大型重機每日 30 元');
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
    await reveal(tester, find.textContaining('與臺北市的停車規則帶入'));
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
    await reveal(tester, underground);
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
    await reveal(tester, guide);
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

  testWidgets('先改一個車種再換格位，另一個規則帶入的車種仍送未確認', (tester) async {
    final store = await openForm(tester, rules: cityRules);
    final scooterUnconfirmed = find.descendant(
      of: find.byType(SegmentedButton<bool?>).first,
      matching: find.text('未確認'),
    );
    await reveal(tester, scooterUnconfirmed);
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

  testWidgets('依標記位置帶入縣市與行政區，並提醒 15 m 內同類型的點', (tester) async {
    final store = await openForm(tester);
    expect(store.lookups, [(25.0339, 121.5623)]);
    expect(find.text('位於臺北市信義區'), findsOneWidget);
    // The known spot sits at the same place with the same bay kind.
    expect(find.byKey(const ValueKey('report-duplicate')), findsOneWidget);
    await pickType(tester, SpaceType.heavyOnly);
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
        await reveal(tester, find.text('送出回報'));
        expect(find.text('送出回報').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<void> tapSegment(WidgetTester tester, int row, String label) async {
    // The list builds lazily; come back from wherever the last step left it.
    final segment = find.descendant(
      of: find.widgetWithText(ChoiceField<bool?>, row == 0 ? '普通機車' : '大型重機'),
      matching: find.text(label),
    );
    await reveal(tester, segment);
    await tester.tap(segment);
    await tester.pumpAndSettle();
  }

  Future<void> trySend(WidgetTester tester) async {
    await reveal(tester, find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
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
    await tester.enterText(note, '夜間有管理員');
    await reveal(tester, nameField);
    await tester.enterText(nameField, '市府路機車格');
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
    expect(find.textContaining('普通機車的計時金額是 0 元'), findsOneWidget);
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
    expect(find.text('位於新北市板橋區'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    store.held!.last.complete(const Town('臺北市', '大安區'));
    await tester.pumpAndSettle();
    expect(find.text('位於臺北市大安區'), findsOneWidget);
    store.held = null;
    final spot = await send(tester, store);
    expect(spot['lat'], 25.0347);
    expect(spot['city'], '臺北市');
    expect(spot['district'], '大安區');
  });
}
