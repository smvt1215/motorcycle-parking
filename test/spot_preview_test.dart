import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The map preview (canvas Ver.143 Main, A3, A5, A6): the four signs and
/// the three actions, on phones and iPads, iOS and Android.
void main() {
  // 2026-11-03 (Tuesday) 14:20 in Taiwan.
  final now = DateTime.utc(2026, 11, 3, 6, 20);
  final lot = ParkingSpot.fromJson({
    'id': 'songshou',
    'name': '松壽地下停車場',
    'lat': 25.03,
    'lng': 121.56,
    'city': '臺北市',
    'district': '信義區',
    'space_type': 'offStreet',
    'facility_type': 'underground',
    'source': 'official',
    'scooter_allowed': true,
    'heavy_allowed': true,
    'fee': {
      'heavy': {
        'mode': 'hourly',
        'amount': 20,
        'per_minutes': 60,
        'daily_cap': 100,
        'cap_reset': 'calendar_day',
      },
    },
    'parking_zones': [
      {
        'id': 'b1',
        'name': 'B1 機車區',
        'area': 'motorcycle',
        'condition': {
          'bay': 'motorcycle',
          'use': 'usual',
          'allow': {'scooter': true, 'heavy': false},
        },
      },
      {
        'id': 'b2',
        'name': 'B2 重機專區',
        'area': 'heavy',
        'condition': {
          'bay': 'heavy',
          'use': 'usual',
          'allow': {'heavy': true},
        },
      },
    ],
  });
  final street = ParkingSpot.fromJson({
    'id': 'heavy-bay',
    'name': '重機專用格',
    'lat': 25.03,
    'lng': 121.56,
    'city': '臺北市',
    'space_type': 'heavyOnly',
    'facility_type': 'roadside',
    'source': 'official',
  });

  Future<AppStore> store(WidgetTester tester, VehicleType vehicle) async {
    final s = (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({'vehicle': vehicle.name});
      final s = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        clock: () => now,
      );
      await s.init();
      return s;
    }))!;
    s.vehicle = vehicle;
    addTearDown(s.dispose);
    return s;
  }

  Future<void> open(
    WidgetTester tester,
    AppStore store,
    ParkingSpot spot, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
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
              onPressed: () => showSpot(context, store, spot),
              child: const Text('開啟點位'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟點位'));
    await tester.pumpAndSettle();
  }

  Rect plate(WidgetTester tester, String face) =>
      tester.getRect(find.byKey(ValueKey('four-sign-$face')));

  const sizes = {
    '手機 390': Size(390, 844),
    'iPad 直向': Size(820, 1180),
    'iPad 橫向': Size(1180, 820),
  };

  final platforms = TargetPlatformVariant({
    TargetPlatform.iOS,
    TargetPlatform.android,
  });
  {
    for (final MapEntry(key: name, value: size) in sizes.entries) {
      testWidgets('$name：四面路牌一列，兩顆動作鈕點得到', variant: platforms, (tester) async {
        final s = await store(tester, VehicleType.heavy);
        await open(tester, s, lot, size: size);
        expect(tester.takeException(), isNull);
        for (final face in ['verdict', 'seat', 'fee', 'where']) {
          expect(
            find.byKey(ValueKey('four-sign-$face')).hitTestable(),
            findsOneWidget,
            reason: face,
          );
        }
        // One row, in the rider's order.
        expect(plate(tester, 'seat').top, plate(tester, 'verdict').top);
        expect(
          plate(tester, 'fee').left,
          greaterThan(plate(tester, 'seat').left),
        );
        expect(find.text('B2'), findsOneWidget);
        expect(find.text('20/時'), findsOneWidget);
        // 回報現場狀況 waits for the sighting sheet (PR-E).
        expect(find.text('回報現場狀況'), findsNothing);
        for (final label in ['導航到入口', '修改建議']) {
          expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
          expect(tester.getSize(find.text(label)).height, greaterThan(0));
        }
        // Touch targets: iOS 44pt, Android 48dp, for every action, the
        // header's icon buttons and the plates themselves.
        final minTarget = defaultTargetPlatform == TargetPlatform.iOS
            ? 44.0
            : 48.0;
        void tappable(Finder f, String reason) {
          expect(f, findsOneWidget, reason: reason);
          final size = tester.getSize(f);
          expect(size.height, greaterThanOrEqualTo(minTarget), reason: reason);
          expect(size.width, greaterThanOrEqualTo(minTarget), reason: reason);
        }

        for (final key in ['spot-navigate', 'spot-suggest']) {
          tappable(find.byKey(ValueKey(key)), key);
        }
        for (final tip in ['收藏停車點', '分享停車點', '關閉詳情']) {
          tappable(
            find.ancestor(
              of: find.byTooltip(tip),
              matching: find.byType(IconButton),
            ),
            tip,
          );
        }
        for (final face in ['verdict', 'seat', 'fee', 'where']) {
          tappable(find.byKey(ValueKey('four-sign-$face')), face);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('放大字級：路牌 2×2，動作列不重疊', variant: platforms, (tester) async {
      final s = await store(tester, VehicleType.heavy);
      await open(tester, s, lot, scale: 1.6);
      expect(tester.takeException(), isNull);
      expect(plate(tester, 'seat').top, plate(tester, 'verdict').top);
      expect(
        plate(tester, 'fee').top,
        greaterThan(plate(tester, 'verdict').bottom),
      );
      expect(plate(tester, 'where').top, plate(tester, 'fee').top);
      // A short sheet keeps the actions at the end of the list (as before);
      // opened to its full height it pins them.
      await tester.tap(find.byKey(const ValueKey('four-sign-verdict')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('spot-navigate')).hitTestable(),
        findsOneWidget,
      );
      final nav = tester.getRect(find.byKey(const ValueKey('spot-navigate')));
      // Two buttons now (回報現場狀況 waits for PR-E): side by side when they
      // fit, else stacked; never overlapping.
      final suggest = tester.getRect(
        find.byKey(const ValueKey('spot-suggest')),
      );
      expect(
        suggest.top >= nav.bottom - 1 || suggest.left >= nav.right - 1,
        isTrue,
      );
      expect(find.text('修改建議').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('每面路牌都有朗讀標籤，可以點', (tester) async {
    final s = await store(tester, VehicleType.heavy);
    await open(tester, s, lot);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('four-sign-where'))),
      matchesSemantics(
        label: '停哪裡：B2 重機專區',
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(find.bySemanticsLabel(RegExp(r'^能不能停：可停')), findsOneWidget);
    handle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('點怎麼算錢路牌，詳情展開並捲到收費', (tester) async {
    final s = await store(tester, VehicleType.heavy);
    await open(tester, s, lot);
    expect(find.text('收費').hitTestable(), findsNothing);
    await tester.tap(find.byKey(const ValueKey('four-sign-fee')));
    await tester.pumpAndSettle();
    expect(find.text('收費').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (face, target) in [
    ('where', find.text('停車資訊')),
    ('seat', find.byKey(const ValueKey('availability-summary'))),
  ]) {
    testWidgets('窄螢幕大字級點 $face 路牌，捲到畫面外的段落', (tester) async {
      final s = await store(tester, VehicleType.heavy);
      await open(tester, s, lot, size: const Size(320, 640), scale: 1.6);
      expect(target.hitTestable(), findsNothing);
      // The resting sheet is short here: bring the plate up first.
      await tester.ensureVisible(find.byKey(ValueKey('four-sign-$face')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('four-sign-$face')));
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('動作列只有兩顆時排成一列', (tester) async {
    final s = await store(tester, VehicleType.heavy);
    await open(tester, s, lot);
    final nav = tester.getRect(find.byKey(const ValueKey('spot-navigate')));
    final suggest = tester.getRect(find.byKey(const ValueKey('spot-suggest')));
    expect(suggest.top, nav.top);
    expect(suggest.left, greaterThan(nav.right));
    expect(find.byKey(const ValueKey('spot-report')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('路邊點寫「導航」；目前車種不能停時只剩一面路牌', (tester) async {
    final s = await store(tester, VehicleType.scooter);
    await open(tester, s, street);
    expect(find.text('導航').hitTestable(), findsOneWidget);
    expect(find.text('普通機車不能停'), findsOneWidget);
    expect(find.byKey(const ValueKey('four-sign-seat')), findsNothing);
    final verdict = plate(tester, 'verdict');
    expect(verdict.width, greaterThan(300));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
