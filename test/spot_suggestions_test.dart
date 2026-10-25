import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const spot = ParkingSpot(
  id: '00000000-0000-4000-8000-000000000123',
  name: '尚未收到不存在回報的機車停車點',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.freeMotorcycle,
);

class RecordingStore extends AppStore {
  RecordingStore(LocalRepository local) : super(local, null);
  final submissions = <Map<String, dynamic>>[];
  bool failNext = false;

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    submissions.add(body);
    if (failNext) {
      failNext = false;
      throw StateError('連線失敗，請重試');
    }
    return '已送交審核';
  }
}

Future<RecordingStore> createStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = RecordingStore(
    LocalRepository(await SharedPreferences.getInstance()),
  );
  store.spots = [spot];
  return store;
}

Future<void> openDetails(
  WidgetTester tester,
  RecordingStore store, {
  ParkingSpot selectedSpot = spot,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpot(context, store, selectedSpot),
            child: const Text('開啟點位'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟點位'));
  await tester.pumpAndSettle();
}

void main() {
  for (final dismissal in ['完成', '關閉', '返回', '下滑']) {
    testWidgets('建議成功後以$dismissal離開，同時關閉父面板', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      await openDetails(tester, store);
      await tester.ensureVisible(find.text('修改建議'));
      await tester.tap(find.text('修改建議'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停車點名稱'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('suggestion-input')),
        '市府路機車格',
      );
      await tester.tap(find.text('送出建議'));
      await tester.pumpAndSettle();
      expect(find.text('完成'), findsOneWidget);
      switch (dismissal) {
        case '完成':
          await tester.tap(find.text('完成'));
        case '關閉':
          await tester.tap(find.byTooltip('關閉').last);
        case '返回':
          await tester.binding.handlePopRoute();
        case '下滑':
          final sheet = tester.getRect(find.byType(BottomSheet).last);
          await tester.flingFrom(
            Offset(sheet.center.dx, sheet.top + 20),
            const Offset(0, 700),
            2000,
          );
      }
      await tester.pumpAndSettle();
      expect(find.text('提出修改建議'), findsNothing);
      expect(find.text('完成'), findsNothing);
      // Return to the spot details, without accidentally popping that route.
      expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
      expect(store.submissions, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('取消或送出失敗後關閉表單，保留修改建議父面板', (tester) async {
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停車點名稱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsOneWidget);
    await tester.tap(find.text('停車點名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '市府路機車格',
    );
    store.failNext = true;
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('連線失敗，請重試'), findsOneWidget);
    await tester.tap(find.byTooltip('關閉').last);
    await tester.pumpAndSettle();
    expect(find.text('提出修改建議'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未回報點位維持顯示，不存在只能由修改建議送交審核', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    expect(find.text(spot.name), findsOneWidget);
    expect(find.text('還在'), findsNothing);
    expect(find.text('已不存在'), findsNothing);
    expect(find.textContaining('最後確認'), findsNothing);
    expect(store.submissions, isEmpty);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('這裡已經不能停車'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('這裡已經不能停車'), findsOneWidget);
    await tester.tap(find.text('這裡已經不能停車'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(find.text('請選擇原因'), findsOneWidget);
    expect(store.submissions, isEmpty);
    // A lasting cause: the bay is gone, so hiding is suggested.
    await tester.tap(find.byKey(const ValueKey('gone-removed')));
    await tester.pumpAndSettle();
    expect(find.text('請選擇原因'), findsNothing);
    expect(find.byKey(const ValueKey('gone-until')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '現場格線已撤除，改為人行道',
    );
    store.failNext = true;
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(find.text('連線失敗，請重試'), findsOneWidget);
    expect(store.spots, contains(spot));
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(store.submissions.last, {
      'action': 'flag',
      'source_id': spot.id,
      'reason': '這裡已經不能停車：格線已撤除；說明：現場格線已撤除，改為人行道',
      'field': 'gone',
      'proposed': {'status': 'hidden'},
      'note': '現場格線已撤除，改為人行道',
    });
    expect(store.submissions.any((body) => body['action'] == 'vote'), isFalse);
    expect(store.spots, contains(spot));
    expect(find.text('範例模式：建議沒有實際送出，只用來測試流程。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('修改建議顯示目前值，格位類型以選項送出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    expect(find.text('目前：${SpaceType.freeMotorcycle.label}'), findsOneWidget);
    await tester.tap(find.text('格位類型'));
    await tester.pumpAndSettle();
    expect(find.text('地圖上目前寫的是'), findsOneWidget);
    // Nothing changes until the reporter picks another marking.
    expect(find.byKey(const ValueKey('suggestion-change')), findsNothing);
    await tester.ensureVisible(find.text('送出建議'));
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('這和目前的格位類型相同，請選擇另一種'), findsOneWidget);
    final heavyOnly = find.byKey(const ValueKey('report-space-heavyOnly'));
    await tester.ensureVisible(heavyOnly);
    await tester.tap(heavyOnly);
    await tester.pumpAndSettle();
    expect(
      find.text(
        '格位類型從「${SpaceType.freeMotorcycle.label}」'
        '改成「${SpaceType.heavyOnly.label}」',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('送出建議'));
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(store.submissions.single, {
      'action': 'flag',
      'source_id': spot.id,
      'reason': '格位類型：建議「${SpaceType.heavyOnly.label}」',
      'field': 'space_type',
      'proposed': {'space_type': 'heavyOnly'},
      'note': '',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('收費建議以結構化費率送出，沒有選收費方式時提示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    // The suggestion list's item, not the details row behind it.
    await tester.tap(find.text('收費資訊').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('送出建議'));
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('請至少選一個車種的收費方式'), findsOneWidget);
    expect(store.submissions, isEmpty);
    final menu = find.byKey(const ValueKey('fee-mode-scooter'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('計次').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '每次金額'), '20');
    await tester.pumpAndSettle();
    expect(find.text('請至少選一個車種的收費方式'), findsNothing);
    expect(
      find.text('收費資訊從「${spot.feeNote}」改成「每次 20 元（大型重機費率未確認）」'),
      findsOneWidget,
    );
    // The form grew with the amount fields; scroll its own list to the button.
    await tester.scrollUntilVisible(
      find.text('送出建議'),
      200,
      scrollable: find
          .ancestor(of: menu, matching: find.byType(Scrollable))
          .first,
    );
    await tester.ensureVisible(find.text('送出建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    final body = store.submissions.single;
    expect(body['field'], 'fee_note');
    expect(body['proposed'], {
      'fee': {
        'scooter': {'mode': 'per_visit', 'amount': 20},
      },
      'fee_note': '每次 20 元（大型重機費率未確認）',
    });
    expect(body['reason'], '收費資訊：建議「每次 20 元（大型重機費率未確認）」');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<RecordingStore> openSuggestion(
    WidgetTester tester,
    String item, {
    ParkingSpot selectedSpot = spot,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, selectedSpot: selectedSpot);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    // The suggestion list, kept by element because its title scrolls away.
    final listElement = tester.element(
      find
          .ancestor(of: find.text('提出修改建議'), matching: find.byType(Scrollable))
          .first,
    );
    // .last only once built: on an empty match it throws instead of waiting.
    await tester.scrollUntilVisible(
      find.text(item),
      150,
      scrollable: find.byElementPredicate((e) => e == listElement),
    );
    final entry = find.text(item).last;
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> submitSuggestion(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find
          .descendant(
            of: find.byType(Form).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('暫時施工只送審、不建議隱藏，可填預計恢復時間', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-works')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('gone-until')),
      '公告寫 11 月 30 日完工',
    );
    await submitSuggestion(tester, '送出回報');
    final body = store.submissions.single;
    expect(body['field'], 'gone');
    expect(body.containsKey('proposed'), isFalse);
    expect(body['reason'], '這裡已經不能停車：施工中；預計恢復：公告寫 11 月 30 日完工');
  });

  testWidgets('改選長期原因後不再帶預計恢復時間', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-works')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('gone-until')),
      '公告寫 11 月 30 日完工',
    );
    await tester.tap(find.byKey(const ValueKey('gone-removed')));
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出回報');
    expect(store.submissions.single['reason'], '這裡已經不能停車：格線已撤除');
  });

  test('長度依伺服器的 UTF-16 計算', () {
    expect(fitsServer('機' * 40, 40), isNull);
    expect(fitsServer('🛵' * 21, 40), isNotNull);
    expect(fitsServer(null, 40), isNull);
  });

  testWidgets('「其他」原因需要說明', (tester) async {
    final store = await openSuggestion(tester, '這裡已經不能停車');
    await tester.tap(find.byKey(const ValueKey('gone-other')));
    await tester.pumpAndSettle();
    await submitSuggestion(tester, '送出回報');
    expect(find.text('請填寫現場狀況'), findsOneWidget);
    expect(store.submissions, isEmpty);
  });

  testWidgets('入口與停車指引只送有變更的欄位', (tester) async {
    final store = await openSuggestion(tester, '入口與停車指引');
    // A street bay has no entrance to fix.
    expect(find.byKey(const ValueKey('suggestion-entrance')), findsNothing);
    await submitSuggestion(tester, '送出建議');
    expect(find.text('請至少修改一項，和目前不同才能送出'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-guide')),
      '格位在便利商店前',
    );
    await tester.pumpAndSettle();
    expect(find.text('停車指引從「未提供」改成「格位在便利商店前」'), findsOneWidget);
    await submitSuggestion(tester, '送出建議');
    final body = store.submissions.single;
    expect(body['field'], 'guide');
    expect(body['proposed'], {'parking_guide': '格位在便利商店前'});
  });

  testWidgets('格位建議改為路外停車場時追問型式與分類', (tester) async {
    final store = await openSuggestion(tester, '格位類型');
    final lot = find.byKey(const ValueKey('report-space-offStreet'));
    await tester.ensureVisible(lot);
    await tester.tap(lot);
    await tester.pumpAndSettle();
    final surface = find.descendant(
      of: find.byType(SegmentedButton<FacilityType?>),
      matching: find.text('平面'),
    );
    await tester.ensureVisible(surface);
    await tester.tap(surface);
    await tester.pumpAndSettle();
    expect(find.text('場站型式從「未提供」改成「路外平面停車場」'), findsOneWidget);
    await submitSuggestion(tester, '送出建議');
    expect(store.submissions.single['proposed'], {
      'space_type': 'offStreet',
      'facility_type': 'surface',
    });
  });

  for (final field in ['facility_type', 'parking_access']) {
    testWidgets('既有路外場站只修改 $field 也能送出，還原後恢復未變更提示', (tester) async {
      final lot = ParkingSpot.fromJson({
        ...spot.toJson(),
        'space_type': 'offStreet',
        'facility_type': 'underground',
        'parking_access': 'scooterHeavy',
      });
      final store = await openSuggestion(tester, '格位類型', selectedSpot: lot);
      await submitSuggestion(tester, '送出建議');
      const error = '請至少修改格位類型、場站型式或停放分類其中一項';
      expect(find.text(error), findsOneWidget);
      expect(store.submissions, isEmpty);

      final control = field == 'facility_type'
          ? find.byType(SegmentedButton<FacilityType?>)
          : find.byType(DropdownButtonFormField<ParkingAccess?>);
      Future<void> choose(String label) async {
        await tester.scrollUntilVisible(
          control,
          -200,
          scrollable: find
              .descendant(
                of: find.byType(Form).last,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        if (field == 'parking_access') {
          await tester.tap(control);
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
        } else {
          await tester.tap(
            find.descendant(of: control, matching: find.text(label)),
          );
        }
        await tester.pumpAndSettle();
      }

      await choose(field == 'facility_type' ? '平面' : '大型重機專用');
      expect(find.text(error), findsNothing);
      await choose(field == 'facility_type' ? '地下' : '普通機車與大型重機共用');
      expect(find.text(error), findsOneWidget);
      await choose(field == 'facility_type' ? '平面' : '大型重機專用');
      await submitSuggestion(tester, '送出建議');
      expect(store.submissions.single['proposed'], {
        'space_type': 'offStreet',
        field: field == 'facility_type' ? 'surface' : 'heavyOnly',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('摘要依伺服器的 UTF-16 長度截斷，不切開 emoji', () {
    final emoji = '🛵' * 300;
    expect(emoji.length, 600);
    final cut = reportSummary(emoji);
    expect(cut.length, lessThanOrEqualTo(500));
    expect(cut, endsWith('…'));
    // Whole scooters only: an odd unit count would mean a split pair.
    expect((cut.length - 1).isEven, isTrue);
    expect(reportSummary('短'), '短');
  });

  testWidgets('詳細費率加上最長說明時，摘要截在伺服器上限內，說明完整保留', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收費資訊').last);
    await tester.pumpAndSettle();
    for (final (menu, field) in [
      ('fee-mode-scooter', 0),
      ('fee-mode-heavy', 1),
    ]) {
      final mode = find.byKey(ValueKey(menu));
      await tester.ensureVisible(mode);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.text('計時').last);
      await tester.pumpAndSettle();
      final amount = find.widgetWithText(TextFormField, '金額').at(field);
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '20');
      final cap = find.widgetWithText(TextFormField, '當日上限（選填）').at(field);
      await tester.ensureVisible(cap);
      await tester.enterText(cap, '100');
      await tester.pumpAndSettle();
    }
    final explanation = '說' * 450;
    final input = find.byKey(const ValueKey('suggestion-input'));
    await tester.ensureVisible(input);
    await tester.enterText(input, explanation);
    await tester.pumpAndSettle();
    final button = find.text('送出建議');
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find
          .ancestor(of: input, matching: find.byType(Scrollable))
          .first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    final body = store.submissions.single;
    expect((body['reason'] as String).length, lessThanOrEqualTo(500));
    expect(body['reason'] as String, endsWith('…'));
    expect(body['note'], explanation);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('名稱建議以填寫內容作為建議值送出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停車點名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '市府路機車格',
    );
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(store.submissions.single, {
      'action': 'flag',
      'source_id': spot.id,
      'reason': '停車點名稱：市府路機車格',
      'field': 'name',
      'proposed': {'name': '市府路機車格'},
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停放資格未修改時在選項下方提示，修改後顯示對照並只送出變更', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store);
    await tester.ensureVisible(find.text('修改建議'));
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('機車停放資格'));
    await tester.pumpAndSettle();
    expect(find.text('現場有告示牌或地面標字時，才選「可停」。'), findsOneWidget);
    await tester.ensureVisible(find.text('送出建議'));
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('請至少改一個車種，和目前不同才能送出'), findsOneWidget);
    expect(store.submissions, isEmpty);
    final heavyAllowed = find.text('可停').last;
    await tester.ensureVisible(heavyAllowed);
    await tester.tap(heavyAllowed);
    await tester.pumpAndSettle();
    expect(find.text('請至少改一個車種，和目前不同才能送出'), findsNothing);
    expect(find.text('大型重機從「未確認」改成「可停」'), findsOneWidget);
    await tester.ensureVisible(find.text('送出建議'));
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(store.submissions.single['field'], 'eligibility');
    expect(store.submissions.single['proposed'], {'heavy_allowed': true});
    expect(find.text('範例模式：建議沒有實際送出，只用來測試流程。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('新增停車點分區填寫，重機專用格自動帶入車種', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReport(
                context,
                store,
                spot.lat,
                spot.lng,
                mapCenter: true,
              ),
              child: const Text('新增'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    expect(find.text('位置：目前地圖中心'), findsOneWidget);
    // Closing stays reachable at the top of the long form.
    expect(find.byTooltip('關閉').hitTestable(), findsOneWidget);
    expect(find.text('0/100'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, '停車點名稱'),
      '松仁路重機格',
    );
    final heavyOnly = find.byKey(const ValueKey('report-space-heavyOnly'));
    await tester.ensureVisible(heavyOnly);
    await tester.tap(heavyOnly);
    await tester.pumpAndSettle();
    // Kept by element: the heading used to find the list scrolls away.
    final listElement = tester.element(
      find
          .ancestor(of: find.text('基本資訊'), matching: find.byType(Scrollable))
          .first,
    );
    await tester.scrollUntilVisible(
      find.text('送出回報'),
      200,
      scrollable: find.byElementPredicate((e) => e == listElement),
    );
    await tester.ensureVisible(find.text('送出回報'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    final created = store.submissions.single['spot'] as Map<String, dynamic>;
    expect(created['name'], '松仁路重機格');
    expect(created['city'], '臺北市');
    expect(created['space_type'], 'heavyOnly');
    expect(created['scooter_allowed'], isFalse);
    expect(created['heavy_allowed'], isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小螢幕深色與放大字級的詳情、修改建議不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 740);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, scale: 1.6, brightness: Brightness.dark);
    await tester.drag(
      find.byKey(const ValueKey('parking-spot-sheet')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('修改建議').hitTestable(),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('parking-spot-sheet')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改建議'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('這裡已經不能停車').hitTestable(),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('這裡已經不能停車'));
    await tester.pumpAndSettle();
    expect(find.text('這裡為什麼不能停車？'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
