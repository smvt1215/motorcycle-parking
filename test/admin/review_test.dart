import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/review/review_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_admin_gateway.dart';

void main() {
  group('審核資料', () {
    final spots = sampleSpots();
    final reports = {for (final r in sampleReports()) r.id: r};

    test('回報分類與標題', () {
      expect(reports['r-type']!.kind, ReviewKind.info);
      expect(reports['r-access']!.kind, ReviewKind.access);
      expect(reports['r-gone']!.kind, ReviewKind.gone);
      expect(reports['r-gone']!.title, '多位騎士回報已不存在');
      // Stable keys show their label; older builds' labels still classify.
      expect(reports['r-access']!.title, '機車停放資格');
      expect(reports['r-type']!.title, '格位類型');
      expect(suggestionKey('點位已不存在'), 'gone');
      expect(suggestionKey('gone'), 'gone');
      ReviewReport legacy(String reason) => ReviewReport(
        id: reason,
        sourceId: communityId,
        reason: reason,
        createdAt: reportTime,
      );
      expect(legacy('點位已不存在：格線撤除').kind, ReviewKind.gone);
      expect(legacy('機車停放資格：建議「可停」').kind, ReviewKind.access);
      expect(initialProposal(legacy('點位已不存在：格線撤除'), spots[communityId]), {
        'status': 'hidden',
      });
      expect(reports['r-legacy']!.title, '收費資訊');
      expect(reports['r-legacy']!.riderText, '收費資訊：改為每次 30 元');
      expect(reports['r-type']!.riderText, '地面有「大型重機」字樣');
    });

    test('不存在回報：社群點改 status，官方點改 hidden', () {
      final community = spots[communityId]!;
      final official = spots[officialId]!;
      expect(initialProposal(reports['r-gone']!, community), {
        'status': 'hidden',
      });
      final officialGone = ReviewReport(
        id: 'x',
        sourceId: officialId,
        reason: '點位已不存在：撤除',
        field: 'gone',
        createdAt: reportTime,
      );
      expect(initialProposal(officialGone, official), {'hidden': true});
      expect(official.allows('status'), isFalse);
      expect(community.allows('hidden'), isFalse);
      expect(ignoredKeys({'status': 'hidden', 'user_id': 'x'}, official), [
        'status',
        'user_id',
      ]);
    });

    test('型別不符的建議值不進入修改內容', () {
      final community = spots[communityId]!;
      final odd = ReviewReport(
        id: 'odd',
        sourceId: communityId,
        reason: '格位類型',
        field: 'space_type',
        proposed: const {'space_type': true, 'name': 3, 'fee_note': '每次 5 元'},
        createdAt: reportTime,
      );
      final proposal = initialProposal(odd, community);
      expect(applicablePatch(proposal, community), {'fee_note': '每次 5 元'});
      expect(ignoredKeys(proposal, community), ['space_type', 'name']);
    });

    test('驗證與資料表約束一致', () {
      final official = spots[officialId]!;
      expect(validatePatch({'name': ' '}, official), '停車點名稱不可空白');
      expect(validatePatch({'name': 'a' * 101}, official), contains('100'));
      expect(validatePatch({'heavy_allowed': null}, official), isNull);
      expect(validatePatch({'lat': 30}, official), contains('緯度'));
      expect(validatePatch({'space_type': 'rocket'}, official), isNotNull);
      expect(
        validatePatch({'heavy_allowed': false, 'hidden': true}, official),
        isNull,
      );
      expect(formatValue('space_type', 'heavyOnly'), '重機專用格');
      expect(formatValue('heavy_allowed', null), '未確認');
      expect(formatValue('hidden', true), '隱藏');
    });
  });

  group('延後送出與復原', () {
    late FakeAdminGateway gateway;
    late ReviewController review;
    var resolvedCalls = 0;

    setUp(() async {
      gateway = FakeAdminGateway(access: adminAal2);
      resolvedCalls = 0;
      review = ReviewController(
        gateway,
        onResolved: () => resolvedCalls++,
        undoWindow: const Duration(seconds: 6),
      );
      await review.load();
    });
    tearDown(() => gateway.dispose());

    test('決定後先移出佇列，復原前不寫入', () async {
      final first = review.queue.first;
      final next = await review.decide(first, ReviewDecision.accept, '比對街景');
      expect(next, 'r-access');
      expect(review.queue.map((r) => r.id), isNot(contains(first.id)));
      expect(gateway.resolved, isEmpty);
      expect(review.undo(), first.id);
      expect(review.queue.first.id, first.id);
      await review.flush();
      expect(gateway.resolved, isEmpty);
    });

    test('時間到或下一個決定時寫入', () async {
      final reports = review.queue;
      await review.decide(reports[0], ReviewDecision.accept, '比對街景');
      await review.decide(reports[1], ReviewDecision.reject, '');
      final first = gateway.resolved.single;
      expect((first.$1, first.$2, first.$4), ('r-type', 'accepted', '比對街景'));
      expect(first.$3, {'space_type': 'heavyOnly'});
      await review.flush();
      expect(gateway.resolved.last.$2, 'rejected');
      expect(gateway.resolved.last.$3, isEmpty);
      expect(resolvedCalls, 2);
    });

    test('寫入失敗放回佇列；已由他人處理則移除', () async {
      final first = review.queue.first;
      gateway.resolveError = const PostgrestException(message: 'offline');
      await review.decide(first, ReviewDecision.accept, '');
      await review.flush();
      expect(review.queue.first.id, first.id);
      expect(review.error, contains('已放回佇列'));
      gateway.resolveError = const PostgrestException(
        message: 'report already resolved',
      );
      await review.decide(first, ReviewDecision.accept, '');
      await review.flush();
      expect(review.byId(first.id), isNull);
      expect(review.error, contains('已由其他人處理'));
    });

    test('修改後套用送出編輯值；無效值不送出', () async {
      final first = review.queue.first;
      review.startEdit(first);
      expect(review.draft, {'space_type': 'heavyOnly'});
      review.setDraft('name', '');
      expect(
        await review.decide(first, ReviewDecision.acceptEdited, ''),
        first.id,
      );
      expect(review.error, '停車點名稱不可空白');
      expect(review.pending, isNull);
      review.setDraft('name', '中山北路重機格');
      await review.decide(first, ReviewDecision.acceptEdited, '');
      await review.flush();
      expect(gateway.resolved.single.$3, {
        'space_type': 'heavyOnly',
        'name': '中山北路重機格',
      });
    });

    test('版本衝突放回佇列並更新目前值，再次套用才強制', () async {
      gateway.changedSpots.add('r-type');
      final first = review.queue.first;
      await review.decide(first, ReviewDecision.accept, '');
      await review.flush();
      expect(review.queue.first.id, first.id);
      expect(review.conflicts, contains(first.id));
      expect(review.error, isNull);
      expect(gateway.resolved, isEmpty);
      await review.decide(first, ReviewDecision.accept, '', force: true);
      await review.flush();
      expect(gateway.resolved.single.$1, first.id);
      expect(gateway.forced.single, isTrue);
    });

    test('衝突後目前值載入失敗時不可強制，重新載入後才可', () async {
      gateway.changedSpots.add('r-type');
      gateway.failSpots = true;
      final first = review.queue.first;
      await review.decide(first, ReviewDecision.accept, '');
      await review.flush();
      expect(review.conflicts, contains(first.id));
      expect(review.canForce(first.id), isFalse);
      expect(await review.refreshSpot(first), isFalse);
      expect(review.canForce(first.id), isFalse);
      gateway.failSpots = false;
      expect(await review.refreshSpot(first), isTrue);
      expect(review.canForce(first.id), isTrue);
    });

    test('下一個決定觸發的寫入失敗時保留錯誤', () async {
      final reports = review.queue;
      await review.decide(reports[0], ReviewDecision.accept, '');
      gateway.resolveError = const PostgrestException(message: 'offline');
      await review.decide(reports[1], ReviewDecision.reject, '');
      expect(review.error, contains('尚未處理成功'));
      expect(review.byId(reports[0].id), isNotNull);
      expect(review.pending?.report.id, reports[1].id);
    });

    test('等待前一筆寫入時登出，不建立也不送出下一筆', () async {
      final reports = review.queue;
      await review.decide(reports[0], ReviewDecision.accept, '');
      gateway.delayedResolve = Completer<void>();
      final next = review.decide(reports[1], ReviewDecision.reject, '');
      review.reset();
      gateway.delayedResolve!.complete();
      await next;
      expect(review.pending, isNull);
      await review.flush();
      expect(gateway.resolved.map((r) => r.$1), isNot(contains(reports[1].id)));
    });

    test('修改後套用寫入失敗時保留修改值，重試送出同一份內容', () async {
      final first = review.queue.first;
      review.startEdit(first);
      review.setDraft('fee_note', '每次 10 元');
      gateway.changedSpots.add(first.id);
      await review.decide(first, ReviewDecision.acceptEdited, '');
      await review.flush();
      expect(review.editing(first.id), isTrue);
      expect(review.draft['fee_note'], '每次 10 元');
      review.cancelEdit();
      review.startEdit(first);
      expect(review.draft['fee_note'], '每次 10 元');
      await review.decide(
        first,
        ReviewDecision.acceptEdited,
        '',
        force: review.canForce(first.id),
      );
      await review.flush();
      expect(gateway.resolved.single.$3['fee_note'], '每次 10 元');
      expect(gateway.forced.single, isTrue);
    });

    test('已載入後重新載入失敗，保留列表並說明', () async {
      gateway.failReports = true;
      await review.load();
      expect(review.loaded, isTrue);
      expect(review.queue, isNotEmpty);
      expect(review.loadError, contains('重新載入失敗'));
    });

    test('找不到點位只能駁回', () async {
      gateway.spots.remove(officialId);
      await review.load();
      final access = review.byId('r-access')!;
      await review.decide(access, ReviewDecision.accept, '');
      expect(review.error, contains('只能駁回'));
      await review.decide(access, ReviewDecision.reject, '');
      await review.flush();
      expect(gateway.resolved.single.$2, 'rejected');
    });

    test('登出或失去權限時清除資料，不寫入', () async {
      await review.decide(review.queue.first, ReviewDecision.accept, '');
      review.reset();
      await review.flush();
      expect(gateway.resolved, isEmpty);
      expect(review.queue, isEmpty);
      expect(review.loaded, isFalse);
    });
  });

  group('審核畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    setUp(() => gateway = FakeAdminGateway(access: adminAal2));
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(
      WidgetTester tester, {
      String path = '/review',
      Size size = const Size(1280, 900),
      ThemeMode mode = ThemeMode.light,
    }) async {
      controller = AdminController(gateway);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await controller.refresh();
      await tester.pumpWidget(
        AdminApp(
          controller: controller,
          initialLocation: path,
          themeMode: mode,
          reviewMapBuilder: (_, data) => Text(
            'map ${data.lat}${data.moved ? ' → ${data.proposedLat},${data.proposedLng}' : ''}',
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('寬螢幕並排顯示佇列與第一筆差異', (tester) async {
      await show(tester);
      expect(find.text('全部 4'), findsOneWidget);
      expect(find.text('格位類型的修改建議'), findsOneWidget);
      expect(find.text('路邊收費機車格'), findsOneWidget);
      expect(find.widgetWithText(ChangeBand, '重機專用格'), findsOneWidget);
      expect(find.text('map 25.0581'), findsOneWidget);
      expect(find.text('套用建議'), findsOneWidget);
      await tester.tap(find.text('停放資格 1'));
      await tester.pumpAndSettle();
      expect(find.text('全部 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('report-r-type')), findsNothing);
      expect(find.text('機車停放資格的修改建議'), findsOneWidget);
      expect(find.text('官方點（新北市政府）'), findsOneWidget);
    });

    testWidgets('套用後跳下一筆，提示可復原', (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const ValueKey('resolution-note')),
        '比對街景',
      );
      await tester.tap(find.text('套用建議'));
      await tester.pumpAndSettle();
      expect(find.text('已套用建議：中山北路二段路邊機車格'), findsOneWidget);
      expect(find.text('機車停放資格的修改建議'), findsOneWidget);
      expect(find.text('全部 3'), findsOneWidget);
      await tester.tap(find.text('復原'));
      await tester.pumpAndSettle();
      expect(find.text('格位類型的修改建議'), findsOneWidget);
      expect(gateway.resolved, isEmpty);
      await tester.tap(find.text('駁回'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$2, 'rejected');
      expect(gateway.countRequests, greaterThan(1));
    });

    testWidgets('修改後套用可改值並加入欄位', (tester) async {
      await show(tester);
      await tester.tap(find.text('修改後套用'));
      await tester.pumpAndSettle();
      expect(find.text('套用修改'), findsOneWidget);
      await tester.tap(find.text('加入要修改的欄位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收費資訊').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit-r-type-fee_note')).first,
        '每次 10 元',
      );
      await tester.tap(find.text('套用修改'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$3, {
        'space_type': 'heavyOnly',
        'fee_note': '每次 10 元',
      });
    });

    testWidgets('官方點加入大型重機欄位可保留未確認', (tester) async {
      final spot = gateway.spots[officialId]!;
      gateway.spots[officialId] = ReviewSpot(
        sourceId: officialId,
        official: true,
        values: {...spot.values, 'heavy_allowed': null},
      );
      await show(tester, path: '/review/r-legacy');
      await tester.tap(find.text('修改後套用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入要修改的欄位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大型重機').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final editor = find.descendant(
        of: find.byKey(const ValueKey('edit-r-legacy-heavy_allowed')),
        matching: find.byType(DropdownButtonFormField<int>),
      );
      await tester.tap(editor);
      await tester.pumpAndSettle();
      await tester.tap(find.text('可停').last);
      await tester.pumpAndSettle();
      await tester.tap(editor);
      await tester.pumpAndSettle();
      await tester.tap(find.text('未確認').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('套用修改'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$3, {'heavy_allowed': null});
    });

    testWidgets('官方點未確認資格建議可編輯並套用', (tester) async {
      gateway.reports = [
        ReviewReport(
          id: 'r-unknown',
          sourceId: officialId,
          reason: '機車停放資格：大型重機未確認',
          field: 'eligibility',
          proposed: const {'heavy_allowed': null},
          createdAt: reportTime,
        ),
      ];
      await show(tester, path: '/review/r-unknown');
      await tester.tap(find.text('修改後套用'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('套用修改'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$3, {'heavy_allowed': null});
    });

    testWidgets('版本衝突顯示送出時的值，按仍要套用才強制', (tester) async {
      gateway.changedSpots.add('r-type');
      await show(tester);
      await tester.tap(find.text('套用建議'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      expect(find.text('資料已更新，需重新檢視'), findsOneWidget);
      expect(find.textContaining('騎士送出後，這個點位已被修改'), findsOneWidget);
      expect(find.text('送出時'), findsOneWidget);
      expect(find.text('免費機車格'), findsOneWidget);
      expect(gateway.resolved, isEmpty);
      await tester.tap(find.text('仍要套用建議'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.forced.single, isTrue);
      expect(gateway.resolved.single.$1, 'r-type');
    });

    testWidgets('衝突後目前值載入失敗只能重新載入或駁回', (tester) async {
      gateway.changedSpots.add('r-type');
      await show(tester);
      gateway.failSpots = true;
      await tester.tap(find.text('套用建議'));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      expect(find.textContaining('目前值尚未重新載入'), findsOneWidget);
      expect(find.text('仍要套用建議'), findsNothing);
      expect(find.text('修改後套用'), findsNothing);
      gateway.failSpots = false;
      await tester.tap(find.text('重新載入目前值'));
      await tester.pumpAndSettle();
      expect(find.text('仍要套用建議'), findsOneWidget);
    });

    testWidgets('舊版回報沒有建議值時可結案或修改', (tester) async {
      await show(tester, path: '/review/r-legacy');
      expect(find.text('收費資訊：改為每次 30 元'), findsOneWidget);
      expect(find.text('套用建議'), findsNothing);
      expect(find.text('結案不修改'), findsOneWidget);
      expect(find.text('修改後套用'), findsOneWidget);
    });

    testWidgets('手機版先列表，點選後進詳情並可返回', (tester) async {
      await show(tester, size: const Size(390, 844), mode: ThemeMode.dark);
      expect(find.text('格位類型的修改建議'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('report-r-gone')));
      await tester.pumpAndSettle();
      expect(find.text('多位騎士回報已不存在'), findsOneWidget);
      expect(find.text('返回佇列（4）'), findsOneWidget);
      // The diff stacks: current and proposed sit under the field name.
      expect(find.text('目前'), findsOneWidget);
      expect(find.text('建議'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('套用建議'));
      await tester.pumpAndSettle();
      expect(find.text('收費資訊的修改建議'), findsOneWidget);
      await tester.tap(find.text('返回佇列（3）'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-r-type')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已隱藏清單可恢復並復原', (tester) async {
      await show(tester);
      await tester.tap(find.text('已隱藏的點位'));
      await tester.pumpAndSettle();
      expect(find.text('中山北路二段路邊機車格'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('restore-$communityId')));
      await tester.pumpAndSettle();
      expect(gateway.hiddenChanges.single, (communityId, false));
      expect(find.text('目前沒有隱藏的點位。'), findsOneWidget);
      await tester.tap(find.text('復原'));
      await tester.pumpAndSettle();
      expect(gateway.hiddenChanges.last, (communityId, true));
      expect(
        find.byKey(const ValueKey('restore-$communityId')),
        findsOneWidget,
      );
    });

    testWidgets('手機版首次載入失敗顯示原因與重試', (tester) async {
      gateway.failReports = true;
      await show(tester, size: const Size(390, 844));
      expect(find.text('待審回報載入失敗，請檢查連線後重試。'), findsOneWidget);
      gateway.failReports = false;
      await tester.tap(find.text('重新載入'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-r-type')), findsOneWidget);
    });

    testWidgets('座標輸入到一半不會讓詳情崩潰', (tester) async {
      await show(tester);
      await tester.tap(find.text('修改後套用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入要修改的欄位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('緯度').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit-r-type-lat')).first,
        '.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('套用修改'), findsOneWidget);
    });

    testWidgets('雙欄窄寬度的動作列改為堆疊，不裁切按鈕', (tester) async {
      await show(tester, size: const Size(700, 900));
      expect(find.byKey(const ValueKey('report-r-type')), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final label in ['套用建議', '修改後套用', '駁回']) {
        expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
      }
      final pane = tester.getRect(find.text('格位類型的修改建議'));
      expect(
        tester.getRect(find.text('駁回')).right,
        lessThanOrEqualTo(700 - 20),
        reason: 'stays inside the detail pane starting at ${pane.left}',
      );
    });

    testWidgets('手機處理最後一筆後寫入失敗，列表顯示原因', (tester) async {
      gateway.reports = [sampleReports().first];
      await show(tester, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      gateway.resolveError = const PostgrestException(message: 'offline');
      await tester.tap(find.text('套用建議'));
      await tester.pumpAndSettle();
      expect(find.text('待審回報'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未處理成功，已放回佇列'), findsOneWidget);
      expect(find.byKey(const ValueKey('report-r-type')), findsOneWidget);
    });

    testWidgets('只改一個座標軸時，另一軸沿用目前位置', (tester) async {
      gateway.reports = [
        ReviewReport(
          id: 'r-lat',
          sourceId: communityId,
          reason: '位置',
          proposed: const {'lat': 25.0583},
          createdAt: reportTime,
        ),
      ];
      await show(tester);
      expect(find.text('map 25.0581 → 25.0583,121.5226'), findsOneWidget);
    });

    testWidgets('重新載入失敗時列表上方顯示原因', (tester) async {
      await show(tester);
      gateway.failReports = true;
      await tester.tap(find.byTooltip('重新載入佇列'));
      await tester.pumpAndSettle();
      expect(find.textContaining('重新載入失敗'), findsOneWidget);
      expect(find.byKey(const ValueKey('report-r-type')), findsOneWidget);
    });

    testWidgets('不存在的回報網址顯示說明', (tester) async {
      await show(tester, path: '/review/nope');
      expect(find.text('這筆回報已處理或不存在'), findsOneWidget);
    });
  });
}
