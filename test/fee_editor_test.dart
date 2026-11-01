import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/fee_editor.dart';

import 'fee_editor_steps.dart';

void main() {
  /// Hosts an editor in a form at [width]; returns the form key and a getter
  /// for the latest fee.
  Future<(GlobalKey<FormState>, Fee Function())> host(
    WidgetTester tester,
    double width, {
    Fee initial = const Fee(),
    double scale = 1,
    bool dark = false,
    FeeVehicle? open,
    bool complete = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final form = GlobalKey<FormState>();
    var fee = initial;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: brand,
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                StatefulBuilder(
                  builder: (context, setState) => FeeEditor(
                    value: fee,
                    initialVehicle: open,
                    requireComplete: complete,
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

  Finder preview(String text) => find.descendant(
    of: find.byKey(const ValueKey('fee-preview')),
    matching: find.textContaining(text, findRichText: true),
  );

  Finder openVehicles() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('fee-open-'),
  );

  const hourly10 = Fee(
    scooter: Rate(FeeMode.hourly, amount: 10, perMinutes: 60),
  );

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    for (final (scale, dark) in [(1.0, false), (1.6, true)]) {
      testWidgets('寬 $width、${scale}x、${dark ? '深色' : '淺色'}：不溢出，觸控 ≥ 48', (
        tester,
      ) async {
        await host(
          tester,
          width,
          initial: hourly10,
          scale: scale,
          dark: dark,
          open: FeeVehicle.heavy,
        );
        await chooseFeeMode(tester, 'heavy', 'per_visit');
        expect(tester.takeException(), isNull);
        for (final key in [
          for (final m in [
            'not_applicable',
            'free',
            'hourly',
            'per_visit',
            'by_time',
            'same_as',
          ])
            'fee-mode-heavy-$m',
          'fee-row-scooter',
          'fee-row-car',
          'fee-renew-heavy-midnight',
          'fee-more-heavy',
        ]) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
        }
        // Phones and the two-pane column stack the vehicles, one open; wide
        // screens list them beside the fields and the preview.
        expect(openVehicles(), findsOneWidget);
        final fields = tester.getRect(
          find.byKey(const ValueKey('fee-open-heavy')),
        );
        final board = tester.getRect(find.byKey(const ValueKey('fee-preview')));
        if (width >= feeEditorWideWidth) {
          expect(board.left, greaterThan(fields.right));
        } else {
          expect(board.top, greaterThan(fields.bottom));
        }
        await chooseFeeMode(tester, 'heavy', 'by_time');
        await tapFee(tester, 'fee-days-heavy-p0-pick');
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 7; i++) {
          final day = tester.getSize(
            find.byKey(ValueKey('fee-day-heavy-p0-$i')),
          );
          expect(day.width, greaterThanOrEqualTo(48), reason: '週$i 寬');
          expect(day.height, greaterThanOrEqualTo(48), reason: '週$i 高');
        }
      });
    }
  }

  testWidgets('手機一次只展開一個車種，其他車種收合成公告牌上的那句話', (tester) async {
    await host(tester, 390, initial: hourly10);
    // The first vehicle with a rate opens; the others read as one line.
    expect(find.byKey(const ValueKey('fee-open-scooter')), findsOneWidget);
    expect(openVehicles(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fee-row-car')),
        matching: find.text('未提供'),
      ),
      findsOneWidget,
    );
    await tapFee(tester, 'fee-row-heavy');
    expect(find.byKey(const ValueKey('fee-open-heavy')), findsOneWidget);
    expect(openVehicles(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fee-row-scooter')),
        matching: find.text('每小時 10 元'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('收合'));
    await tester.pumpAndSettle();
    expect(openVehicles(), findsNothing);
  });

  testWidgets('App 表單預設展開目前車種', (tester) async {
    await host(tester, 390, open: FeeVehicle.heavy);
    expect(find.byKey(const ValueKey('fee-open-heavy')), findsOneWidget);
    expect(openVehicles(), findsOneWidget);
  });

  testWidgets('收費方式 6 種：不適用在最前，沒有「未確認」與「每日」（#188 第 2 層）', (tester) async {
    await host(tester, 390, open: FeeVehicle.car);
    expect(find.text('依現場公告'), findsNothing);
    for (final m in ['unknown', 'daily', 'posted']) {
      expect(find.byKey(ValueKey('fee-mode-car-$m')), findsNothing);
    }
    expect(
      find.byKey(const ValueKey('fee-mode-car-not_applicable')),
      findsOneWidget,
    );
    expect(find.text('這裡沒有這種車的格位就選「不適用」。'), findsOneWidget);
    // Only heavy bikes follow another vehicle.
    expect(find.byKey(const ValueKey('fee-mode-car-same_as')), findsNothing);
    expect(find.byKey(const ValueKey('fee-mode-car-by_time')), findsOneWidget);
  });

  testWidgets('不適用的車種存成 not_applicable，公告牌不列出', (tester) async {
    final (_, fee) = await host(tester, 390, initial: hourly10);
    await chooseFeeMode(tester, 'heavy', 'not_applicable');
    expect(fee().toJson()['heavy'], {'mode': 'not_applicable'});
    // The open vehicle still reads 不適用 in the preview; riders' boards
    // leave it out (fee_board_test).
    expect(preview('不適用'), findsOneWidget);
  });

  testWidgets('計次的「跨日怎麼收」只有兩個答案，送出前必須選（Un-1）', (tester) async {
    final (form, fee) = await host(
      tester,
      390,
      open: FeeVehicle.car,
      initial: const Fee(
        scooter: Rate(FeeMode.notApplicable),
        heavy: Rate(FeeMode.notApplicable),
      ),
      complete: true,
    );
    await chooseFeeMode(tester, 'car', 'per_visit');
    await tester.enterText(feeField('amount', 'car'), '40');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fee-renew-car-unknown')), findsNothing);
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.textContaining('汽車還有規則沒選'), findsOneWidget);
    expect(preview('未確認'), findsNothing);
    await tapFee(tester, 'fee-renew-car-midnight');
    expect(fee().car!.renew, Renew.midnight);
    expect(preview('隔日另計'), findsOneWidget);
    expect(find.text('停多久都只收一次'), findsOneWidget);
    expect(form.currentState!.validate(), isTrue);
  });

  testWidgets('首次 0 元與延長每次多少錢；限停時間不在費率裡（F2）', (tester) async {
    final (form, fee) = await host(tester, 390, open: FeeVehicle.heavy);
    await chooseFeeMode(tester, 'heavy', 'per_visit');
    await tester.enterText(feeField('amount', 'heavy'), '0');
    await tapFee(tester, 'fee-renew-heavy-none');
    await tapFee(tester, 'fee-more-heavy');
    expect(find.text('每次限停多久、可延長幾次在「限時」設定，不在費率裡'), findsOneWidget);
    await tester.enterText(feeField('ext-amount', 'heavy'), '40');
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    expect(fee().toJson()['heavy'], {
      'mode': 'per_visit',
      'amount': 0,
      'renew': 'none',
      'extension_amount': 40,
    });
    expect(preview('延長每次 40 元'), findsOneWidget);
    expect(preview('免費'), findsNothing);
    expect(find.byKey(const ValueKey('fee-free-heavy')), findsNothing);
  });

  testWidgets('計時的當日上限與上限重算，收合時列出已設的規則', (tester) async {
    final (form, fee) = await host(tester, 390);
    await chooseFeeMode(tester, 'scooter', 'hourly');
    await tester.enterText(feeField('amount', 'scooter'), '20');
    await tapFee(tester, 'fee-more-scooter');
    expect(find.byKey(const ValueKey('fee-unit-scooter')), findsNothing);
    await tester.enterText(feeField('cap', 'scooter'), '100');
    await tester.pumpAndSettle();
    await tapFee(tester, 'fee-cap-reset-scooter');
    expect(find.text('未確認'), findsNothing);
    await tester.tap(find.text('零時重算').last);
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    expect(fee().toJson()['scooter'], {
      'mode': 'hourly',
      'amount': 20,
      'per_minutes': 60,
      'daily_cap': 100,
      'cap_reset': 'calendar_day',
    });
    expect(preview('當日上限 100 元（零時重算）'), findsOneWidget);
    await tapFee(tester, 'fee-more-scooter');
    expect(find.text('已設：當日上限 100 元'), findsOneWidget);
  });

  testWidgets('比照其他車種：只能選有費率的車種，App 只顯示算好的金額', (tester) async {
    final (form, fee) = await host(
      tester,
      390,
      initial: hourly10,
      open: FeeVehicle.heavy,
    );
    await chooseFeeMode(tester, 'heavy', 'same_as');
    expect(find.text('和哪個車種收一樣的錢'), findsOneWidget);
    // The car rate is unconfirmed, so it cannot be followed.
    final car = tester.widget<RadioListTile<FeeMode>>(
      find.byKey(const ValueKey('fee-follow-car')),
    );
    expect(car.enabled, isFalse);
    expect(find.text('費率未提供，不能選'), findsOneWidget);
    expect(fee().heavy, const Rate(FeeMode.sameAsScooter));
    expect(find.text('普通機車的費率之後改了，大型重機會跟著變。'), findsOneWidget);
    // No factor (#188 layer 2).
    expect(find.byKey(const ValueKey('fee-factor')), findsNothing);
    expect(form.currentState!.validate(), isTrue);
    expect(fee().toJson()['heavy'], {'mode': 'same_as_scooter'});
    expect(preview('每小時 10 元'), findsWidgets);
    expect(preview('比照'), findsNothing);
  });

  testWidgets('依時段不同：每段選哪幾天與時間，未涵蓋寫出來，有計次且兩段以上就問跨時段（C7）', (tester) async {
    final (form, fee) = await host(tester, 390, open: FeeVehicle.car);
    await chooseFeeMode(tester, 'car', 'by_time');
    // The first period is open: every day, all day, hourly.
    await tapFee(tester, 'fee-days-car-p0-weekday');
    await tapFee(tester, 'fee-all-day-car-p0-false');
    await tapFee(tester, 'fee-mode-car-p0-per_visit');
    await tester.enterText(feeField('amount', 'car-p0'), '30');
    await tapFee(tester, 'fee-renew-car-p0-none');
    // Decision 55: the gaps in a few words first, the times under
    // 看完整時段; decision 47: gaps are the start day's.
    expect(find.text('平日夜間、假日全天沒有費率'), findsOneWidget);
    expect(find.text('・週五 20:00–隔日 00:00'), findsNothing);
    await tapFee(tester, 'fee-gaps-more-car');
    for (final gap in [
      '週一 00:00–08:00',
      '週一、週二、週三、週四 20:00–隔日 08:00',
      '週五 20:00–隔日 00:00',
      '假日 全天',
    ]) {
      expect(find.text('・$gap'), findsOneWidget);
    }
    await tapFee(tester, 'fee-gaps-more-car');
    expect(find.text('・假日 全天'), findsNothing);
    await tapFee(tester, 'fee-period-add-car');
    // The new period opens and the first collapses to one line.
    expect(find.text('每次 30 元，停多久都只收一次'), findsOneWidget);
    await tapFee(tester, 'fee-days-car-p1-pick');
    // 指定 starts from the days the period covered: every day.
    await tapFee(tester, 'fee-day-car-p1-0');
    // A per-visit period beside another: 停到下一個時段時 (C7).
    expect(find.text('停到下一個時段時'), findsOneWidget);
    await tapFee(tester, 'fee-mode-car-p1-per_visit');
    await tester.enterText(feeField('amount', 'car-p1'), '50');
    await tester.pumpAndSettle();
    expect(fee().car!.crossPeriod, isNull);
    expect(preview('跨時段計費方式未確認'), findsNothing);
    await tapFee(tester, 'fee-cross-car-each_period');
    expect(fee().car!.crossPeriod, CrossPeriod.eachPeriod);
    expect(preview('跨時段分別計費'), findsOneWidget);
    expect(form.currentState!.validate(), isTrue);
    expect(fee().toJson()['car'], {
      'mode': 'by_time',
      'periods': [
        {
          'days': 'weekday',
          'from': '08:00',
          'to': '20:00',
          'rate': {'mode': 'per_visit', 'amount': 30, 'renew': 'none'},
        },
        {
          'days': ['tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
          'from': '08:00',
          'to': '20:00',
          'rate': {'mode': 'per_visit', 'amount': 50},
        },
      ],
      'cross_period': 'each_period',
    });
    // Picked weekdays are listed day by day on the board (canvas FeeDays).
    expect(preview('週二、週三、週四、週五、週六、週日'), findsOneWidget);
    // One period left: the choice it no longer needs goes.
    await tapFee(tester, 'fee-period-remove-car-p1');
    expect(find.text('停到下一個時段時'), findsNothing);
    expect(fee().car!.crossPeriod, isNull);
  });

  testWidgets('收合的車種沒填完也擋下送出', (tester) async {
    final (form, _) = await host(tester, 390);
    await chooseFeeMode(tester, 'scooter', 'per_visit');
    await tester.enterText(feeField('amount', 'scooter'), '20000');
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('請填 0 到 10000 的整數'), findsOneWidget);
    await tester.enterText(feeField('amount', 'scooter'), '');
    await tester.pumpAndSettle();
    await tapFee(tester, 'fee-row-heavy');
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('普通機車的費率還沒填完，請填好'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fee-row-scooter')),
        matching: find.text('還沒填完'),
      ),
      findsOneWidget,
    );
    expect(preview('普通機車的金額填好後才會顯示'), findsOneWidget);
  });

  testWidgets('填了任一車種，三個車種都要選（PM_ANS_20261101_55）', (tester) async {
    final (form, fee) = await host(
      tester,
      390,
      initial: hourly10,
      complete: true,
    );
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('請選大型重機、汽車的收費方式；這裡沒有這種車的格位就選「不適用」'), findsOneWidget);
    await chooseFeeMode(tester, 'heavy', 'not_applicable');
    await chooseFeeMode(tester, 'car', 'not_applicable');
    expect(form.currentState!.validate(), isTrue);
    expect(fee().writeComplete, isTrue);
  });

  testWidgets('沒有填任何費率也可以送出', (tester) async {
    final (form, _) = await host(tester, 390, complete: true);
    expect(form.currentState!.validate(), isTrue);
  });

  testWidgets('汽車費率存在 fee.car，編輯中的車種排在預覽第一', (tester) async {
    final (form, fee) = await host(tester, 390, initial: hourly10);
    await chooseFeeMode(tester, 'car', 'hourly');
    await tester.enterText(feeField('amount', 'car'), '40');
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    expect(fee().toJson(), {
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
      'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
    });
    expect(
      tester.getTopLeft(preview('汽車')).dy,
      lessThan(tester.getTopLeft(preview('普通機車')).dy),
    );
  });

  testWidgets('公告牌預覽是唯一醒目元素：只有它有粗框', (tester) async {
    await host(
      tester,
      390,
      initial: const Fee(
        scooter: Rate(FeeMode.hourly, amount: 10, perMinutes: 60),
        heavy: Rate(FeeMode.perVisit, amount: 40),
      ),
      open: FeeVehicle.heavy,
    );
    // Every box draws through a DecoratedBox; only the preview's is thick.
    final thick = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          ((w.decoration as BoxDecoration).border?.top.width ?? 0) >= 2,
    );
    expect(thick, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('fee-preview')),
        matching: thick,
      ),
      findsOneWidget,
    );
    expect(preview('App 會顯示'), findsOneWidget);
    expect(preview('每次 40 元'), findsOneWidget);
    // An old rate without renew says nothing of it (Un-1).
    expect(preview('未確認'), findsNothing);
  });

  testWidgets('改金額時保留其他設定與汽車費率；換收費方式只帶該方式的欄位', (tester) async {
    final initial = Fee.fromJson({
      'heavy': {
        'mode': 'per_visit',
        'amount': 40,
        'renew': 'midnight',
        'extension_amount': 40,
      },
      'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
    });
    final (_, fee) = await host(tester, 390, initial: initial);
    expect(find.byKey(const ValueKey('fee-open-heavy')), findsOneWidget);
    await tester.enterText(feeField('amount', 'heavy'), '50');
    await tester.pumpAndSettle();
    expect(fee().heavy!.toJson(), {
      'mode': 'per_visit',
      'amount': 50,
      'renew': 'midnight',
      'extension_amount': 40,
    });
    expect(fee().car, initial.car);
    await chooseFeeMode(tester, 'heavy', 'hourly');
    expect(fee().heavy!.toJson(), {
      'mode': 'hourly',
      'amount': 50,
      'per_minutes': 60,
    });
  });

  testWidgets('比照：沒有已知來源時不能選；被比照的車種改回未確認時擋下送出', (tester) async {
    final (form, fee) = await host(tester, 390, open: FeeVehicle.heavy);
    // Neither the scooter nor the car has a rate: nothing to follow.
    expect(find.byKey(const ValueKey('fee-follow-hint')), findsOneWidget);
    await tapFee(tester, 'fee-mode-heavy-same_as');
    expect(fee().heavy, isNull);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('fee-mode-heavy-same_as'))),
      matchesSemantics(
        label: '比照其他車種',
        isButton: true,
        hasSelectedState: true,
        // Disabled: shown, not tappable.
        hasEnabledState: true,
      ),
    );

    await chooseFeeMode(tester, 'car', 'hourly');
    await tester.enterText(feeField('amount', 'car'), '40');
    await tester.pumpAndSettle();
    await chooseFeeMode(tester, 'heavy', 'same_as');
    // Only the car has a rate, so the heavy bike follows the car.
    expect(fee().toJson()['heavy'], {'mode': 'same_as_car'});
    expect(form.currentState!.validate(), isTrue);
    await chooseFeeMode(tester, 'car', 'not_applicable');
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('大型重機比照汽車費率，但還沒填汽車費率。請填汽車費率，或改選其他收費方式。'), findsOneWidget);
  });

  testWidgets('清空當日上限一併清除重算方式', (tester) async {
    final (form, fee) = await host(tester, 390);
    await chooseFeeMode(tester, 'scooter', 'hourly');
    await tester.enterText(feeField('amount', 'scooter'), '10');
    await tapFee(tester, 'fee-more-scooter');
    await tester.enterText(feeField('cap', 'scooter'), '50');
    await tester.pumpAndSettle();
    await tapFee(tester, 'fee-cap-reset-scooter');
    await tester.tap(find.text('零時重算').last);
    await tester.pumpAndSettle();
    expect(fee().scooter!.capReset, CapReset.calendarDay);
    await tester.enterText(feeField('cap', 'scooter'), '');
    await tester.pumpAndSettle();
    expect(fee().scooter!.capReset, isNull);
    expect(form.currentState!.validate(), isTrue);
  });

  testWidgets('上限填了讀不出的文字後收合再展開，欄位不顯示 -1 並清掉該值', (tester) async {
    final (form, fee) = await host(tester, 390);
    await chooseFeeMode(tester, 'scooter', 'hourly');
    await tester.enterText(feeField('amount', 'scooter'), '10');
    await tapFee(tester, 'fee-more-scooter');
    await tester.enterText(feeField('cap', 'scooter'), 'abc');
    await tester.pumpAndSettle();
    // Unreadable text stays out of range, never silently dropped.
    expect(fee().scooter!.dailyCap, -1);
    expect(form.currentState!.validate(), isFalse);
    await tapFee(tester, 'fee-row-heavy');
    await tapFee(tester, 'fee-row-scooter');
    await tapFee(tester, 'fee-more-scooter');
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: feeField('cap', 'scooter'),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '',
    );
    expect(fee().scooter!.dailyCap, isNull);
    expect(form.currentState!.validate(), isTrue);
  });
}
