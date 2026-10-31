import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/features/my_parking/parking_page.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'app_test.dart' show testStore;

void main() {
  test('停車時長以天、小時、分鐘顯示', () {
    expect(parkedDuration(const Duration(seconds: 30)), '0 分鐘');
    expect(parkedDuration(const Duration(minutes: 5)), '5 分鐘');
    expect(parkedDuration(const Duration(hours: 2)), '2 小時');
    expect(parkedDuration(const Duration(hours: 2, minutes: 5)), '2 小時 5 分鐘');
    expect(parkedDuration(const Duration(days: 1)), '1 天');
    expect(parkedDuration(const Duration(days: 1, hours: 3)), '1 天 3 小時');
    // A clock set back never shows a negative time.
    expect(parkedDuration(const Duration(minutes: -3)), '0 分鐘');
    expect(parkedDuration(const Duration(hours: -1)), '0 分鐘');
    expect(parkedDuration(const Duration(days: -2, hours: -5)), '0 分鐘');
  });
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final size in const [Size(390, 844), Size(820, 1180)]) {
      testWidgets(
        '個人中心停車卡在 ${platform.name} ${size.width.toInt()} px 不溢出，按鈕夠大',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final store = (await tester.runAsync(testStore))!;
          store.parked = ParkedRecord(
            lat: 25.04,
            lng: 121.56,
            at: DateTime.now().subtract(const Duration(minutes: 80)),
            floor: 'B2 重機區',
            note: '電梯旁第三排',
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [storeProvider.overrideWith((ref) => store)],
              child: const ParkingApp(),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          GoRouter.of(tester.element(find.byType(Navigator).last))
              .go('/parking');
          await tester.pumpAndSettle();
          expect(find.byType(ParkingPage), findsOneWidget);
          expect(find.text('1 小時 20 分鐘'), findsOneWidget);
          expect(find.text('B2 重機區'), findsOneWidget);
          for (final label in ['導航回車旁', '已取車']) {
            final button = find.ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate(
                (w) => w is ButtonStyleButton || w is cu.CupertinoButton,
              ),
            );
            expect(
              tester.getSize(button.first).height,
              greaterThanOrEqualTo(44),
            );
          }
          expect(find.text('地圖怎麼看'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  }
}
