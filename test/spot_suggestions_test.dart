import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/models/closure.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const spot = ParkingSpot(
  id: '00000000-0000-4000-8000-000000000123',
  name: '尚未收到不存在回報的機車停車點',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.freeMotorcycle,
);

class RecordingStore extends AppStore {
  RecordingStore(LocalRepository local) : super(local, null);
  final submissions = <Map<String, dynamic>>[];
  bool failNext = false;

  /// Thrown by the next [submit] instead of succeeding.
  Object? throwNext;

  /// What the reverse lookup answers, offline.
  Town? town = const Town('臺北市', '信義區');

  @override
  Future<Town?> townAt(double lat, double lng) async => town;

  /// What「移到我的位置」reads.
  LocationFix fix = const LocationFix(25.0339, 121.5623, 5);

  @override
  Future<LocationFix> currentFix() async => fix;

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    submissions.add(body);
    if (throwNext case final error?) {
      throwNext = null;
      throw error;
    }
    if (failNext) {
      failNext = false;
      throw StateError('連線失敗，請重試');
    }
    return '已送交審核';
  }
}

/// Scrolls the open suggestion form to its button and taps it.
/// Taps [target] after scrolling it to the middle of its list, clear of
/// the sheet's header and button bar.
Future<void> tapCentered(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Taps the bay kind [kind] in the list.
Future<void> pickKind(WidgetTester tester, SpaceKind kind) =>
    tapCentered(tester, find.byKey(ValueKey('report-space-${kind.name}')));

Future<void> scrollAndSend(WidgetTester tester) async {
  final button = find.text('送出修改建議');
  await tester.scrollUntilVisible(
    button,
    200,
    scrollable: find
        .descendant(
          of: find.byType(Form).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<RecordingStore> createStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = RecordingStore(
    LocalRepository(await SharedPreferences.getInstance()),
  );
  store.spots = [spot];
  return store;
}

Future<void> openDetails(
  WidgetTester tester,
  RecordingStore store, {
  ParkingSpot selectedSpot = spot,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // The app's bridge for CNBottomSheet's Material localizations.
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpot(context, store, selectedSpot),
            child: const Text('開啟點位'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟點位'));
  await tester.pumpAndSettle();
}

/// Scrolls the spot sheet until [finder] shows: the details sit under the
/// preview's four signs.
Future<void> showInSheet(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('parking-spot-sheet')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  test('位置卡寫縣市、區與地址，不寫經緯度', () {
    ParkingSpot at({
      String city = '臺北市',
      String district = '中山區',
      String address = '',
      String road = '',
    }) => ParkingSpot(
      id: 'a',
      name: 'x',
      lat: 25.05,
      lng: 121.52,
      city: city,
      district: district,
      address: address,
      roadSegment: road,
      spaceType: SpaceType.freeMotorcycle,
    );
    expect(locationSummary(at()), '目前位置：臺北市中山區');
    expect(locationSummary(at(district: '')), '目前位置：臺北市');
    expect(locationSummary(at(city: '', district: '')), '目前位置：縣市與區未提供');
    expect(locationSummary(at(address: '南京東路二段 1 號')), '臺北市中山區 南京東路二段 1 號');
    expect(
      locationSummary(at(address: '臺北市中山區南京東路二段 1 號')),
      '臺北市中山區南京東路二段 1 號',
    );
    expect(locationSummary(at(address: '中山區南京東路二段 1 號')), '臺北市中山區南京東路二段 1 號');
    expect(
      locationSummary(at(road: '林森北路（長安東路至南京東路）')),
      '臺北市中山區 林森北路（長安東路至南京東路）',
    );
  });

  for (final dismissal in ['完成', '關閉', '返回', '下滑']) {
    testWidgets('建議成功後回到清單，以$dismissal離開清單回到詳情（#403）', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      await openDetails(tester, store);
      await tester.ensureVisible(find.text('修改建議'));
      await tester.tap(find.text('修改建議'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('名稱'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('suggestion-input')),
        '市府路機車格',
      );
      await tester.tap(find.text('送出修改建議'));
      await tester.pumpAndSettle();
      // Back on the list, which says what went; its 完成 closes it.
      expect(find.text('提出修改建議'), findsOneWidget);
      expect(find.text('「名稱」的建議已送出'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestion-input')), findsNothing);
      expect(find.text('完成'), findsOneWidget);
      switch (dismissal) {
        case '完成':
          await tester.tap(find.text('完成'));
        case '關閉':
          await tester.tap(find.byTooltip('關閉').last);
        case '返回':
          await tester.binding.handlePopRoute();
        case '下滑':
          final sheet = tester.getRect(find.byType(BottomSheet).last);
          await tester.flingFrom(
            Offset(sheet.center.dx, sheet.top + 20),
            const Offset(0, 700),
            2000,
          );
      }
      await tester.pumpAndSettle();
      expect(find.text('提出修改建議'), findsNothing);
      expect(find.text('完成'), findsNothing);
      // Return to the spot details, without accidentally popping that route.
      expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
      expect(store.submissions, hasLength(1));
      // Said once on the page under it (S6b ④); this store has no backend.
      expect(
        find.byKey(const ValueKey('suggestions-sent-toast')),
        findsOneWidget,
      );
      expect(find.text('範例模式：建議沒有實際送出，只用來測試流程。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('取消或送出失敗後關閉表單，保留修改建議父面板', (tester) async {
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名稱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsOneWidget);
    await tester.tap(find.text('名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '市府路機車格',
    );
    store.failNext = true;
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
    expect(find.text('連線失敗，請重試'), findsOneWidget);
    await tester.tap(find.byTooltip('關閉').last);
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停權時送出修改建議顯示停權面板，不顯示一般錯誤（#331）', (tester) async {
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '市府路機車格',
    );
    store.throwNext = AccountSuspended(DateTime.utc(2099, 1, 2));
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
    expect(find.byType(SuspendedPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('suspended-until')), findsOneWidget);
    expect(find.textContaining('請確認網路'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('「這裡又可以停了」把停權交給 runAction，其他錯誤仍回訊息（#331）', () async {
    SharedPreferences.setMockInitialValues({});
    final store = RecordingStore(
      LocalRepository(await SharedPreferences.getInstance()),
    );
    addTearDown(store.dispose);
    store.throwNext = const AccountSuspended(null);
    await expectLater(
      reportReopened(store, spot),
      throwsA(isA<AccountSuspended>()),
    );
    store.throwNext = Exception('offline');
    expect(await reportReopened(store, spot), '回報沒有送出，請確認網路後再試一次。');
  });

  testWidgets('未回報點位維持顯示，不存在只能由修改建議送交審核', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    expect(find.text(spot.name), findsOneWidget);
    expect(find.text('還在'), findsNothing);
    expect(find.text('已不存在'), findsNothing);
    expect(find.textContaining('最後確認'), findsNothing);
    expect(store.submissions, isEmpty);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('這裡已經不能停車'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('這裡已經不能停車'));
    await tester.pumpAndSettle();
    expect(find.text('這裡已經不能停車'), findsOneWidget);
    await tester.tap(find.text('這裡已經不能停車'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(find.text('請選擇原因'), findsOneWidget);
    expect(store.submissions, isEmpty);
    // A lasting cause: the bay is gone, so hiding is suggested.
    await tester.tap(find.byKey(const ValueKey('gone-removed')));
    await tester.pumpAndSettle();
    expect(find.text('請選擇原因'), findsNothing);
    expect(find.byKey(const ValueKey('gone-until')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '現場格線已撤除，改為人行道',
    );
    store.failNext = true;
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(find.text('連線失敗，請重試'), findsOneWidget);
    expect(store.spots, contains(spot));
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(store.submissions.last, {
      'action': 'flag',
      'source_id': spot.id,
      'reason': '這裡已經不能停車：格線已撤除；說明：現場格線已撤除，改為人行道',
      'field': 'gone',
      'proposed': {'status': 'hidden'},
      'note': '現場格線已撤除，改為人行道',
    });
    expect(store.submissions.any((body) => body['action'] == 'vote'), isFalse);
    expect(store.spots, contains(spot));
    expect(find.text('範例模式：建議沒有實際送出，只用來測試流程。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('修改建議顯示目前值，格位類型以選項送出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    unawaited(
      showKindSuggestion(
        tester.element(find.byType(SuggestionListPage)),
        store,
        spot,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('地圖上目前寫的是'), findsOneWidget);
    // Nothing changes until the reporter picks another marking.
    expect(find.byKey(const ValueKey('suggestion-change')), findsNothing);
    await scrollAndSend(tester);
    expect(find.text('這和目前的格位類型相同，請選擇另一種'), findsOneWidget);
    await pickKind(tester, SpaceKind.heavy);
    expect(
      find.text(
        '格位類型從「${SpaceKind.motorcycle.label}」'
        '改成「${SpaceKind.heavy.label}」',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    await scrollAndSend(tester);
    expect(store.submissions.single, {
      'action': 'flag',
      'source_id': spot.id,
      'reason': '格位類型：建議「${SpaceType.heavyOnly.label}」',
      'field': 'space_type',
      // The kind's condition goes with it, so the two never disagree.
      'proposed': {
        'space_type': 'heavyOnly',
        'condition': {'bay': 'heavy', 'use': 'usual'},
      },
      'note': '',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<RecordingStore> openSuggestion(
    WidgetTester tester,
    String item, {
    ParkingSpot selectedSpot = spot,
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, selectedSpot: selectedSpot);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    final list = find
        .descendant(
          of: find.byType(SuggestionListPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final entry = switch (item) {
      '格位類型' when selectedSpot.spaceType == SpaceType.offStreet => find.byKey(
        const ValueKey('suggest-facility'),
      ),
      '格位類型' => find.byKey(const ValueKey('suggest-limits')),
      '入口與停車指引' => find.byKey(const ValueKey('suggest-where')),
      goneLabel => find.byKey(const ValueKey('suggest-gone')),
      '其他備註' => find.byKey(const ValueKey('suggest-note')),
      '停車點名稱' => find.text('名稱'),
      _ => find.text(item),
    };
    if (item == '格位類型' && selectedSpot.spaceType != SpaceType.offStreet) {
      // A street spot's limits open S5b; its kind form is not on the list.
      unawaited(
        showKindSuggestion(
          tester.element(find.byType(SuggestionListPage)),
          store,
          selectedSpot,
        ),
      );
      await tester.pumpAndSettle();
      return store;
    }
    await tester.scrollUntilVisible(entry, 150, scrollable: list);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    if (item == '入口與停車指引') {
      await tester.tap(find.text('入口'));
      await tester.pumpAndSettle();
    }
    return store;
  }

  Future<void> submitSuggestion(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find
          .descendant(
            of: find.byType(Form).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> pickReopening(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('gone-dated-true')));
    await tester.tap(find.byKey(const ValueKey('gone-dated-true')));
    await tester.pumpAndSettle();
    // The picker opens on today; confirm it.
    final ok = find.text('確定').evaluate().isNotEmpty
        ? find.text('確定')
        : find.text('OK');
    await tester.tap(ok.last);
    await tester.pumpAndSettle();
  }

  testWidgets('施工中送暫時封閉（#116）：日期用選擇器，不建議隱藏', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-works')));
    await tester.pumpAndSettle();
    // The 40-character free text is gone; 不知道 is the start.
    expect(find.byType(TextFormField), findsOneWidget);
    await pickReopening(tester);
    final today = taiwanToday(DateTime.now());
    expect(find.text(closureDayLabel(today)), findsOneWidget);
    await submitSuggestion(tester, '送出回報');
    final body = store.submissions.single;
    expect(body['field'], 'gone');
    expect(body['proposed'], {
      'closure': {'reason': 'works', 'until': closureDate(today)},
    });
    expect(body['reason'], '這裡已經不能停車：施工中；預計恢復：${closureDayLabel(today)}');
  });

  testWidgets('暫時封閉沒有日期：只送原因，7 天後到期', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-closed')));
    await tester.pumpAndSettle();
    expect(find.textContaining('7 天後自動恢復顯示'), findsOneWidget);
    await submitSuggestion(tester, '送出回報');
    expect(store.submissions.single['proposed'], {
      'closure': {'reason': 'closed'},
    });
  });

  testWidgets('改選長期原因後不再帶預計恢復日期', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-works')));
    await tester.pumpAndSettle();
    await pickReopening(tester);
    await tester.tap(find.byKey(const ValueKey('gone-removed')));
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出回報');
    expect(store.submissions.single['reason'], '這裡已經不能停車：格線已撤除');
    expect(store.submissions.single['proposed'], isNot(contains('closure')));
  });

  testWidgets('原因膠囊選中不加勾勾、寬度不變', (tester) async {
    await openSuggestion(tester, '這裡已經不能停車');
    final pill = find.byKey(const ValueKey('gone-works'));
    final before = tester.getSize(pill);
    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(tester.getSize(pill), before);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  test('長度依伺服器的 UTF-16 計算', () {
    expect(fitsServer('機' * 40, 40), isNull);
    expect(fitsServer('🛵' * 21, 40), isNotNull);
    expect(fitsServer(null, 40), isNull);
  });

  testWidgets('「其他」原因需要說明', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-other')));
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出回報');
    expect(find.text('請填寫現場狀況'), findsOneWidget);
    expect(store.submissions, isEmpty);
  });

  testWidgets('入口與停車指引只送有變更的欄位', (tester) async {
    final store = await openSuggestion(
      tester,
      '入口與停車指引',
      selectedSpot: const ParkingSpot(
        id: 'lot',
        name: '松壽地下停車場',
        lat: 25.0339,
        lng: 121.5623,
        city: '臺北市',
        spaceType: SpaceType.offStreet,
        source: 'official',
      ),
    );
    expect(find.byKey(const ValueKey('suggestion-entrance')), findsOneWidget);
    await submitSuggestion(tester, '送出修改建議');
    expect(find.text('請至少修改一項，和目前不同才能送出'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-guide')),
      '格位在便利商店前',
    );
    await tester.pumpAndSettle();
    expect(find.text('停車指引從「未提供」改成「格位在便利商店前」'), findsOneWidget);
    await submitSuggestion(tester, '送出修改建議');
    final body = store.submissions.single;
    expect(body['field'], 'guide');
    expect(body['proposed'], {'parking_guide': '格位在便利商店前'});
  });

  testWidgets('格位建議改為路外停車場時追問型式與分類', (tester) async {
    final store = await openSuggestion(tester, '格位類型');
    await pickKind(tester, SpaceKind.offStreet);
    final surface = find.byKey(const ValueKey('facility-surface'));
    await tester.ensureVisible(surface);
    await tester.tap(surface);
    await tester.pumpAndSettle();
    expect(find.text('場站型式從「未提供」改成「路外平面停車場」'), findsOneWidget);
    await submitSuggestion(tester, '送出修改建議');
    expect(store.submissions.single['proposed'], {
      'space_type': 'offStreet',
      'facility_types': ['surface'],
    });
  });

  testWidgets('勾選場站型式時保留選項外的既有型式（路邊）', (tester) async {
    final lot = ParkingSpot.fromJson({
      ...spot.toJson(),
      'space_type': 'offStreet',
      'facility_type': 'underground',
      'facility_types': ['underground', 'roadside'],
    });
    final store = await openSuggestion(tester, '格位類型', selectedSpot: lot);
    final surface = find.byKey(const ValueKey('facility-surface'));
    await tester.ensureVisible(surface);
    await tester.pumpAndSettle();
    await tester.tap(surface);
    await tester.pumpAndSettle();
    // Still in the set, so the precheck asks the rider about it instead of
    // the form dropping it unseen.
    expect(tester.widget<FacilityField>(find.byType(FacilityField)).value, {
      FacilityType.underground,
      FacilityType.surface,
      FacilityType.roadside,
    });
    await submitSuggestion(tester, '送出修改建議');
    expect(store.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Who may park is each zone's (as the new-spot form N1): this form no
  // longer asks it or sends the spot's parking_access, on phone and tablet,
  // on both platforms.
  for (final width in [390.0, 680.0, 1040.0]) {
    testWidgets(
      '既有路外場站只修改場站型式也能送出，還原後恢復未變更提示（寬 $width）',
      (tester) async {
        final lot = ParkingSpot.fromJson({
          ...spot.toJson(),
          'space_type': 'offStreet',
          'facility_type': 'underground',
          'parking_access': 'scooterHeavy',
        });
        final store = await openSuggestion(
          tester,
          '格位類型',
          selectedSpot: lot,
          size: Size(width, 844),
        );
        expect(find.text('停放分類'), findsNothing);
        await submitSuggestion(tester, '送出修改建議');
        const error = '請至少修改格位類型或場站型式其中一項';
        expect(find.text(error), findsOneWidget);
        expect(store.submissions, isEmpty);

        final control = find.byType(FacilityField);
        Future<void> choose(String label) async {
          await tester.scrollUntilVisible(
            control,
            -200,
            scrollable: find
                .descendant(
                  of: find.byType(Form).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(control);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(of: control, matching: find.text(label)),
          );
          await tester.pumpAndSettle();
        }

        // A second lot type for the facility; ticking it off restores it.
        await choose('路外平面停車場');
        expect(find.text(error), findsNothing);
        expect(find.text('場站型式從「地下停車場」改成「地下、平面停車場」'), findsOneWidget);
        await choose('路外平面停車場');
        expect(find.text(error), findsOneWidget);
        await choose('路外平面停車場');
        await submitSuggestion(tester, '送出修改建議');
        expect(store.submissions.single['proposed'], {
          'space_type': 'offStreet',
          'facility_types': ['underground', 'surface'],
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets('格位建議帶停放條件：限時格的收費與限停分鐘', (tester) async {
    final store = await openSuggestion(tester, '格位類型');
    // 限時 is a limit on a 一般機車格 (#188).
    await pickKind(tester, SpaceKind.motorcycle);
    final timed = find.byKey(const ValueKey('condition-limit-time_limit'));
    await tester.ensureVisible(timed);
    await tester.tap(timed);
    await tester.pumpAndSettle();
    await tapCentered(
      tester,
      find.byKey(const ValueKey('condition-charge-toll')),
    );
    final minutes = find.byKey(const ValueKey('condition-max-minutes'));
    await tester.ensureVisible(minutes);
    await tester.enterText(minutes, '20');
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出修改建議');
    expect(store.submissions.single['proposed'], {
      'space_type': 'timedMotorcycle',
      'condition': {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'limits': [
          {
            'kind': 'time_limit',
            'periods': [
              {'days': 'all', 'max_minutes': 20, 'extensions': 0},
            ],
          },
        ],
      },
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('普大共用沒選收費或免費會擋下', (tester) async {
    // A heavy-only bay says nothing about charge to carry over.
    final heavy = ParkingSpot.fromJson({
      ...spot.toJson(),
      'space_type': 'heavyOnly',
    });
    final store = await openSuggestion(tester, '格位類型', selectedSpot: heavy);
    await pickKind(tester, SpaceKind.scooterHeavy);
    await submitSuggestion(tester, '送出修改建議');
    expect(store.submissions, isEmpty);
    expect(find.text('請選收費格或免費格'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('路外停車場改成路邊格時清除場站型式與場站的 parking_access', (tester) async {
    final lot = ParkingSpot.fromJson({
      ...spot.toJson(),
      'space_type': 'offStreet',
      'facility_type': 'underground',
      'parking_access': 'scooterHeavy',
    });
    final store = await openSuggestion(tester, '格位類型', selectedSpot: lot);
    await pickKind(tester, SpaceKind.motorcycle);
    final toll = find.byKey(const ValueKey('condition-charge-toll'));
    await tester.ensureVisible(toll);
    await tester.tap(toll);
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出修改建議');
    expect(store.submissions.single['proposed'], {
      'space_type': 'paidMotorcycle',
      'condition': {'bay': 'motorcycle', 'use': 'usual', 'charge': 'toll'},
      'facility_types': ['roadside'],
      'parking_access': null,
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只改停放條件也能送出，並列在你要改的內容', (tester) async {
    final store = await openSuggestion(tester, '格位類型');
    // 普大共用 is a kind of its own (C6 canvas AppPatterns), still stored as
    // the free bay it is.
    await pickKind(tester, SpaceKind.scooterHeavy);
    await tapCentered(
      tester,
      find.byKey(const ValueKey('condition-charge-free')),
    );
    // The change list sits by the button, below the fold.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('suggestion-change')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(Form).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.text('格位類型從「一般機車格」改成「普大共用格」', skipOffstage: false),
      findsOneWidget,
    );
    // Decision 60: 普大共用 brings heavy bikes in, 可停 by default.
    expect(find.text('大型重機從「未確認」改成「可停」', skipOffstage: false), findsOneWidget);
    // A free 普大共用 bay waits for review; a link helps.
    expect(find.byKey(const ValueKey('condition-hold')), findsOneWidget);
    await submitSuggestion(tester, '送出修改建議');
    expect(store.submissions.single['proposed'], {
      'space_type': 'freeMotorcycle',
      'condition': {
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'charge': 'free',
      },
      'heavy_allowed': true,
    });
    expect(store.submissions.single['reason'], contains('普大共用格，大型重機可停'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 320 px wide, tall enough that the helper finds 修改建議 without dragging
  // the sheet.
  for (final size in const [Size(320, 900), Size(402, 874), Size(820, 1180)]) {
    testWidgets('普大共用的大型重機選項在 ${size.width.toInt()} 寬不溢出、可點', (tester) async {
      await openSuggestion(tester, '格位類型', size: size);
      await pickKind(tester, SpaceKind.scooterHeavy);
      for (final v in ['allowed', 'notAllowed']) {
        final option = find.byKey(ValueKey('suggestion-share-heavy-$v'));
        await tester.ensureVisible(option);
        await tester.pumpAndSettle();
        expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
        await tester.tap(option);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('建議普大共用時大型重機預設可停，可改成不可停、不能改回未確認（決定 60、#201）', (tester) async {
    final store = await openSuggestion(tester, '格位類型');
    await pickKind(tester, SpaceKind.scooterHeavy);
    final toll = find.descendant(
      of: find.byKey(const ValueKey('condition-charge')),
      matching: find.text('收費格'),
    );
    await tester.ensureVisible(toll);
    await tester.tap(toll);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('suggestion-share-heavy-notStated')),
      findsNothing,
    );
    final closed = find.byKey(
      const ValueKey('suggestion-share-heavy-notAllowed'),
    );
    await tester.ensureVisible(closed);
    await tester.tap(closed);
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出修改建議');
    final proposed = store.submissions.single['proposed'] as Map;
    expect(proposed['heavy_allowed'] ?? false, false);
    expect(
      proposed.containsKey('heavy_allowed') &&
          proposed['heavy_allowed'] == null,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('摘要依伺服器的 UTF-16 長度截斷，不切開 emoji', () {
    final emoji = '🛵' * 300;
    expect(emoji.length, 600);
    final cut = reportSummary(emoji);
    expect(cut.length, lessThanOrEqualTo(500));
    expect(cut, endsWith('…'));
    // Whole scooters only: an odd unit count would mean a split pair.
    expect((cut.length - 1).isEven, isTrue);
    expect(reportSummary('短'), '短');
  });

  testWidgets('名稱建議以填寫內容作為建議值送出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '市府路機車格',
    );
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
    expect(store.submissions.single, {
      'action': 'flag',
      'source_id': spot.id,
      'reason': '停車點名稱：市府路機車格',
      'field': 'name',
      'proposed': {'name': '市府路機車格'},
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小螢幕深色與放大字級的詳情、修改建議不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 740);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, scale: 1.6, brightness: Brightness.dark);
    await tester.drag(
      find.byKey(const ValueKey('parking-spot-sheet')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('修改建議').hitTestable(),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('parking-spot-sheet')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('這裡已經不能停車').hitTestable(),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('這裡已經不能停車'));
    await tester.pumpAndSettle();
    expect(find.text('這裡為什麼不能停車？'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (width, scale, brightness) in [
    (390.0, 1.0, Brightness.light),
    (320.0, 1.6, Brightness.dark),
  ]) {
    testWidgets('名稱建議填占位詞或電話時，在輸入框下方說明怎麼改（$width px、$scale 倍）', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      await openDetails(tester, store, scale: scale, brightness: brightness);
      // At this size a resting sheet keeps the three actions (three rows)
      // at the end of its list; opened to full height it pins them.
      await tester.tap(find.byKey(const ValueKey('four-sign-verdict')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改建議'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('名稱'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('suggestion-input'));
      await tester.enterText(input, '測試');
      await tester.pumpAndSettle();
      expect(find.textContaining('「測試」看不出是哪個停車點'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(input, '請打 0912 345 678');
      await tester.pumpAndSettle();
      expect(find.textContaining('內容含有電話號碼'), findsOneWidget);
      final button = find.text('送出修改建議');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find
            .ancestor(of: input, matching: find.byType(Scrollable))
            .first,
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(store.submissions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('其他備註只寫「不知道」時提示寫出現場狀況，不送出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('其他備註').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他備註').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '不知道',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('看不出現場狀況'), findsOneWidget);
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
    expect(store.submissions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  /// The open suggestion form's list, kept once the form opens: its title
  /// scrolls away and is disposed later.
  late ScrollPosition formList;

  void captureForm(WidgetTester tester) {
    formList = tester
        .state<ScrollableState>(
          find
              .ancestor(
                // The form's own close button, at the top of its list.
                of: find.byTooltip('關閉').last,
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
  }

  /// Scrolls the suggestion form until [target] is built and on screen,
  /// moving the list itself: a drag could land on the map.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    final position = formList;
    position.jumpTo(0);
    await tester.pump();
    for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
      position.jumpTo(
        (position.pixels + 200).clamp(0, position.maxScrollExtent),
      );
      await tester.pump();
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> openLocation(
    WidgetTester tester,
    RecordingStore store, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('位置'));
    await tester.pumpAndSettle();
    captureForm(tester);
  }

  // N1's floating controls at phone and tablet widths, both platforms.
  for (final size in const [Size(390, 844), Size(820, 1180), Size(1180, 820)]) {
    testWidgets(
      '位置不正確：地圖疊加控制在 ${size.width.toInt()}×${size.height.toInt()} 可點、不溢出',
      (tester) async {
        final store = (await tester.runAsync(createStore))!;
        addTearDown(store.dispose);
        await openLocation(tester, store, size: size);
        // Read first: the list builds lazily, and revealing the map's lower
        // controls can scroll this card out of it.
        expect(find.text('目前位置：臺北市'), findsOneWidget);
        for (final key in ['location-expand', 'location-locate']) {
          await reveal(tester, find.byKey(ValueKey(key)));
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  Future<void> sendSuggestion(WidgetTester tester) async {
    await reveal(tester, find.text('送出修改建議'));
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
  }

  for (final found in [true, false]) {
    testWidgets('位置不正確：拖曳標記後送座標${found ? '與反查的縣市、行政區' : '；查不到縣市時只送座標'}，說明另外寫', (
      tester,
    ) async {
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      if (!found) store.town = null;
      await openLocation(tester, store);
      // N1's map (#190): the place by name, the controls on the map, and
      // no coordinates or full-width search above it.
      expect(find.text('目前位置：臺北市'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Form).last,
          matching: find.textContaining('25.03'),
        ),
        findsNothing,
      );
      expect(find.text('搜尋門牌、路段或路口'), findsNothing);
      // No backend here, so no search; the rest float on the map.
      for (final key in ['location-expand', 'location-locate']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      await sendSuggestion(tester);
      expect(find.text('請把標記拖到停車格的實際位置，和目前不同才能送出'), findsOneWidget);
      expect(store.submissions, isEmpty);
      final pin = find.byKey(const ValueKey('touch-marker'));
      await reveal(tester, pin);
      final gesture = await tester.startGesture(tester.getCenter(pin));
      await gesture.moveBy(const Offset(0, -40));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.textContaining('請把標記拖到'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Form).last,
          matching: find.textContaining('25.03'),
        ),
        findsNothing,
      );
      expect(find.textContaining('位置往北移動約'), findsOneWidget);
      expect(
        find.textContaining('行政區從「未提供」改成「信義區」'),
        found ? findsOneWidget : findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('suggestion-input')),
        '格位在對面的便利商店前',
      );
      await sendSuggestion(tester);
      final body = store.submissions.single;
      expect(body['field'], 'location');
      final proposed = body['proposed'] as Map<String, Object?>;
      expect(
        proposed.keys,
        unorderedEquals([
          'lat',
          'lng',
          if (found) ...['city', 'district'],
        ]),
      );
      if (found) {
        expect(proposed['city'], '臺北市');
        expect(proposed['district'], '信義區');
      }
      expect(proposed['lat'] as double, greaterThan(spot.lat));
      expect(proposed['lng'], closeTo(spot.lng, 1e-6));
      expect(body['note'], '格位在對面的便利商店前');
      expect(body['reason'], startsWith('停車點位置：建議移到 '));
      expect(body['reason'], endsWith('；說明：格位在對面的便利商店前'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('位置不正確：跨縣市提醒規則改變，超過 150 m 先確認', (tester) async {
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    store
      ..town = const Town('新北市', '板橋區')
      ..fix = const LocationFix(25.0369, 121.5623, 6);
    await openLocation(tester, store);
    await reveal(tester, find.byKey(const ValueKey('location-locate')));
    await tester.tap(find.byKey(const ValueKey('location-locate')));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('GPS 精準度約 ±6 m'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('suggestion-city-changed')),
      findsOneWidget,
    );
    expect(find.textContaining('縣市從「臺北市」改成「新北市」'), findsOneWidget);
    await sendSuggestion(tester);
    expect(find.byKey(const ValueKey('suggestion-far')), findsOneWidget);
    await tester.tap(find.text('返回調整'));
    await tester.pumpAndSettle();
    expect(store.submissions, isEmpty);
    await sendSuggestion(tester);
    await tester.tap(find.text('是同一個，送出'));
    await tester.pumpAndSettle();
    final body = store.submissions.single;
    expect(body['proposed'], {
      'lat': 25.0369,
      'lng': 121.5623,
      'city': '新北市',
      'district': '板橋區',
    });
    expect(body['reason'], contains('位於新北市'));
    expect(find.text('完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('位置不正確在 320 px 深色放大字級與鍵盤彈出時不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, scale: 1.6, brightness: Brightness.dark);
    await tester.drag(
      find.byKey(const ValueKey('parking-spot-sheet')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('修改建議').hitTestable(),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('parking-spot-sheet')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('位置').hitTestable(),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('位置'));
    await tester.pumpAndSettle();
    captureForm(tester);
    expect(find.byKey(const ValueKey('touch-marker')), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('suggestion-input')));
    await tester.showKeyboard(find.byKey(const ValueKey('suggestion-input')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await reveal(tester, find.text('送出修改建議'));
    expect(find.text('送出修改建議').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('暫時封閉（#116）', () {
    // One instant for the group: `today` and a later DateTime.now() fall on
    // different days when the run crosses Taiwan's midnight.
    final now = DateTime.now();
    final today = taiwanToday(now);
    ParkingSpot closed(SpotClosure closure) => ParkingSpot(
      id: spot.id,
      name: spot.name,
      lat: spot.lat,
      lng: spot.lng,
      city: spot.city,
      spaceType: spot.spaceType,
      closure: closure,
    );

    test('沒填日期 7 天後到期；伺服器的判斷優先', () {
      final c = SpotClosure.fromJson({
        'reason': 'works',
        'since': closureDate(today.subtract(const Duration(days: 7))),
      })!;
      expect(c.stateOn(now), ClosureState.active);
      final older = SpotClosure.fromJson({
        'reason': 'works',
        'since': closureDate(today.subtract(const Duration(days: 8))),
      })!;
      expect(older.stateOn(now), ClosureState.expired);
      // Read as active, then the date passes: it lapses all the same.
      expect(
        SpotClosure.fromJson({
          'reason': 'works',
          'since': '2020-01-01',
        }, state: 'active')!.stateOn(now),
        ClosureState.expired,
      );
      expect(
        SpotClosure.fromJson({
          'reason': 'works',
          'since': closureDate(today),
        }, state: 'active')!.stateOn(now),
        ClosureState.active,
      );
      // Favorites keep it, without the judgement.
      final saved = ParkingSpot.fromJson(
        ParkingSpot(
          id: spot.id,
          name: spot.name,
          lat: spot.lat,
          lng: spot.lng,
          city: spot.city,
          spaceType: spot.spaceType,
          closure: SpotClosure(reason: ClosureReason.works, since: today),
        ).toJson(),
      );
      expect(saved.closure?.reason, ClosureReason.works);
      expect(saved.closure?.state, isNull);
      expect(validClosure({'reason': 'works', 'since': '2026-02-30'}), isFalse);
      expect(
        validClosure({
          'reason': 'closed',
          'since': '2026-10-26',
          'until': '2026-10-25',
        }),
        isFalse,
      );
    });

    for (final width in [320.0, 390.0]) {
      testWidgets('詳情：到期前、沒填日期、過期待確認（${width.toInt()} px）', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = (await tester.runAsync(createStore))!;
        addTearDown(store.dispose);
        final until = today.add(const Duration(days: 30));
        await openDetails(
          tester,
          store,
          selectedSpot: closed(
            SpotClosure(
              reason: ClosureReason.works,
              since: today,
              until: until,
              basis: '車友回報',
              state: ClosureState.active,
            ),
          ),
        );
        await showInSheet(tester, find.text('施工中，暫時不能停'));
        expect(find.text('施工中，暫時不能停'), findsOneWidget);
        expect(find.text('預計 ${closureDayLabel(until)}恢復'), findsOneWidget);
        expect(find.text('已經可以停'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());

        await openDetails(
          tester,
          store,
          selectedSpot: closed(
            SpotClosure(
              reason: ClosureReason.closed,
              since: today,
              state: ClosureState.active,
            ),
          ),
        );
        await showInSheet(tester, find.text('暫時封閉，暫時不能停'));
        expect(find.text('暫時封閉，暫時不能停'), findsOneWidget);
        expect(find.text('恢復時間未知'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());

        await openDetails(
          tester,
          store,
          selectedSpot: closed(
            SpotClosure(
              reason: ClosureReason.closed,
              since: today.subtract(const Duration(days: 40)),
              until: today.subtract(const Duration(days: 1)),
              state: ClosureState.expired,
            ),
          ),
        );
        await showInSheet(tester, find.textContaining('原定'));
        expect(find.textContaining('原定'), findsOneWidget);
        expect(find.text('現場是否已恢復，還沒有人確認'), findsOneWidget);
        final reopened = find.byKey(const ValueKey('closure-reopened'));
        await tester.ensureVisible(reopened);
        await tester.pumpAndSettle();
        expect(tester.getSize(reopened).height, greaterThanOrEqualTo(48));
        await tester.tap(reopened);
        await tester.pumpAndSettle();
        expect(store.submissions.single, {
          'action': 'flag',
          'source_id': spot.id,
          'reason': '暫時封閉已恢復：現場已經可以停',
          'field': 'reopened',
          'proposed': {'closure': null},
        });
        await tester.ensureVisible(find.byKey(const ValueKey('closure-still')));
        await tester.tap(find.byKey(const ValueKey('closure-still')));
        await tester.pumpAndSettle();
        expect(find.text('這裡為什麼不能停車？'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });
}
