import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/map/map_page.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/map_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'spot_detail_fixtures.dart';

/// The tablet layout (#190 PR-F2, canvas T1 portrait, T2 landscape): the
/// details in a panel beside the map on iPad and Android tablets, the
/// phone's sheet everywhere else.
const _panel = ValueKey('spot-side-panel');
const _overlay = ValueKey('spot-sheet-overlay');
const _backing = ValueKey('sheet-bar-backing');
const _search = ValueKey('parking-search');
const _filters = ValueKey('tablet-filters');
const _legend = ValueKey('map-legend-button');
const _selectedMarker = ValueKey('selected-spot-marker');

const _phones = [Size(390, 844), Size(375, 667), Size(844, 390)];
const _tablets = [
  Size(820, 1180),
  Size(768, 1024),
  Size(1180, 820),
  Size(1024, 768),
];

/// Windows an iPad's Split View leaves: half and a third of the screen.
const _splits = [Size(590, 820), Size(507, 1180), Size(320, 1180)];

final _platforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

Future<AppStore> _store(WidgetTester tester) async =>
    (await tester.runAsync(() async {
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

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// The map alone, as the shell's body: [inset] stands for the iPad's tab
/// bar, which the page runs under.
Future<void> _pumpMap(
  WidgetTester tester,
  AppStore store, {
  required Size size,
  double inset = 0,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(bottom: inset),
            textScaler: TextScaler.linear(scale),
          ),
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(child: child!),
        ),
        home: const Scaffold(body: MapPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpApp(
  WidgetTester tester,
  AppStore store, {
  required Size size,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

Future<void> _openFirst(WidgetTester tester) async {
  await tester.tap(find.byType(SpotMarker).first, warnIfMissed: false);
  await tester.pumpAndSettle();
}

String _openName(WidgetTester tester) =>
    tester.widget<SpotSheet>(find.byType(SpotSheet)).spot.name;

void main() {
  test('680 寬、600 高以上才是平板版面；手機橫放與分割畫面的窄視窗不是', () {
    for (final size in _tablets) {
      expect(isTabletSize(size), isTrue, reason: '$size');
    }
    for (final size in [..._phones, ..._splits]) {
      expect(isTabletSize(size), isFalse, reason: '$size');
    }
    expect(isTabletSize(const Size(680, 600)), isTrue);
    expect(isTabletSize(const Size(679, 1024)), isFalse);
    expect(isTabletSize(const Size(960, 599)), isFalse);
    // Two thirds of an 11-inch iPad on its side.
    expect(isTabletSize(const Size(780, 820)), isTrue);
  });

  for (final size in _tablets) {
    testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
        '詳情在左側面板，寬 400，一路到底，地圖與地圖按鈕留在旁邊', (tester) async {
      final store = await _store(tester);
      await _pumpMap(tester, store, size: size);
      expect(tester.takeException(), isNull);
      // The search field heads the panel column, the filters run beside it.
      final search = tester.getRect(
        find
            .ancestor(of: find.byKey(_search), matching: find.byType(Material))
            .first,
      );
      expect(search.left, 16);
      expect(search.width, sidePanelWidth);
      final filters = tester.getRect(find.byKey(_filters));
      expect(filters.left, 16 + sidePanelWidth + 16);
      expect(filters.top, lessThan(search.bottom));
      final legend = tester.getRect(find.byKey(_legend));
      expect(legend.right, size.width - 16);
      final upright = size.height > size.width;
      if (!isCupertino && upright) {
        // T1 Android: the filters take the whole width, the button under.
        expect(filters.right, size.width);
        expect(legend.top, greaterThan(filters.bottom));
      } else {
        expect(legend.left, greaterThanOrEqualTo(filters.right + 12));
        expect(legend.top, lessThan(search.bottom));
      }

      await _openFirst(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(_overlay), findsNothing);
      expect(find.byKey(_backing), findsNothing);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      final panel = tester.getRect(find.byKey(_panel));
      expect(panel.left, 16);
      expect(panel.width, sidePanelWidth);
      expect(panel.top, search.bottom + 12);
      expect(panel.bottom, size.height);
      // Top corners rounded as drawn: 26 on iPad, 28 on Android.
      final surface = tester.widget<Material>(
        find
            .descendant(of: find.byKey(_panel), matching: find.byType(Material))
            .first,
      );
      expect(
        surface.borderRadius,
        BorderRadius.vertical(top: Radius.circular(isCupertino ? 26 : 28)),
      );
      // The name, the four signs and the actions, all inside the panel.
      for (final key in ['spot-four-sign', 'spot-navigate', 'spot-suggest']) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.left, greaterThanOrEqualTo(panel.left), reason: key);
        expect(rect.right, lessThanOrEqualTo(panel.right), reason: key);
        expect(rect.bottom, lessThanOrEqualTo(panel.bottom), reason: key);
      }
      expect(find.byTooltip('關閉詳情').hitTestable(), findsOneWidget);
      // The map's own actions stay in view beside the panel.
      final actions = tester.getRect(find.byType(MapActions));
      expect(actions.left, greaterThan(panel.right));
      expect(actions.bottom, size.height - 28);
      expect(
        find.byType(isCupertino ? MapAction : M3EFab).first.hitTestable(),
        findsOneWidget,
      );
    }, variant: _platforms);
  }

  for (final size in [..._phones, ..._splits]) {
    testWidgets('手機與窄視窗 ${size.width.toInt()}×${size.height.toInt()}：'
        '維持底部卡片', (tester) async {
      final store = await _store(tester);
      await _pumpMap(tester, store, size: size);
      expect(find.byKey(_filters), findsNothing);
      final search = tester.getRect(
        find
            .ancestor(of: find.byKey(_search), matching: find.byType(Material))
            .first,
      );
      expect(search.left, 16);
      expect(search.right, size.width - 16);
      await _openFirst(tester);
      expect(find.byKey(_panel), findsNothing);
      expect(find.byKey(_overlay), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      // The sheet covers the map's actions, as before.
      expect(find.byType(MapActions), findsNothing);
    }, variant: _platforms);
  }

  testWidgets('窄視窗在 iPad 上有分頁列時照樣畫卡片底色（A1b）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final store = await _store(tester);
    await _pumpMap(tester, store, size: const Size(640, 1100), inset: 83);
    await _openFirst(tester);
    expect(find.byKey(_overlay), findsOneWidget);
    expect(find.byKey(_backing), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final size in _tablets) {
    testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
        '選取的點置中在面板右邊露出的地圖', (tester) async {
      final store = await _store(tester);
      await _pumpMap(tester, store, size: size);
      await _openFirst(tester);
      final map = tester.getRect(find.byType(FlutterMap));
      final marker = tester.getCenter(find.byKey(_selectedMarker));
      const covered = 16 + sidePanelWidth;
      expect(
        marker.dx,
        moreOrLessEquals((covered + map.right) / 2, epsilon: 1),
      );
      expect(marker.dy, moreOrLessEquals(map.center.dy, epsilon: 1));
      // The camera's centre moved by half the panel column, no more.
      final camera = MapCamera.of(
        tester.element(find.byType(MarkerLayer).first),
      );
      final spot = tester.widget<SpotSheet>(find.byType(SpotSheet)).spot;
      final at = camera.latLngToScreenOffset(LatLng(spot.lat, spot.lng));
      expect(at.dx - map.width / 2, moreOrLessEquals(covered / 2, epsilon: 1));
    }, variant: _platforms);
  }

  testWidgets('手機：選取的點仍置中在卡片上方，不左右偏移', (tester) async {
    final store = await _store(tester);
    await _pumpMap(tester, store, size: const Size(390, 844));
    await _openFirst(tester);
    final map = tester.getRect(find.byType(FlutterMap));
    final marker = tester.getCenter(find.byKey(_selectedMarker));
    expect(marker.dx, moreOrLessEquals(map.center.dx, epsilon: 1));
    expect(marker.dy, lessThan(map.center.dy));
  }, variant: _platforms);

  testWidgets('平板流程：換另一個點、點路牌跳到該段、關閉、返回鍵關閉', (tester) async {
    final store = await _store(tester);
    await _pumpMap(tester, store, size: const Size(1180, 820));
    await _openFirst(tester);
    final first = _openName(tester);
    final state = tester.state(find.byType(SpotSheet));
    // Another marker beside the panel: the panel stays and shows it.
    final others = find.byType(SpotMarker).evaluate().where((e) {
      final rect = tester.getRect(find.byWidget(e.widget));
      return rect.left > 16 + sidePanelWidth + 8 &&
          e.widget.key != _selectedMarker;
    });
    expect(others, isNotEmpty);
    await tester.tapAt(tester.getCenter(find.byWidget(others.first.widget)));
    await tester.pumpAndSettle();
    expect(find.byKey(_panel), findsOneWidget);
    expect(_openName(tester), isNot(first));
    // A new spot starts at the top with its own state.
    expect(tester.state(find.byType(SpotSheet)), isNot(same(state)));

    // A plate opens its section: the panel scrolls, nothing else moves.
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('spot-panel-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scroll.position.pixels, 0);
    final panelTop = tester.getRect(find.byKey(_panel)).top;
    await tester.tap(find.byKey(const ValueKey('four-sign-where')));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(tester.getRect(find.byKey(_panel)).top, panelTop);
    // The name and the plates stay at the top while the rest scrolls.
    expect(
      find.byKey(const ValueKey('spot-four-sign')).hitTestable(),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('關閉詳情'));
    await tester.pump();
    expect(find.byKey(_panel), findsNothing);

    await _openFirst(tester);
    expect(find.byKey(_panel), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_panel), findsNothing);
  }, variant: _platforms);

  testWidgets('平板：點地圖空白處關閉面板', (tester) async {
    final store = await _store(tester);
    await _pumpMap(tester, store, size: const Size(820, 1180));
    await _openFirst(tester);
    expect(find.byKey(_panel), findsOneWidget);
    await tester.tapAt(const Offset(800, 1000));
    await tester.pumpAndSettle();
    expect(find.byKey(_panel), findsNothing);
  });

  testWidgets('旋轉與分割畫面：跨過平板寬度時面板與卡片互換，狀態留著', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final store = await _store(tester);
    await _pumpMap(tester, store, size: const Size(820, 1180));
    await _openFirst(tester);
    final name = _openName(tester);
    final state = tester.state(find.byType(SpotSheet));
    // Upright to on its side: still the panel.
    tester.view.physicalSize = const Size(1180, 820);
    await tester.pumpAndSettle();
    expect(find.byKey(_panel), findsOneWidget);
    expect(tester.getRect(find.byKey(_panel)).bottom, 820);
    expect(tester.state(find.byType(SpotSheet)), same(state));
    // Split View leaves half the screen: the phone's sheet, same spot.
    tester.view.physicalSize = const Size(590, 820);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_panel), findsNothing);
    expect(find.byKey(_overlay), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(_openName(tester), name);
    expect(tester.state(find.byType(SpotSheet)), same(state));
    // And back to the full screen.
    tester.view.physicalSize = const Size(1180, 820);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_overlay), findsNothing);
    expect(find.byKey(_panel), findsOneWidget);
    expect(tester.state(find.byType(SpotSheet)), same(state));
    debugDefaultTargetPlatformOverride = null;
  });

  for (final size in _tablets) {
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()} '
            '字級 $scale ${brightness.name}：不溢位，動作列點得到', (tester) async {
          final store = await _store(tester);
          await _pumpMap(
            tester,
            store,
            size: size,
            scale: scale,
            brightness: brightness,
            // The iPad's tab bar at the panel's foot.
            inset: isCupertino ? 72 : 0,
          );
          await _openFirst(tester);
          expect(tester.takeException(), isNull);
          final panel = tester.getRect(find.byKey(_panel));
          expect(panel.bottom, size.height);
          final surface = tester.widget<Material>(
            find
                .descendant(
                  of: find.byKey(_panel),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(
            surface.color,
            Theme.of(tester.element(find.byKey(_panel))).colorScheme.surface,
          );
          // The actions hold the foot, above the iPad's tab bar.
          final navigate = find.byKey(const ValueKey('spot-navigate'));
          expect(navigate.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(navigate).bottom,
            lessThanOrEqualTo(size.height - (isCupertino ? 72 : 0)),
          );
          // Every section can be reached.
          await tester.tap(find.byKey(const ValueKey('four-sign-where')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byKey(const ValueKey('spot-panel-scroll')),
            const Offset(0, -4000),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('資料與查核'), findsOneWidget);
        }, variant: _platforms);
      }
    }
  }

  group('分頁', () {
    for (final size in _tablets) {
      testWidgets('Android 平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '左側導覽軌，沒有底部分頁列，面板排在導覽軌之後', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final store = await _store(tester);
        await _pumpApp(tester, store, size: size);
        expect(tester.takeException(), isNull);
        expect(find.byType(M3ENavigationBar), findsNothing);
        final rail = tester.getRect(find.byType(M3ENavigationRail));
        expect(rail.left, 0);
        expect(rail.width, tabletRailWidth);
        expect(rail.bottom, size.height);
        final map = tester.getRect(find.byType(MapPage));
        expect(map.left, tabletRailWidth);
        expect(map.bottom, size.height);
        await _openFirst(tester);
        final panel = tester.getRect(find.byKey(_panel));
        expect(panel.left, tabletRailWidth + 16);
        expect(panel.width, sidePanelWidth);
        expect(panel.bottom, size.height);
        // The rail's tabs work, and each tab's panel takes the same place.
        await tester.tap(find.text('貢獻'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(_panel), findsNothing);
        final tab = tester.getRect(
          find.descendant(
            of: find.byType(MapPanel),
            matching: find.byKey(const ValueKey('side-panel')),
          ),
        );
        expect(tab.left, tabletRailWidth + 16);
        expect(tab.width, sidePanelWidth);
        expect(tab.bottom, size.height);
        expect(find.byType(DraggableScrollableSheet), findsNothing);
        await tester.tap(find.text('探索'));
        await tester.pumpAndSettle();
        expect(find.byType(MapPanel).hitTestable(), findsNothing);
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('iPad ${size.width.toInt()}×${size.height.toInt()}：'
          '分頁列膠囊在面板欄底部，面板底色在它後面', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final store = await _store(tester);
        await _pumpApp(tester, store, size: size);
        expect(tester.takeException(), isNull);
        expect(find.byType(M3ENavigationRail), findsNothing);
        final bar = tester.getRect(
          find.byKey(const ValueKey('tablet-tab-bar')),
        );
        expect(bar.left, 32);
        expect(bar.width, sidePanelWidth - 32);
        expect(bar.bottom, size.height - 16);
        // The map runs the whole window, behind the capsule.
        final map = tester.getRect(find.byType(MapPage));
        expect(map.left, 0);
        expect(map.bottom, size.height);
        await _openFirst(tester);
        expect(tester.takeException(), isNull);
        final panel = tester.getRect(find.byKey(_panel));
        expect(panel.left, 16);
        expect(panel.bottom, size.height);
        // The panel is behind the bar, its actions above it, and the bar
        // still takes taps.
        expect(panel.left, lessThan(bar.left));
        expect(panel.right, greaterThan(bar.right));
        final navigate = find.byKey(const ValueKey('spot-navigate'));
        expect(tester.getRect(navigate).bottom, lessThanOrEqualTo(bar.top));
        expect(navigate.hitTestable(), findsOneWidget);
        expect(find.text('個人中心').hitTestable(), findsOneWidget);
        await tester.tap(find.text('個人中心'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(_panel), findsNothing);
        final tab = tester.getRect(
          find.descendant(
            of: find.byType(MapPanel).hitTestable(),
            matching: find.byKey(const ValueKey('side-panel')),
          ),
        );
        expect(tab.left, 16);
        expect(tab.width, sidePanelWidth);
        expect(tab.bottom, size.height);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    for (final size in [..._phones, ..._splits]) {
      testWidgets('手機與窄視窗 ${size.width.toInt()}×${size.height.toInt()}：'
          '分頁列仍在底部，佔滿寬度', (tester) async {
        final store = await _store(tester);
        await _pumpApp(tester, store, size: size);
        expect(find.byType(M3ENavigationRail), findsNothing);
        expect(find.byKey(const ValueKey('tablet-tab-bar')), findsNothing);
        expect(tester.getRect(find.byType(MapPage)).left, 0);
        final bar = isCupertino
            ? find.byType(BottomNavigationBar)
            : find.byType(M3ENavigationBar);
        if (!isCupertino) {
          final rect = tester.getRect(bar);
          expect(rect.left, 0);
          expect(rect.width, size.width);
          expect(rect.bottom, size.height);
        }
      }, variant: _platforms);
    }
  });

  group('面板位置的 sheet（A7c ⑦⑧）', () {
    Future<void> pumpOpener(WidgetTester tester, Size size) async {
      _size(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAdaptiveSheet<void>(
                  context,
                  (_) => const Text('回報內容'),
                  sidePanel: true,
                ),
                child: const Text('開'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開'));
      await tester.pumpAndSettle();
    }

    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '在左側面板的位置升起，整個畫面加遮罩，點遮罩關閉', (tester) async {
        await pumpOpener(tester, size);
        expect(tester.takeException(), isNull);
        final panel = tester.getRect(find.byKey(const ValueKey('side-panel')));
        // After Android's rail; at the window's edge on iPad.
        expect(panel.left, isCupertino ? 16 : tabletRailWidth + 16);
        expect(panel.width, sidePanelWidth);
        expect(panel.top, 4 + 52 + 12);
        expect(panel.bottom, size.height);
        expect(find.text('回報內容'), findsOneWidget);
        final barrier = tester.widget<ModalBarrier>(
          find.byType(ModalBarrier).last,
        );
        expect(barrier.color, const Color(0x6116313a));
        await tester.tapAt(Offset(size.width - 20, size.height / 2));
        await tester.pumpAndSettle();
        expect(find.text('回報內容'), findsNothing);
      }, variant: _platforms);
    }

    testWidgets('手機：照舊是底部 sheet', (tester) async {
      await pumpOpener(tester, const Size(390, 844));
      expect(find.byKey(const ValueKey('side-panel')), findsNothing);
      expect(find.text('回報內容'), findsOneWidget);
      expect(tester.getRect(find.text('回報內容')).top, greaterThan(844 / 2));
    }, variant: _platforms);
  });
}
