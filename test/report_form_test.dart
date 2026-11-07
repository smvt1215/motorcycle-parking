import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/models/zone_entries.dart';
import 'package:motorcycle_parking/ui/fee_editor.dart';
import 'package:motorcycle_parking/ui/location_picker.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

class RecordingStore extends AppStore {
  RecordingStore(LocalRepository local) : super(local, null);
  final submissions = <Map<String, dynamic>>[];

  /// Thrown by [submit] instead of succeeding.
  Object? refuse;

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
    if (refuse case final error?) throw error;
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
          // The app's bridge for CNBottomSheet's Material localizations.
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(child: child!),
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
  final nameField = find.widgetWithText(TextFormField, '名稱');

  bool built(Finder target) {
    // A `.first` inside the finder throws until its parent is built.
    try {
      return target.evaluate().isNotEmpty;
    } on StateError {
      return false;
    }
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    if (!built(target)) {
      final position = tester.state<ScrollableState>(form).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await scrollTo(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// Adds a segment of [kind] from N1's 停哪裡, picking what is still empty.
  Future<void> addSegment(
    WidgetTester tester, {
    SpaceKind kind = SpaceKind.motorcycle,
    Eligible scooter = Eligible.allowed,
    Eligible heavy = Eligible.notAllowed,
  }) async {
    await tapKey(tester, 'spot-kind-street');
    await tapKey(tester, 'n1-where');
    await tester.tap(find.text('新增一段'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'bay-${kind.name}');
    await tapKey(tester, 'entry-scooter-${scooter.name}');
    await tapKey(tester, 'entry-heavy-${heavy.name}');
    await tester.tap(find.widgetWithText(AdaptiveButton, '完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('form-header-leading')).last);
    await tester.pumpAndSettle();
  }

  /// Adds zone [name] from N1's 停哪裡.
  Future<void> addZone(
    WidgetTester tester, {
    String name = 'B2 機車區',
    SpaceKind kind = SpaceKind.motorcycle,
    Eligible scooter = Eligible.allowed,
    Eligible heavy = Eligible.notAllowed,
  }) async {
    await tapKey(tester, 'spot-kind-lot');
    await tapKey(tester, 'n1-where');
    await tester.tap(find.text('新增一區'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('entry-name')), name);
    await tapKey(tester, 'bay-${kind.name}');
    await tapKey(tester, 'entry-scooter-${scooter.name}');
    await tapKey(tester, 'entry-heavy-${heavy.name}');
    await tester.tap(find.widgetWithText(AdaptiveButton, '完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('form-header-leading')).last);
    await tester.pumpAndSettle();
  }

  Future<void> pressSend(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(AdaptiveButton, '送出'));
    await tester.pumpAndSettle();
  }

  Future<Map<String, dynamic>> send(
    WidgetTester tester,
    RecordingStore store,
  ) async {
    await addSegment(tester);
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '測試點');
    await tester.pumpAndSettle();
    await pressSend(tester);
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
    await tester.tap(find.byKey(const ValueKey('location-locate')));
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

  testWidgets('標記移動後，前一個位置晚到的反查結果不會套用', (tester) async {
    final store = await openForm(tester);
    store.held = [];
    store.fix = const LocationFix(25.0343, 121.5623, 8);
    // Move once so a lookup for the first new position is in flight.
    await tester.tap(find.byKey(const ValueKey('location-locate')));
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.held, hasLength(1));
    // Move again; the first answer arrives before the next lookup starts.
    store.fix = const LocationFix(25.0347, 121.5623, 8);
    await tester.tap(find.byKey(const ValueKey('location-locate')));
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

  testWidgets('依標記位置帶入縣市與行政區，並提醒 15 m 內同類型的點', (tester) async {
    final store = await openForm(tester);
    expect(store.lookups, [(25.0339, 121.5623)]);
    expect(find.text('信義區'), findsOneWidget);
    expect(find.byKey(const ValueKey('report-duplicate')), findsNothing);
    final spot = await send(tester, store);
    expect(spot['city'], '臺北市');
    expect(spot['district'], '信義區');
    expect(spot['lat'], 25.0339);
  });

  testWidgets('路邊：停哪裡必填（C1），點位資格由各段彙總，不送點位層 condition（C9）', (tester) async {
    final store = await openForm(tester);
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '南京東路');
    await tapKey(tester, 'spot-kind-street');
    await pressSend(tester);
    expect(store.submissions, isEmpty);
    expect(find.textContaining('請填停哪裡'), findsOneWidget);
    await addSegment(tester);
    expect(find.textContaining('請填停哪裡'), findsNothing);
    expect(find.text('1 段'), findsOneWidget);
    await pressSend(tester);
    final spot = store.submissions.single['spot'] as Map<String, dynamic>;
    expect(spot['space_type'], 'paidMotorcycle');
    expect(spot.containsKey('condition'), isFalse);
    expect(spot['scooter_allowed'], isTrue);
    expect(spot['heavy_allowed'], isFalse);
    final segment = (spot['parking_segments'] as List).single as Map;
    expect(segment['name'], '一般機車格');
    expect(segment['condition'], {
      'bay': 'motorcycle',
      'use': 'usual',
      'allow': {'scooter': true, 'heavy': false},
    });
  });

  testWidgets('B3 汽機車共用格、普機可停可以送出，分區不帶 access（#356）', (tester) async {
    final store = await openForm(tester);
    await addZone(
      tester,
      name: 'B3 汽車區',
      kind: SpaceKind.carMotorcycle,
      heavy: Eligible.allowed,
    );
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '松壽地下停車場');
    await tester.pump();
    await pressSend(tester);
    final spot = store.submissions.single['spot'] as Map<String, dynamic>;
    final zone = (spot['parking_zones'] as List).single as Map;
    expect((zone['condition'] as Map)['share'], 'car_motorcycle');
    expect(zone.containsKey('access'), isFalse);
    expect(validZoneList(spot['parking_zones']), isTrue);
  });

  testWidgets('停權時開共用面板，表單內容保留（#331）', (tester) async {
    final store = await openForm(tester);
    store.refuse = const AccountSuspended(null);
    await addSegment(tester);
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '南京東路');
    await tester.pump();
    await pressSend(tester);
    expect(find.byType(SuspendedPanel), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(SuspendedPanel), findsNothing);
    expect(find.text('南京東路'), findsOneWidget);
    expect(find.text('1 段'), findsOneWidget);
    store.refuse = null;
    await pressSend(tester);
    expect(store.submissions, hasLength(1));
  });

  testWidgets('路外：場站型式、入口、分區，官方未標示彙總成 not_stated', (tester) async {
    final store = await openForm(tester);
    await addZone(
      tester,
      heavy: Eligible.notStated,
      scooter: Eligible.notAllowed,
    );
    expect(find.text('1 區'), findsOneWidget);
    await tapKey(tester, 'facility-underground');
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '松壽地下停車場');
    final entrance = find.byKey(const ValueKey('report-entrance'));
    await scrollTo(tester, entrance);
    await tester.enterText(entrance, '松壽路側車道下坡');
    await tester.pump();
    await pressSend(tester);
    final spot = store.submissions.single['spot'] as Map<String, dynamic>;
    expect(spot['space_type'], 'offStreet');
    expect(spot['facility_types'], ['underground']);
    expect(spot['entrance_note'], '松壽路側車道下坡');
    expect(spot['scooter_allowed'], isFalse);
    expect(spot['heavy_not_stated'], isTrue);
    final zone = (spot['parking_zones'] as List).single as Map;
    expect(zone['name'], 'B2 機車區');
    expect(zone.containsKey('access'), isFalse);
    expect((zone['condition'] as Map)['allow'], {
      'scooter': false,
      'heavy': 'not_stated',
    });
  });

  testWidgets('沒選種類時送出標在卡片上，三列先不能點', (tester) async {
    final store = await openForm(tester);
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '南京東路');
    await pressSend(tester);
    expect(store.submissions, isEmpty);
    expect(find.text('請選這是哪一種停車點'), findsOneWidget);
    expect(
      tester.widget<EntryRow>(find.byKey(const ValueKey('n1-where'))).onTap,
      isNull,
    );
  });

  testWidgets('名稱是占位詞時在欄位下方提示，不送出', (tester) async {
    final store = await openForm(tester);
    await addSegment(tester);
    await scrollTo(tester, nameField);
    await tester.enterText(nameField, '測試');
    await tester.pumpAndSettle();
    await pressSend(tester);
    expect(store.submissions, isEmpty);
    expect(find.textContaining('測試'), findsWidgets);
  });

  testWidgets('未填的三列顯示未填；路邊怎麼算錢走路段頁，整條路費率寫回 N1', (tester) async {
    await openForm(tester);
    await tapKey(tester, 'spot-kind-street');
    expect(
      tester.widget<EntryRow>(find.byKey(const ValueKey('n1-rules'))).onTap,
      isNull,
    );
    await tapKey(tester, 'n1-fee');
    expect(find.text('路段與格位'), findsOneWidget);
    expect(find.text('整條路費率'), findsOneWidget);
  });

  testWidgets('路外怎麼算錢填全場費率，完成回 N1 並顯示摘要', (tester) async {
    await openForm(tester);
    await tapKey(tester, 'spot-kind-lot');
    await tapKey(tester, 'n1-fee');
    expect(find.text('費率'), findsOneWidget);
    expect(find.byType(FeeEditor), findsOneWidget);
    await tester.tap(find.widgetWithText(AdaptiveButton, '完成'));
    await tester.pumpAndSettle();
    expect(find.text('怎麼算錢'), findsOneWidget);
    expect(find.text('未填'), findsNWidgets(2));
  });

  testWidgets('路外的入口欄換成路邊的怎麼找到格位', (tester) async {
    await openForm(tester);
    await tapKey(tester, 'spot-kind-lot');
    final field = find.byKey(const ValueKey('report-entrance'));
    await scrollTo(tester, field);
    expect(find.text('入口在哪裡（選填）'), findsOneWidget);
    await tapKey(tester, 'spot-kind-street');
    await scrollTo(tester, field);
    expect(find.text('怎麼找到格位（選填）'), findsOneWidget);
    expect(find.text('場站型式（可複選）'), findsNothing);
  });

  testWidgets('新增模式：S1b 隱藏入口列、沒有修改中和撤除，已加的可刪除', (tester) async {
    await openForm(tester);
    await addZone(tester);
    await tapKey(tester, 'n1-where');
    expect(find.text('入口'), findsNothing);
    await tester.tap(find.text('B2 機車區'));
    await tester.pumpAndSettle();
    expect(find.text('修改中'), findsNothing);
    expect(find.text('你要改的內容'), findsNothing);
    expect(find.text('這區已撤除'), findsNothing);
    final delete = find.text('刪除這一區');
    await scrollTo(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('B2 機車區'), findsNothing);
  });

  for (final (size, scale) in const [
    (Size(320, 640), 1.0),
    (Size(390, 844), 1.0),
    (Size(390, 844), 1.6),
    (Size(820, 1180), 1.0),
    (Size(1024, 768), 1.0),
  ]) {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets(
        'N1 在 ${size.width.toInt()}×${size.height.toInt()}、$scale 倍、${platform.name} 不溢出',
        (tester) async {
          await openForm(tester, size: size, scale: scale);
          await tapKey(tester, 'spot-kind-lot');
          expect(tester.takeException(), isNull);
          final min = platform == TargetPlatform.iOS ? 44.0 : 48.0;
          final height = tester
              .getSize(find.byKey(const ValueKey('n1-where')))
              .height;
          expect(height, greaterThanOrEqualTo(min));
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
