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

    // iPhone report (2026-11-08): Zhuyin has no dismiss key, and Return in a
    // multi-line field adds a line, so the sheet must put the keyboard away.
    for (final size in const [Size(390, 844), Size(820, 1180)]) {
      testWidgets('$platform ${size.width.toInt()} 寬：點面板空白處或拖動清單收起鍵盤，按鈕照常', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                // ignore: deprecated_member_use
                MaterialUiCompatibilityBridge(child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAdaptiveSheet<void>(
                    context,
                    (_) => SizedBox(
                      height: 500,
                      child: ListView(
                        key: const ValueKey('sheet-list'),
                        children: [
                          const SizedBox(height: 120, child: Text('面板說明')),
                          const TextField(
                            key: ValueKey('sheet-note'),
                            minLines: 2,
                            maxLines: 5,
                          ),
                          TextButton(
                            key: const ValueKey('sheet-action'),
                            onPressed: () => taps++,
                            child: const Text('動作'),
                          ),
                          const SizedBox(height: 800),
                        ],
                      ),
                    ),
                  ),
                  child: const Text('開啟'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('開啟'));
        await tester.pumpAndSettle();
        final note = find.byKey(const ValueKey('sheet-note'));
        bool focused() => tester
            .widget<EditableText>(
              find.descendant(of: note, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus;

        // A tap on the blank part of the sheet.
        await tester.showKeyboard(note);
        expect(focused(), isTrue);
        await tester.tap(find.text('面板說明'));
        await tester.pumpAndSettle();
        expect(focused(), isFalse);

        // A tap on the field itself keeps it; a button still works.
        await tester.showKeyboard(note);
        await tester.tap(note);
        await tester.pumpAndSettle();
        expect(focused(), isTrue);
        await tester.tap(find.byKey(const ValueKey('sheet-action')));
        await tester.pumpAndSettle();
        expect(taps, 1);

        // A drag of the list.
        await tester.showKeyboard(note);
        expect(focused(), isTrue);
        await tester.drag(
          find.byKey(const ValueKey('sheet-list')),
          const Offset(0, -200),
        );
        await tester.pumpAndSettle();
        expect(focused(), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
