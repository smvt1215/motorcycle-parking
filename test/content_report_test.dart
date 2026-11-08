import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import 'package:motorcycle_parking/data/account_suspended.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/content_report_display.dart';
import 'package:motorcycle_parking/domain/hidden_riders_display.dart';
import 'package:motorcycle_parking/domain/precheck.dart' show reportRefusal;
import 'package:motorcycle_parking/domain/spot_contributor.dart';
import 'package:motorcycle_parking/features/content_report/content_report.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart'
    show SignInPrompt;
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 't280_harness.dart';

const riderSpot = ParkingSpot(
  id: 'rider-spot',
  name: '市府轉運站機車區',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  contributorName: '阿明',
  contributorRole: 'rider',
);
const unnamedSpot = ParkingSpot(
  id: 'unnamed-spot',
  name: '永吉路巷口機車格',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  contributorRole: 'rider',
);
const importedSpot = ParkingSpot(
  id: 'import-spot',
  name: '匯入的機車格',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: 'import',
  contributorRole: 'import',
);
const officialSpot = ParkingSpot(
  id: 'official:1',
  name: '市政府機車停車場',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  source: 'official',
);

/// A store whose sign-in and submit the test decides.
class ReportStore extends AppStore {
  ReportStore(LocalRepository local) : super(local, null);
  bool signedIn = true;
  Object? failWith;
  final sent = <Map<String, dynamic>>[];

  @override
  bool get canReport => signedIn;

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    if (!signedIn) throw StateError('請先以 Google 或 Apple 登入才能回報');
    if (failWith case final error?) throw error;
    sent.add(body);
    return 'ok';
  }
}

Future<ReportStore> reportStore() async {
  SharedPreferences.setMockInitialValues({});
  return ReportStore(LocalRepository(await SharedPreferences.getInstance()));
}

Future<void> openReport(
  WidgetTester tester,
  AppStore store,
  ParkingSpot spot, {
  double scale = 1,
}) async {
  await tester.pumpWidget(
    app(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showContentReport(context, store, spot),
            child: const Text('open'),
          ),
        ),
      ),
      scale: scale,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder get submitButton => find.byKey(const ValueKey('content-report-submit'));

bool submitEnabled(WidgetTester tester) {
  final button = tester.widget<AdaptiveButton>(submitButton);
  return button.onPressed != null;
}

Future<void> pick(WidgetTester tester, ContentReportTarget target) async {
  final tile = find.byKey(ValueKey('content-report-${target.wire}'));
  // Built lazily: on a short sheet the tile may not exist until scrolled to.
  await tester.scrollUntilVisible(
    tile,
    100,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('content-report-form')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await centre(tester, tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

/// Scrolls [finder] to the middle of its list, clear of pinned bars.
Future<void> centre(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
}

Future<void> send(WidgetTester tester) async {
  await tester.tap(submitButton);
  await tester.pumpAndSettle();
}

/// submit-report's 400 for a note with a phone number (Codex #315).
const piiBody = {
  'error': 'precheck reject',
  'action': 'reject',
  'message': '內容含有電話號碼。為保護個人資料，請刪除電話號碼再送出。',
  'issues': [
    {
      'rule': 'pii_phone',
      'action': 'reject',
      'field': 'note',
      'message': '內容含有電話號碼。為保護個人資料，請刪除電話號碼再送出。',
    },
  ],
};

void main() {
  test('送出格式照 API 草案：flag、inappropriate、proposed.target、note', () {
    expect(
      contentReportBody(riderSpot, ContentReportTarget.contributorName, ' 罵人 '),
      {
        'action': 'flag',
        'source_id': 'rider-spot',
        'reason': '內容不當：車友名稱',
        'field': 'inappropriate',
        'proposed': {'target': 'rider_name'},
        'note': '罵人',
      },
    );
    expect(
      contentReportBody(riderSpot, ContentReportTarget.spotName, ''),
      isNot(contains('note')),
    );
    expect(ContentReportTarget.values.map((t) => t.wire), [
      'rider_name',
      'spot_name',
      'text',
      'impersonation',
      'other',
    ]);
  });

  test('結果只看狀態碼：409 重複、429 上限，其他都是失敗', () {
    expect(
      contentReportRefusal(
        const FunctionException(
          status: 409,
          details: {'error': 'duplicate report'},
        ),
      ),
      ContentReportOutcome.duplicate,
    );
    expect(
      contentReportRefusal(const FunctionException(status: 429)),
      ContentReportOutcome.limit,
    );
    for (final status in [400, 403, 500]) {
      expect(contentReportRefusal(FunctionException(status: status)), isNull);
    }
    expect(contentReportRefusal(Exception('offline')), isNull);
  });

  test('「車友名稱」只在有公開車友名稱時出現', () {
    expect(
      contentReportTargets(riderSpot),
      contains(ContentReportTarget.contributorName),
    );
    for (final spot in [unnamedSpot, importedSpot]) {
      expect(
        contentReportTargets(spot),
        isNot(contains(ContentReportTarget.contributorName)),
      );
    }
    const email = ParkingSpot(
      id: 'e',
      name: 'x',
      lat: 0,
      lng: 0,
      city: '',
      spaceType: SpaceType.paidMotorcycle,
      contributorName: 'a@b.c',
    );
    expect(publicRiderName(email), isEmpty);
  });

  test('目前文案：先暫時隱藏、5 個工作天內審核', () {
    expect(contentReportIntro, '送出後，被檢舉的內容會先暫時隱藏，管理員會在 5 個工作天內審核。檢舉不會通知對方。');
    expect(contentReportSentBody, '已送出。被檢舉的內容會先暫時隱藏，管理員會在 5 個工作天內審核。');
    expect(contentReportDuplicateBody, contains('5 個工作天'));
    for (final text in [
      contentReportIntro,
      contentReportSentBody,
      contentReportDuplicateBody,
    ]) {
      expect(text, isNot(contains('24 小時')));
    }
  });

  test('附註以 UTF-16 長度限制 500（伺服器的算法）', () {
    const limit = Utf16LengthLimit(500);
    final ok = limit.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(text: 'a' * 500),
    );
    expect(ok.text.length, 500);
    final emoji = limit.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(text: 'a' * 499 + '😀'),
    );
    expect(emoji.text, 'a' * 499);
  });

  test('附註或摘要被拒：400 且 issues 有 note／reason 才算，網址另有一句', () {
    expect(
      noteRefusalMessage(ReportRefused(reportRefusal(piiBody)!, piiBody)),
      contentReportNotePersonal,
    );
    expect(
      noteRefusalMessage(
        const FunctionException(status: 400, details: piiBody),
      ),
      contentReportNotePersonal,
    );
    Map<String, Object> refusal(String rule, String field) => {
      'error': 'precheck reject',
      'action': 'reject',
      'message': 'x',
      'issues': [
        {'rule': rule, 'action': 'reject', 'field': field, 'message': 'x'},
      ],
    };
    expect(
      noteRefusalMessage(
        FunctionException(status: 400, details: refusal('pii_email', 'reason')),
      ),
      contentReportNotePersonal,
    );
    expect(
      noteRefusalMessage(
        FunctionException(status: 400, details: refusal('ad_url', 'note')),
      ),
      contentReportNoteLink,
    );
    expect(
      noteRefusalMessage(
        FunctionException(status: 400, details: refusal('pii_email', 'name')),
      ),
      isNull,
    );
    expect(
      noteRefusalMessage(
        const FunctionException(
          status: 400,
          details: {'error': 'invalid note'},
        ),
      ),
      isNull,
    );
    expect(
      noteRefusalMessage(FunctionException(status: 500, details: piiBody)),
      isNull,
    );
  });

  group('P17b 檢舉表單', () {
    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        testWidgetsOn('${platform.name} $name：選原因才能送出、成功畫面', (tester) async {
          setUpView(tester, platform, size);
          final store = (await tester.runAsync(reportStore))!;
          await openReport(tester, store, riderSpot);
          expect(tester.takeException(), isNull);
          expect(find.text(contentReportTitle), findsOneWidget);
          expect(find.text(contentReportIntro), findsOneWidget);
          expect(find.text('「阿明」'), findsOneWidget);
          expect(find.text('「市府轉運站機車區」'), findsWidgets);
          expect(submitEnabled(tester), isFalse);

          await pick(tester, ContentReportTarget.contributorName);
          expect(submitEnabled(tester), isTrue);
          await tester.enterText(
            find.byKey(const ValueKey('content-report-note')),
            '名字裡有辱罵字眼。',
          );
          await send(tester);
          expect(store.sent.single['proposed'], {'target': 'rider_name'});
          expect(store.sent.single['note'], '名字裡有辱罵字眼。');
          expect(find.text(contentReportSentTitle), findsOneWidget);
          expect(find.text(contentReportSentBody), findsOneWidget);
          // No handle on this spot (the model has none yet): no shortcut.
          expect(
            find.byKey(const ValueKey('content-report-hide')),
            findsNothing,
          );
          await tester.tap(find.byKey(const ValueKey('content-report-done')));
          await tester.pumpAndSettle();
          expect(find.byType(ContentReportSheet), findsNothing);
        });
      }

      // iPhone report (2026-11-08): the keyboard covered the note and
      // 送出檢舉 after picking 其他. A phone on its side (Codex #379) leaves
      // only ~170 pt above its keyboard.
      for (final (name, size, inset) in [
        for (final (name, size) in layouts) (name, size, 300.0),
        ('phone landscape', const Size(844, 390), 216.0),
      ]) {
        testWidgetsOn('${platform.name} $name：鍵盤出現時附註欄與送出檢舉在鍵盤上方', (
          tester,
        ) async {
          setUpView(tester, platform, size);
          final store = (await tester.runAsync(reportStore))!;
          await openReport(tester, store, riderSpot);
          await pick(tester, ContentReportTarget.other);
          final noteField = find.byKey(const ValueKey('content-report-note'));
          await tester.showKeyboard(noteField);
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final keyboardTop = size.height - inset;
          // The focused field scrolled clear of the keyboard.
          final field = tester.getRect(find.byType(EditableText));
          expect(field.top, greaterThanOrEqualTo(0), reason: '$field');
          expect(
            field.bottom,
            lessThanOrEqualTo(keyboardTop),
            reason: '$field',
          );
          if (size.height > size.width) {
            // Pinned right above the keyboard, under the field.
            final submit = tester.getRect(submitButton);
            expect(
              submit.bottom,
              lessThanOrEqualTo(keyboardTop),
              reason: '$submit',
            );
            expect(field.bottom, lessThanOrEqualTo(submit.top));
          }
          // A phone on its side: too short to pin, so it scrolls to it.
          await tester.ensureVisible(submitButton);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(submitButton).bottom,
            lessThanOrEqualTo(keyboardTop),
          );
          expect(submitButton.hitTestable(), findsOneWidget);
          await tester.ensureVisible(noteField);
          await tester.pumpAndSettle();
          await tester.enterText(noteField, '其他原因');
          await tester.pumpAndSettle();

          // No dismiss key on Zhuyin: a tap on the form's blank part puts
          // the keyboard away, and 送出檢舉 still sends.
          bool focused() => tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus;
          expect(focused(), isTrue);
          // The form's margin beside the field.
          final beside = tester.getRect(noteField);
          await tester.tapAt(Offset(beside.left - 10, beside.center.dy));
          await tester.pumpAndSettle();
          expect(focused(), isFalse);
          await send(tester);
          expect(store.sent.single['note'], '其他原因');
        });
      }

      testWidgetsOn('${platform.name} 選「其他」但附註空白：顯示錯誤、不送出', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!;
        await openReport(tester, store, riderSpot);
        await pick(tester, ContentReportTarget.other);
        expect(
          find.text(contentReportNoteLabel(required: true)),
          findsOneWidget,
        );
        await send(tester);
        expect(store.sent, isEmpty);
        expect(find.text(contentReportNoteMissing), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('content-report-note')),
          '第二段',
        );
        await tester.pumpAndSettle();
        expect(find.text(contentReportNoteMissing), findsNothing);
        await send(tester);
        expect(store.sent.single['proposed'], {'target': 'other'});
      });

      testWidgetsOn('${platform.name} 重複檢舉（409）', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!
          ..failWith = const FunctionException(
            status: 409,
            details: {'error': 'duplicate report'},
          );
        await openReport(tester, store, riderSpot);
        await pick(tester, ContentReportTarget.spotName);
        await send(tester);
        expect(find.text(contentReportDuplicateTitle), findsOneWidget);
        expect(find.text(contentReportDuplicateBody), findsOneWidget);
      });

      testWidgetsOn('${platform.name} 已達每日上限（429）', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!
          ..failWith = const FunctionException(
            status: 429,
            details: {'error': 'daily report limit reached'},
          );
        await openReport(tester, store, riderSpot);
        await pick(tester, ContentReportTarget.spotName);
        await send(tester);
        expect(find.text(contentReportLimitTitle), findsOneWidget);
        expect(find.text(contentReportLimitBody), findsOneWidget);
      });

      testWidgetsOn('${platform.name} 送出失敗：內容保留、可以再送', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!
          ..failWith = const FunctionException(status: 500);
        await openReport(tester, store, riderSpot);
        await pick(tester, ContentReportTarget.description);
        await tester.enterText(
          find.byKey(const ValueKey('content-report-note')),
          '備註有髒話',
        );
        await send(tester);
        expect(find.text(contentReportFailed), findsOneWidget);
        expect(find.text('備註有髒話'), findsOneWidget);
        expect(submitEnabled(tester), isTrue);
        store.failWith = null;
        await send(tester);
        expect(store.sent.single['proposed'], {'target': 'text'});
        expect(find.text(contentReportSentTitle), findsOneWidget);
      });

      testWidgetsOn('${platform.name} 附註含個資被拒：顯示提示、內容保留', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!
          // What ParkingRepository.report throws for that 400.
          ..failWith = ReportRefused(reportRefusal(piiBody)!, piiBody);
        await openReport(tester, store, riderSpot);
        // The helper under the note says it before sending.
        expect(find.text(contentReportNotePersonal), findsOneWidget);
        await pick(tester, ContentReportTarget.personalData);
        await tester.enterText(
          find.byKey(const ValueKey('content-report-note')),
          '他的電話 0912-345-678',
        );
        await send(tester);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('content-report-failure')),
            matching: find.text(contentReportNotePersonal),
          ),
          findsOneWidget,
        );
        expect(find.text('他的電話 0912-345-678'), findsOneWidget);
        expect(submitEnabled(tester), isTrue);
      });

      testWidgetsOn('${platform.name} 附註含網址被拒：顯示網址提示', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        const body = {
          'error': 'precheck reject',
          'action': 'reject',
          'message': '請刪除網址再送出。',
          'issues': [
            {
              'rule': 'ad_url',
              'action': 'reject',
              'field': 'note',
              'message': '請刪除網址再送出。',
            },
          ],
        };
        final store = (await tester.runAsync(reportStore))!
          ..failWith = const FunctionException(status: 400, details: body);
        await openReport(tester, store, riderSpot);
        await pick(tester, ContentReportTarget.description);
        await send(tester);
        expect(find.text(contentReportNoteLink), findsOneWidget);
        expect(submitEnabled(tester), isTrue);
      });

      for (final (name, refusal) in <(String, Object)>[
        (
          '403 account.suspended',
          const FunctionException(
            status: 403,
            details: {
              'error': 'account.suspended',
              'until': '2026-12-01T00:00:00Z',
            },
          ),
        ),
        ('AccountSuspended', AccountSuspended(DateTime.utc(2026, 12))),
      ]) {
        testWidgetsOn('${platform.name} 帳號停權（$name）：停權面板、內容保留', (tester) async {
          setUpView(tester, platform, const Size(390, 844));
          final store = (await tester.runAsync(reportStore))!
            ..failWith = refusal;
          await openReport(tester, store, riderSpot);
          await pick(tester, ContentReportTarget.description);
          await tester.enterText(
            find.byKey(const ValueKey('content-report-note')),
            '備註有髒話',
          );
          await send(tester);
          expect(find.byKey(const ValueKey('suspended-panel')), findsOneWidget);
          expect(find.byKey(const ValueKey('suspended-until')), findsOneWidget);
          final dismiss = find.byKey(const ValueKey('suspended-dismiss'));
          await tester.ensureVisible(dismiss);
          await tester.tap(dismiss);
          await tester.pumpAndSettle();
          // Back on the form, as filled in, and it can be sent again.
          expect(find.byKey(const ValueKey('suspended-panel')), findsNothing);
          expect(find.byType(ContentReportSheet), findsOneWidget);
          expect(find.text('備註有髒話'), findsOneWidget);
          expect(find.text(contentReportFailed), findsNothing);
          expect(submitEnabled(tester), isTrue);
          store.failWith = null;
          await send(tester);
          expect(store.sent.single['proposed'], {'target': 'text'});
          expect(find.text(contentReportSentTitle), findsOneWidget);
        });
      }

      testWidgetsOn('${platform.name} 其他 400：一般失敗、內容保留', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!
          ..failWith = const FunctionException(
            status: 400,
            details: {'error': 'invalid proposed'},
          );
        await openReport(tester, store, riderSpot);
        await pick(tester, ContentReportTarget.spotName);
        await send(tester);
        expect(find.text(contentReportFailed), findsOneWidget);
        expect(submitEnabled(tester), isTrue);
      });

      testWidgetsOn('${platform.name} 沒登入：登入提示、送出停用', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!..signedIn = false;
        await openReport(tester, store, riderSpot);
        expect(find.byType(SignInPrompt), findsOneWidget);
        expect(find.text(contentReportSignIn), findsOneWidget);
        await pick(tester, ContentReportTarget.spotName);
        expect(submitEnabled(tester), isFalse);
      });
    }

    testWidgetsOn('大字 2.0：表單與結果不溢出', (tester) async {
      setUpView(tester, TargetPlatform.android, const Size(390, 844));
      final store = (await tester.runAsync(reportStore))!;
      await openReport(tester, store, riderSpot, scale: 2);
      expect(tester.takeException(), isNull);
      await pick(tester, ContentReportTarget.personalData);
      await send(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(contentReportSentTitle), findsOneWidget);
    });

    testWidgetsOn('沒有公開名稱的點不顯示「車友名稱」', (tester) async {
      setUpView(tester, TargetPlatform.iOS, const Size(390, 844));
      final store = (await tester.runAsync(reportStore))!;
      await openReport(tester, store, importedSpot);
      expect(find.text('車友名稱'), findsNothing);
      expect(find.text('停車點名稱'), findsOneWidget);
    });
  });

  group('P17a ⑤ ⋯ 選單', () {
    Future<void> openSpot(
      WidgetTester tester,
      AppStore store,
      ParkingSpot spot,
    ) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSpot(context, store, spot),
                child: const Text('details'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('details'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('parking-spot-sheet')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
    }

    final more = find.byKey(const ValueKey('spot-more'));

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 車友的點：朗讀「這筆回報：更多動作」，沒有代號只能檢舉', (
        tester,
      ) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!;
        final semantics = tester.ensureSemantics();
        await openSpot(tester, store, riderSpot);
        await tester.scrollUntilVisible(
          more,
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('parking-spot-sheet')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.bySemanticsLabel('這筆回報：更多動作'), findsOneWidget);
        expect(
          tester.getSize(more).height,
          greaterThanOrEqualTo(platform == TargetPlatform.iOS ? 44 : 48),
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(find.text(reportContentAction), findsOneWidget);
        expect(find.text(hideRiderAction), findsNothing);
        await tester.tap(find.text(reportContentAction));
        await tester.pumpAndSettle();
        expect(find.byType(ContentReportSheet), findsOneWidget);
        semantics.dispose();
      });

      testWidgetsOn('${platform.name} 匯入的點：朗讀「這筆資料：更多動作」', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!;
        final semantics = tester.ensureSemantics();
        await openSpot(tester, store, importedSpot);
        await tester.scrollUntilVisible(
          more,
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('parking-spot-sheet')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.bySemanticsLabel('這筆資料：更多動作'), findsOneWidget);
        semantics.dispose();
      });

      testWidgetsOn('${platform.name} 官方點沒有 ⋯', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!;
        await openSpot(tester, store, officialSpot);
        expect(more, findsNothing);
      });
    }
  });

  group('P17b ① 修改建議清單', () {
    Future<void> openSuggestions(
      WidgetTester tester,
      AppStore store,
      ParkingSpot spot,
    ) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSpotSuggestions(context, store, spot),
                child: const Text('suggest'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('suggest'));
      await tester.pumpAndSettle();
    }

    final row = find.byKey(const ValueKey('suggest-content-report'));

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 社群點有「內容有問題」，點了開檢舉表單', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!;
        await openSuggestions(tester, store, riderSpot);
        await tester.scrollUntilVisible(
          row,
          200,
          // The suggestion list is the only scrolling view on screen.
          scrollable: find.byType(Scrollable).first,
        );
        await centre(tester, row);
        expect(find.text(contentProblemGroup), findsOneWidget);
        expect(find.text(contentProblemDetail), findsOneWidget);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byType(ContentReportSheet), findsOneWidget);
      });

      testWidgetsOn('${platform.name} 官方點沒有「內容有問題」', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(reportStore))!;
        await openSuggestions(tester, store, officialSpot);
        expect(row, findsNothing);
        expect(find.text(contentProblemGroup), findsNothing);
      });
    }
  });
}
