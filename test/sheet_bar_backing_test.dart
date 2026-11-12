import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/map/map_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'spot_detail_fixtures.dart';

const backing = ValueKey('sheet-bar-backing');
const barInset = 83.0;

Future<AppStore> mapStore(WidgetTester tester) async {
  final store = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({
      'legendSeen': true,
      'availabilityBetaIntroSeen': true,
    });
    final s = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      clock: () => detailDay,
    );
    await s.init();
    return s;
  }))!;
  return store;
}

/// The map as the shell shows it: on iOS the page runs under the floating
/// bar, which the Scaffold reports as bottom padding.
Future<void> pumpMap(
  WidgetTester tester,
  AppStore store, {
  required Size size,
  double inset = barInset,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(padding: EdgeInsets.only(bottom: inset)),
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(child: child!),
        ),
        home: const Scaffold(body: MapPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openSpot(WidgetTester tester) async {
  await tester.tap(find.byType(SpotMarker).first, warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('spot-sheet-overlay')), findsOneWidget);
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('只有手機、地圖跑到分頁列後面時才需要', () {
    bool on(double inset, Size size) =>
        sheetBarBacking(tabBarInset: inset, tablet: isTabletWindow(size));
    expect(on(barInset, const Size(390, 844)), isTrue);
    expect(on(barInset, const Size(844, 390)), isTrue);
    expect(on(0, const Size(390, 844)), isFalse);
    expect(on(barInset, const Size(820, 1180)), isFalse);
    expect(on(barInset, const Size(1180, 820)), isFalse);
  });

  for (final brightness in Brightness.values) {
    testWidgets('iOS ${brightness.name}：有卡片時底色和卡片同色、高度等於分頁列，'
        '關閉同一幀消失', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final store = await mapStore(tester);
      await pumpMap(
        tester,
        store,
        size: const Size(390, 844),
        brightness: brightness,
      );
      expect(find.byKey(backing), findsNothing);
      await openSpot(tester);
      final strip = find.byKey(backing);
      expect(strip, findsOneWidget);
      final rect = tester.getRect(strip);
      expect(rect.height, barInset);
      expect(rect.bottom, 844);
      expect(rect.width, 390);
      final sheet = find.byKey(const ValueKey('spot-sheet-overlay'));
      // No seam: the sheet ends where the strip starts.
      expect(tester.getRect(sheet).bottom, rect.top);
      final color = tester.widget<ColoredBox>(strip).color;
      expect(color, Theme.of(tester.element(sheet)).colorScheme.surface);
      expect(color.a, 1);
      await tester.tap(find.byTooltip('關閉詳情'));
      // The very next frame, with no fade.
      await tester.pump();
      expect(find.byKey(const ValueKey('spot-sheet-overlay')), findsNothing);
      expect(find.byKey(backing), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Android：導覽列不透明，頁面沒有底部 inset，不畫底色', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final store = await mapStore(tester);
    await pumpMap(tester, store, size: const Size(390, 844), inset: 0);
    await openSpot(tester);
    expect(find.byKey(backing), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final size in const [Size(820, 1180), Size(1180, 820)]) {
    testWidgets('平板 ${size.width.toInt()}：詳情在左側面板，不畫底色', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final store = await mapStore(tester);
      await pumpMap(tester, store, size: size);
      // T1, T2: the panel runs to the bottom itself, behind the tab bar.
      await tester.tap(find.byType(SpotMarker).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-sheet-overlay')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('spot-side-panel'))).bottom,
        size.height,
      );
      expect(find.byKey(backing), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('沒有卡片：地圖滿版，不畫底色', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final store = await mapStore(tester);
    await pumpMap(tester, store, size: const Size(390, 844));
    expect(find.byKey(backing), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
