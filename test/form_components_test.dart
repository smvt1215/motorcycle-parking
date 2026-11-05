import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/form_display.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

/// Pumps [child] in a 390-wide phone, at [scale] text size.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
  bool center = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SafeArea(
          child: center
              ? Center(child: child)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [child],
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _minTouch() => isCupertino ? 44 : 48;

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    final variant = TargetPlatformVariant({platform});
    final ios = platform == TargetPlatform.iOS;

    group('$platform FormHeader', () {
      testWidgets('取消：標題、副標、按鈕大小與朗讀', (tester) async {
        var tapped = 0;
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          FormHeader(
            title: '新增停車點',
            subtitle: '貢獻',
            leading: FormHeaderLeading.cancel,
            onLeading: () => tapped++,
          ),
        );
        expect(find.text('新增停車點'), findsOneWidget);
        expect(find.text('貢獻'), findsOneWidget);
        final leading = find.byKey(const ValueKey('form-header-leading'));
        final size = tester.getSize(leading);
        expect(size.width, greaterThanOrEqualTo(_minTouch()));
        expect(size.height, greaterThanOrEqualTo(_minTouch()));
        expect(
          tester.getSemantics(leading),
          ios
              ? isSemantics(label: formCancel, isButton: true)
              : isSemantics(tooltip: formClose, isButton: true),
        );
        if (ios) {
          expect(
            find.descendant(of: leading, matching: find.text(formCancel)),
            findsOneWidget,
          );
          // Centred on the 390 screen.
          expect(tester.getCenter(find.text('新增停車點')).dx, closeTo(195, 1));
        } else {
          expect(find.byIcon(Icons.close), findsOneWidget);
          expect(find.text(formCancel), findsNothing);
          expect(
            tester.getTopLeft(find.text('新增停車點')).dx,
            greaterThan(tester.getTopRight(leading).dx),
          );
        }
        await tester.tap(leading);
        expect(tapped, 1);
        handle.dispose();
      }, variant: variant);

      testWidgets('返回：沒有 onLeading 時回上一頁', (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: SafeArea(
                      child: FormHeader(
                        title: '限時／禁停／共用時段',
                        subtitle: '松壽地下停車場',
                        leading: FormHeaderLeading.back,
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('開啟'),
            ),
          ),
        );
        await tester.tap(find.text('開啟'));
        await tester.pumpAndSettle();
        final leading = find.byKey(const ValueKey('form-header-leading'));
        expect(
          tester.getSemantics(leading),
          ios
              ? isSemantics(label: formBack, isButton: true)
              : isSemantics(tooltip: formBack, isButton: true),
        );
        expect(
          find.descendant(
            of: leading,
            matching: find.byIcon(ios ? Icons.chevron_left : Icons.arrow_back),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: leading, matching: find.text(formBack)),
          ios ? findsOneWidget : findsNothing,
        );
        await tester.tap(leading);
        await tester.pumpAndSettle();
        expect(find.text('限時／禁停／共用時段'), findsNothing);
        handle.dispose();
      }, variant: variant);

      testWidgets('大字 2.0 不溢位', (tester) async {
        for (final leading in FormHeaderLeading.values) {
          await _pump(
            tester,
            FormHeader(
              title: '路邊格修改建議：限時／禁停／共用時段',
              subtitle: '松壽路・松壽地下停車場旁',
              leading: leading,
              onLeading: () {},
            ),
            scale: 2,
          );
          expect(tester.takeException(), isNull);
        }
      }, variant: variant);
    });

    group('$platform SubmitBar', () {
      testWidgets('送出、說明、高度與朗讀', (tester) async {
        var sent = 0;
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          SubmitBar(
            label: '送出 1 項建議',
            note: '管理員審核後才會更新地圖',
            onPressed: () => sent++,
          ),
        );
        final button = find.byKey(const ValueKey('submit-bar-button'));
        expect(tester.getSize(button).height, greaterThanOrEqualTo(52));
        expect(tester.getSize(button).width, 390 - 32);
        expect(find.text('管理員審核後才會更新地圖'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('送出 1 項建議')),
          isSemantics(label: '送出 1 項建議', isButton: true, isEnabled: true),
        );
        await tester.tap(find.text('送出 1 項建議'));
        expect(sent, 1);
        handle.dispose();
      }, variant: variant);

      testWidgets('送出中與沒有 onPressed 時停用', (tester) async {
        var sent = 0;
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          SubmitBar(label: '送出', onPressed: () => sent++, sending: true),
        );
        expect(find.text('送出'), findsNothing);
        expect(find.text(formSending), findsOneWidget);
        expect(
          tester.getSemantics(find.text(formSending)),
          isSemantics(isButton: true, isEnabled: false),
        );
        await tester.tap(find.text(formSending), warnIfMissed: false);
        expect(sent, 0);

        await _pump(tester, const SubmitBar(label: '送出', onPressed: null));
        expect(
          tester.getSemantics(find.text('送出')),
          isSemantics(isButton: true, isEnabled: false),
        );
        handle.dispose();
      }, variant: variant);

      testWidgets('大字 2.0 不溢位', (tester) async {
        await _pump(
          tester,
          SubmitBar(
            label: '送出 12 項建議',
            note: '回到清單，送出時一併列在「你要改的內容」',
            onPressed: () {},
          ),
          scale: 2,
        );
        expect(tester.takeException(), isNull);
      }, variant: variant);
    });

    group('$platform FormInfoNote', () {
      testWidgets('三種語氣都顯示圖示與文字，大字 2.0 不溢位', (tester) async {
        final handle = tester.ensureSemantics();
        for (final tone in FormNoteTone.values) {
          for (final scale in [1.0, 2.0]) {
            await _pump(
              tester,
              FormInfoNote(
                icon: Icons.info_outline,
                text: '23:00–07:00、假日是大型重機非開放時段，不用填費率。',
                tone: tone,
              ),
              scale: scale,
            );
            expect(tester.takeException(), isNull);
            expect(find.byIcon(Icons.info_outline), findsOneWidget);
            expect(
              tester.getSemantics(find.byType(FormInfoNote)),
              isSemantics(
                label: '23:00–07:00、假日是大型重機非開放時段，不用填費率。',
                isLiveRegion: tone == FormNoteTone.error,
              ),
            );
          }
        }
        handle.dispose();
      }, variant: variant);

      testWidgets('語氣顏色不同', (tester) async {
        Color? colorOf(FormNoteTone tone) =>
            tester.widget<Icon>(find.byIcon(Icons.signpost)).color;
        final colors = <Color?>{};
        for (final tone in FormNoteTone.values) {
          await _pump(
            tester,
            FormInfoNote(icon: Icons.signpost, text: '說明', tone: tone),
          );
          colors.add(colorOf(tone));
        }
        expect(colors, hasLength(3));
        expect(colors, contains(conditionalColor));
      }, variant: variant);
    });

    group('$platform AdaptiveTimeField', () {
      Widget field({
        String? value,
        bool enabled = true,
        ValueChanged<String>? onChanged,
      }) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: AdaptiveTimeField(
                label: '開始時間',
                value: value,
                enabled: enabled,
                onChanged: onChanged ?? (_) {},
              ),
            ),
            const SizedBox(width: 8),
            const Text('–'),
            const SizedBox(width: 8),
            Expanded(
              child: AdaptiveTimeField(
                label: '結束時間',
                value: '20:00',
                enabled: enabled,
                onChanged: (_) {},
              ),
            ),
          ],
        ),
      );

      testWidgets('顯示值或佔位字、高度與朗讀', (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, field(value: '07:00'));
        expect(find.text('07:00'), findsOneWidget);
        final box = find.byType(AdaptiveTimeField).first;
        expect(tester.getSize(box).height, greaterThanOrEqualTo(ios ? 44 : 56));
        expect(
          tester.getSemantics(box),
          isSemantics(
            label: '開始時間',
            value: '07:00',
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        await _pump(tester, field());
        expect(find.text(timePlaceholder), findsOneWidget);
        expect(
          tester.getSemantics(find.byType(AdaptiveTimeField).first),
          isSemantics(label: '開始時間', value: timeUnset),
        );
        handle.dispose();
      }, variant: variant);

      testWidgets('停用時點了不開選擇器', (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, field(value: '07:00', enabled: false));
        final box = find.byType(AdaptiveTimeField).first;
        expect(
          tester.getSemantics(box),
          isSemantics(isButton: true, isEnabled: false),
        );
        await tester.tap(box);
        await tester.pumpAndSettle();
        expect(find.text(timePickerConfirm), findsNothing);
        handle.dispose();
      }, variant: variant);

      testWidgets('選了時間之後回傳 HH:mm', (tester) async {
        String? changed;
        await _pump(
          tester,
          field(value: '07:00', onChanged: (v) => changed = v),
        );
        await tester.tap(find.byType(AdaptiveTimeField).first);
        await tester.pumpAndSettle();
        expect(find.text('開始時間'), findsOneWidget);
        if (ios) {
          final wheel = tester.widget<cu.CupertinoDatePicker>(
            find.byType(cu.CupertinoDatePicker),
          );
          expect(wheel.use24hFormat, isTrue);
          expect(wheel.mode, cu.CupertinoDatePickerMode.time);
          expect(wheel.initialDateTime.hour, 7);
          wheel.onDateTimeChanged(DateTime(2000, 1, 1, 9, 5));
          await tester.pump();
          final confirm = find.byKey(const ValueKey('time-picker-confirm'));
          expect(tester.getSize(confirm).height, greaterThanOrEqualTo(44));
          await tester.tap(confirm);
        } else {
          final boxes = find.descendant(
            of: find.byType(TimePickerDialog),
            matching: find.byType(EditableText),
          );
          expect(boxes, findsNWidgets(2));
          await tester.enterText(boxes.at(0), '9');
          await tester.enterText(boxes.at(1), '05');
          await tester.pump();
          await tester.tap(find.text(timePickerConfirm));
        }
        await tester.pumpAndSettle();
        expect(changed, '09:05');
      }, variant: variant);

      testWidgets('取消時不回傳', (tester) async {
        String? result = 'unset';
        await _pump(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showAdaptiveTimePicker(context, title: '結束時間'),
              child: const Text('開啟'),
            ),
          ),
        );
        await tester.tap(find.text('開啟'));
        await tester.pumpAndSettle();
        expect(find.text('結束時間'), findsOneWidget);
        await tester.tap(find.text(timePickerCancel));
        await tester.pumpAndSettle();
        expect(result, isNull);
      }, variant: variant);

      testWidgets('沒有初值時從 00:00 開始', (tester) async {
        String? result;
        await _pump(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showAdaptiveTimePicker(context, title: '開始時間'),
              child: const Text('開啟'),
            ),
          ),
        );
        await tester.tap(find.text('開啟'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(timePickerConfirm));
        await tester.pumpAndSettle();
        expect(result, '00:00');
      }, variant: variant);

      testWidgets('欄位與選擇器在大字 2.0 不溢位', (tester) async {
        await _pump(tester, field(value: '07:00'), scale: 2);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(AdaptiveTimeField).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(timePickerConfirm), findsOneWidget);
      }, variant: variant);
    });

    group('$platform AdaptiveStepper', () {
      Widget stepper(int value, ValueChanged<int> onChanged) => AdaptiveStepper(
        label: '每次限停',
        value: value,
        min: 30,
        max: 240,
        step: 30,
        format: (m) => m % 60 == 0 ? '${m ~/ 60}小時' : '$m分鐘',
        onChanged: onChanged,
      );
      final dec = find.byKey(const ValueKey('stepper-decrease'));
      final inc = find.byKey(const ValueKey('stepper-increase'));

      testWidgets('加減一格、按鈕大小與朗讀', (tester) async {
        final handle = tester.ensureSemantics();
        final changes = <int>[];
        await _pump(tester, stepper(120, changes.add), center: true);
        expect(find.text('2小時'), findsOneWidget);
        for (final b in [dec, inc]) {
          expect(tester.getSize(b).width, greaterThanOrEqualTo(_minTouch()));
          expect(tester.getSize(b).height, greaterThanOrEqualTo(_minTouch()));
        }
        expect(
          tester.getSemantics(dec),
          ios
              ? isSemantics(
                  label: stepperDecrease('每次限停'),
                  isButton: true,
                  isEnabled: true,
                )
              : isSemantics(
                  tooltip: stepperDecrease('每次限停'),
                  isButton: true,
                  isEnabled: true,
                ),
        );
        expect(
          tester.getSemantics(inc),
          ios
              ? isSemantics(label: stepperIncrease('每次限停'), isButton: true)
              : isSemantics(tooltip: stepperIncrease('每次限停'), isButton: true),
        );
        final value = find.text('2小時');
        expect(
          tester.getSemantics(value),
          isSemantics(
            label: '每次限停',
            value: '2小時',
            increasedValue: '150分鐘',
            decreasedValue: '90分鐘',
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ),
        );
        await tester.tap(inc);
        await tester.tap(dec);
        final node = tester.getSemantics(value);
        node.owner!.performAction(node.id, SemanticsAction.increase);
        node.owner!.performAction(node.id, SemanticsAction.decrease);
        expect(changes, [150, 90, 150, 90]);
        handle.dispose();
      }, variant: variant);

      testWidgets('到下限停用減少、到上限停用增加', (tester) async {
        final handle = tester.ensureSemantics();
        final changes = <int>[];
        await _pump(tester, stepper(30, changes.add), center: true);
        expect(
          tester.getSemantics(dec),
          isSemantics(isButton: true, isEnabled: false),
        );
        expect(
          tester.getSemantics(find.text('30分鐘')),
          isSemantics(hasDecreaseAction: false, hasIncreaseAction: true),
        );
        await tester.tap(dec, warnIfMissed: false);
        expect(changes, isEmpty);

        await _pump(tester, stepper(240, changes.add), center: true);
        expect(
          tester.getSemantics(inc),
          isSemantics(isButton: true, isEnabled: false),
        );
        expect(
          tester.getSemantics(dec),
          isSemantics(isButton: true, isEnabled: true),
        );
        expect(
          tester.getSemantics(find.text('4小時')),
          isSemantics(hasIncreaseAction: false, hasDecreaseAction: true),
        );
        await tester.tap(inc, warnIfMissed: false);
        expect(changes, isEmpty);
        await tester.tap(dec);
        expect(changes, [210]);
        handle.dispose();
      }, variant: variant);

      testWidgets('步長不整除時不越過上限', (tester) async {
        final changes = <int>[];
        await _pump(
          tester,
          AdaptiveStepper(
            label: '可延長次數',
            value: 9,
            min: 0,
            max: 10,
            step: 2,
            format: (n) => '$n次',
            onChanged: changes.add,
          ),
          center: true,
        );
        await tester.tap(inc, warnIfMissed: false);
        expect(changes, isEmpty);
        await tester.tap(dec);
        expect(changes, [7]);
      }, variant: variant);

      testWidgets('大字 2.0 不溢位', (tester) async {
        await _pump(tester, stepper(120, (_) {}), scale: 2, center: true);
        expect(tester.takeException(), isNull);
        expect(find.text('2小時'), findsOneWidget);
      }, variant: variant);
    });
  }
}
