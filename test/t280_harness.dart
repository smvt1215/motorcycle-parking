/// Shared setup for #280's tests (hidden riders, content reports).
library;

import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const handleA = '3fa8c1d27b9e40a6c55d0e1f2a3b4c5d';
const handleK = '0123456789abcdef0123456789abcdef';
const handleU = 'ffffffffffffffffffffffffffffffff';

/// The layouts every new screen is checked at (IMPL-BRIEF).
const layouts = <(String, Size)>[
  ('phone', Size(390, 844)),
  ('tablet portrait', Size(820, 1180)),
  ('tablet landscape', Size(1180, 820)),
];
const platforms = [TargetPlatform.iOS, TargetPlatform.android];

void setUpView(WidgetTester tester, TargetPlatform platform, Size size) {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// [testWidgets] that always clears the platform override before the
/// framework checks its debug variables.
void testWidgetsOn(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

Widget app(Widget home, {double scale = 1, bool accessible = false}) =>
    MaterialApp(
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        cu.GlobalCupertinoLocalizations.delegate,
      ],
      // The app's bridge for CNBottomSheet's Material localizations.
      // ignore: deprecated_member_use
      builder: (context, child) => MaterialUiCompatibilityBridge(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
            accessibleNavigation: accessible,
          ),
          child: child!,
        ),
      ),
      home: home,
    );

Future<AppStore> storeWith(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  return AppStore(LocalRepository(await SharedPreferences.getInstance()), null);
}
