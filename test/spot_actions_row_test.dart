import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/map/map_page.dart';
import 'package:motorcycle_parking/features/map/spot_preview.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'spot_detail_fixtures.dart';

/// The one-row action bar and the preview that grows to show its plates
/// (#414, canvas v211 A15a–d), on iOS and Android, phones and tablets, at
/// text scales 1.0 to 2.0.
const _rail = ValueKey('spot-actions-rail');
const _fadeStart = ValueKey('spot-actions-fade-start');
const _fadeEnd = ValueKey('spot-actions-fade-end');
const _navigate = ValueKey('spot-navigate');
const _report = ValueKey('spot-report');
const _suggest = ValueKey('spot-suggest');
const _overlay = ValueKey('spot-sheet-overlay');

final _platforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

/// A spot a rider can report on: the 回報現場狀況 button shows.
final _reportable = ParkingSpot.fromJson({
  ...detailLotJson,
  'id': '11111111-1111-4111-8111-111111111111',
});

Future<void> _pumpBar(
  WidgetTester tester, {
  double width = 390,
  double edge = 20,
  bool street = false,
  bool report = true,
  double scale = 1,
  Key? key,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 200);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SpotPreviewActions(
            key: key,
            street: street,
            edge: edge,
            onNavigate: () {},
            onReport: report ? () {} : null,
            onSuggest: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<AppStore> _mapStore(WidgetTester tester) async {
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

/// The map as the shell shows it, with [inset] standing for the floating
/// tab bar, and a spot opened.
Future<void> _openOnMap(
  WidgetTester tester,
  AppStore store, {
  required Size size,
  required double inset,
  required double scale,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: MaterialApp(
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
  await tester.tap(find.byType(SpotMarker).first, warnIfMissed: false);
  await tester.pumpAndSettle();
  expect(find.byKey(_overlay), findsOneWidget);
}

Iterable<Rect> _plates(WidgetTester tester) => find
    .byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('four-sign-');
    })
    .evaluate()
    .where(
      (e) => (e.widget.key! as ValueKey<String>).value != 'four-sign-current',
    )
    .map((e) => tester.getRect(find.byWidget(e.widget)));

ScrollPosition _railPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: find.byKey(_rail), matching: find.byType(Scrollable)),
    )
    .position;

void main() {
  group('按鈕列', () {
    testWidgets('放不下：三顆一起滑，導航在最左、不固定，兩端淡出跟著走', variant: _platforms, (
      tester,
    ) async {
      await _pumpBar(tester);
      expect(find.byKey(_rail), findsOneWidget);
      // All one row, 導航 first at the margin.
      final nav = tester.getRect(find.byKey(_navigate));
      expect(nav.left, 20);
      expect(tester.getRect(find.byKey(_report)).top, nav.top);
      expect(tester.getRect(find.byKey(_suggest)).top, nav.top);
      // The last button is cut at the edge, and that edge fades.
      final suggest = tester.getRect(find.byKey(_suggest));
      expect(suggest.left, lessThan(390));
      expect(suggest.right, greaterThan(390));
      expect(find.byKey(_fadeEnd), findsOneWidget);
      expect(find.byKey(_fadeStart), findsNothing);

      await tester.drag(find.byKey(_rail), const Offset(-600, 0));
      await tester.pumpAndSettle();
      // 導航 slides away with the others; the last keeps the page margin.
      expect(tester.getRect(find.byKey(_navigate)).left, lessThan(20));
      expect(tester.getRect(find.byKey(_suggest)).right, 370);
      expect(find.byKey(_fadeEnd), findsNothing);
      expect(find.byKey(_fadeStart), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('開另一個停車點回到最左', variant: _platforms, (tester) async {
      await _pumpBar(tester, key: const ValueKey('a'));
      await tester.drag(find.byKey(_rail), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(_railPosition(tester).pixels, greaterThan(0));
      await _pumpBar(tester, key: const ValueKey('b'));
      expect(_railPosition(tester).pixels, 0);
      expect(tester.getRect(find.byKey(_navigate)).left, 20);
    });

    testWidgets('路邊點導航差一點放不下：縮內距，同一排不滑', variant: _platforms, (tester) async {
      for (final width in [390.0, 375.0, 360.0]) {
        await _pumpBar(tester, width: width, street: true);
        expect(find.byKey(_rail), findsNothing, reason: '$width');
        expect(
          tester.getRect(find.byKey(_suggest)).right,
          lessThanOrEqualTo(width - 20),
          reason: '$width',
        );
        for (final label in ['導航', '回報現場狀況', '修改建議']) {
          expect(
            tester.getSize(find.text(label)).height,
            lessThan(24),
            reason: '$label 在 $width 不換行',
          );
        }
        expect(tester.takeException(), isNull, reason: '$width');
      }
    });

    testWidgets('#466 各手機寬度與字級：按鈕文字都不截成刪節號', variant: _platforms, (
      tester,
    ) async {
      for (final width in [360.0, 390.0, 411.0, 430.0]) {
        for (final scale in [1.0, 1.3, 2.0]) {
          for (final street in [false, true]) {
            await _pumpBar(tester, width: width, scale: scale, street: street);
            final where = '$width 字級 $scale ${street ? '路邊' : '路外'}';
            for (final label in [
              SpotPreviewActions.navigateLabel(street: street),
              '回報現場狀況',
              '修改建議',
            ]) {
              final paragraph = tester.renderObject<RenderParagraph>(
                find.text(label),
              );
              expect(paragraph.didExceedMaxLines, isFalse, reason: where);
            }
            expect(tester.takeException(), isNull, reason: where);
          }
        }
      }
    });

    testWidgets('#466 411 寬 Android：導航到入口完整、縮內距同一排不滑', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await _pumpBar(tester, width: 411);
      expect(find.byKey(_rail), findsNothing);
      // The label gets its whole width, letter spacing included.
      final label = tester.renderObject<RenderParagraph>(find.text('導航到入口'));
      expect(
        label.size.width,
        greaterThanOrEqualTo(label.getMaxIntrinsicWidth(double.infinity)),
      );
      expect(
        tester.getRect(find.byKey(_suggest)).right,
        lessThanOrEqualTo(391),
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('兩顆放得下：不滑，導航撐滿剩下寬度', variant: _platforms, (tester) async {
      await _pumpBar(tester, report: false);
      expect(find.byKey(_rail), findsNothing);
      expect(tester.getRect(find.byKey(_navigate)).left, 20);
      expect(tester.getRect(find.byKey(_suggest)).right, 370);
      expect(find.byKey(_fadeEnd), findsNothing);
    });

    testWidgets('平板寬度：三顆同一排不滑', variant: _platforms, (tester) async {
      await _pumpBar(tester, width: 640);
      expect(find.byKey(_rail), findsNothing);
      expect(tester.getRect(find.byKey(_suggest)).right, 620);
    });

    testWidgets('按鈕文字 16pt，放大字級時按鈕跟著長高、仍單排', variant: _platforms, (
      tester,
    ) async {
      await _pumpBar(tester);
      expect(tester.widget<Text>(find.text('修改建議')).style!.fontSize, 16);
      await _pumpBar(tester, scale: 2);
      expect(find.byKey(_rail), findsOneWidget);
      final nav = tester.getRect(find.byKey(_navigate));
      expect(tester.getRect(find.byKey(_report)).top, nav.top);
      expect(tester.takeException(), isNull);
    });
  });

  group('預覽卡高度', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    const sizes = {
      '390×844': (Size(390, 844), 83.0),
      '402×874': (Size(402, 874), 97.0),
      'iPhone SE 375×667': (Size(375, 667), 63.0),
      '360×800': (Size(360, 800), 0.0),
      // A wide window short of the tablet layout (Split View) keeps the
      // card, 640 at most; a tablet shows the details in its side panel
      // instead (tablet_layout_test).
      '寬視窗 679×1180': (Size(679, 1180), 74.0),
    };

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      for (final MapEntry(key: name, value: (size, inset)) in sizes.entries) {
        for (final scale in [1.0, 1.3, 1.6, 2.0]) {
          testWidgets(
            '${platform.name} $name 字級 $scale：42–62%、按鈕固定在分頁列上方、路牌看得到',
            (tester) async {
              debugDefaultTargetPlatformOverride = platform;
              final store = await _mapStore(tester);
              await _openOnMap(
                tester,
                store,
                size: size,
                inset: inset,
                scale: scale,
              );
              expect(tester.takeException(), isNull);

              final overlay = tester.getRect(find.byKey(_overlay));
              // The bar's position comes from the measured inset.
              expect(overlay.bottom, size.height - inset);
              final sheet = find.descendant(
                of: find.byKey(_overlay),
                matching: find.byType(Material),
              );
              final card = tester.getRect(sheet.first);
              final share = card.height / overlay.height;
              expect(share, greaterThanOrEqualTo(.42 - .001));
              expect(share, lessThanOrEqualTo(.62 + .001));

              // Pinned: above the tab bar and tappable without scrolling.
              final nav = tester.getRect(find.byKey(_navigate));
              expect(nav.bottom, lessThanOrEqualTo(overlay.bottom));
              expect(nav.height, greaterThanOrEqualTo(44));
              expect(
                find.byKey(_navigate).hitTestable(),
                findsOneWidget,
                reason: '按鈕列沒被遮住',
              );

              final footerTop = nav.top - 10;
              final lowest = _plates(tester)
                  .map((r) => r.bottom)
                  .reduce((a, b) => a > b ? a : b);
              final handle = find.byKey(const ValueKey('spot-sheet-handle'));
              if (handle.evaluate().isEmpty) {
                // The card has grown to hold every plate.
                expect(lowest, lessThanOrEqualTo(footerTop));
              } else {
                // At the 62% limit the plates scroll inside the card, and
                // the bar stays put.
                expect(share, closeTo(.62, .001));
                await tester.dragFrom(
                  Offset(card.center.dx, card.top + 100),
                  const Offset(0, -400),
                );
                await tester.pumpAndSettle();
                expect(tester.getRect(sheet.first).height, card.height);
                expect(tester.getRect(find.byKey(_navigate)), nav);
                final moved = _plates(tester)
                    .map((r) => r.bottom)
                    .reduce((a, b) => a > b ? a : b);
                expect(moved, lessThanOrEqualTo(footerTop));
              }
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
              debugDefaultTargetPlatformOverride = null;
            },
          );
        }
      }
    }
  });

  group('預覽卡到上限', () {
    Finder scrollables() => find.descendant(
      of: find.byKey(const ValueKey('parking-spot-sheet')),
      matching: find.byType(Scrollable),
    );

    testWidgets('拉把手進整頁；卡片內捲過再進整頁，內容從頂端開始', variant: _platforms, (
      tester,
    ) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(
        tester,
        store,
        detailLot,
        size: const Size(375, 667),
        scale: 2,
        full: false,
      );
      final handle = find.byKey(const ValueKey('spot-sheet-handle'));
      expect(handle, findsOneWidget);
      final top = tester.getRect(find.byKey(_navigate)).top;
      await tester.dragFrom(
        tester.getCenter(find.text(detailLot.name)),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      final inner = tester.state<ScrollableState>(scrollables().at(1));
      expect(inner.position.pixels, greaterThan(0));
      expect(tester.getRect(find.byKey(_navigate)).top, top);
      expect(find.byKey(const ValueKey('spot-detail-header')), findsNothing);

      // Back at the top, the handle is in reach again.
      inner.position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.drag(handle, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-detail-header')), findsOneWidget);
      expect(
        tester.state<ScrollableState>(scrollables().at(1)).position.pixels,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('在卡片內捲過，點路牌進整頁也從段落開始、不留位移', variant: _platforms, (
      tester,
    ) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(
        tester,
        store,
        detailLot,
        size: const Size(375, 667),
        scale: 2,
        full: false,
      );
      await tester.dragFrom(
        tester.getCenter(find.text(detailLot.name)),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('four-sign-verdict')));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollables().at(1)).position.pixels,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('卡片到上限：整頁慢慢往下拉，回到預覽卡', variant: _platforms, (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(
      tester,
      store,
      detailLot,
      size: const Size(375, 667),
      scale: 2,
    );
    const header = ValueKey('spot-detail-header');
    expect(find.byKey(header), findsOneWidget);
    // Slowly: the sheet leaves the full page many frames before the finger
    // lifts, and the drag has to outlive that change.
    final gesture = await tester.startGesture(const Offset(187, 420));
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(header), findsNothing);
    expect(find.byKey(const ValueKey('spot-sheet-handle')), findsOneWidget);
    // At rest the plates scroll inside the card again, the card stays put.
    final top = tester.getRect(find.byKey(_navigate)).top;
    await tester.dragFrom(
      tester.getCenter(find.text(detailLot.name)),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(header), findsNothing);
    expect(tester.getRect(find.byKey(_navigate)).top, top);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('地圖置中跟著卡片實際高度', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = await _mapStore(tester);
    await _openOnMap(
      tester,
      store,
      size: const Size(375, 667),
      inset: 63,
      scale: 2,
    );
    final card = tester.getRect(
      find
          .descendant(of: find.byKey(_overlay), matching: find.byType(Material))
          .first,
    );
    expect(
      card.height / tester.getRect(find.byKey(_overlay)).height,
      closeTo(.62, .001),
    );
    final marker = tester.getRect(
      find.byWidgetPredicate((w) => w is SpotMarker && w.selected),
    );
    // At the default 42% it would sit about 60 points lower, under the card.
    expect(marker.center.dy, lessThan(card.top));
    expect(marker.center.dy, closeTo(card.top / 2, 30));

    // Tapping the marker already selected centres it above the same card,
    // not above the default 42% one: the open sheet reports no new height.
    // The marker's own tap, called directly: a test tap at its centre does
    // not reach it on this screen.
    tester
        .widget<GestureDetector>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('selected-spot-marker')),
                matching: find.byType(GestureDetector),
              )
              .first,
        )
        .onTap!();
    await tester.pumpAndSettle();
    final again = tester.getRect(
      find.byWidgetPredicate((w) => w is SpotMarker && w.selected),
    );
    expect(again.center.dy, closeTo(marker.center.dy, 1));
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('詳情頁', () {
    testWidgets('手機：和預覽卡同一條按鈕列，三顆一起滑', variant: _platforms, (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, _reportable, size: const Size(360, 800));
      expect(find.byKey(const ValueKey('spot-detail-header')), findsOneWidget);
      expect(find.byKey(_rail), findsOneWidget);
      final nav = tester.getRect(find.byKey(_navigate));
      expect(nav.left, 16);
      expect(tester.getRect(find.byKey(_suggest)).top, nav.top);
      await tester.drag(find.byKey(_rail), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(_suggest)).right, 360 - 16);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('平板：三顆同一排不滑', variant: _platforms, (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, _reportable, size: const Size(820, 1180));
      expect(find.byKey(_rail), findsNothing);
      expect(find.byKey(_report).hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('放大字級仍單排', variant: _platforms, (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, _reportable, scale: 1.3);
      final nav = tester.getRect(find.byKey(_navigate));
      expect(tester.getRect(find.byKey(_report)).top, nav.top);
      expect(find.byKey(_navigate).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
