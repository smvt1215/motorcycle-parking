import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/app_version.dart';
import 'package:motorcycle_parking/features/launch/launch_screen.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

void main() {
  test('通道依 flavor 與建置號判斷，與 cd_gate 的建置號規則一致', () {
    String? channel(String? flavor, String build) =>
        AppVersion.channelOf(flavor: flavor, build: build);
    expect(channel('staging', '42'), 'Alpha');
    for (final build in ['12341', '12344']) {
      expect(channel('production', build), 'Beta', reason: build);
    }
    // RC and the store release ship the same binary: no tag.
    for (final build in ['12345', '12349']) {
      expect(channel('production', build), isNull, reason: build);
    }
    expect(channel(null, 'local'), isNull);
    expect(
      AppVersion.channelOf(flavor: 'staging', build: '42', debug: true),
      'Debug',
    );
  });

  test('標籤含版本、建置號與通道', () {
    expect(
      const AppVersion('0.2.0', '1234', channel: 'Beta').label,
      'v0.2.0 · Build 1234 · Beta',
    );
    expect(const AppVersion('0.2.0', '1235').label, 'v0.2.0 · Build 1235');
  });

  void mockVersion() {
    PackageInfo.setMockInitialValues(
      appName: '機車停車指南',
      packageName: 'tw.motopark.motorcycle_parking',
      version: '0.2.0',
      buildNumber: '1234',
      buildSignature: '',
    );
    AppVersion.reset();
    addTearDown(AppVersion.reset);
  }

  testWidgets('設定面板顯示可複製的版本與建置號', (tester) async {
    mockVersion();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
    final store = AppStore(LocalRepository(prefs), null);
    await tester.runAsync(store.init);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('個人中心').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('帳號與設定'));
    await tester.pumpAndSettle();
    final version = find.byKey(const ValueKey('app-version'));
    expect(
      tester.widget<SelectableText>(version).data,
      'v0.2.0 · Build 1234 · Debug',
    );
  });

  testWidgets('啟動畫面顯示版本與建置號', (tester) async {
    mockVersion();
    await tester.pumpWidget(
      const MaterialApp(home: LaunchScreen(locating: false)),
    );
    await tester.pump();
    // Tests run a debug build.
    expect(find.text('v0.2.0 · Build 1234 · Debug'), findsOneWidget);
  });
}
