import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/review/review_page.dart';
import 'package:motorcycle_parking/admin/review/review_resolution.dart';
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
      expect(
        initialProposal(legacy('點位已不存在：格線撤除'), spots[communityId]),
        isEmpty,
      );
      expect(legacy('位置或其他備註：入口在巷內').title, '位置或其他備註');
      expect(suggestionKey('位置或其他備註'), 'note');
      expect(suggestionFieldLabels['guide'], '入口與停車指引');
      expect(suggestionFieldLabels['location'], '位置不正確');
      expect(reports['r-legacy']!.title, '收費資訊');
      expect(reports['r-legacy']!.riderText, '收費資訊：改為每次 30 元');
      expect(reports['r-type']!.riderText, '地面有「大型重機」字樣');
      // A temporary closure has no proposal; its cause must stay visible
      // even when the rider also wrote a note.
      expect(
        ReviewReport(
          id: 'r-closed',
          sourceId: communityId,
          reason: '點位已不存在：施工中；預計恢復：11 月底；說明：入口有圍籬',
          field: 'gone',
          note: '入口有圍籬',
          createdAt: reportTime,
        ).riderText,
        '點位已不存在：施工中；預計恢復：11 月底；說明：入口有圍籬',
      );
      // A lasting cause proposes hiding; its cause still shows.
      expect(
        ReviewReport(
          id: 'r-removed',
          sourceId: communityId,
          reason: '點位已不存在：格線已撤除',
          field: 'gone',
          proposed: const {'status': 'hidden'},
          createdAt: reportTime,
        ).riderText,
        '點位已不存在：格線已撤除',
      );
    });

    test('不存在回報：沒附建議值時不預設隱藏；社群點用 status，官方點用 hidden', () {
      final community = spots[communityId]!;
      final official = spots[officialId]!;
      expect(initialProposal(reports['r-gone']!, community), isEmpty);
      expect(visibilityKey(community), 'status');
      expect(visibilityKey(official), 'hidden');
      final officialGone = ReviewReport(
        id: 'x',
        sourceId: officialId,
        reason: '點位已不存在：撤除',
        field: 'gone',
        createdAt: reportTime,
      );
      expect(initialProposal(officialGone, official), isEmpty);
      final removed = ReviewReport(
        id: 'y',
        sourceId: officialId,
        reason: '點位已不存在：格線已撤除',
        field: 'gone',
        proposed: const {'hidden': true},
        createdAt: reportTime,
      );
      expect(initialProposal(removed, official), {'hidden': true});
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
      // A write never clears a vehicle; 官方未標示 goes with a null flag (#201).
      expect(validatePatch({'heavy_allowed': null}, official), isNotNull);
      expect(
        validatePatch({
          'heavy_allowed': null,
          'heavy_not_stated': true,
        }, official),
        isNull,
      );
      expect(validatePatch({'heavy_not_stated': false}, official), isNotNull);
      expect(formatValue('heavy_not_stated', true), '官方未標示');
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
      await review.decide(
        reports[1],
        ReviewDecision.reject,
        '',
        resolutionKind: ResolutionKind.wrong,
      );
      final first = gateway.resolved.single;
      expect((first.$1, first.$2, first.$4), ('r-type', 'accepted', '比對街景'));
      expect(first.$3, {'space_type': 'heavyOnly'});
      await review.flush();
      expect(gateway.resolved.last.$2, 'rejected');
      expect(gateway.resolved.last.$3, isEmpty);
      expect(resolvedCalls, 2);
    });

    test('駁回必須帶原因，原因隨決定寫入', () async {
      final report = review.queue.first;
      expect(await review.decide(report, ReviewDecision.reject, ''), report.id);
      expect(review.error, '請先選擇駁回原因。');
      expect(review.pending, isNull);
      await review.decide(
        report,
        ReviewDecision.reject,
        '同一點已有相同建議',
        resolutionKind: ResolutionKind.duplicate,
      );
      expect(review.error, isNull);
      await review.flush();
      expect(gateway.resolved.single.$2, 'rejected');
      expect(gateway.kinds.single, ResolutionKind.duplicate);
    });

    test('「其他原因」必須寫處理說明', () async {
      final report = review.queue.first;
      await review.decide(
        report,
        ReviewDecision.reject,
        '  ',
        resolutionKind: ResolutionKind.other,
      );
      expect(review.error, '選「其他原因」時，請在處理說明寫下原因。');
      expect(review.pending, isNull);
      await review.decide(
        report,
        ReviewDecision.reject,
        '騎士回報的是隔壁停車場',
        resolutionKind: ResolutionKind.other,
      );
      await review.flush();
      expect(gateway.resolved.single.$4, '騎士回報的是隔壁停車場');
      expect(gateway.kinds.single, ResolutionKind.other);
    });

    test('結案不修改可不帶原因', () async {
      await review.decide(review.queue[3], ReviewDecision.close, '');
      await review.flush();
      expect(gateway.resolved.single.$2, 'accepted');
      expect(gateway.kinds.single, isNull);
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
      await review.decide(
        reports[1],
        ReviewDecision.reject,
        '',
        resolutionKind: ResolutionKind.wrong,
      );
      expect(review.error, contains('尚未處理成功'));
      expect(review.byId(reports[0].id), isNotNull);
      expect(review.pending?.report.id, reports[1].id);
    });

    test('等待前一筆寫入時登出，不建立也不送出下一筆', () async {
      final reports = review.queue;
      await review.decide(reports[0], ReviewDecision.accept, '');
      gateway.delayedResolve = Completer<void>();
      final next = review.decide(
        reports[1],
        ReviewDecision.reject,
        '',
        resolutionKind: ResolutionKind.wrong,
      );
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

    test('復原修改後套用時回到編輯並保留修改值', () async {
      final first = review.queue.first;
      review.startEdit(first);
      review.setDraft('fee_note', '每次 10 元');
      await review.decide(first, ReviewDecision.acceptEdited, '');
      expect(review.editing(first.id), isFalse);
      expect(review.undo(), first.id);
      expect(review.editing(first.id), isTrue);
      expect(review.draft['fee_note'], '每次 10 元');
      expect(gateway.resolved, isEmpty);
    });

    test('重新載入期間寫入成功的案件不會被舊結果加回', () async {
      final first = review.queue.first;
      await review.decide(
        first,
        ReviewDecision.reject,
        '',
        resolutionKind: ResolutionKind.wrong,
      );
      gateway.delayedSpots = Completer<void>();
      final reload = review.load();
      await review.flush();
      gateway.delayedSpots!.complete();
      await reload;
      expect(review.byId(first.id), isNull);
    });

    test('沒附建議值的不存在回報：修改後套用從目前的顯示狀態開始', () async {
      final gone = review.byId('r-gone')!;
      review.startEdit(gone);
      expect(review.draft, {'status': 'hidden'});
      review.setDraft('status', 'pending');
      await review.decide(gone, ReviewDecision.acceptEdited, '格線仍在');
      await review.flush();
      expect(gateway.resolved.single.$3, {'status': 'pending'});
    });

    test('入口指引與場站型式的建議可直接套用', () async {
      final guide = ReviewReport(
        id: 'r-guide',
        sourceId: officialId,
        reason: '入口與停車指引：入口在巷內',
        field: 'guide',
        proposed: const {
          'entrance_note': '從中山路一段巷口進入',
          'parking_guide': 'B2 黃牌專區',
          'facility_type': 'underground',
        },
        createdAt: reportTime,
      );
      final spot = gateway.spots[officialId]!;
      expect(guide.title, '入口與停車指引');
      expect(applicablePatch(initialProposal(guide, spot), spot).keys, [
        'entrance_note',
        'parking_guide',
        'facility_type',
      ]);
      expect(formatValue('facility_type', 'underground'), '地下停車場');
      expect(validatePatch({'facility_type': 'rooftop'}, spot), isNotNull);
      // Builds since decision 58 send the set.
      expect(
        formatValue('facility_types', ['underground', 'surface']),
        '地下、平面停車場',
      );
      expect(
        validatePatch({
          'facility_types': ['surface'],
        }, spot),
        isNull,
      );
      expect(validatePatch({'facility_types': null}, spot), isNull);
      for (final bad in [
        <String>[],
        ['rooftop'],
        ['surface', 'surface'],
        'surface',
      ]) {
        expect(validatePatch({'facility_types': bad}, spot), isNotNull);
      }
      expect(
        sameValue(
          'facility_types',
          ['surface', 'underground'],
          ['underground', 'surface'],
        ),
        isTrue,
      );
    });

    test('找不到點位只能駁回', () async {
      gateway.spots.remove(officialId);
      await review.load();
      final access = review.byId('r-access')!;
      await review.decide(access, ReviewDecision.accept, '');
      expect(review.error, contains('只能駁回'));
      await review.decide(
        access,
        ReviewDecision.reject,
        '',
        resolutionKind: ResolutionKind.wrong,
      );
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
      double textScale = 1,
    }) async {
      controller = AdminController(gateway);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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

    ReviewReport locationReport({bool withTown = true}) => ReviewReport(
      id: 'r-loc',
      sourceId: communityId,
      reason: '停車點位置：建議移到 25.060000, 121.522600',
      field: 'location',
      proposed: {
        'lat': 25.06,
        'lng': 121.5226,
        if (withTown) ...{'city': '新北市', 'district': '三重區'},
      },
      createdAt: reportTime,
      risk: ReviewRisk.medium,
    );

    testWidgets('跨縣市的位置建議一併套用縣市與行政區', (tester) async {
      gateway.reports = [locationReport()];
      await show(tester, path: '/review/r-loc');
      expect(find.widgetWithText(ChangeBand, '新北市'), findsOneWidget);
      expect(find.widgetWithText(ChangeBand, '三重區'), findsOneWidget);
      expect(find.textContaining('沒有附縣市與行政區'), findsNothing);
      await tester.tap(find.text('套用建議'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$3, {
        'lat': 25.06,
        'lng': 121.5226,
        'city': '新北市',
        'district': '三重區',
      });
    });

    for (final width in [390.0, 700.0]) {
      testWidgets('位置建議沒有縣市時提醒，修改後套用可加入縣市（${width.toInt()} px）', (
        tester,
      ) async {
        gateway.reports = [locationReport(withTown: false)];
        await show(tester, path: '/review/r-loc', size: Size(width, 900));
        final notice = find.textContaining('沒有附縣市與行政區');
        await tester.scrollUntilVisible(
          notice,
          200,
          scrollable: find
              .ancestor(
                of: find.text('建議變更'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(notice, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('修改後套用'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('修改後套用'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('加入要修改的欄位'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('加入要修改的欄位'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('縣市').last);
        await tester.pumpAndSettle();
        final city = find.byKey(const ValueKey('edit-r-loc-city')).first;
        await tester.ensureVisible(city);
        await tester.enterText(city, '新北市');
        await tester.ensureVisible(find.text('套用修改'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('套用修改'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        expect(gateway.resolved.single.$3, {
          'lat': 25.06,
          'lng': 121.5226,
          'city': '新北市',
        });
        expect(tester.takeException(), isNull);
      });
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('與現況不符'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('駁回這筆回報'));
      await tester.pumpAndSettle();
      expect(find.text('已駁回（與現況不符）：中山北路二段路邊機車格'), findsOneWidget);
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

    testWidgets('官方點加入大型重機欄位不能留未確認（#201）', (tester) async {
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
      expect(find.textContaining('大型重機請選可停或不可停，或設為官方未標示'), findsWidgets);
      expect(gateway.resolved, isEmpty);
    });

    testWidgets('舊版送來的未確認資格建議不能直接套用（#201）', (tester) async {
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
      expect(gateway.resolved, isEmpty);
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
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      expect(find.text('格位類型的修改建議'), findsOneWidget);
      expect(find.text('返回佇列（4）'), findsOneWidget);
      // The diff stacks: current and proposed sit under the field name.
      expect(find.text('目前'), findsOneWidget);
      expect(find.text('建議'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('套用建議'));
      await tester.pumpAndSettle();
      expect(find.text('機車停放資格的修改建議'), findsOneWidget);
      await tester.tap(find.text('返回佇列（3）'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-r-gone')), findsOneWidget);
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

    testWidgets('佇列與詳情以文字與圖示標示風險等級', (tester) async {
      await show(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('report-r-access')),
          matching: find.text('高風險'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('report-r-type')),
          matching: find.text('中風險'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('report-r-legacy')),
          matching: find.byType(RiskTag),
        ),
        findsNothing,
        reason: 'unclassified reports carry no tag',
      );
      expect(find.text(ReviewRisk.medium.reason), findsOneWidget);
      expect(find.byIcon(Icons.signal_cellular_alt), findsOneWidget);
    });

    testWidgets('寬螢幕駁回以對話框選原因，未選不能駁回，可取消', (tester) async {
      await show(tester);
      await tester.tap(find.text('駁回'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('駁回原因'), findsOneWidget);
      final confirm = find.byKey(const ValueKey('reject-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('格位類型的修改建議'), findsOneWidget);
      expect(find.textContaining('已駁回'), findsNothing);
      await tester.tap(find.text('駁回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重複回報'));
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('已駁回（重複回報）：中山北路二段路邊機車格'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$2, 'rejected');
      expect(gateway.kinds.single, ResolutionKind.duplicate);
    });

    testWidgets('選「其他原因」要在面板內寫說明才能駁回', (tester) async {
      await show(tester, size: const Size(390, 700));
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('駁回'));
      await tester.pumpAndSettle();
      final other = find.byKey(const ValueKey('reject-other'));
      await tester.ensureVisible(other);
      await tester.tap(other);
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('reject-other-note'));
      expect(field, findsOneWidget);
      final confirm = find.byKey(const ValueKey('reject-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(field, '騎士回報的是隔壁停車場');
      await tester.pumpAndSettle();
      // The keyboard is up; the field and the button stay reachable.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(field);
      expect(confirm.hitTestable(), findsOneWidget);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.kinds.single, ResolutionKind.other);
      expect(gateway.resolved.single.$4, '騎士回報的是隔壁停車場');
    });

    for (final (width, scale) in [(320.0, 1.6), (390.0, 1.0)]) {
      testWidgets('手機 ${width.toInt()} px、${scale}x 字級以底部面板選駁回原因', (
        tester,
      ) async {
        await show(
          tester,
          path: '/review/r-access',
          size: Size(width, 700),
          mode: ThemeMode.dark,
          textScale: scale,
        );
        await tester.tap(find.text('駁回'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final k in ResolutionKind.values) {
          final tile = find.byKey(ValueKey('reject-${k.name}'));
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          expect(tile.hitTestable(), findsOneWidget, reason: k.label);
          expect(
            tester.getSize(tile).height,
            greaterThanOrEqualTo(48),
            reason: k.label,
          );
          expect(tester.getRect(tile).right, lessThanOrEqualTo(width));
        }
        final insufficient = find.byKey(const ValueKey('reject-insufficient'));
        await tester.ensureVisible(insufficient);
        await tester.pumpAndSettle();
        await tester.tap(insufficient);
        await tester.pumpAndSettle();
        final confirm = find.byKey(const ValueKey('reject-confirm'));
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        expect(gateway.kinds.single, ResolutionKind.insufficient);
      });
    }

    testWidgets('不存在的回報網址顯示說明', (tester) async {
      await show(tester, path: '/review/nope');
      expect(find.text('這筆回報已處理或不存在'), findsOneWidget);
    });
  });
}
