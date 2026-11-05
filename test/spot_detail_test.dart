import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/four_sign_plates.dart';

import 'spot_detail_fixtures.dart';

/// The full-page details (#190 PR-D; canvas v154 A2, A4, A8, A9, A10,
/// A12): pulled up from the preview, the four plates as a table of
/// contents, the four sections, the address, and the photo viewer, on
/// phones and iPads, iOS and Android, large text and dark.
void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.iOS,
    TargetPlatform.android,
  });
  const sizes = {
    '手機 390': Size(390, 844),
    'iPad 直向': Size(820, 1180),
    'iPad 橫向': Size(1180, 820),
  };
  double minTarget() =>
      defaultTargetPlatform == TargetPlatform.iOS ? 44.0 : 48.0;

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key), skipOffstage: false)).data!;

  Finder toc(String face) => find.descendant(
    of: find.byKey(const ValueKey('spot-detail-toc')),
    matching: find.byKey(ValueKey('four-sign-$face')),
  );

  /// Whether the table of contents marks [face].
  bool marked(WidgetTester tester, String face) => find
      .descendant(
        of: toc(face),
        matching: find.byKey(const ValueKey('four-sign-current')),
      )
      .evaluate()
      .isNotEmpty;

  Future<void> show(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(key)),
      200,
      scrollable: detailScrollable,
    );
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in sizes.entries) {
    testWidgets('$name：拉起整頁，返回、目錄、收藏分享與動作列點得到', variant: platforms, (
      tester,
    ) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailLot, size: size);
      expect(tester.takeException(), isNull);
      // The full page: its header replaces the preview's.
      expect(find.byKey(const ValueKey('spot-detail-header')), findsOneWidget);
      expect(find.byTooltip('關閉詳情'), findsNothing);
      void tappable(Finder f, String reason) {
        expect(f.hitTestable(), findsOneWidget, reason: reason);
        final box = tester.getSize(f);
        expect(box.height, greaterThanOrEqualTo(minTarget()), reason: reason);
        expect(box.width, greaterThanOrEqualTo(minTarget()), reason: reason);
      }

      for (final key in [
        'spot-detail-back',
        'spot-detail-favorite',
        'spot-detail-share',
        'spot-navigate',
        'spot-suggest',
      ]) {
        tappable(find.byKey(ValueKey(key)), key);
      }
      for (final face in ['verdict', 'seat', 'fee', 'where']) {
        // The plate itself is a touch target tall (its mark sits below).
        final plate = toc(face);
        expect(plate.hitTestable(), findsOneWidget, reason: face);
        expect(
          tester.getSize(plate).height,
          greaterThanOrEqualTo(minTarget()),
          reason: face,
        );
      }
      // iOS: chevron and 返回; Android: arrow_back (FIX-DECISIONS).
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        expect(find.text('返回'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      } else {
        expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      }
      // 返回 closes the details.
      await tester.tap(find.byKey(const ValueKey('spot-detail-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('parking-spot-sheet')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('預覽往上拉才換成整頁；往下拉回到預覽', (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot, full: false);
    expect(find.byKey(const ValueKey('spot-detail-header')), findsNothing);
    expect(find.byTooltip('關閉詳情'), findsOneWidget);
    await pullUp(tester);
    expect(find.byKey(const ValueKey('spot-detail-header')), findsOneWidget);
    // Pulling the page down from its top returns to the preview.
    await tester.drag(detailScrollable, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spot-detail-header')), findsNothing);
    expect(find.byTooltip('關閉詳情'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('目錄：點路牌跳到該段並標記，捲動時標記跟著段落', variant: platforms, (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot);
    expect(marked(tester, 'verdict'), isTrue);
    final fees = find.text('怎麼算錢（大型重機現在可停的分區）');
    await tester.tap(toc('fee'));
    await tester.pumpAndSettle();
    // The section starts right under the pinned header.
    expect(fees.hitTestable(), findsOneWidget);
    final header = tester.getRect(
      find.byKey(const ValueKey('spot-detail-header')),
    );
    expect(tester.getRect(fees).top - header.bottom, lessThan(48));
    expect(marked(tester, 'fee'), isTrue);
    expect(marked(tester, 'verdict'), isFalse);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(toc('fee')),
      matchesSemantics(
        label: '怎麼算錢：每小時 20 元，當日上限 100 元',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    handle.dispose();
    await tester.tap(toc('where'));
    await tester.pumpAndSettle();
    expect(find.text('停哪裡（大型重機）').hitTestable(), findsOneWidget);
    expect(marked(tester, 'where'), isTrue);
    // Scrolling back to the top marks 能不能停 again.
    await tester.drag(detailScrollable, const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(marked(tester, 'verdict'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('預覽的路牌點了也會拉起整頁並跳到該段', (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot, full: false);
    await tester.tap(find.byKey(const ValueKey('four-sign-where')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spot-detail-header')), findsOneWidget);
    expect(find.text('停哪裡（大型重機）').hitTestable(), findsOneWidget);
    expect(marked(tester, 'where'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('官方停車場（A2、A8）：大型重機平日 14:20', () {
    testWidgets('能不能停：判定、限時延長、禁停、共用，只列重機適用的規定', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailLot);
      expect(text(tester, 'spot-decision-label'), '大型重機現在有條件');
      expect(text(tester, 'spot-decision-basis'), '依政府公開資料');
      // The rows say what limits it; the reason is not repeated above.
      expect(
        find.byKey(const ValueKey('spot-decision-explanation')),
        findsNothing,
      );
      expect(text(tester, 'detail-rule-limit'), 'B2 重機專區：每次限停 2 小時，可延長 1 次');
      expect(
        text(tester, 'detail-rule-noParking'),
        'B2 重機專區：23:00–隔日 07:00、假日 全天',
      );
      expect(text(tester, 'detail-rule-shared'), 'B3 汽車區：20:00–23:00 開放大型重機');
      expect(text(tester, 'detail-rules-scope'), '只列大型重機適用的規定');
      // B1 is closed to heavy bikes: none of its rules is listed.
      expect(find.textContaining('B1 機車區：'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('有沒有位：逐區官方列，留給車友回報', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailLot);
      await show(tester, 'detail-seat-row-1');
      expect(find.text('有沒有位（大型重機能停的分區）'), findsOneWidget);
      expect(find.text('B2 重機專區'), findsWidgets);
      expect(find.text('汽機車共用格・20:00–23:00 才開放大型重機'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-seat-official-0')),
          matching: find.text('空位未知'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('detail-seat-row-2')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('怎麼算錢：只列現在可停的區，全場同價、非開放時段、另有 B3', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailLot);
      await show(tester, 'detail-fee-card-0');
      expect(find.text('怎麼算錢（大型重機現在可停的分區）'), findsOneWidget);
      expect(find.text('B2 重機專區　重機專用格'), findsOneWidget);
      expect(text(tester, 'detail-fee-main'), '每小時 20 元');
      expect(text(tester, 'detail-fee-detail'), '現在適用，全天；當日上限 100 元（零時重算）');
      expect(find.byKey(const ValueKey('detail-fee-card-1')), findsNothing);
      expect(find.text('全場同價'), findsOneWidget);
      expect(find.text('23:00–隔日 07:00、假日 全天'), findsOneWidget);
      expect(find.text('B1 機車區（一般機車格）'), findsOneWidget);
      expect(
        find.text('另有 B3 汽車區（汽機車共用格），20:00–23:00 才開放大型重機，同樣每小時 20 元。'),
        findsOneWidget,
      );
      expect(find.text('請以現場公告為準'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('停哪裡：入口、分區卡、另有 B1 不能停、照片與地址', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailLot);
      await show(tester, 'detail-coordinates');
      expect(find.text('松壽路側車道下坡，機車走右側'), findsOneWidget);
      expect(find.text('電梯旁，地面標「重機」'), findsOneWidget);
      expect(find.text('20:00–23:00 才開放大型重機'), findsOneWidget);
      expect(text(tester, 'detail-where-closed'), '另有 B1 機車區（一般機車格），大型重機不能停');
      expect(find.text('點照片可放大'), findsOneWidget);
      // Five photos: three, then 「+2」.
      expect(find.text('+2'), findsOneWidget);
      expect(text(tester, 'detail-address'), '臺北市信義區松壽路');
      expect(text(tester, 'detail-coordinates'), '25.036000, 121.567000');
      // The sources come last, in small print.
      final address = tester.getRect(
        find.byKey(const ValueKey('detail-address')),
      );
      await tester.scrollUntilVisible(
        find.text('資料來源'),
        200,
        scrollable: detailScrollable,
      );
      expect(
        tester.getRect(find.text('資料來源')).top,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('detail-address'))).top,
        ),
      );
      expect(address, isNotNull);
      expect(
        tester.widget<Text>(find.text('資料來源')).style?.fontSize ??
            Theme.of(tester.element(find.text('資料來源')))
                .textTheme
                .bodySmall!
                .fontSize,
        lessThanOrEqualTo(12),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('晚上 21:00 兩區同時可停，官方剩餘逐區並列（A12）', (tester) async {
      final store = await detailStore(
        tester,
        VehicleType.heavy,
        now: detailNight,
      );
      AvailabilitySnapshot count(AvailabilityVehicle v, int available) =>
          AvailabilitySnapshot(
            spotId: 'songshou',
            vehicle: v,
            provider: '臺北市停管處',
            window: AvailabilityWindow.taipei,
            total: 40,
            available: available,
            sourceUpdatedAt: detailNight.subtract(const Duration(minutes: 2)),
          );
      store.availability = {
        'songshou': SpotAvailability([
          count(AvailabilityVehicle.heavy, 4),
          count(AvailabilityVehicle.car, 9),
        ]),
      };
      await openDetail(tester, store, detailLot);
      await show(tester, 'detail-seat-row-1');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-seat-official-0')),
          matching: find.text('剩 4 格'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-seat-official-1')),
          matching: find.text('剩 9 格'),
        ),
        findsOneWidget,
      );
      expect(find.text('2 分鐘前'), findsNWidgets(2));
      // Both zones open now: each its card (B2 keeps its 禁停 times).
      await show(tester, 'detail-fee-card-1');
      expect(find.byKey(const ValueKey('detail-fee-later-0')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('路邊（A10）：南京東路三段，大型重機平日 14:20', () {
    testWidgets('能不能停的規則、逐段有沒有位與逐段費率', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailStreet);
      expect(
        text(tester, 'detail-rule-limit'),
        '南側汽機車共用格：平日 07:00–20:00 每次限停 2 小時，可延長 1 次',
      );
      expect(text(tester, 'detail-rule-noParking'), '北側一般機車格：週一 06:00–08:00');
      await show(tester, 'detail-seat-row-1');
      expect(find.text('有沒有位（大型重機能停的路段）'), findsOneWidget);
      expect(find.text('共 18 格'), findsOneWidget);
      expect(find.text('共 12 格'), findsOneWidget);
      // Only the segments the heavy bike may use: not 北側汽機車共用格.
      expect(find.byKey(const ValueKey('detail-seat-row-2')), findsNothing);
      await show(tester, 'detail-fee-card-1');
      expect(find.text('怎麼算錢（大型重機現在可停的路段）'), findsOneWidget);
      final cards = find.byKey(const ValueKey('detail-fee-main'));
      expect(tester.widgetList<Text>(cards).map((t) => t.data), [
        '每小時 20 元',
        '每小時 30 元',
      ]);
      expect(find.text('現在適用，08:00–20:00'), findsOneWidget);
      expect(find.text('20:00–隔日 08:00'), findsOneWidget);
      expect(find.text('免費'), findsOneWidget);
      expect(find.text('週一 06:00–08:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('停哪裡選定一段：能不能停路牌與判定卡改看選定段', variant: platforms, (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailStreet);
      await show(tester, 'detail-where-card-1');
      expect(find.text('建國北路口 → 松江路口・一般機車格・收費格・共 18 格'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-where-selected')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('detail-where-card-1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('detail-where-selected')),
        findsOneWidget,
      );
      expect(find.text('目前選定'), findsOneWidget);
      expect(
        find.descendant(of: toc('verdict'), matching: find.text('有條件')),
        findsNothing,
      );
      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(toc('verdict')).label,
        '能不能停：限時段，目前選定的南側汽機車共用格',
      );
      handle.dispose();
      expect(text(tester, 'spot-decision-label'), '大型重機現在有條件');
      expect(
        text(tester, 'spot-decision-explanation'),
        '選定的南側汽機車共用格平日 07:00–20:00 每次限停 2 小時，可延長 1 次；北側一般機車格現在可停',
      );
      // Tapping it again lets go.
      await show(tester, 'detail-where-card-1');
      await tester.tap(find.byKey(const ValueKey('detail-where-card-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-where-selected')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('沒有路段資料的路邊點：整個點當一段，沒有空值', (tester) async {
      final store = await detailStore(tester, VehicleType.heavy);
      await openDetail(tester, store, detailBay);
      expect(text(tester, 'spot-decision-label'), '大型重機現在可停');
      expect(find.byKey(const ValueKey('detail-seat-whole')), findsOneWidget);
      expect(find.text('共 24 格'), findsWidgets);
      await show(tester, 'detail-where-card-0');
      expect(find.text('一般機車格'), findsWidgets);
      expect(find.text('民生東路二段：松江路口至伊通街口，南側・一般機車格・收費格・共 24 格'), findsOneWidget);
      expect(text(tester, 'detail-fee-main'), '每小時 20 元');
      expect(find.byKey(const ValueKey('detail-where-card-1')), findsNothing);
      for (final empty in ['null', '（）', '：，']) {
        expect(find.textContaining(empty), findsNothing, reason: empty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('收藏與分享在標題列，按收藏會加入收藏', variant: platforms, (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot);
    final name = tester.getRect(find.byKey(const ValueKey('spot-detail-name')));
    final favorite = tester.getRect(
      find.byKey(const ValueKey('spot-detail-favorite')),
    );
    final share = tester.getRect(
      find.byKey(const ValueKey('spot-detail-share')),
    );
    expect(favorite.left, greaterThanOrEqualTo(name.left));
    expect(share.left, greaterThan(favorite.left));
    expect(share.top, favorite.top);
    expect(store.favorites, isEmpty);
    await tester.tap(find.byKey(const ValueKey('spot-detail-favorite')));
    await tester.pumpAndSettle();
    expect(store.favorites.map((s) => s.id), ['songshou']);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('複製地址與座標', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot);
    await show(tester, 'detail-copy');
    await tester.tap(find.byKey(const ValueKey('detail-copy')));
    await tester.pumpAndSettle();
    expect(copied, '松壽地下停車場\n臺北市信義區松壽路\n25.036000, 121.567000');
    expect(find.byKey(const ValueKey('detail-copied')), findsOneWidget);
    // The note goes after a few seconds.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('detail-copied')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('照片全螢幕：張數、左右滑、縮圖列與關閉（A9）', variant: platforms, (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot);
    await show(tester, 'spot-photo-thumb-1');
    await tester.tap(find.byKey(const ValueKey('spot-photo-thumb-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spot-photo-viewer')), findsOneWidget);
    expect(find.text('2 / 5'), findsOneWidget);
    await tester.fling(
      find.byKey(const ValueKey('spot-photo-pages')),
      const Offset(-400, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.text('3 / 5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('spot-photo-pick-4')));
    await tester.pumpAndSettle();
    expect(find.text('5 / 5'), findsOneWidget);
    final close = find.byKey(const ValueKey('spot-photo-close'));
    expect(tester.getSize(close).height, greaterThanOrEqualTo(minTarget()));
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spot-photo-viewer')), findsNothing);
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    // 「+2」 opens the fourth photo.
    await tester.tap(find.byKey(const ValueKey('spot-photo-thumb-3')));
    await tester.pumpAndSettle();
    expect(find.text('4 / 5'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final MapEntry(key: name, value: size) in sizes.entries) {
    testWidgets('$name 大字 2.0：不溢出，目錄 2×2，動作列點得到', variant: platforms, (
      tester,
    ) async {
      final store = await detailStore(tester, VehicleType.heavy);
      for (final spot in [detailLot, detailStreet, detailBay]) {
        await openDetail(tester, store, spot, size: size, scale: 2);
        expect(tester.takeException(), isNull, reason: spot.name);
        expect(
          tester.getRect(toc('fee')).top,
          greaterThan(tester.getRect(toc('verdict')).bottom),
          reason: spot.name,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('detail-coordinates')),
          200,
          scrollable: detailScrollable,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: spot.name);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('spot-navigate')),
          200,
          scrollable: detailScrollable,
        );
        expect(
          find.byKey(const ValueKey('spot-navigate')).hitTestable(),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  for (final MapEntry(key: name, value: size) in sizes.entries) {
    testWidgets(
      '$name 深色：路牌與判定卡用固定色，不跟 dynamic color（A4）',
      variant: platforms,
      (tester) async {
        final store = await detailStore(tester, VehicleType.heavy);
        await openDetail(tester, store, detailLot, size: size, dark: true);
        expect(tester.takeException(), isNull);
        // A solid plate keeps its colour; the card its dark tint and text.
        final plate = tester.widget<Container>(
          find
              .descendant(of: toc('verdict'), matching: find.byType(Container))
              .first,
        );
        expect(
          (plate.decoration! as BoxDecoration).color,
          PlateColors.conditional,
        );
        final card = tester.widget<Container>(
          find.byKey(const ValueKey('spot-decision')),
        );
        expect(
          (card.decoration! as BoxDecoration).color,
          const Color(0xff352914),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('spot-decision-label')))
              .style!
              .color,
          const Color(0xffe3a64a),
        );
        // The fee card stays white paper with ink text.
        await show(tester, 'detail-fee-main');
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('detail-fee-main')))
              .style!
              .color,
          const Color(0xff16313a),
        );
        await show(tester, 'detail-coordinates');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('不能停的點：目錄只剩一面路牌，判定卡寫不能停', (tester) async {
    final store = await detailStore(tester, VehicleType.scooter);
    final heavyBay = ParkingSpot.fromJson({
      ...detailBay.toJson(),
      'id': 'heavy-only',
      'space_type': 'heavyOnly',
      'parking_segments': <Object>[],
    });
    await openDetail(tester, store, heavyBay);
    expect(tester.takeException(), isNull);
    expect(toc('seat'), findsNothing);
    expect(text(tester, 'spot-decision-label'), '普通機車不能停');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('觸控尺寸：複製與照片縮圖達標', variant: platforms, (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    await openDetail(tester, store, detailLot);
    await show(tester, 'detail-copy');
    for (final key in ['detail-copy', 'spot-photo-thumb-0']) {
      final box = tester.getSize(find.byKey(ValueKey(key)));
      expect(box.height, greaterThanOrEqualTo(minTarget()), reason: key);
      expect(box.width, greaterThanOrEqualTo(minTarget()), reason: key);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('資料與查核保留掛載點給來源動作（#280）', (tester) async {
    final store = await detailStore(tester, VehicleType.heavy);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpotSheet(
            store: store,
            spot: detailLot,
            onClose: () {},
            sourceActions: const Text('來源動作', key: ValueKey('source-actions')),
          ),
        ),
      ),
    );
    await pullUp(tester);
    await show(tester, 'source-actions');
    // Under 資料來源, in 資料與查核.
    expect(
      tester.getRect(find.byKey(const ValueKey('source-actions'))).top,
      greaterThan(tester.getRect(find.text('資料來源')).top),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
