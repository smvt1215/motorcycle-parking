import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/rider_meter_display.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/features/map/availability_capsule.dart';
import 'package:motorcycle_parking/features/map/google_parking_map.dart';
import 'package:motorcycle_parking/features/map/heavy_glyph.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/map/map_legend_page.dart';
import 'package:motorcycle_parking/features/map/map_page.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'app_test.dart' show testStore;

/// A stand-in drawing, not the licensed silhouette.
const _sampleSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<path d="M2 12h20v4H2z"/></svg>';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.assets);
  final Map<String, String> assets;
  @override
  Future<ByteData> load(String key) async {
    final text = assets[key];
    if (text == null) throw FlutterError('missing $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// Records which canvas calls a painter makes.
class _RecordingCanvas implements Canvas {
  final calls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    return null;
  }
}

/// Every tooltip in the semantics tree.
List<String> _tooltips(WidgetTester tester) => [
  for (final node
      in find.semantics
          .byPredicate((node) => node.tooltip.isNotEmpty)
          .evaluate())
    node.tooltip,
];

void main() {
  group('車友回報角標', () {
    testWidgets('量表格數等於空位多寡，說法不一並排兩個量表', (tester) async {
      Future<(int, int)> bars(RiderMeter meter) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(child: RiderMeterBadge(meter: meter)),
          ),
        );
        int count(String state) => find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('rider-bar-') &&
                  (w.key! as ValueKey<String>).value.endsWith(state),
            )
            .evaluate()
            .length;
        return (count('filled'), count('empty'));
      }

      expect(await bars(const RiderMeter(RiderLevel.plenty)), (3, 0));
      expect(await bars(const RiderMeter(RiderLevel.some)), (2, 1));
      expect(await bars(const RiderMeter(RiderLevel.almostFull)), (1, 2));
      expect(await bars(const RiderMeter(RiderLevel.full)), (0, 3));
      expect(
        await bars(
          const RiderMeter.conflict(RiderLevel.plenty, RiderLevel.full),
        ),
        (3, 3),
      );
      expect(
        tester.getSemantics(find.byType(RiderMeterBadge)).label,
        '車友回報說法不一：很多空位到已停滿，回報對不上，到場再確認',
      );
      expect(tester.takeException(), isNull);
    });

    test('有任何官方膠囊時不顯示角標', () {
      expect(riderMeterShown(const []), isTrue);
      for (final style in CapsuleStyle.values) {
        expect(
          riderMeterShown([
            AvailabilityCapsule(text: '剩 1', style: style, semantics: ''),
          ]),
          isFalse,
        );
      }
    });
  });

  group('重機剪影', () {
    tearDown(resetHeavyGlyph);

    test('沒有載入時不等待，Google 標記照樣畫', () async {
      await heavyGlyphSettled;
      expect(heavyGlyph.value, isNull);
    });

    testWidgets('建置沒有剪影時退回 two_wheeler，不拋錯', (tester) async {
      await tester.runAsync(() => loadHeavyGlyph(_Bundle(const {})));
      expect(heavyGlyph.value, isNull);
      expect(spaceBadgeIcon(SpaceBadge.heavyOnly), heavyGlyphFallback);
      expect(heavyGlyphFallback, Icons.two_wheeler);
      expect(spaceBadgeIcon(SpaceBadge.shared), Icons.two_wheeler);
      await tester.pumpWidget(
        const MaterialApp(
          home: SpotMarker(
            look: (EligibilityStatus.allowed, null),
            badge: SpaceBadge.heavyOnly,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('有剪影時載入並畫進徽章', (tester) async {
      await tester.runAsync(
        () => loadHeavyGlyph(_Bundle(const {heavyGlyphAsset: _sampleSvg})),
      );
      expect(heavyGlyph.value, isNotNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: SpotMarker(
            look: (EligibilityStatus.allowed, null),
            badge: SpaceBadge.shared,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // The badge draws the silhouette, never the two-wheeler glyph.
      for (final badge in [SpaceBadge.heavyOnly, SpaceBadge.shared]) {
        final canvas = _RecordingCanvas();
        paintSpaceBadge(
          canvas,
          const Rect.fromLTWH(0, 0, 19, 19),
          badge,
          glyph: heavyGlyph.value,
        );
        expect(canvas.calls, contains(#drawPicture));
        expect(canvas.calls, isNot(contains(#drawParagraph)));
      }
      // Without it, the fallback glyph is drawn as text and no picture.
      final fallback = _RecordingCanvas();
      paintSpaceBadge(
        fallback,
        const Rect.fromLTWH(0, 0, 19, 19),
        SpaceBadge.heavyOnly,
      );
      expect(fallback.calls, contains(#drawParagraph));
      expect(fallback.calls, isNot(contains(#drawPicture)));
    });
  });

  testWidgets('空位膠囊只在有即時資料時列出，汽車格膠囊只給大型重機', (tester) async {
    Future<void> pump(VehicleType vehicle, {required bool availability}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  MapLegendContent(
                    vehicle: vehicle,
                    availability: availability,
                  ),
                ],
              ),
            ),
          ),
        );
    await pump(VehicleType.heavy, availability: true);
    expect(find.text('汽車格的剩餘格數'), findsOneWidget);
    expect(find.textContaining('「大型重機」'), findsOneWidget);
    await pump(VehicleType.scooter, availability: true);
    expect(find.text('官方即時剩餘格數'), findsOneWidget);
    expect(find.text('汽車格的剩餘格數'), findsNothing);
    await pump(VehicleType.heavy, availability: false);
    expect(find.text('官方即時剩餘格數'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Google 標記圖依外觀逐一產生：六種徽章、無徽章與選取都畫得出來', (tester) async {
    for (final badge in [null, ...SpaceBadge.values]) {
      for (final selected in [false, true]) {
        final icon = await tester.runAsync(
          () => markerIcon(
            (EligibilityStatus.conditional, RuleRestriction.evOnly),
            badge,
            selected,
          ),
        );
        expect(icon, isNotNull);
      }
    }
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final size in const [
      Size(390, 844),
      Size(820, 1180),
      Size(1180, 820),
    ]) {
      final name =
          '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';
      testWidgets('地圖怎麼看整頁在 $name 不溢出，各段都在', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = (await tester.runAsync(testStore))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: const MaterialApp(home: MapLegendPage(fromMap: false)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scrollable = find.byType(Scrollable).first;
        for (final heading in [
          '停車點標記',
          '有條件的圖示',
          '格位徽章：圖示＝格位類別，白圓＝專用，方形＝共用',
          '車友回報角標（15 分鐘內，淺灰底量表）',
          '其他狀態',
        ]) {
          await tester.scrollUntilVisible(
            find.text(heading),
            200,
            scrollable: scrollable,
          );
          expect(tester.takeException(), isNull);
        }
        for (final label in [
          '重機專用格',
          '普大共用格',
          '汽車格',
          '汽機車共用格',
          '身障格',
          '充電格',
          '長按地圖',
        ]) {
          await tester.scrollUntilVisible(
            find.text(label),
            200,
            scrollable: scrollable,
          );
        }
        expect(find.text('不可停'), findsNothing);
        expect(find.text('身障機車專用格'), findsNothing);
        // The back control is a full-size target.
        final back = platform == TargetPlatform.iOS
            ? find.text('個人中心')
            : find.byTooltip('返回');
        expect(back, findsOneWidget);
        final box = tester.getSize(
          platform == TargetPlatform.iOS
              ? find.ancestor(of: back, matching: find.byType(Semantics)).first
              : back,
        );
        expect(box.height, greaterThanOrEqualTo(44));
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('${platform.name}：從個人中心與地圖按鈕都推入同一頁，分頁列仍在', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
      final router = GoRouter.of(tester.element(find.byType(Navigator).last));
      router.go('/parking');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('地圖怎麼看'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('地圖怎麼看'));
      await tester.pumpAndSettle();
      expect(find.byType(MapLegendPage), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/parking/legend',
      );
      // The tab bar stays below the pushed page.
      expect(find.text('探索'), findsWidgets);
      expect(find.text('貢獻'), findsWidgets);
      if (platform == TargetPlatform.iOS) {
        await tester.tap(
          find.descendant(
            of: find.byType(MapLegendPage),
            matching: find.text('個人中心'),
          ),
        );
      } else {
        await tester.tap(find.byTooltip('返回'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(MapLegendPage), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/parking');

      router.go('/map');
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('map-legend-button'));
      expect(
        tester.getSize(button).height,
        platform == TargetPlatform.iOS ? 44 : 48,
      );
      final semantics = tester.ensureSemantics();
      expect(_tooltips(tester), contains('地圖怎麼看'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(MapLegendPage), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/map/legend',
      );
      // The covered map is neither read out nor animated.
      expect(_tooltips(tester), isNot(contains('地圖怎麼看')));
      expect(
        TickerMode.valuesOf(tester.element(find.byType(MapPage))).enabled,
        isFalse,
      );
      expect(find.text('貢獻'), findsWidgets);
      if (platform == TargetPlatform.iOS) {
        expect(find.text('探索'), findsWidgets);
        await tester.tap(
          find.descendant(
            of: find.byType(MapLegendPage),
            matching: find.text('探索'),
          ),
        );
      } else {
        await tester.tap(find.byTooltip('返回'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(MapLegendPage), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/map');
      expect(_tooltips(tester), contains('地圖怎麼看'));
      expect(
        TickerMode.valuesOf(tester.element(find.byType(MapPage))).enabled,
        isTrue,
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('詳情開啟時推入圖例：sheet 隱藏不擋點擊，返回後 sheet 與選取都還在', (tester) async {
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
    final spot = store.spots.first;
    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(LatLng(spot.lat, spot.lng), 18);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(FlutterMap),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Semantics &&
                  (w.properties.label ?? '').startsWith('${spot.name} '),
            ),
          )
          .hitTestable()
          .first,
    );
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('parking-spot-sheet'));
    final selected = find.byKey(const ValueKey('selected-spot-marker'));
    expect(sheet.hitTestable(), findsOneWidget);
    expect(selected, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-legend-button')));
    await tester.pumpAndSettle();
    expect(find.byType(MapLegendPage), findsOneWidget);
    // The sheet is hidden, not closed: nothing of it takes taps.
    expect(sheet.hitTestable(), findsNothing);
    expect(sheet, findsNothing);
    expect(find.text('貢獻').hitTestable(), findsOneWidget);
    final footnote = find.text('社群資訊可能有延遲，停車前請確認現場標示。');
    await tester.scrollUntilVisible(
      footnote,
      200,
      scrollable: find
          .descendant(
            of: find.byType(MapLegendPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(footnote);
    await tester.pumpAndSettle();
    expect(footnote.hitTestable(), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(MapLegendPage), findsNothing);
    expect(sheet.hitTestable(), findsOneWidget);
    expect(selected, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text(spot.name)),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
