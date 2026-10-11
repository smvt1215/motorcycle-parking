import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('地圖、搜尋、詳情、回報、規則與深淺色', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = AppStore(LocalRepository(prefs), null);
    await store.init();
    final container = ProviderContainer(
      overrides: [storeProvider.overrideWith((ref) => store)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ParkingApp(),
      ),
    );
    await tester.pumpAndSettle();
    if (defaultTargetPlatform == TargetPlatform.android) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    await binding.takeScreenshot('map-light');
    await tester.tap(find.byKey(const ValueKey('parking-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('parking-search')), '地下');
    await tester.pumpAndSettle();
    await tester.tap(find.text('[範例] 信義地下停車場'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('spot-sheet-half');
    await tester.drag(
      find.byType(DraggableScrollableSheet),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    await binding.takeScreenshot('spot-sheet-full');
    await binding.handlePopRoute();
    await tester.pumpAndSettle();
    // Native tab items render outside Flutter's text tree; tap their actual frame.
    final scaffold = tester.getRect(find.byType(AdaptiveScaffold));
    await tester.tapAt(Offset(scaffold.center.dx, scaffold.bottom - 50));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('personal-light');
    await tester.tap(find.text('停車規則'));
    await tester.pumpAndSettle();
    expect(find.text('停之前，先看規則'), findsOneWidget);
    await binding.takeScreenshot('rules-light');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ParkingApp(themeMode: ThemeMode.dark),
      ),
    );
    await tester.pumpAndSettle();
    await binding.takeScreenshot('map-dark');
    await tester.tapAt(
      Offset(scaffold.right - scaffold.width / 6, scaffold.bottom - 50),
    );
    await tester.pumpAndSettle();
    expect(find.text('新增停車點'), findsOneWidget);
    await binding.takeScreenshot('contribute-dark');
    await tester.tap(find.byTooltip('新增停車點'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('report-dark');
    expect(tester.takeException(), isNull);
  });
}
