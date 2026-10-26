import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/launch/launch_screen.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

Future<void> pumpLaunch(
  WidgetTester tester, {
  required Size size,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: const LaunchScreen(locating: true),
      ),
    ),
  );
  await tester.pump();
}

Rect markRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('launch-mark')));

String markAsset(WidgetTester tester) =>
    ((tester.widget<Image>(find.byKey(const ValueKey('launch-mark'))).image)
            as AssetImage)
        .assetName;

void main() {
  testWidgets('手機上的標誌與原生啟動畫面同尺寸、置中於整個螢幕', (tester) async {
    await pumpLaunch(tester, size: const Size(390, 844));
    expect(markRect(tester).size, const Size.square(288));
    expect(markRect(tester).center, const Offset(195, 422));
    expect(markAsset(tester), 'assets/branding/png/splash_mark.png');
    final screen = tester.widget<Material>(
      find.byKey(const ValueKey('launch-screen')),
    );
    expect(screen.color, launchBlue);
    expect(find.text('正在取得目前位置…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色模式用柏油底，和原生深色啟動畫面一致', (tester) async {
    await pumpLaunch(
      tester,
      size: const Size(390, 844),
      brightness: Brightness.dark,
    );
    expect(markAsset(tester), 'assets/branding/png/splash_mark.png');
    final screen = tester.widget<Material>(
      find.byKey(const ValueKey('launch-screen')),
    );
    expect(screen.color, launchAsphalt);
  });

  for (final (size, scale) in [
    (const Size(320, 568), 1.6),
    (const Size(844, 390), 1.6),
    (const Size(700, 1000), 1.0),
    (const Size(1280, 800), 1.0),
  ]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}、字級 $scale 倍時標誌'
        '不壓到載入狀態', (tester) async {
      await pumpLaunch(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      final mark = markRect(tester);
      // The icon is the middle 150 of the 288 px image.
      final drawingBottom = mark.center.dy + mark.height * 150 / 288 / 2;
      final progress = tester.getRect(find.byType(CircularProgressIndicator));
      expect(drawingBottom, lessThanOrEqualTo(progress.top));
      expect(mark.center.dx, closeTo(size.width / 2, .01));
      expect(
        tester.getRect(find.text('正在取得目前位置…')).right,
        lessThanOrEqualTo(size.width),
      );
    });
  }
}
