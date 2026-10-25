import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/admin/spots/spots_controller.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/domain/location_check.dart';

import 'fake_admin_gateway.dart';

void main() {
  group('點位編輯', () {
    late FakeAdminGateway gateway;
    late SpotsController spots;

    setUp(() async {
      gateway = FakeAdminGateway(access: adminAal2);
      spots = SpotsController(gateway);
      await spots.search();
    });
    tearDown(() => gateway.dispose());

    test('搜尋兩種來源並依來源篩選', () async {
      expect(spots.results.map((r) => r.kind), [
        SpotKind.community,
        SpotKind.official,
      ]);
      spots.setFilters(kind: SpotKind.official);
      await Future<void>.delayed(Duration.zero);
      expect(spots.results.single.sourceId, officialId);
    });

    test('只送出改過的欄位，並帶開啟時的版本', () async {
      await spots.open(communityId);
      final opened = spots.record!.updatedAt;
      expect(spots.dirty, isFalse);
      spots.set('name', '中山北路二段機車格（新）');
      spots.set('fee_note', spots.draft['fee_note']);
      expect(spots.changes.keys, ['name']);
      expect(await spots.save('比對街景'), isTrue);
      final (id, values, base, note) = gateway.spotUpdates.single;
      expect((id, base, note), (communityId, opened, '比對街景'));
      expect(values, {'name': '中山北路二段機車格（新）'});
      expect(spots.dirty, isFalse);
      expect(spots.results.first.name, '中山北路二段機車格（新）');
    });

    test('開啟後被他人修改：不覆蓋，保留修改並提示重新載入', () async {
      await spots.open(communityId);
      gateway.spotRows[communityId]!['updated_at'] =
          '2026-10-25T01:00:00+00:00';
      spots.set('fee_note', '每次 10 元');
      expect(await spots.save(''), isFalse);
      expect(spots.stale, isTrue);
      expect(spots.saveError, contains('已被其他人修改'));
      expect(spots.draft['fee_note'], '每次 10 元');
      expect(gateway.spotUpdates, isEmpty);
    });

    test('改過的欄位依資料表約束驗證，未改的舊資料不擋儲存', () async {
      gateway.spotRows[officialId]!['source_name'] = '';
      await spots.open(officialId);
      spots.set('name', ' ');
      spots.set('source_url', 'http://example.test');
      expect(spots.errors.keys, containsAll(['name', 'source_url']));
      expect(await spots.save(''), isFalse);
      expect(gateway.spotUpdates, isEmpty);
      spots.discard();
      spots.set('fee_note', '每次 30 元');
      expect(spots.errors, isEmpty);
      expect(await spots.save(''), isTrue);
    });

    test('隱藏點位時保留尚未儲存的修改', () async {
      await spots.open(communityId);
      spots.set('note', '入口在巷內');
      expect(await spots.setHidden(true), isTrue);
      expect(spots.record!.hidden, isTrue);
      expect(spots.draft['note'], '入口在巷內');
      expect(gateway.hiddenChanges.single, (communityId, true));
    });

    test('新增點位送出全部已填欄位，位置帶入縣市與行政區', () async {
      spots.startNew(SpotKind.community, 25.06, 121.52);
      await Future<void>.delayed(Duration.zero);
      expect(spots.draft['city'], '臺北市');
      expect(spots.draft['district'], '中山區');
      expect(spots.dirty, isTrue);
      expect(spots.errors.keys, containsAll(['name', 'space_type']));
      expect(await spots.save(''), isFalse);
      spots.set('name', '新的機車格');
      spots.set('space_type', 'freeMotorcycle');
      expect(await spots.save('現場新增'), isTrue);
      final (kind, values, note) = gateway.created.single;
      expect((kind, note), (SpotKind.community, '現場新增'));
      expect(values, containsPair('lat', 25.06));
      expect(values, containsPair('city', '臺北市'));
      expect(values, containsPair('status', 'pending'));
      expect(spots.record!.isNew, isFalse);
    });

    test('附近 15 m 同類型點位列為可能重複，查不到縣市時說明', () async {
      gateway.nearby = const [
        NearbySpot(
          sourceId: 'x',
          name: '隔壁同類型',
          spaceType: 'freeMotorcycle',
          lat: 25.06001,
          lng: 121.52,
        ),
      ];
      gateway.townAt = null;
      spots.startNew(SpotKind.community, 25.06, 121.52);
      spots.set('space_type', 'freeMotorcycle');
      await spots.locate();
      expect(spots.notes.duplicates.single.name, '隔壁同類型');
      expect(spots.locateError, contains('查不到縣市'));
    });

    test('切換點位後，前一個點位較晚回來的查詢不會覆蓋新表單', () async {
      await spots.open(communityId);
      spots.set('lat', 25.07);
      gateway.delayedTown = Completer<void>();
      gateway.townAt = const Town('新北市', '三重區');
      final pending = spots.locate();
      await spots.open(officialId);
      gateway.delayedTown!.complete();
      await pending;
      expect(spots.record!.sourceId, officialId);
      expect(spots.draft['city'], '新北市');
      expect(spots.draft['district'], '板橋區');
      expect(spots.changes, isEmpty);
    });

    test('移動後立即儲存，先完成縣市查詢再寫入', () async {
      await spots.open(communityId);
      gateway.townAt = const Town('新北市', '三重區');
      spots.set('lat', 25.07);
      expect(spots.positionResolved, isFalse);
      expect(await spots.save(''), isTrue);
      final values = gateway.spotUpdates.single.$2;
      expect(values['lat'], 25.07);
      expect((values['city'], values['district']), ('新北市', '三重區'));
    });

    test('新位置查不到縣市時不儲存', () async {
      await spots.open(communityId);
      gateway.failTown = true;
      spots.set('lat', 25.07);
      expect(await spots.save(''), isFalse);
      expect(spots.saveError, contains('尚未查到'));
      expect(gateway.spotUpdates, isEmpty);
      spots.set('lat', gateway.spotRows[communityId]!['lat']);
      spots.set('note', '只改備註');
      expect(await spots.save(''), isTrue);
    });

    test('查詢服務失敗時，確認手動填寫的縣市後可儲存', () async {
      await spots.open(communityId);
      gateway.failTown = true;
      spots.set('lat', 25.07);
      await spots.locate();
      expect(spots.locateError, contains('查詢失敗'));
      spots.set('city', '新北市');
      spots.set('district', '三重區');
      expect(spots.confirmManualTown(), isTrue);
      expect(await spots.save(''), isTrue);
      expect(gateway.spotUpdates.single.$2['city'], '新北市');
      // Moving again needs a new lookup or confirmation.
      spots.set('lat', 25.08);
      expect(spots.positionResolved, isFalse);
    });

    test('移回原座標但縣市已被改掉時，仍重新查詢', () async {
      await spots.open(communityId);
      final lat = gateway.spotRows[communityId]!['lat'];
      gateway.townAt = const Town('新北市', '三重區');
      spots.set('lat', 25.07);
      await spots.locate();
      expect(spots.draft['city'], '新北市');
      spots.set('lat', lat);
      expect(spots.positionResolved, isFalse);
      gateway.townAt = const Town('臺北市', '中山區');
      final before = gateway.townRequests;
      expect(await spots.save(''), isTrue);
      expect(gateway.townRequests, before + 1);
      expect(spots.record!.values['city'], '臺北市');
    });

    test('查到縣市後改了縣市或行政區，需重新查詢或確認', () async {
      await spots.open(communityId);
      gateway.townAt = const Town('新北市', '三重區');
      spots.set('lat', 25.07);
      await spots.locate();
      expect(spots.positionResolved, isTrue);
      spots.set('district', '蘆洲區');
      expect(spots.positionResolved, isFalse);
      spots.set('district', '三重區');
      expect(spots.positionResolved, isTrue);
      spots.set('city', '臺北市');
      expect(spots.positionResolved, isFalse);
      final before = gateway.townRequests;
      expect(await spots.save(''), isTrue);
      expect(gateway.townRequests, before + 1);
      final values = gateway.spotUpdates.single.$2;
      expect((values['city'], values['district']), ('新北市', '三重區'));
    });

    test('手動確認縣市後又改縣市，需再確認', () async {
      spots.startNew(SpotKind.community, 25.06, 121.52);
      gateway.failTown = true;
      await spots.locate();
      spots.set('city', '新北市');
      expect(spots.confirmManualTown(), isTrue);
      expect(spots.positionResolved, isTrue);
      spots.set('city', '桃園市');
      expect(spots.positionResolved, isFalse);
    });

    test('查詢中連按兩次建立，只建立一筆', () async {
      spots.startNew(SpotKind.community, 25.06, 121.52);
      await Future<void>.delayed(Duration.zero);
      spots.set('name', '新的機車格');
      spots.set('space_type', 'freeMotorcycle');
      spots.set('lat', 25.061);
      gateway.delayedTown = Completer<void>();
      final first = spots.save('');
      final second = spots.save('');
      gateway.delayedTown!.complete();
      expect(await second, isFalse);
      expect(await first, isTrue);
      expect(gateway.created, hasLength(1));
    });

    test('改為官方點只送管理者填的來源與資格', () async {
      await spots.open(communityId);
      final id = await spots.promote({
        'source_name': '臺北市政府',
        'source_url': 'https://example.test/lot',
        'effective_date': '2026-10-25',
      }, '比對停管處資料');
      expect(id, startsWith('official:'));
      expect(
        gateway.promotions.single.$2.containsKey('heavy_allowed'),
        isFalse,
      );
      expect(gateway.spotRows[id]!['heavy_allowed'], isNull);
      expect(gateway.spotRows[communityId]!['status'], 'hidden');
    });
  });

  /// The form's own list, not a text field's inner scrollable.
  Finder form() => find
      .descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('spot-form-'),
        ),
        matching: find.byType(Scrollable),
      )
      .first;

  group('點位畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    setUp(() => gateway = FakeAdminGateway(access: adminAal2));
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(
      WidgetTester tester, {
      String path = '/spots',
      Size size = const Size(1280, 900),
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
          reviewMapBuilder: (_, _) => const SizedBox(),
          locationMapBuilder: (_, view) => Row(
            children: [
              TextButton(
                onPressed: () => view.onMove(view.lat + 0.00005, view.lng),
                child: const Text('拖曳到附近'),
              ),
              TextButton(
                onPressed: () => view.onMove(view.lat + 0.002, view.lng),
                child: const Text('拖曳到遠處'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('寬螢幕選點位、修改標示已修改、儲存後關閉', (tester) async {
      await show(tester);
      expect(find.text('選擇一個點位'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spot-$communityId')));
      await tester.pumpAndSettle();
      expect(find.text('社群點（社群回報整理）'), findsOneWidget);
      expect(find.text('儲存並關閉'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, '名稱'),
        '中山北路機車格',
      );
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsOneWidget);
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates.single.$2, {'name': '中山北路機車格'});
      expect(find.text('已儲存：中山北路機車格'), findsOneWidget);
      expect(find.text('選擇一個點位'), findsOneWidget);
    });

    testWidgets('有未儲存的修改時，換點位前先確認', (tester) async {
      await show(tester, path: '/spots/$communityId');
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '暫存名稱');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spot-$officialId')));
      await tester.pumpAndSettle();
      expect(find.text('放棄未儲存的修改？'), findsOneWidget);
      await tester.tap(find.text('繼續編輯'));
      await tester.pumpAndSettle();
      expect(find.text('社群點（社群回報整理）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spot-$officialId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放棄修改').last);
      await tester.pumpAndSettle();
      expect(find.text('官方點（新北市政府）'), findsOneWidget);
    });

    testWidgets('手機版先列表，點選後進表單並可返回', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(find.text('儲存並關閉'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('spot-$officialId')));
      await tester.pumpAndSettle();
      expect(find.text('官方點（新北市政府）'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('ntpc-001'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('ntpc-001'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('返回點位清單'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('返回點位清單'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsOneWidget);
    });

    testWidgets('改為官方點需填官方來源，完成後開啟新的官方點', (tester) async {
      await show(tester, path: '/spots/$communityId');
      await tester.tap(find.text('改為官方點').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '改為官方點'));
      await tester.pumpAndSettle();
      expect(find.text('請選擇資料來源'), findsOneWidget);
      expect(gateway.promotions, isEmpty);
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, '資料來源'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('臺北市政府').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '官方資料網址'),
        'https://example.test/lot',
      );
      await tester.tap(find.widgetWithText(FilledButton, '改為官方點'));
      await tester.pumpAndSettle();
      expect(gateway.promotions.single.$2['source_name'], '臺北市政府');
      expect(find.text('官方點（臺北市政府）'), findsOneWidget);
    });

    testWidgets('新增停車點：選類型、拖曳選位、自動帶入縣市後建立', (tester) async {
      await show(tester);
      await tester.tap(find.text('新增停車點'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('社群點').last);
      await tester.pumpAndSettle();
      expect(find.text('新增社群點'), findsOneWidget);
      expect(find.text('建立停車點'), findsOneWidget);
      expect(find.text('隱藏點位'), findsNothing);
      expect(find.text('請填寫名稱'), findsNothing);
      await tester.tap(find.text('建立停車點'));
      await tester.pumpAndSettle();
      expect(find.text('請填寫名稱'), findsOneWidget);
      expect(gateway.created, isEmpty);
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '新的機車格');
      await tester.scrollUntilVisible(
        find.text('拖曳到附近'),
        300,
        scrollable: form(),
      );
      await tester.tap(find.text('拖曳到附近'));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(gateway.townRequests, greaterThan(0));
      await tester.scrollUntilVisible(
        find.widgetWithText(DropdownButtonFormField<String>, '格位類型'),
        -300,
        scrollable: form(),
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, '格位類型'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('免費機車格').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('建立停車點'));
      await tester.pumpAndSettle();
      expect(gateway.created.single.$2['city'], '臺北市');
      expect(find.text('已建立：新的機車格'), findsOneWidget);
      expect(find.text('社群點（社群回報整理）'), findsOneWidget);
    });

    testWidgets('換新增類型時表單欄位重新開始', (tester) async {
      await show(tester);
      await tester.tap(find.text('新增停車點'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('社群點').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '暫時名稱');
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增停車點'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('官方點').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('放棄修改').last);
      await tester.pumpAndSettle();
      expect(find.text('新增官方點'), findsOneWidget);
      expect(find.text('暫時名稱'), findsNothing);
    });

    testWidgets('新增中再選同類型並放棄修改，重新開始並帶入縣市', (tester) async {
      await show(tester);
      await tester.tap(find.text('新增停車點'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('社群點').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '暫時名稱');
      await tester.pumpAndSettle();
      final before = gateway.townRequests;
      await tester.tap(find.text('新增停車點'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('社群點').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('放棄修改').last);
      await tester.pumpAndSettle();
      expect(find.text('新增社群點'), findsOneWidget);
      expect(find.text('暫時名稱'), findsNothing);
      expect(gateway.townRequests, before + 1);
      // Both fields show the looked-up values; the district is further down.
      await tester.scrollUntilVisible(
        find.text('臺北市'),
        300,
        scrollable: form(),
      );
      await tester.drag(form(), const Offset(0, -300));
      await tester.pumpAndSettle();
      final texts = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((e) => e.controller.text);
      expect(texts, containsAll(['臺北市', '中山區']));
    });

    testWidgets('移動超過 150 m 時儲存前確認', (tester) async {
      await show(tester, path: '/spots/$communityId');
      await tester.scrollUntilVisible(
        find.text('拖曳到遠處'),
        300,
        scrollable: form(),
      );
      await tester.ensureVisible(find.text('拖曳到遠處'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拖曳到遠處'));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.textContaining('超過 150 m'), findsOneWidget);
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      expect(find.text('移動超過 150 m'), findsOneWidget);
      await tester.tap(find.text('回去調整'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates, isEmpty);
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('是同一個點位，儲存'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates.single.$2.keys, containsAll(['lat']));
    });

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(700, 900),
      Size(1280, 900),
    ]) {
      testWidgets('新增點位的位置區塊在 ${size.width.round()} px 不溢出', (tester) async {
        await show(tester, path: '/spots/new?kind=official', size: size);
        expect(find.text('新增官方點'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byTooltip('往東 1 m'),
          300,
          scrollable: form(),
        );
        await tester.ensureVisible(find.byTooltip('往東 1 m'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('往東 1 m').hitTestable(), findsOneWidget);
        expect(find.text('建立停車點').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(700, 900),
      Size(1280, 900),
    ]) {
      testWidgets('核驗目前車種在 ${size.width.round()} px 可用且不溢出', (tester) async {
        await show(tester, path: '/spots/$communityId', size: size);
        final button = find.byKey(const ValueKey('verify-vehicles'));
        await tester.scrollUntilVisible(button, 300, scrollable: form());
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(find.text('尚未核驗'), findsOneWidget);
        expect(find.text('未確認，無法核驗'), findsOneWidget);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        await tester.tap(button.hitTestable());
        await tester.pumpAndSettle();
        // Only the known flag is restated, unchanged.
        expect(gateway.spotUpdates.single.$2, {'scooter_allowed': true});
        expect(gateway.spotUpdates.single.$4, '核驗目前車種');
        expect(find.text('已核驗目前車種'), findsOneWidget);
        // The reloaded form starts at the top again.
        await tester.scrollUntilVisible(
          find.textContaining('已核驗（2026-10-25）'),
          300,
          scrollable: form(),
        );
        expect(find.textContaining('已核驗（2026-10-25）'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('有未儲存的修改時不能核驗車種', (tester) async {
      await show(tester, path: '/spots/$communityId');
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '暫存名稱');
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('verify-vehicles'));
      await tester.scrollUntilVisible(button, 300, scrollable: form());
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(find.text('有未儲存的修改，請先儲存或捨棄後再核驗。'), findsOneWidget);
    });

    testWidgets('官方點不顯示車種核驗', (tester) async {
      await show(tester, path: '/spots/$officialId');
      expect(find.byKey(const ValueKey('vehicle-verification')), findsNothing);
    });

    testWidgets('隱藏點位後可復原', (tester) async {
      await show(tester, path: '/spots/$officialId');
      await tester.tap(find.text('隱藏點位'));
      await tester.pumpAndSettle();
      expect(find.text('這個點位已隱藏，App 地圖上不會顯示。'), findsOneWidget);
      expect(find.text('恢復顯示'), findsOneWidget);
      await tester.tap(find.text('復原'));
      await tester.pumpAndSettle();
      expect(gateway.hiddenChanges.last, (officialId, false));
      expect(find.text('隱藏點位'), findsOneWidget);
    });
  });
}
