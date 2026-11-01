import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/features/map/availability_capsule.dart';
import 'package:motorcycle_parking/features/map/parking_access_view.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/features/map/vehicle_sheet.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'availability_fixtures.dart';

void useSize(WidgetTester tester, double width, [double height = 844]) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<AppStore> pumpMap(
  WidgetTester tester,
  List<ParkingSpot> spots,
  List<AvailabilitySnapshot> counts, {
  VehicleType vehicle = VehicleType.scooter,
  bool enabled = true,
}) async {
  final store = (await tester.runAsync(
    () => availabilityStore(spots, counts, enabled: enabled),
  ))!;
  if (vehicle != store.vehicle) {
    await tester.runAsync(() => store.setVehicle(vehicle));
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  expect(find.byType(FlutterMap), findsOneWidget);
  return store;
}

Finder capsule(String text) => find.descendant(
  of: find.byType(AvailabilityCapsuleView),
  matching: find.text(text),
);

Future<void> tapFilter(WidgetTester tester) async {
  final pill = find.byKey(const ValueKey('availability-filter'));
  await tester.ensureVisible(pill);
  await tester.pumpAndSettle();
  await tester.tap(pill);
  await tester.pumpAndSettle();
}

Future<void> openDetails(
  WidgetTester tester,
  AppStore store,
  ParkingSpot spot, {
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpot(context, store, spot),
            child: const Text('開啟詳情'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟詳情'));
  await tester.pumpAndSettle();
  await tester.drag(
    find.byKey(const ValueKey('parking-spot-sheet')),
    const Offset(0, -500),
  );
  await tester.pumpAndSettle();
}

Future<AppStore> detailStore(
  WidgetTester tester,
  ParkingSpot spot,
  List<AvailabilitySnapshot> counts, {
  VehicleType vehicle = VehicleType.scooter,
}) async {
  final store = (await tester.runAsync(
    () => availabilityStore([spot], counts),
  ))!;
  addTearDown(store.dispose);
  if (vehicle != store.vehicle) {
    await tester.runAsync(() => store.setVehicle(vehicle));
  }
  return store;
}

String summaryText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('availability-summary')),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? t.textSpan!.toPlainText())
    .join('｜');

final heavyLot = lotAt('h', 0, 0, heavy: true);
final heavyCarLot = lotAt(
  'hc',
  0,
  0,
  heavy: true,
  access: ParkingAccess.heavyCar,
);

void main() {
  group('地圖膠囊', () {
    for (final width in [320.0, 390.0, 700.0, 1280.0]) {
      testWidgets('寬 $width 依設計稿顯示新鮮、已滿、延遲；不可停不顯示數字', (tester) async {
        useSize(tester, width);
        await pumpMap(tester, canvasSpots, canvasCounts);
        final shown = width >= 390;
        if (shown) {
          expect(capsule('剩 12'), findsOneWidget);
          expect(capsule('剩 2'), findsOneWidget);
          expect(capsule('已滿'), findsOneWidget);
          expect(capsule('剩 7'), findsOneWidget);
          // Closed to scooters: no count, so it never reads as an invite.
          expect(capsule('剩 20'), findsNothing);
          // Only the delayed pill has a clock; the -9 lot has no pill.
          expect(find.byType(CapsuleClock), findsOneWidget);
          expect(find.byType(AvailabilityCapsuleView), findsNWidgets(4));
          final full = tester.widget<AvailabilityCapsuleView>(
            find.ancestor(
              of: capsule('已滿'),
              matching: find.byType(AvailabilityCapsuleView),
            ),
          );
          expect(full.capsule.style, CapsuleStyle.full);
          expect(find.bySemanticsLabel(RegExp('官方即時：剩 12 格')), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp('官方即時：已滿')), findsOneWidget);
          expect(
            find.bySemanticsLabel(RegExp('更新延遲 14 分鐘：最後一筆剩 7 格')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('膠囊在標記正上方置中，間隔 10，點膠囊開啟詳情', (tester) async {
      useSize(tester, 390);
      await pumpMap(tester, canvasSpots, canvasCounts);
      final pill = tester.getRect(
        find.ancestor(
          of: capsule('剩 12'),
          matching: find.byType(AvailabilityCapsuleView),
        ),
      );
      final box = tester.getRect(
        find
            .ancestor(
              of: capsule('剩 12'),
              matching: find.byType(MarkerWithCapsules),
            )
            .first,
      );
      expect(pill.height, 24);
      expect(pill.center.dx, closeTo(box.center.dx, .01));
      expect(pill.bottom, closeTo(box.center.dy - 19 - 10, .01));
      await tester.tap(capsule('剩 12'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
      expect(find.text('測試停車場 fresh'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('官方資料更新時，開著的詳情不關閉、不重建，數字與時間跟著更新', (tester) async {
      // Side panel: the whole details are on screen.
      useSize(tester, 1180, 820);
      final counts = [...canvasCounts];
      final store = await pumpMap(tester, canvasSpots, counts);
      await tester.tap(capsule('剩 12'));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('parking-spot-sheet'));
      final before = tester.element(sheet);
      expect(summaryText(tester), startsWith('機車車位｜12 剩餘 ／ 共 80 格｜17:02 更新'));
      counts[0] = count(
        'fresh',
        AvailabilityVehicle.scooter,
        available: 9,
        minutes: 1,
      );
      await tester.runAsync(store.pollAvailability);
      await tester.pump();
      expect(sheet, findsOneWidget, reason: '詳情沒有關閉');
      expect(
        identical(tester.element(sheet), before),
        isTrue,
        reason: '沒有重建整個面板',
      );
      expect(summaryText(tester), startsWith('機車車位｜9 剩餘 ／ 共 80 格｜17:04 更新'));
      expect(capsule('剩 9'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('白色膠囊與墨色膠囊外圈都是 2px 白邊、一樣高', (tester) async {
      useSize(tester, 390);
      await pumpMap(tester, canvasSpots, canvasCounts);
      for (final text in ['剩 12', '剩 7']) {
        final view = find.ancestor(
          of: capsule(text),
          matching: find.byType(AvailabilityCapsuleView),
        );
        expect(tester.getSize(view).height, 24);
        final outer = tester.widget<Container>(
          find.descendant(of: view, matching: find.byType(Container)).first,
        );
        expect((outer.decoration! as BoxDecoration).color, Colors.white);
        expect(outer.padding, const EdgeInsets.all(2));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('大型重機：重機剩餘數與汽車格膠囊（含延遲時鐘），無值不顯示', (tester) async {
      useSize(tester, 390);
      await pumpMap(
        tester,
        [
          lotAt('h1', -100, -150, heavy: true),
          lotAt('h2', 20, -40, heavy: true, access: ParkingAccess.heavyCar),
          lotAt('h3', -80, 120, heavy: true, access: ParkingAccess.heavyCar),
          lotAt('h4', 60, 220, heavy: true),
        ],
        [
          count('h1', AvailabilityVehicle.heavy, total: 12, available: 3),
          count('h2', AvailabilityVehicle.heavy, total: 12, available: 3),
          count('h2', AvailabilityVehicle.car, total: 100, available: 30),
          count(
            'h3',
            AvailabilityVehicle.car,
            total: 100,
            available: 30,
            minutes: 14,
          ),
          count('h4', AvailabilityVehicle.heavy, available: -9),
          count('h4', AvailabilityVehicle.scooter),
        ],
        vehicle: VehicleType.heavy,
      );
      expect(capsule('剩 3'), findsNWidgets(2));
      expect(capsule('剩 30'), findsNWidgets(2));
      expect(find.byType(CapsuleCar), findsNWidgets(2));
      expect(find.byType(CapsuleClock), findsOneWidget);
      // The scooter count of h4 never stands in for heavy bikes.
      expect(capsule('剩 12'), findsNothing);
      expect(find.textContaining('共用'), findsNothing);
      expect(find.textContaining('汽車格'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('密集時只留主要膠囊；選取一點時顯示完整一組並隱藏碰到它的鄰點', (tester) async {
      // Tall enough that every lot stays on screen after the camera
      // centres the open one above the details.
      useSize(tester, 390, 1600);
      await pumpMap(
        tester,
        denseSpots,
        denseCounts,
        vehicle: VehicleType.heavy,
      );
      expect(capsule('剩 3'), findsNWidgets(9));
      expect(find.byType(CapsuleCar), findsNothing);
      await tester.tap(find.bySemanticsLabel(RegExp('^測試停車場 row1 ')));
      await tester.pumpAndSettle();
      // row1 is open: its car pill joins; row0 and row2 touch it and hide.
      // The camera centres row1 above the details, which moves row4 off
      // screen: 9 - 2 hidden - 1 off screen.
      expect(find.byType(CapsuleCar), findsOneWidget);
      expect(capsule('剩 3'), findsNWidgets(6));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('沒有即時資料源時不顯示膠囊與「有即時空位」', (tester) async {
      useSize(tester, 390);
      await pumpMap(tester, canvasSpots, canvasCounts, enabled: false);
      expect(find.byType(AvailabilityCapsuleView), findsNothing);
      expect(find.byKey(const ValueKey('availability-filter')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('圖例列出即時、已滿、延遲、暫停與汽車格膠囊', (tester) async {
    useSize(tester, 390);
    await pumpMap(tester, canvasSpots, canvasCounts);
    await tester.tap(find.byKey(const ValueKey('map-legend-button')));
    await tester.pumpAndSettle();
    final legend = find.byKey(const ValueKey('availability-legend'));
    await tester.scrollUntilVisible(
      legend,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    for (final line in [
      '官方即時剩餘格數',
      '更新延遲，數字可能已變',
      '官方資料目前沒有空位',
      '場站暫停營運',
      '空位未知或不能停時不掛。',
    ]) {
      expect(find.text(line), findsOneWidget);
    }
    expect(find.byType(CapsulePause), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('有即時空位篩選', () {
    testWidgets('只留新鮮有位且可停的點，其他改成灰點，未知不算已滿', (tester) async {
      useSize(tester, 390);
      await pumpMap(tester, canvasSpots, canvasCounts);
      await tapFilter(tester);
      // fresh (allowed) and conditional stay; full, delayed, unknown and
      // closed become dots.
      expect(capsule('剩 12'), findsOneWidget);
      expect(capsule('剩 2'), findsOneWidget);
      expect(find.byType(AvailabilityCapsuleView), findsNWidgets(2));
      expect(find.byType(ExcludedSpotDot), findsNWidgets(4));
      expect(find.byKey(const ValueKey('availability-empty')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final (width, scale) in [(320.0, 1.6), (390.0, 1.0), (700.0, 1.0)]) {
      testWidgets('寬 $width 空結果列出原因與數量，可清除或改看即時資訊', (tester) async {
        useSize(tester, width);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpMap(
          tester,
          emptySpots,
          emptyCounts,
          vehicle: VehicleType.heavy,
        );
        await tapFilter(tester);
        final card = find.byKey(const ValueKey('availability-empty'));
        expect(card, findsOneWidget);
        expect(find.text('這個範圍沒有「大型重機有即時空位」的停車點'), findsOneWidget);
        expect(find.text('範圍內 4 個點都還在，只是都不符合條件：'), findsOneWidget);
        expect(find.text('場站沒有大型重機的即時資料，空位未知'), findsOneWidget);
        expect(find.text('資料更新延遲，暫不列為有位'), findsOneWidget);
        expect(find.text('大型重機不可停'), findsOneWidget);
        expect(find.textContaining('已滿'), findsNothing);
        expect(find.byType(ExcludedSpotDot), findsNWidgets(4));
        final clear = find.text('清除「有即時空位」');
        final live = find.text('只看有即時資訊');
        for (final button in [clear, live]) {
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          expect(tester.getSize(button).height, greaterThan(0));
          final box = tester.getRect(
            find.ancestor(
              of: button,
              matching: find.byWidgetPredicate(
                (w) => w is FilledButton || w is OutlinedButton,
              ),
            ),
          );
          expect(box.height, greaterThanOrEqualTo(48));
          expect(box.right, lessThanOrEqualTo(width));
        }
        await tester.tap(live);
        await tester.pumpAndSettle();
        // Closed to heavy bikes is not live information for them either.
        expect(find.text('這個範圍沒有大型重機的即時資訊'), findsOneWidget);
        expect(find.byType(ExcludedSpotDot), findsNWidgets(4));
        await tester.ensureVisible(find.text('清除「有即時資訊」'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清除「有即時資訊」'));
        await tester.pumpAndSettle();
        expect(card, findsNothing);
        expect(find.byType(ExcludedSpotDot), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  group('詳情摘要', () {
    final lot = canvasSpots.first;
    final cases = <String, (List<AvailabilitySnapshot>, String)>{
      '新鮮': (
        [count('fresh', AvailabilityVehicle.scooter)],
        '12 剩餘 ／ 共 80 格｜17:02 更新 ・ 臺北市停管處',
      ),
      '已滿': (
        [count('fresh', AvailabilityVehicle.scooter, available: 0)],
        '0 剩餘，已滿 ／ 共 80 格',
      ),
      '延遲': (
        [
          count(
            'fresh',
            AvailabilityVehicle.scooter,
            available: 7,
            minutes: 14,
          ),
        ],
        '7 剩餘，更新延遲 14 分鐘 ／ 共 80 格｜最後更新 16:51 ・ 臺北市停管處',
      ),
      '過期': (
        [count('fresh', AvailabilityVehicle.scooter, minutes: 40)],
        '資料過期 ・ 空位未知｜共 80 格',
      ),
      '異常': (
        [count('fresh', AvailabilityVehicle.scooter, available: 99)],
        '空位未知｜共 80 格 ・ 即時資料暫時無法使用',
      ),
      '暫停': (
        [count('fresh', AvailabilityVehicle.scooter, suspended: true)],
        '暫停營運｜來源標示場站停止服務',
      ),
      '無資料': (
        [count('fresh', AvailabilityVehicle.scooter, available: -9)],
        '無即時資料｜共 80 格（靜態資料） ・ 場站未提供此車種剩餘',
      ),
      '靜態': (const [], '無即時資料｜共 80 格（靜態資料）'),
    };
    for (final MapEntry(key: name, value: (counts, expected))
        in cases.entries) {
      testWidgets(name, (tester) async {
        useSize(tester, 390);
        final store = await detailStore(tester, lot, counts);
        await openDetails(tester, store, lot);
        expect(summaryText(tester), contains(expected));
        expect(summaryText(tester), startsWith('機車車位'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('重機無值時只列機車次要列；汽車格寫「汽車格剩餘 N」', (tester) async {
      useSize(tester, 390);
      var store = await detailStore(tester, heavyLot, [
        count('h', AvailabilityVehicle.heavy, available: -9),
        count('h', AvailabilityVehicle.scooter, minutes: 14),
      ], vehicle: VehicleType.heavy);
      await openDetails(tester, store, heavyLot);
      expect(summaryText(tester), startsWith('大型重機車位｜無即時資料'));
      expect(summaryText(tester), contains('普通機車區剩 12 格，更新延遲 14 分鐘'));
      expect(summaryText(tester), contains('不代表重機可用格數'));
      await tester.pumpWidget(const SizedBox.shrink());
      store = await detailStore(tester, heavyCarLot, [
        count('hc', AvailabilityVehicle.heavy, total: 12, available: 3),
        count(
          'hc',
          AvailabilityVehicle.car,
          total: 100,
          available: 30,
          minutes: 14,
        ),
      ], vehicle: VehicleType.heavy);
      await openDetails(tester, store, heavyCarLot);
      expect(summaryText(tester), contains('3 剩餘 ／ 共 12 格'));
      expect(summaryText(tester), contains('汽車格剩餘 30，更新延遲 14 分鐘'));
      expect(summaryText(tester), isNot(contains('共用')));
      expect(summaryText(tester), isNot(contains('費率')));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final width in [320.0, 390.0, 700.0, 1280.0]) {
      testWidgets('寬 $width 深色 1.6 倍字級摘要上下排列不溢出', (tester) async {
        useSize(tester, width);
        final store = await detailStore(tester, heavyCarLot, [
          count('hc', AvailabilityVehicle.heavy, total: 12, available: 3),
          count('hc', AvailabilityVehicle.car, total: 100, available: 30),
        ], vehicle: VehicleType.heavy);
        await openDetails(
          tester,
          store,
          heavyCarLot,
          scale: 1.6,
          brightness: Brightness.dark,
        );
        final summary = tester.getRect(
          find.byKey(const ValueKey('availability-summary')),
        );
        expect(summary.right, lessThanOrEqualTo(width));
        expect(find.bySemanticsLabel(RegExp('大型重機車位，剩餘 3 格')), findsOneWidget);
        expect(find.text('導航到這裡').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  testWidgets('#131 詳情橫幅的車牌是雙色：普通機車綠白、大型重機紅黃', (tester) async {
    useSize(tester, 320);
    for (final (vehicle, colors) in [
      (VehicleType.scooter, {const Color(0xff2e7d4f), Colors.white}),
      (VehicleType.heavy, {const Color(0xffc62828), const Color(0xfff2c200)}),
    ]) {
      final store = await detailStore(
        tester,
        heavyLot,
        const [],
        vehicle: vehicle,
      );
      await openDetails(tester, store, heavyLot, scale: 1.6);
      final plate = find.byKey(const ValueKey('spot-decision-plate'));
      expect(tester.widget(plate), isA<SmallPlateStack>());
      expect(tester.getSize(plate), const Size(25, 17));
      final fills = tester
          .widgetList<Container>(
            find.descendant(of: plate, matching: find.byType(Container)),
          )
          .map((c) => (c.decoration as BoxDecoration?)?.color)
          .whereType<Color>()
          .toSet();
      expect(fills, containsAll(colors));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('#131 車牌邊框：淺色用墨色，深色用前景色', (tester) async {
    useSize(tester, 390);
    for (final dark in [false, true]) {
      final store = await detailStore(tester, heavyLot, const []);
      await openDetails(
        tester,
        store,
        heavyLot,
        brightness: dark ? Brightness.dark : Brightness.light,
      );
      final plate = find.byKey(const ValueKey('spot-decision-plate'));
      final expected = dark
          ? Theme.of(tester.element(plate)).colorScheme.onSurface
          : const Color(0xff16313a);
      final edges = tester
          .widgetList<Container>(
            find.descendant(of: plate, matching: find.byType(Container)),
          )
          .map((c) => (c.decoration as BoxDecoration?)?.border)
          .whereType<Border>()
          .map((b) => b.top.color)
          .toSet();
      expect(edges, {expected});
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('#130 停放車種區不顯示「共用」說明行，Semantics 保留完整說明', (tester) async {
    for (final access in [ParkingAccess.heavyCar, ParkingAccess.scooterHeavy]) {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ParkingAccessView(spot: lotAt('a', 0, 0, access: access)),
          ),
        ),
      );
      expect(find.text(access.description), findsNothing);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('parking-access-vehicles')))
            .label,
        contains(access.description),
      );
      // The tokens keep their 共用 state and the ⇄ icon (user decision).
      expect(find.text('共用'), findsNWidgets(2));
      expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
      handle.dispose();
    }
  });
}
