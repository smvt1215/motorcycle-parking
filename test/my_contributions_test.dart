import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/contributions_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/contribute/my_contributions.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const openSpot = ParkingSpot(
  id: 'official:00000000-0000-4000-8000-0000000000aa',
  name: '市府轉運站重機格',
  lat: 25.041,
  lng: 121.565,
  city: '臺北市',
  source: 'official',
  spaceType: SpaceType.heavyOnly,
);

final now = DateTime(2026, 10, 25, 12);

Map<String, dynamic> row(
  String id, {
  String kind = 'report',
  String status = 'pending',
  String? spotName = '市府轉運站重機格',
  String? spotId = 'official:00000000-0000-4000-8000-0000000000aa',
  String? field = 'fee_note',
  String? summary = '收費資訊：建議「計時 每小時 20 元」；說明：現場告示牌',
  bool visible = true,
  String created = '2026-10-22T03:04:05.123456+00:00',
}) => {
  'id': id,
  'kind': kind,
  'spot_id': spotId,
  'spot_name': spotName,
  'field': field,
  'summary': summary,
  'status': status,
  'created_at': created,
  'resolved_at': null,
  'spot_visible': visible,
  'lat': visible ? 25.041 : null,
  'lng': visible ? 121.565 : null,
};

/// Every status a rider can see, on one page.
final allRows = [
  row('a', status: 'accepted'),
  row(
    'b',
    status: 'rejected',
    field: 'gone',
    summary: '這裡已經不能停車：格線已撤除；說明：改成人行道，非常非常長的說明文字會換行而不是讓版面超出螢幕寬度',
    visible: false,
    spotName: '一個名稱很長很長很長很長很長很長很長很長很長的停車點',
  ),
  row('c'),
  row('d', status: 'closed', field: null, summary: '其他回報'),
  row('e', kind: 'new_spot', field: null, summary: null),
  row('f', kind: 'new_spot', status: 'confirmed', field: null, summary: null),
  row(
    'g',
    kind: 'new_spot',
    status: 'hidden',
    field: null,
    summary: null,
    visible: false,
  ),
  row('h', spotName: null, spotId: 'tdx:old', visible: false, field: null),
];

class FakeContributions extends ContributionsRepository {
  FakeContributions(this.pages) : super(null);
  final List<Object> pages;
  final calls = <MyContribution?>[];

  @override
  Future<ContributionPage> load({MyContribution? after}) async {
    calls.add(after);
    final next = pages.isEmpty
        ? const <Map<String, dynamic>>[]
        : pages.removeAt(0);
    if (next is Exception) throw next;
    final rows = next is Completer<List<Map<String, dynamic>>>
        ? await next.future
        : next as List<Map<String, dynamic>>;
    return ContributionPage(
      rows.map(MyContribution.fromJson).toList(),
      hasMore: rows.length == 2 && pages.isNotEmpty,
    );
  }
}

class ContributorStore extends AppStore {
  ContributorStore(
    LocalRepository local,
    FakeContributions repo, {
    this.rider = 'rider-1',
  }) : super(local, null, contributionsRepository: repo);
  String? rider;

  @override
  bool get demo => false;
  @override
  bool get canReport => rider != null;
  @override
  String? get riderId => rider;
}

Future<ContributorStore> createStore(
  List<Object> pages, {
  String? rider = 'rider-1',
}) async {
  SharedPreferences.setMockInitialValues({});
  return ContributorStore(
    LocalRepository(await SharedPreferences.getInstance()),
    FakeContributions(pages),
    rider: rider,
  )..spots = [openSpot];
}

Future<void> pump(
  WidgetTester tester,
  AppStore store, {
  double width = 390,
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool active = true,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            TickerMode(
              enabled: active,
              child: MyContributionsSection(store: store, now: now),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('MyContribution', () {
    test('reads kinds, fields and the rider summary', () {
      final fee = MyContribution.fromJson(row('1'));
      expect(fee.kind, ContributionKind.suggestion);
      expect(fee.action, '建議修改收費資訊');
      expect(fee.detail, '建議「計時 每小時 20 元」；說明：現場告示牌');
      expect(fee.canOpen, isTrue);

      // Older builds sent the label as field, or only a prefixed reason.
      final legacy = MyContribution.fromJson(
        row('2', field: '點位已不存在', summary: '點位已不存在：格位已撤除'),
      );
      expect(legacy.kind, ContributionKind.gone);
      expect(legacy.action, '回報這裡已經不能停車');
      final prefixed = MyContribution.fromJson(
        row('3', field: null, summary: '停車點名稱：新名稱'),
      );
      expect(prefixed.action, '建議修改停車點名稱');
      expect(prefixed.detail, '新名稱');
      final free = MyContribution.fromJson(
        row('4', field: null, summary: '舊版回報'),
      );
      expect(free.action, '提出修改建議');
      expect(free.detail, '舊版回報');

      final spot = MyContribution.fromJson(
        row('5', kind: 'new_spot', status: 'hidden', visible: false),
      );
      expect(spot.kind, ContributionKind.newSpot);
      expect(spot.status, ContributionStatus.hidden);
      expect(spot.canOpen, isFalse);
      expect(
        MyContribution.fromJson(row('6', status: 'later')).status,
        ContributionStatus.unknown,
      );
    });

    test('keeps the server timestamp for the next page', () {
      expect(
        MyContribution.fromJson(row('1')).cursor,
        '2026-10-22T03:04:05.123456+00:00',
      );
    });

    test('every status has words, not only a colour', () {
      final labels = <String>{};
      for (final r in allRows) {
        final look = statusLook(MyContribution.fromJson(r));
        expect(look.label, isNotEmpty);
        labels.add(look.label);
      }
      expect(labels, {'已採納', '未採納', '審核中', '已結案', '待車友確認', '車友已確認', '已從地圖移除'});
    });

    test('a rejection reads its kind, never an admin note', () {
      String? note(String status, String? kind) => statusNote(
        MyContribution.fromJson({
          ...row('1', status: status),
          'resolution_kind': kind,
        }),
      );
      expect(note('rejected', 'insufficient'), '資訊不足，無法查證。');
      expect(note('rejected', 'outdated'), '點位已變更，建議不再適用。');
      expect(note('rejected', null), '管理員核對後沒有採用。');
      expect(note('closed', 'duplicate'), '已有相同的建議，併入先前的處理。地圖沒有變更。');
      expect(note('closed', null), '這筆回報已處理完畢。地圖沒有變更。');
      for (final kind in [
        'wrong',
        'duplicate',
        'insufficient',
        'outdated',
        'abuse',
        'other',
      ]) {
        expect(rejectionReasons[kind], isNotEmpty);
      }
    });

    test('不能停車回報照畫板：停車點確定不在地圖上才是已從地圖移除', () {
      MyContribution gone(
        String status, [
        String? kind,
        bool visible = false,
      ]) => MyContribution.fromJson({
        ...row(
          'g',
          status: status,
          field: 'gone',
          summary: '這裡已經不能停車：格線已撤除',
          visible: visible,
        ),
        'resolution_kind': kind,
      });
      // Hidden or removed: the spot is no longer public.
      expect(statusLook(gone('accepted')).label, '已從地圖移除');
      expect(statusNote(gone('accepted')), '管理員已將這個停車點從地圖移除。');
      // A temporary closure (works, closed) keeps the spot on the map with a
      // closure, so the adopted report reads neutrally.
      final closure = gone('accepted', null, true);
      expect(goneRemoved(closure), isFalse);
      expect(statusLook(closure).label, '已採納');
      expect(statusNote(closure), '已依你的回報處理這個停車點。');
      expect(statusLook(gone('pending')).label, '審核中');
      expect(statusNote(gone('pending')), isNull);
      expect(statusLook(gone('rejected')).label, '未採納');
      expect(statusNote(gone('rejected', 'wrong')), '核對後與現場資訊不符。');
      expect(statusLook(gone('closed')).label, '已結案');
    });

    test('dates say the day, and the year only when it differs', () {
      expect(sentDate(DateTime(2026, 10, 2), now), '10月2日送出');
      expect(sentDate(DateTime(2025, 12, 31), now), '2025年12月31日送出');
    });
  });

  group('我送出的建議', () {
    for (final (width, scale, brightness) in [
      (320.0, 1.0, Brightness.light),
      (390.0, 1.6, Brightness.dark),
      (360.0, 1.6, Brightness.light),
      (700.0, 1.0, Brightness.dark),
      (1280.0, 1.6, Brightness.light),
    ]) {
      testWidgets('every status fits at $width px, ${scale}x, $brightness', (
        tester,
      ) async {
        final store = await createStore([allRows]);
        await pump(
          tester,
          store,
          width: width,
          scale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        for (final label in [
          '已採納',
          '未採納',
          '審核中',
          '已結案',
          '待車友確認',
          '車友已確認',
          '已從地圖移除',
        ]) {
          await tester.scrollUntilVisible(
            find.text(label).first,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(find.text(label).first);
          await tester.pump();
          expect(find.text(label).hitTestable(), findsWidgets);
        }
        expect(find.text('已不在地圖資料中的停車點'), findsOneWidget);
        // Every row is at least a 48 px touch target.
        for (final element in find.byType(ContributionRow).evaluate()) {
          expect(element.size!.height, greaterThanOrEqualTo(48));
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the row reads kind and date, then the plate, spot and field', (
      tester,
    ) async {
      final store = await createStore([
        [row('a', status: 'accepted')],
      ]);
      await pump(tester, store, width: 390);
      final plate = tester.getTopLeft(find.byType(StatusPlate));
      final meta = tester.getTopLeft(find.text('修改建議　10月22日'));
      final name = tester.getTopLeft(find.text('市府轉運站重機格'));
      expect(plate.dy, lessThan(name.dy));
      expect(plate.dx, greaterThan(meta.dx + 100));
      expect(find.text('怎麼算錢：建議「計時 每小時 20 元」；說明：現場告示牌'), findsOneWidget);
    });

    testWidgets('a visible spot opens its details', (tester) async {
      final store = await createStore([
        [row('a', status: 'accepted')],
      ]);
      await pump(tester, store);
      await tester.tap(find.byType(ContributionRow));
      await tester.pumpAndSettle();
      expect(find.byType(SpotSheet), findsOneWidget);
    });

    testWidgets('a spot off the map explains instead of opening', (
      tester,
    ) async {
      final store = await createStore([
        [
          row('b', status: 'rejected', visible: false, spotName: '已撤除的格位'),
          row('h', spotName: null, spotId: 'tdx:old', visible: false),
        ],
      ]);
      await pump(tester, store);
      expect(find.text('修改建議　10月22日，已不在地圖上'), findsNWidgets(2));
      await tester.tap(find.byType(ContributionRow).first);
      await tester.pump();
      expect(find.text('「已撤除的格位」已不在地圖上，無法開啟詳情。'), findsOneWidget);
      expect(find.byType(SpotSheet), findsNothing);
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .removeCurrentSnackBar();
      await tester.pump();
      await tester.tap(find.byType(ContributionRow).last);
      await tester.pump();
      expect(find.text('這個停車點已不在地圖資料中，無法開啟。'), findsOneWidget);
    });

    testWidgets('signed out: says what signing in adds and loads nothing', (
      tester,
    ) async {
      final store = await createStore([allRows], rider: null);
      await pump(tester, store, width: 320, scale: 1.6);
      expect(find.text('登入後，你送出的建議與審核結果會列在這裡。'), findsOneWidget);
      // The tab's banner holds the only sign-in button.
      expect(find.widgetWithText(TextButton, '登入'), findsNothing);
      expect((store.contributions as FakeContributions).calls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signing in loads the list', (tester) async {
      final store = await createStore([
        [row('a')],
      ], rider: null);
      await pump(tester, store);
      store.rider = 'rider-1';
      store.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.text('審核中'), findsOneWidget);
    });

    testWidgets('empty: points to the next step', (tester) async {
      final store = await createStore([<Map<String, dynamic>>[]]);
      await pump(tester, store, width: 320, scale: 1.6);
      expect(find.textContaining('還沒有送出建議'), findsOneWidget);
      expect(find.text('新增停車點').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an error offers a retry that loads again', (tester) async {
      final store = await createStore([
        Exception('offline'),
        [row('a', status: 'accepted')],
      ]);
      await pump(tester, store, width: 320);
      expect(find.text('讀不到你送出的建議。請確認網路連線後重試。'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '重試'));
      await tester.pump();
      await tester.pump();
      expect(find.text('已採納'), findsOneWidget);
    });

    testWidgets('loads older pages after the last row', (tester) async {
      final store = await createStore([
        [row('a'), row('b', created: '2026-10-21T00:00:00.000001+00:00')],
        [row('c', status: 'accepted')],
      ]);
      await pump(tester, store);
      await tester.tap(find.text('載入更早的紀錄'));
      await tester.pump();
      await tester.pump();
      final calls = (store.contributions as FakeContributions).calls;
      expect(calls.last?.cursor, '2026-10-21T00:00:00.000001+00:00');
      expect(find.byType(ContributionRow), findsNWidgets(3));
      expect(find.text('載入更早的紀錄'), findsNothing);
    });

    testWidgets('a sent report reloads the list', (tester) async {
      final store = await createStore([
        [row('a')],
        [row('a', status: 'accepted')],
      ]);
      await pump(tester, store);
      expect(find.text('審核中'), findsOneWidget);
      store.reportsSent++;
      store.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.text('已採納'), findsOneWidget);
    });

    testWidgets('returning to the tab fetches the latest results', (
      tester,
    ) async {
      final store = await createStore([
        [row('a')],
        [row('a', status: 'accepted')],
      ]);
      await pump(tester, store);
      expect(find.text('審核中'), findsOneWidget);
      await pump(tester, store, active: false);
      await pump(tester, store);
      await tester.pump();
      // The old list stays until the new one arrives, then is replaced.
      expect(find.text('已採納'), findsOneWidget);
      expect(find.text('審核中'), findsNothing);
      expect((store.contributions as FakeContributions).calls, hasLength(2));
    });

    testWidgets('a reload during an older-page request frees the button', (
      tester,
    ) async {
      final older = Completer<List<Map<String, dynamic>>>();
      final store = await createStore([
        [row('a'), row('b')],
        older,
        [row('c'), row('d')],
        [row('e')],
      ]);
      await pump(tester, store);
      await tester.tap(find.text('載入更早的紀錄'));
      await tester.pump();
      expect(find.text('載入更早的紀錄'), findsNothing);
      store.reportsSent++;
      store.notifyListeners();
      await tester.pump();
      await tester.pump();
      older.complete([row('x')]);
      await tester.pump();
      expect(find.text('載入更早的紀錄').hitTestable(), findsOneWidget);
      expect(find.byType(ContributionRow), findsNWidgets(2));
    });

    testWidgets('screen readers hear everything the row shows', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await createStore([
        [
          {
            ...row('b', status: 'rejected', visible: false),
            'resolution_kind': 'insufficient',
          },
        ],
      ]);
      await pump(tester, store);
      final label = tester.getSemantics(find.byType(ContributionRow)).label;
      for (final part in [
        '市府轉運站重機格',
        '建議修改收費資訊',
        '建議「計時 每小時 20 元」；說明：現場告示牌',
        '未採納',
        '資訊不足，無法查證。',
        '10月22日送出',
        '已不在地圖上',
      ]) {
        expect(label, contains(part));
      }
      semantics.dispose();
    });

    testWidgets('older pages wait while the first page is refreshed', (
      tester,
    ) async {
      final refreshed = Completer<List<Map<String, dynamic>>>();
      final store = await createStore([
        [row('a'), row('b')],
        refreshed,
        [row('c'), row('d')],
      ]);
      await pump(tester, store);
      await pump(tester, store, active: false);
      await pump(tester, store);
      // The refresh is running: paging from the old list is not offered.
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '載入更早的紀錄'),
      );
      expect(button.onPressed, isNull);
      await tester.tap(find.text('載入更早的紀錄'), warnIfMissed: false);
      await tester.pump();
      final calls = (store.contributions as FakeContributions).calls;
      expect(calls, hasLength(2));
      refreshed.complete([row('a2'), row('b2')]);
      await tester.pump();
      await tester.tap(find.text('載入更早的紀錄'));
      await tester.pump();
      await tester.pump();
      // Paging continues from the refreshed list, not the replaced one.
      expect(calls.last?.id, 'b2');
      expect(find.byType(ContributionRow), findsNWidgets(4));
    });

    testWidgets('screen readers can open a row', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await createStore([
        [row('a', status: 'accepted')],
      ]);
      await pump(tester, store);
      final node = tester.getSemantics(find.byType(ContributionRow));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.byType(SpotSheet), findsOneWidget);
      semantics.dispose();
    });
  });
}
