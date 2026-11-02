import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/content_report_display.dart';
import 'package:motorcycle_parking/domain/hidden_riders_display.dart';
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
