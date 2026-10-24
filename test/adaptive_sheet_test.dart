import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform 開啟下方面板時底圖的位置與大小保持不變', (tester) async {
      const mapKey = ValueKey('map-background');
      await tester.pumpWidget(
        MaterialApp(
          // Match the app's bridge for CNBottomSheet's Material localizations.
          builder: (context, child) =>
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => SizedBox.expand(
                key: mapKey,
                child: TextButton(
                  onPressed: () => showAdaptiveSheet<void>(
                    context,
                    (_) => const SizedBox(
                      height: 300,
                      child: Column(
                        children: [
                          Text('面板內容'),
                          TextField(key: ValueKey('sheet-input')),
                        ],
                      ),
                    ),
                  ),
                  child: const Text('開啟'),
                ),
              ),
            ),
          ),
        ),
      );
      final before = tester.getRect(find.byKey(mapKey));
      await tester.tap(find.text('開啟'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(find.byKey(mapKey)), before);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(mapKey)), before);
      expect(find.text('面板內容'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sheet-input')), '測試');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant({platform}));
  }
}
