import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/fee_editor.dart';

void main() {
  /// Hosts an editor in a form at [width]; returns the form key and a getter
  /// for the latest fee.
  Future<(GlobalKey<FormState>, Fee Function())> host(
    WidgetTester tester,
    double width, {
    Fee initial = const Fee(),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final form = GlobalKey<FormState>();
    var fee = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                StatefulBuilder(
                  builder: (context, setState) => FeeEditor(
                    value: fee,
                    onChanged: (v) => setState(() => fee = v),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return (form, () => fee);
  }

  Future<void> pick(WidgetTester tester, String menu, String item) async {
    await tester.tap(find.byKey(ValueKey(menu)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  for (final width in [390.0, 700.0]) {
    testWidgets('寬度 $width：分車種選收費方式，預覽組成的文字', (tester) async {
      final (form, fee) = await host(tester, width);
      expect(find.text('顯示為：請依現場公告'), findsOneWidget);
      await pick(tester, 'fee-mode-scooter', '計時');
      expect(find.text('請填完金額，才會顯示費率'), findsOneWidget);
      // An hourly rate needs its amount before the form can be sent.
      expect(form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('請填寫金額'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, '金額'), '20');
      await tester.enterText(
        find.widgetWithText(TextFormField, '當日上限（選填）'),
        '100',
      );
      await pick(tester, 'fee-mode-heavy', '比照汽車費率');
      await tester.pumpAndSettle();
      expect(
        find.text('顯示為：機車每小時 20 元，當日上限 100 元（上限計算方式未確認）；大型重機費率未提供'),
        findsOneWidget,
      );
      expect(form.currentState!.validate(), isTrue);
      expect(fee().toJson(), {
        'scooter': {
          'mode': 'hourly',
          'amount': 20,
          'per_minutes': 60,
          'daily_cap': 100,
        },
        'heavy': {'mode': 'same_as_car'},
      });
      // Amounts sit side by side in a wide pane and stack on phones.
      final amount = tester.getRect(find.widgetWithText(TextFormField, '金額'));
      final cap = tester.getRect(
        find.widgetWithText(TextFormField, '當日上限（選填）'),
      );
      expect(amount.top == cap.top, width >= 560);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('金額只接受 0 到 10000 的整數；改回未確認即清除該車種', (tester) async {
    final (form, fee) = await host(tester, 390);
    await pick(tester, 'fee-mode-scooter', '每日');
    await tester.enterText(find.widgetWithText(TextFormField, '每日金額'), '20000');
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('請填 0 到 10000 的整數'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '每日金額'), '30');
    expect(form.currentState!.validate(), isTrue);
    expect(fee().scooter, const Rate(FeeMode.daily, amount: 30));
    await pick(tester, 'fee-mode-scooter', '未確認');
    expect(fee().isEmpty, isTrue);
    expect(find.widgetWithText(TextFormField, '每日金額'), findsNothing);
  });

  testWidgets('比照其他車種只出現在大型重機', (tester) async {
    await host(tester, 390);
    await tester.tap(find.byKey(const ValueKey('fee-mode-scooter')));
    await tester.pumpAndSettle();
    expect(find.text('比照汽車費率'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fee-mode-heavy')));
    await tester.pumpAndSettle();
    expect(find.text('比照汽車費率'), findsWidgets);
    expect(find.text('比照機車費率'), findsWidgets);
  });

  testWidgets('改金額時保留編輯器還沒有欄位的設定與汽車費率', (tester) async {
    final initial = Fee.fromJson({
      'heavy': {
        'mode': 'per_visit',
        'amount': 40,
        'renew': 'midnight',
        'extension': {'amount': 40, 'max_times': 1},
      },
      'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
    });
    final (_, fee) = await host(tester, 390, initial: initial);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('fee-heavy')),
        matching: find.widgetWithText(TextFormField, '每次金額'),
      ),
      '50',
    );
    await tester.pumpAndSettle();
    expect(fee().heavy!.toJson(), {
      'mode': 'per_visit',
      'amount': 50,
      'renew': 'midnight',
      'extension': {'amount': 40, 'max_times': 1},
    });
    expect(fee().car, initial.car);
    // Another mode starts from its own fields only.
    await pick(tester, 'fee-mode-heavy', '每日');
    expect(fee().heavy!.renew, isNull);
  });
}
