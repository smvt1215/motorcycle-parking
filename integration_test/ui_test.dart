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
    await shoot(binding, tester, 'map-light');
    await tester.tap(find.byKey(const ValueKey('parking-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('parking-search')), '地下');
    await tester.pumpAndSettle();
    await tester.tap(find.text('[範例] 信義地下停車場'));
    await tester.pumpAndSettle();
    await shoot(binding, tester, 'spot-sheet-half');
    await tester.drag(
      find.byType(DraggableScrollableSheet),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    await shoot(binding, tester, 'spot-sheet-full');
    await binding.handlePopRoute();
    await tester.pumpAndSettle();
    await selectTab(tester, 2, (rect) => rect.center.dx);
    await shoot(binding, tester, 'personal-light');
    await tester.tap(find.text('停車規則'));
    await tester.pumpAndSettle();
    expect(find.text('停之前，先看規則'), findsOneWidget);
    await shoot(binding, tester, 'rules-light');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ParkingApp(themeMode: ThemeMode.dark),
      ),
    );
    await tester.pumpAndSettle();
    await shoot(binding, tester, 'map-dark');
    await selectTab(tester, 4, (rect) => rect.right - rect.width / 6);
    expect(find.text('新增停車點'), findsOneWidget);
    await shoot(binding, tester, 'contribute-dark');
    await tester.tap(find.byTooltip('新增停車點'));
    await tester.pumpAndSettle();
    await shoot(binding, tester, 'report-dark');
    expect(tester.takeException(), isNull);
  });
}

/// Switches to shell [branch]. The iOS 26+ tab bar is a UIKit platform view,
/// and test pointer events never reach it, so invoke its callback there;
/// other platforms tap the Flutter tab item at [dx] of the scaffold.
Future<void> selectTab(
  WidgetTester tester,
  int branch,
  double Function(Rect rect) dx,
) async {
  final scaffold = find.byType(AdaptiveScaffold);
  if (nativeGlass) {
    tester.widget<AdaptiveScaffold>(scaffold).onTab(branch);
  } else {
    final rect = tester.getRect(scaffold);
    await tester.tapAt(Offset(dx(rect), rect.bottom - 50));
  }
  await tester.pumpAndSettle();
}

/// Native iOS platform views (tab bar, glass buttons) draw after Flutter
/// settles; wait briefly so screenshots show them instead of placeholders.
Future<void> shoot(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  if (isCupertino) {
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pump();
  }
  await binding.takeScreenshot(name);
}
