import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
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
            onPressed: () => showSpot(context, store, spot),
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
      find.text('點位已不存在'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('點位已不存在'), findsOneWidget);
    await tester.tap(find.text('點位已不存在'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('送出回報'));
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    expect(find.text('請填寫建議內容'), findsOneWidget);
    expect(store.submissions, isEmpty);
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
      'reason': '點位已不存在：現場格線已撤除，改為人行道',
      'field': 'gone',
      'proposed': {'status': 'hidden'},
      'note': '現場格線已撤除，改為人行道',
    });
    expect(store.submissions.any((body) => body['action'] == 'vote'), isFalse);
    expect(store.spots, contains(spot));
    expect(find.text('範例建議已送出，僅供本次功能測試。'), findsOneWidget);
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
    await tester.tap(find.text('送出建議'));
    await tester.pumpAndSettle();
    expect(find.text('請選擇與目前不同的格位類型'), findsOneWidget);
    await tester.tap(find.text('正確的格位類型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SpaceType.heavyOnly.label).last);
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('格位類型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SpaceType.heavyOnly.label).last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('送出回報'),
      200,
      scrollable: find
          .ancestor(of: find.text('基本資訊'), matching: find.byType(Scrollable))
          .first,
    );
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
      find.text('點位已不存在').hitTestable(),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('點位已不存在'));
    await tester.pumpAndSettle();
    expect(find.text('請說明現場狀況'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
