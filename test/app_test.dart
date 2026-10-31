import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/config.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

Future<AppStore> testStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
  );
  await store.init();
  return store;
}

void main() {
  testWidgets('搜尋框直接顯示下拉結果，選取後開啟車位詳情', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('parking-search'));
    final mapSize = tester.getSize(find.byType(FlutterMap));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    // The keyboard overlays the map; resizing a native map shows blank bands.
    expect(tester.getSize(find.byType(FlutterMap)), mapSize);
    tester.view.resetViewInsets();
    await tester.pump();
    expect(find.byTooltip('車種與地圖'), findsNothing);
    expect(find.byTooltip('圖例與篩選'), findsNothing);
    expect(find.byKey(const ValueKey('city-selector')), findsNothing);
    await tester.tap(input);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    await tester.enterText(input, '   ');
    await tester.pump();
    expect(find.byTooltip('清除搜尋'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    await tester.enterText(input, '[範例]');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(
      find.byKey(const ValueKey('parking-search-results')),
      findsOneWidget,
    );
    await tester.enterText(input, '地下');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('parking-search-results')),
      findsOneWidget,
    );
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.text('[範例] 信義地下停車場'), findsOneWidget);
    await tester.enterText(input, '沒有這個名字');
    await tester.pumpAndSettle();
    expect(find.textContaining('沒有符合的停車點'), findsOneWidget);
    await tester.enterText(input, '地下');
    await tester.pumpAndSettle();
    await tester.tap(find.text('[範例] 信義地下停車場'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-search-results')), findsNothing);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    final sheetContext = tester.element(find.byType(DraggableScrollableSheet));
    expect(
      Navigator.of(sheetContext),
      same(Navigator.of(sheetContext, rootNavigator: true)),
    );
    final sheetRect = tester.getRect(find.byType(DraggableScrollableSheet));
    expect(sheetRect.bottom, closeTo(tester.view.physicalSize.height, 1));
    expect(find.text('個人中心').hitTestable(), findsNothing);
    await tester.drag(
      find.byType(DraggableScrollableSheet),
      const Offset(0, -550),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(DraggableScrollableSheet)).top,
      lessThan(60),
    );
    expect(
      find.byKey(const ValueKey('parking-search')).hitTestable(),
      findsNothing,
    );
    await tester.drag(
      find.byKey(const ValueKey('parking-spot-sheet')),
      const Offset(0, 700),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('parking-spot-sheet'))).height,
      closeTo(tester.view.physicalSize.height * .42, 1),
    );
    // The map above stays undimmed, as in map apps.
    expect(
      tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .map((barrier) => barrier.color)
          .where((color) => color != null && color.a > 0),
      isEmpty,
    );
    await tester.drag(
      find.byKey(const ValueKey('parking-spot-sheet')),
      const Offset(0, 150),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('parking-search-results')), findsNothing);
    expect(find.text('個人中心').hitTestable(), findsOneWidget);
    await tester.tap(input);
    await tester.enterText(input, '地下');
    await tester.pumpAndSettle();
    await tester.tap(find.text('[範例] 信義地下停車場'));
    await tester.pumpAndSettle();
    final detailsBeforeSuggest = tester.getRect(
      find.byKey(const ValueKey('parking-spot-sheet')),
    );
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsOneWidget);
    expect(find.byTooltip('關閉詳情').hitTestable(), findsNothing);
    await tester.tap(find.text('停車點名稱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
    expect(find.text('請填寫正確的停車點名稱'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '建議的新名稱',
    );
    await tester.tap(find.text('送出修改建議'));
    await tester.pumpAndSettle();
    expect(find.text('範例模式：建議沒有實際送出，只用來測試流程。'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('parking-spot-sheet'))),
      detailsBeforeSuggest,
    );
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    await tester.tap(find.byTooltip('關閉詳情'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-search-results')), findsNothing);
    await tester.tap(input);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('parking-search-results')),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(30, 550));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  });
  testWidgets('格位與剩餘篩選同步套用搜尋，無結果可清除條件', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final searchButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '搜尋停車點',
    );
    expect(tester.widget<IconButton>(searchButton).onPressed, isNull);
    await tester.tap(find.text('全部格位'));
    await tester.pumpAndSettle();
    // The seven bay kinds and the lot (#188, P1).
    expect(find.text('一般機車格'), findsOneWidget);
    expect(find.text('普大共用格'), findsOneWidget);
    await tester.tap(find.text('一般機車格'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('parking-search'));
    await tester.enterText(input, '[範例]');
    await tester.pumpAndSettle();
    expect(find.text('[範例] 市府周邊免費機車格'), findsOneWidget);
    expect(find.text('[範例] 信義地下停車場'), findsNothing);
    expect(find.textContaining('已套用篩選'), findsOneWidget);
    // The off-street lot exists but the bay filter hides it.
    await tester.enterText(input, '[範例] 信義地下');
    await tester.pumpAndSettle();
    expect(find.textContaining('沒有符合的停車點'), findsOneWidget);
    await tester.tap(find.text('清除篩選查看結果'));
    await tester.pumpAndSettle();
    expect(find.text('全部格位'), findsOneWidget);
    expect(find.text('[範例] 信義地下停車場'), findsOneWidget);
    await tester.enterText(input, '地下');
    await tester.pumpAndSettle();
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('隱藏不可停篩選、搜尋依可停程度排序，並可開啟地圖圖例', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('parking-search'));
    // Only two in-viewport spots match, so the capped list builds both.
    await tester.enterText(input, '路');
    await tester.pumpAndSettle();
    final denied = find.text('[範例] 松高路汽車格');
    expect(denied, findsOneWidget);
    // Not-allowed spots sort below every allowed or conditional result.
    expect(
      tester.getTopLeft(denied).dy,
      greaterThan(tester.getTopLeft(find.text('[範例] 信義路收費機車格')).dy),
    );
    expect(find.textContaining('不可停 · 汽車格'), findsOneWidget);
    await tester.tapAt(const Offset(30, 550));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('隱藏不可停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隱藏不可停'));
    await tester.pumpAndSettle();
    await tester.tap(input);
    await tester.pumpAndSettle();
    expect(find.text('[範例] 松高路汽車格'), findsNothing);
    expect(find.text('[範例] 信義路收費機車格'), findsOneWidget);
    expect(find.textContaining('已套用篩選'), findsOneWidget);
    await tester.tapAt(const Offset(30, 550));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('地圖怎麼看'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('地圖怎麼看'));
    await tester.pumpAndSettle();
    // The legend is a page pushed over the map (P3), back to the map.
    expect(find.text('依現場標示'), findsOneWidget);
    expect(find.textContaining('目前車種「普通機車」'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('依現場標示'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('詳情開啟時地圖仍可拖動、可直接改選其他停車點，選取點放大標示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    Finder marker(String name) => find.descendant(
      of: find.byType(FlutterMap),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Semantics && (w.properties.label ?? '').startsWith('$name '),
      ),
    );
    String sheetTitle() => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(const ValueKey('parking-spot-sheet')),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;
    final first = store.spots.first, second = store.spots[1];
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    // Close enough to separate the two markers from any cluster.
    map.mapController!.move(LatLng(first.lat, first.lng), 18);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('selected-spot-marker')), findsNothing);
    await tester.tap(marker(first.name).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    expect(sheetTitle(), first.name);
    expect(find.byKey(const ValueKey('selected-spot-marker')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('selected-spot-marker'))).width,
      greaterThan(38),
    );
    // Tapping the selected marker itself keeps its details open.
    final selectedCenter = map.mapController!.camera.center;
    await tester.tap(find.byKey(const ValueKey('selected-spot-marker')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sheetTitle(), first.name);
    expect(map.mapController!.camera.center, selectedCenter);
    // The map above the sheet still pans.
    final before = map.mapController!.camera.center;
    await tester.drag(find.byType(FlutterMap), const Offset(-60, 80));
    await tester.pumpAndSettle();
    expect(map.mapController!.camera.center, isNot(before));
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    // Another spot switches the open details directly.
    map.mapController!.move(LatLng(second.lat, second.lng), 18);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(marker(second.name).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    expect(sheetTitle(), second.name);
    final centerBeforeClosing = map.mapController!.camera.center;
    // Tapping the map away from markers closes the details.
    await tester.tapAt(const Offset(30, 300));
    // The map waits out the double-tap window before reporting a tap.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('selected-spot-marker')), findsNothing);
    // Back closes the details and stays on the map.
    expect(map.mapController!.camera.center, centerBeforeClosing);
    await tester.tap(marker(second.name).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsNothing);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('地圖移至其他範圍後清除原點位並顯示空範圍提示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.mapController!.move(const LatLng(24.15, 120.67), 16);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(store.spots, isEmpty);
    expect(find.textContaining('目前範圍尚無停車資料'), findsOneWidget);
    map.mapController!.move(const LatLng(25.0339, 121.5623), 16);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(store.spots, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('車種切換、規則與收藏畫面更新', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('範例資料 · 行駛中請勿操作'), findsOneWidget);
    await tester.tap(find.text('普通機車').first);
    await tester.pumpAndSettle();
    // The legend lives behind the map's help button only.
    expect(find.text('有條件・限標示車格'), findsNothing);
    await tester.tap(find.text('大型重機').first);
    await tester.pumpAndSettle();
    expect(store.vehicle, VehicleType.heavy);
    expect(store.local.vehicle, VehicleType.heavy);
    await tester.tap(find.text('個人中心').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停車規則').last);
    await tester.pumpAndSettle();
    expect(find.text('停之前，先看規則。各縣市開放的格位和收費不同。'), findsOneWidget);
    // The fee sits below the space-type groups.
    await tester.scrollUntilVisible(
      find.textContaining('40 元'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('40 元'), findsOneWidget);
    await store.toggleFavorite(store.spots.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('個人中心').last);
    await tester.pumpAndSettle();
    // Favorites appear once: one section, no separate shortcut to them.
    expect(find.text('我的收藏'), findsOneWidget);
    // The legend and the account sheet are also rows of the page.
    expect(find.text('地圖怎麼看'), findsOneWidget);
    expect(find.text('帳號與設定'), findsOneWidget);
    // One vehicle switch: the map's pill, not the account sheet.
    await tester.tap(find.byTooltip('設定與登入'));
    await tester.pumpAndSettle();
    // The page row and the sheet's title.
    expect(find.text('帳號與設定'), findsNWidgets(2));
    expect(find.text('大型重機'), findsNothing);
    expect(find.text('範例模式'), findsOneWidget);
    await tester.tap(find.byTooltip('關閉').last);
    await tester.pumpAndSettle();
    expect(find.text('已儲存的停車點'), findsNothing);
    expect(find.text(store.spots.first.name), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('all-favorites')));
    await tester.pumpAndSettle();
    expect(find.text(store.spots.first.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('個人中心與貢獻是地圖上可收展的面板，修改建議覆蓋面板', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    final center = controller.camera.center;
    await tester.tap(find.text('個人中心').last);
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('parking-search')), findsNothing);
    expect(find.text('探索').hitTestable(), findsOneWidget);
    expect(find.text('貢獻').hitTestable(), findsOneWidget);
    await tester.tap(find.text('貢獻').last);
    await tester.pumpAndSettle();
    expect(find.text('修正附近停車點'), findsOneWidget);
    // Editing and reporting share one list: no duplicate action buttons.
    expect(find.byTooltip('修改資訊'), findsNothing);
    expect(find.byTooltip('檢舉錯誤'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('contribute-new-spot')));
    await tester.pumpAndSettle();
    expect(find.text('拖曳標記對準停車格，或點地圖選位置'), findsOneWidget);
    await tester.tap(find.byTooltip('關閉').last);
    await tester.pumpAndSettle();
    // A spot in the list goes straight to the edit and "gone" reports.
    await tester.tap(find.text('修改').first);
    await tester.pumpAndSettle();
    final suggestions = find.text('提出修改建議');
    expect(suggestions, findsOneWidget);
    final ctx = tester.element(suggestions);
    expect(Navigator.of(ctx), same(Navigator.of(ctx, rootNavigator: true)));
    // The "gone" report sits below the editable fields; the list itself is
    // kept by element because its title scrolls away.
    final listElement = tester.element(
      find.ancestor(of: suggestions, matching: find.byType(Scrollable)).first,
    );
    final list = find.byElementPredicate((e) => e == listElement);
    await tester.scrollUntilVisible(
      find.text('這裡已經不能停車'),
      200,
      scrollable: list,
    );
    expect(find.text('這裡已經不能停車'), findsOneWidget);
    expect(find.text('探索').hitTestable(), findsNothing);
    await tester.scrollUntilVisible(suggestions, -200, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('關閉').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('探索').last);
    await tester.pumpAndSettle();
    expect(controller.camera.center, center);
    expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  });
  testWidgets('個人中心與貢獻面板滑動至底部時關閉並回到探索', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('parking-search'));
    for (final (tab, content) in [('個人中心', '我停哪裡'), ('貢獻', '修正附近停車點')]) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      // A short drag snaps to half height and keeps the panel open.
      await tester.drag(find.text(content), const Offset(0, 250));
      await tester.pumpAndSettle();
      expect(find.text(content).hitTestable(), findsOneWidget);
      expect(search, findsNothing);
      await tester.drag(find.text(content), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(search, findsOneWidget);
      expect(find.text(content).hitTestable(), findsNothing);
      // Reopening restores the initial height instead of an empty panel.
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(find.text(content).hitTestable(), findsOneWidget);
      await tester.tap(find.text('探索').last);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('本機收藏與停車紀錄在重啟後保留', (tester) async {
    await tester.runAsync(() async {
      final store = await testStore();
      await store.toggleFavorite(store.spots.first);
      await store.local.setParked(
        ParkedRecord(lat: 25, lng: 121, at: DateTime.now(), floor: 'B1'),
      );
      final second = AppStore(store.local, null);
      await second.init();
      expect(second.favorites.length, 1);
      expect(second.parked!.floor, 'B1');
      store.dispose();
      second.dispose();
    });
  });
  testWidgets('Android 地圖動作使用精簡 M3E FAB，提示不重疊', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final locate = tester.getRect(find.byKey(const ValueKey('locate-fab')));
    final fab = tester.getRect(find.byKey(const ValueKey('record-fab')));
    final notice = tester.getRect(find.text('範例資料 · 行駛中請勿操作'));
    final nav = tester.getRect(find.byType(M3ENavigationBar));
    // Compact map actions, still large touch targets.
    for (final action in [locate, fab]) {
      expect(action.width, inInclusiveRange(48, 56));
    }
    expect(locate.bottom, lessThanOrEqualTo(fab.top));
    expect(fab.bottom, lessThanOrEqualTo(nav.top));
    expect(notice.right, lessThan(fab.left));
    await tester.tap(find.byKey(const ValueKey('record-fab')));
    await tester.pumpAndSettle();
    expect(find.text('記錄停車'), findsOneWidget);
    expect(find.text('樓層或區域（選填）'), findsOneWidget);
    // The reminder is one segmented choice, not a dropdown.
    final reminder = find.byKey(const ValueKey('parking-reminder'));
    expect(reminder, findsOneWidget);
    await tester.tap(
      find.descendant(of: reminder, matching: find.text('1 小時')).first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('iOS 地圖控制與提示避開懸浮分頁列，離線不顯示 OSM 署名', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final store = (await tester.runAsync(testStore))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final tabBar = tester.getRect(
      find.ancestor(
        of: find.text('探索').last,
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'CupertinoTabBar',
        ),
      ),
    );
    final notice = tester.getRect(find.text('範例資料 · 行駛中請勿操作'));
    for (final rect in [
      notice,
      ...find
          .byType(MapAction)
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget))),
    ]) {
      expect(rect.bottom, lessThanOrEqualTo(tabBar.top));
    }
    for (final action in find.byType(MapAction).evaluate()) {
      expect(
        tester.getSize(find.byWidget(action.widget)).width,
        MapAction.size,
      );
    }
    // The OSM credit appears only when OpenStreetMap tiles actually load.
    expect(
      find.text('© OpenStreetMap contributors'),
      AppConfig.showsOsmTiles ? findsOneWidget : findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final dark in [false, true]) {
      testWidgets('${platform.name} ${dark ? '深色' : '淺色'} 規則畫面 golden', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final font = FontLoader('Outfit')
          ..addFont(rootBundle.load('assets/fonts/Outfit.ttf'));
        await tester.runAsync(font.load);
        final store = (await tester.runAsync(testStore))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: ParkingApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await tester.tap(find.text('個人中心').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('停車規則').last);
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(ParkingApp),
          matchesGoldenFile(
            'goldens/rules_${platform.name}_${dark ? 'dark' : 'light'}.png',
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
