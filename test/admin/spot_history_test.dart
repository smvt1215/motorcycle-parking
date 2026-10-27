import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/spots/spot_history_page.dart';
import 'package:motorcycle_parking/models/spot_history.dart';

import 'fake_admin_gateway.dart';
import 'spots_test.dart' show FakeSpotMap;

final _rows = <Map<String, dynamic>>[
  {
    'at': '2026-10-27T01:12:00Z',
    'kind': 'report',
    'action': 'resolve_report',
    'actor_name': '小哲',
    'created': false,
    'changes': [
      {
        'field': 'fee_note',
        'before': '大型重機每小時 20 元',
        'after': '大型重機每次 40 元，隔日另計',
      },
      {'field': 'fee', 'before': null, 'after': <String, Object>{}},
    ],
    'note': '現場確認',
    'report': {
      'id': 'r1',
      'status': 'accepted',
      'reason': '收費：大型重機每次 40 元',
      'field': 'fee',
      'proposed': {'fee_note': '大型重機每次 40 元，隔日另計'},
      'note': '我昨天停過',
      'evidence_url': 'https://example.test/notice',
      'created_at': '2026-10-26T01:00:00Z',
    },
  },
  {
    'at': '2026-10-20T07:40:00Z',
    'kind': 'import',
    'action': 'import_spot',
    'actor_name': '小哲',
    'created': false,
    'source_name': '臺北市停管處',
    'changes': [
      {'field': 'address', 'before': '', 'after': '忠孝東路五段 1 號'},
      {'field': 'scooter_total', 'before': 120, 'after': 150},
    ],
  },
  {
    'at': '2026-10-15T07:40:00Z',
    'kind': 'admin',
    'action': 'update_spot',
    'actor_name': '',
    'created': false,
    'changes': [
      {'field': 'heavy_allowed', 'before': null, 'after': true},
    ],
  },
  {
    'at': '2026-10-12T00:05:00Z',
    'kind': 'report',
    'action': 'resolve_report',
    'actor_name': '小哲',
    'created': false,
    'changes': <Object>[],
    'report': {'id': 'r2', 'status': 'rejected', 'resolution_kind': 'wrong'},
  },
  {
    'at': '2026-09-30T02:00:00Z',
    'kind': 'import',
    'action': 'import_spot',
    'created': true,
    'changes': <Object>[],
  },
];

void main() {
  test('時間軸的來源與標題', () {
    final e = HistoryEntry.list(_rows);
    expect(historyMeta(e[0]), endsWith('車友回報（已採納）・管理員 小哲'));
    expect(e[0].title(), '收費');
    expect(shownChanges(e[0]).map((c) => c.field), ['fee_note']);
    expect(historyMeta(e[1]), endsWith('匯入（臺北市停管處）'));
    expect(e[1].title(), '地址、總格數');
    expect(historyMeta(e[2]), endsWith('・管理員'));
    expect(e[2].title(), '停放車種');
    expect(historyMeta(e[3]), endsWith('車友回報（已駁回）・管理員 小哲'));
    expect(e[3].title(), '駁回回報');
    expect(e[4].title(), '建立點位');
    expect(HistoryFilter.report.shows(e[0]), isTrue);
    expect(HistoryFilter.admin.shows(e[0]), isFalse);
  });

  late FakeAdminGateway gateway;
  AdminController? controller;
  setUp(() => gateway = FakeAdminGateway(access: adminAal2));
  tearDown(() async {
    controller?.dispose();
    controller = null;
    await gateway.dispose();
  });

  for (final size in const [
    Size(320, 640),
    Size(402, 874),
    Size(820, 1180),
    Size(1440, 960),
  ]) {
    testWidgets(
      '點位頁開啟編輯紀錄、篩選與看原始回報（${size.width.toInt()}×${size.height.toInt()}）',
      (tester) async {
        gateway.historyRows[communityId] = _rows;
        controller = AdminController(gateway);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await controller!.refresh();
        await tester.pumpWidget(
          AdminApp(
            controller: controller!,
            initialLocation: '/spots/$communityId',
            reviewMapBuilder: (_, _) => const SizedBox(),
            spotMapBuilder: (_, view) => FakeSpotMap(view: view),
            locationMapBuilder: (_, _) => const SizedBox(),
          ),
        );
        await tester.pumpAndSettle();
        final open = find.byKey(const ValueKey('spot-history-open'));
        await tester.ensureVisible(open);
        await tester.pumpAndSettle();
        expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(gateway.historyRequests, [communityId]);
        expect(find.text('編輯紀錄'), findsOneWidget);
        expect(find.text('共 5 筆，最新在上'), findsOneWidget);
        expect(find.text('大型重機每小時 20 元'), findsOneWidget);
        expect(find.text('大型重機每次 40 元，隔日另計'), findsOneWidget);
        expect(tester.takeException(), isNull);

        for (final f in HistoryFilter.values) {
          final chip = find.byKey(ValueKey('history-filter-${f.name}'));
          expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
        }
        await tester.tap(find.byKey(const ValueKey('history-filter-import')));
        await tester.pumpAndSettle();
        expect(find.textContaining('匯入（臺北市停管處）'), findsOneWidget);
        expect(find.textContaining('車友回報（'), findsNothing);
        expect(find.text('大型重機每小時 20 元'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('history-filter-report')));
        await tester.pumpAndSettle();
        expect(find.text('看原始回報'), findsWidgets);
        await tester.tap(find.text('看原始回報').first);
        await tester.pumpAndSettle();
        expect(find.text('原始回報'), findsOneWidget);
        expect(find.text('我昨天停過'), findsOneWidget);
        expect(find.text('https://example.test/notice'), findsOneWidget);
        await tester.tap(find.text('關閉'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回點位'));
        await tester.pumpAndSettle();
        expect(find.text('編輯紀錄'), findsOneWidget);
        expect(find.byTooltip('返回點位'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('讀取失敗可重新載入', (tester) async {
    controller = AdminController(gateway);
    gateway.historyError = StateError('offline');
    await tester.pumpWidget(
      MaterialApp(
        home: SpotHistoryPage(
          gateway: gateway,
          sourceId: communityId,
          name: '測試點',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('編輯紀錄讀取失敗，請稍後再試。'), findsOneWidget);
    gateway.historyError = null;
    await tester.tap(find.text('重新載入'));
    await tester.pumpAndSettle();
    expect(find.text('這個點位還沒有編輯紀錄。'), findsOneWidget);
  });
}
