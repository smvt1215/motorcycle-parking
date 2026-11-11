import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

/// What the engine reports with a keyboard [inset] tall: `padding` is
/// `viewPadding` less the keyboard, so a home indicator's [safe] area reads 0
/// once the keyboard covers it.
void setKeyboard(WidgetTester tester, double safe, double inset) {
  tester.view.viewPadding = FakeViewPadding(top: 47, bottom: safe);
  tester.view.padding = FakeViewPadding(
    top: 47,
    bottom: (safe - inset).clamp(0, safe),
  );
  tester.view.viewInsets = FakeViewPadding(bottom: inset);
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    // iPhone report (build 277): the sheet's top dropped ~34 pt while the
    // keyboard was up, and rose again as the keyboard went down. Forms of
    // .86 of the screen fit; .92 ones reach the top of the safe area.
    for (final (name, size, safe) in const [
      ('phone', Size(402, 874), 34.0),
      ('tablet', Size(820, 1180), 20.0),
    ]) {
      for (final factor in const [.86, .92]) {
        testWidgets('$platform $name 高度 $factor：鍵盤開關時面板頂端不動，表單讓出鍵盤位置', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          setKeyboard(tester, safe, 0);
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
                      (ctx) => SizedBox(
                        height: MediaQuery.sizeOf(ctx).height * factor,
                        child: Builder(
                          // As the forms do: give the keyboard its room.
                          builder: (ctx) => Padding(
                            padding: EdgeInsets.only(
                              bottom: MediaQuery.viewInsetsOf(ctx).bottom,
                            ),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  key: ValueKey('sheet-title'),
                                  height: 44,
                                ),
                                Expanded(
                                  child: TextField(
                                    expands: true,
                                    maxLines: null,
                                  ),
                                ),
                                SizedBox(
                                  key: ValueKey('sheet-footer'),
                                  height: 48,
                                ),
                              ],
                            ),
                          ),
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
          Rect rectOf(String key) => tester.getRect(find.byKey(ValueKey(key)));
          final top = rectOf('sheet-title').top;
          final closedFooter = rectOf('sheet-footer').bottom;

          // Every frame of the keyboard going up and back down.
          const keyboard = 336.0;
          final steps = [
            for (var inset = 0.0; inset <= keyboard; inset += 12) inset,
            keyboard,
            for (var inset = keyboard; inset >= 0; inset -= 12) inset,
            0.0,
          ];
          for (final inset in steps) {
            setKeyboard(tester, safe, inset);
            await tester.pump(const Duration(milliseconds: 16));
            expect(rectOf('sheet-title').top, top, reason: 'inset $inset');
            // Right above the keyboard, without a home indicator's gap over
            // it; iOS keeps clear of the home indicator with it down.
            final floor = platform == TargetPlatform.iOS ? safe : 0.0;
            expect(
              rectOf('sheet-footer').bottom,
              size.height - (inset > floor ? inset : floor),
              reason: 'inset $inset',
            );
          }
          expect(rectOf('sheet-footer').bottom, closedFooter);
          expect(rectOf('sheet-title').top, top);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }, variant: TargetPlatformVariant({platform}));
      }
    }

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
