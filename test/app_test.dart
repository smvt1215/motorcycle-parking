import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
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
      closeTo(tester.view.physicalSize.height / 2, 1),
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
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsOneWidget);
    expect(find.byTooltip('關閉詳情').hitTestable(), findsNothing);
    await tester.tap(find.text('停車點名稱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('請填寫建議內容'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '建議的新名稱',
    );
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('範例建議已送出，僅供本次功能測試。'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
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
    expect(find.text('路邊收費機車格'), findsOneWidget);
    await tester.tap(find.text('免費機車格'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('parking-search'));
    await tester.enterText(input, '[範例]');
    await tester.pumpAndSettle();
    expect(find.text('[範例] 市府周邊免費機車格'), findsOneWidget);
    expect(find.text('[範例] 信義地下停車場'), findsNothing);
    expect(find.textContaining('已套用篩選'), findsOneWidget);
    await tester.tapAt(const Offset(30, 550));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('有剩餘車位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('有剩餘車位'));
    await tester.pumpAndSettle();
    await tester.tap(input);
    await tester.pumpAndSettle();
    expect(find.textContaining('沒有符合的停車點'), findsOneWidget);
    await tester.tap(find.text('清除篩選查看結果'));
    await tester.pumpAndSettle();
    expect(find.text('全部格位'), findsOneWidget);
    expect(find.text('[範例] 市府周邊免費機車格'), findsOneWidget);
    expect(find.text('[範例] 信義地下停車場'), findsOneWidget);
    await tester.enterText(input, '地下');
    await tester.pumpAndSettle();
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
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
    await tester.tap(find.text('大型重機').first);
    await tester.pumpAndSettle();
    expect(store.vehicle, VehicleType.heavy);
    expect(store.local.vehicle, VehicleType.heavy);
    await tester.tap(find.text('個人中心').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停車規則').last);
    await tester.pumpAndSettle();
    expect(find.text('停之前，先看規則'), findsOneWidget);
    expect(find.textContaining('40 元'), findsOneWidget);
    await store.toggleFavorite(store.spots.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('個人中心').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的收藏').last);
    await tester.pumpAndSettle();
    expect(find.text(store.spots.first.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('個人中心與貢獻是地圖上可收展的面板，詳情覆蓋面板', (tester) async {
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
    expect(find.text('目前地圖範圍'), findsOneWidget);
    await tester.tap(find.byTooltip('新增停車點'));
    await tester.pumpAndSettle();
    expect(find.text('停車點名稱'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(store.spots.first.name));
    await tester.pumpAndSettle();
    final detail = find.byKey(const ValueKey('parking-spot-sheet'));
    expect(detail, findsOneWidget);
    expect(find.text('探索').hitTestable(), findsNothing);
    final ctx = tester.element(detail);
    expect(Navigator.of(ctx), same(Navigator.of(ctx, rootNavigator: true)));
    await tester.tap(find.byTooltip('關閉詳情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('探索').last);
    await tester.pumpAndSettle();
    expect(controller.camera.center, center);
    expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
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
