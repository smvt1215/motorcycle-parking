import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/ui/option_pill.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_page.dart'
    show ChangeBand;
import 'package:motorcycle_parking/admin/spots/spot_map.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/admin/spots/spots_controller.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';

import 'fake_admin_gateway.dart';
import 'fold_helpers.dart';

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

    test('其他頁寫入後背景重新讀取開啟中的點位；等待期間的修改不被覆蓋（決定 49）', () async {
      await spots.open(communityId);
      gateway.spotRows[communityId]!['name'] = '審核後的新名稱';
      // Not this spot: the form is left alone.
      await spots.refresh({officialId});
      expect(spots.record!.name, isNot('審核後的新名稱'));
      // This spot, nothing typed: the form shows the new values.
      await spots.refresh({communityId});
      expect(spots.record!.name, '審核後的新名稱');
      expect(spots.opening, isFalse);
      // Typing while the read is on its way keeps what was typed.
      gateway.delayedSpot = Completer<void>();
      final reading = spots.refresh({communityId});
      spots.set('note', '管理員剛輸入的備註');
      gateway.spotRows[communityId]!['name'] = '又一次的新名稱';
      gateway.delayedSpot!.complete();
      await reading;
      expect(spots.draft['note'], '管理員剛輸入的備註');
      expect(spots.dirty, isTrue);
      expect(spots.record!.name, '審核後的新名稱');
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
    SpotMapView? mapView;

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
          spotMapBuilder: (_, view) {
            mapView = view;
            return FakeSpotMap(view: view);
          },
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
      expect(find.text('儲存並關閉'), findsNothing);
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
      expect(find.text('儲存並關閉'), findsNothing);
    });

    testWidgets('場站類型可複選，送出依契約順序的型式（決定 58）', (tester) async {
      await show(tester, path: '/spots/$officialId');
      await openFold(tester, '格位與停放條件');
      final surface = find.byKey(const ValueKey('spot-facility_types-surface'));
      await tester.ensureVisible(surface);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OptionCheck>(
              find.byKey(const ValueKey('spot-facility_types-underground')),
            )
            .value,
        isTrue,
      );
      await tester.tap(surface);
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsOneWidget);
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates.single.$2, {
        'facility_types': ['underground', 'surface'],
      });
    });

    testWidgets('格位類型用 App 的分組清單：普大共用寫入條件，選回原類型還原', (tester) async {
      await show(tester, path: '/spots/$communityId');
      await openFold(tester, '格位與停放條件');
      Future<void> tapKey(String key) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      // The stored paid bay sits in its open group.
      await tapKey('spot-space-scooterHeavy');
      await tapKey('spot-space-charge-free');
      expect(find.text('已修改'), findsWidgets);
      // Back to the stored kind: nothing left to save, the heavy bikes'
      // access 普大共用 set (decision 60) included.
      await tapKey('spot-space-motorcycle');
      expect(find.byType(ChangeBand), findsNothing);
      await tapKey('spot-space-scooterHeavy');
      await tapKey('spot-space-charge-free');
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates.single.$2, {
        'space_type': 'freeMotorcycle',
        'condition': {
          'bay': 'motorcycle',
          'use': 'share',
          'share': 'scooter_heavy',
          'charge': 'free',
        },
        // Decision 60: 普大共用 brings heavy bikes in, 可停.
        'heavy_allowed': true,
      });
    });

    group('換格位類型時的條件', () {
      Future<void> tapKey(WidgetTester tester, String key) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      Future<Map<String, dynamic>> save(WidgetTester tester) async {
        await tester.tap(find.text('儲存並關閉'));
        await tester.pumpAndSettle();
        return gateway.spotUpdates.single.$2;
      }

      testWidgets('保留公告依據與共用時段；普大共用收費切回原值即還原', (tester) async {
        const basis = {'source_url': 'https://example.test/notice'};
        const slot = {
          'days': 'weekday',
          'from': '07:00',
          'to': '20:00',
          'vehicles': ['scooter', 'car'],
        };
        gateway.spotRows[communityId]!
          ..['space_type'] = 'paidMotorcycle'
          ..['condition'] = {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'charge': 'toll',
            'schedule': [slot],
            'basis': basis,
          };
        await show(tester, path: '/spots/$communityId');
        await openFold(tester, '格位與停放條件');
        // 免費 then back to 收費: the stored condition, nothing to save.
        await tapKey(tester, 'spot-space-charge-free');
        expect(find.text('已修改'), findsWidgets);
        await tapKey(tester, 'spot-space-charge-toll');
        expect(find.byType(ChangeBand), findsNothing);
        await tapKey(tester, 'spot-space-car');
        expect(await save(tester), {
          'space_type': 'car',
          'condition': {
            'bay': 'car',
            'use': 'usual',
            'schedule': [slot],
            'basis': basis,
          },
        });
      });

      testWidgets('限時的普大共用格改收費時保留限時與分鐘', (tester) async {
        gateway.spotRows[communityId]!
          ..['space_type'] = 'timedMotorcycle'
          ..['condition'] = {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'limits': [
              {'kind': 'time_limit', 'max_minutes': 30},
            ],
          };
        await show(tester, path: '/spots/$communityId');
        await openFold(tester, '格位與停放條件');
        await tapKey(tester, 'spot-space-charge-free');
        expect(await save(tester), {
          'condition': {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'charge': 'free',
            'limits': [
              {'kind': 'time_limit', 'max_minutes': 30},
            ],
          },
        });
      });

      testWidgets('改成路外時條件為 null', (tester) async {
        gateway.spotRows[communityId]!['condition'] = {
          'bay': 'motorcycle',
          'use': 'usual',
          'charge': 'toll',
        };
        await show(tester, path: '/spots/$communityId');
        await openFold(tester, '格位與停放條件');
        await tapKey(tester, 'spot-space-offStreet');
        final saved = await save(tester);
        expect(saved['space_type'], 'offStreet');
        expect(saved.containsKey('condition'), isTrue);
        expect(saved['condition'], isNull);
      });

      testWidgets('原本沒有條件的點位換一般類型仍沒有條件', (tester) async {
        await show(tester, path: '/spots/$communityId');
        await openFold(tester, '格位與停放條件');
        await tapKey(tester, 'spot-space-heavy');
        expect(await save(tester), {'space_type': 'heavyOnly'});
      });
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
      await tester.tap(find.text('清單'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spot-$officialId')));
      await tester.pumpAndSettle();
      expect(find.text('官方點（新北市政府）'), findsOneWidget);
      await openFold(tester, '資料來源');
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

    testWidgets('地圖顯示官方點與社群點，已隱藏圖層另外開啟並淡化', (tester) async {
      await show(tester);
      expect(find.byKey(const ValueKey('marker-$communityId')), findsOneWidget);
      expect(find.byKey(const ValueKey('marker-$officialId')), findsOneWidget);
      expect(find.textContaining('淡'), findsNothing);
      expect(gateway.mapRequests.last.$2, isTrue);
      expect(gateway.mapRequests.last.$4, isFalse);
      await tester.tap(find.byKey(const ValueKey('map-layers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('layer-hidden')));
      await tester.pumpAndSettle();
      expect(gateway.mapRequests.last.$4, isTrue);
      expect(find.textContaining('淡'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('layer-official')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('marker-$officialId')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('layer-satellite')));
      await tester.pumpAndSettle();
      expect(mapView!.satellite, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('車種切換改變標記的停放資格', (tester) async {
      await show(tester);
      String look() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('marker-$officialId')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      final scooter = look();
      await tester.tap(find.byKey(const ValueKey('map-vehicle-heavy')));
      await tester.pumpAndSettle();
      expect(look(), 'allowed');
      expect(look(), isNot(scooter));
    });

    testWidgets('點標記開啟右側表單，標記停在表單旁並保持縮放', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('marker-$officialId')));
      await tester.pumpAndSettle();
      expect(find.text('官方點（新北市政府）'), findsOneWidget);
      expect(mapView!.selected?.id, officialId);
      expect(mapView!.focus!.zoom, isNull);
      // Form 480 px on the right, list 380 px on the left.
      expect(mapView!.focus!.leftOfCenter, 50);
      await tester.tap(find.byKey(const ValueKey('close-form')));
      await tester.pumpAndSettle();
      expect(find.text('儲存並關閉'), findsNothing);
      expect(mapView!.selected, isNull);
    });

    testWidgets('點清單移動地圖到街道層級並開啟表單', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('spot-$communityId')));
      await tester.pumpAndSettle();
      expect(mapView!.focus!.zoom, 18);
      expect(mapView!.focus!.lat, 25.0581);
      expect(mapView!.selected?.id, communityId);
    });

    testWidgets('清單可收起與展開', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('list-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsNothing);
      await tester.tap(find.text('顯示清單'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsOneWidget);
    });

    testWidgets('雙欄窄版開表單時清單讓位，關閉後回來', (tester) async {
      await show(tester, size: const Size(760, 900));
      await tester.tap(find.byKey(const ValueKey('spot-$communityId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsNothing);
      expect(find.text('社群點（社群回報整理）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Brought back beside the form, the list can step aside again.
      await tester.tap(find.byKey(const ValueKey('list-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('list-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('close-form')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spot-$communityId')), findsOneWidget);
    });

    testWidgets('雙欄窄版表單旁切換清單時，相機重新偏移讓標記不被清單蓋住', (tester) async {
      await show(tester, size: const Size(760, 900));
      await tester.tap(find.byKey(const ValueKey('spot-$communityId')));
      await tester.pumpAndSettle();
      // Form 425.6 px (56 % of 760) on the right, no list: the spot sits in
      // the middle of the map left of the form.
      const formWidth = 760 * .56;
      final opened = mapView!.focus!;
      expect(opened.zoom, 18);
      expect(opened.leftOfCenter, closeTo(formWidth / 2, 1e-9));
      // The 300 px list comes back beside the form: the camera pans the
      // spot into the gap between the panels, keeping the zoom.
      await tester.tap(find.byKey(const ValueKey('list-toggle')));
      await tester.pumpAndSettle();
      final beside = mapView!.focus!;
      expect(beside.seq, greaterThan(opened.seq));
      expect(beside.zoom, isNull);
      expect((beside.lat, beside.lng), (opened.lat, opened.lng));
      expect(beside.leftOfCenter, closeTo((formWidth - 300) / 2, 1e-9));
      final spotX = 760 / 2 - beside.leftOfCenter;
      expect(spotX, greaterThan(300));
      expect(spotX, lessThan(760 - formWidth));
      // Stepping aside again pans it back to the middle of the open map.
      await tester.tap(find.byKey(const ValueKey('list-toggle')));
      await tester.pumpAndSettle();
      final alone = mapView!.focus!;
      expect(alone.seq, greaterThan(beside.seq));
      expect(alone.zoom, isNull);
      expect(alone.leftOfCenter, closeTo(formWidth / 2, 1e-9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('手機版從地圖點標記進表單，返回地圖', (tester) async {
      await show(tester, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('marker-$communityId')));
      await tester.pumpAndSettle();
      expect(find.text('社群點（社群回報整理）'), findsOneWidget);
      expect(mapView!.covered, isTrue);
      await tester.tap(find.text('返回地圖'));
      await tester.pumpAndSettle();
      expect(mapView!.covered, isFalse);
      expect(find.byKey(const ValueKey('marker-$communityId')), findsOneWidget);
    });

    testWidgets('地圖載入失敗時說明並可重試', (tester) async {
      gateway.failMap = true;
      await show(tester);
      expect(find.text('地圖上的停車點載入失敗，請檢查連線後重試。'), findsOneWidget);
      gateway.failMap = false;
      await tester.tap(find.text('重試'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('marker-$communityId')), findsOneWidget);
    });

    testWidgets('隱藏點位後地圖重新載入', (tester) async {
      await show(tester, path: '/spots/$communityId');
      final before = gateway.mapRequests.length;
      await tester.tap(find.text('隱藏點位').last);
      await tester.pumpAndSettle();
      expect(gateway.mapRequests.length, greaterThan(before));
    });

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(700, 900),
      Size(1280, 900),
    ]) {
      testWidgets('地圖控制在 ${size.width.round()} px 不溢出、按鈕至少 48 px', (
        tester,
      ) async {
        await show(tester, size: size);
        await tester.tap(find.byKey(const ValueKey('map-layers')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final key in [
          'map-vehicle-scooter',
          'map-vehicle-heavy',
          'map-layers',
        ]) {
          final box = tester.getSize(find.byKey(ValueKey(key)));
          expect(box.height, greaterThanOrEqualTo(48), reason: key);
        }
        if (size.width >= 680) {
          await tester.tap(find.byKey(const ValueKey('spot-$officialId')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }

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
      // The first section with an error opened.
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '新的機車格');
      await openFold(tester, '位置');
      await tester.scrollUntilVisible(
        find.text('拖曳到附近'),
        300,
        scrollable: form(),
      );
      await tester.tap(find.text('拖曳到附近'));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(gateway.townRequests, greaterThan(0));
      await openFold(tester, '格位與停放條件');
      // The app's ground-marking list (#188): 一般機車格, then 免費格.
      for (final key in ['spot-space-motorcycle', 'spot-space-charge-free']) {
        final target = find.byKey(ValueKey(key));
        await tester.scrollUntilVisible(target, 300, scrollable: form());
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('建立停車點'));
      await tester.pumpAndSettle();
      expect(gateway.created.single.$2['city'], '臺北市');
      expect(gateway.created.single.$2['space_type'], 'freeMotorcycle');
      expect(find.text('已建立：新的機車格'), findsOneWidget);
      expect(find.text('社群點（社群回報整理）'), findsOneWidget);
      // The list reads again and shows the new spot at once (決定 49).
      expect(
        find.byKey(const ValueKey('spot-77777777-7777-4777-8777-777777777777')),
        findsOneWidget,
      );
    });

    testWidgets('換新增類型時表單欄位重新開始', (tester) async {
      await show(tester);
      await tester.tap(find.text('新增停車點'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('社群點').last);
      await tester.pumpAndSettle();
      await openFold(tester, '基本資訊');
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
      await openFold(tester, '基本資訊');
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
      await openFold(tester, '位置');
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

    for (final size in const [Size(390, 844), Size(1280, 900)]) {
      testWidgets('${size.width.round()} px 搜尋路口：移動標記、填入路段並儲存', (tester) async {
        gateway.addressResults = const [
          AddressCandidate(
            kind: AddressKind.intersection,
            label: '中山北路二段與南京東路一段',
            place: '臺北市中山區',
            lat: 25.0521,
            lng: 121.5222,
            precision: AddressPrecision.center,
          ),
        ];
        await show(tester, path: '/spots/$communityId', size: size);
        await openFold(tester, '位置');
        final entry = find.byKey(const ValueKey('location-search'));
        await tester.scrollUntilVisible(entry, 300, scrollable: form());
        await tester.ensureVisible(entry);
        await tester.pumpAndSettle();
        await tester.tap(entry);
        await tester.pumpAndSettle();
        final search = find.byKey(const ValueKey('address-search'));
        await tester.enterText(search, '中山北路二段與南京東路');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(gateway.addressQueries, ['中山北路二段與南京東路']);
        await tester.tap(find.text('中山北路二段與南京東路一段'));
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
        expect(find.textContaining('交會點，請把標記拖到'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('儲存並關閉'));
        await tester.pumpAndSettle();
        // The crossing may be far from the stored point.
        final same = find.text('是同一個點位，儲存');
        if (same.evaluate().isNotEmpty) {
          await tester.tap(same);
          await tester.pumpAndSettle();
        }
        final saved = gateway.spotUpdates.single.$2;
        expect(saved['road_segment'], '中山北路二段與南京東路一段');
        expect(saved['lat'], 25.0521);
      });
    }

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
        await openFold(tester, '可停車種');
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
      await openFold(tester, '可停車種');
      final button = find.byKey(const ValueKey('verify-vehicles'));
      await tester.scrollUntilVisible(button, 300, scrollable: form());
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(find.text('有未儲存的修改，請先儲存或捨棄後再核驗。'), findsOneWidget);
    });

    testWidgets('官方點不顯示車種核驗', (tester) async {
      await show(tester, path: '/spots/$officialId');
      expect(find.byKey(const ValueKey('vehicle-verification')), findsNothing);
    });

    testWidgets('分段收合：一次展開一段，收起時寫摘要，沒填的寫「還沒填」（決定 57）', (tester) async {
      await show(tester, path: '/spots/new?kind=community');
      Future<Finder> sub(String title, String text) async => find.descendant(
        of: await revealFold(tester, title),
        matching: find.text(text),
      );
      // A new spot starts at its position; the rest is folded.
      expect(find.byKey(const ValueKey('location-search')), findsOneWidget);
      expect(await sub('基本資訊', '還沒填'), findsOneWidget);
      expect(await sub('補充', '還沒填'), findsOneWidget);
      expect(await sub('可停車種', '普通機車未確認・大型重機未確認'), findsOneWidget);
      await openFold(tester, '基本資訊');
      // Opening one folds the other; its summary says where it is.
      expect(find.byKey(const ValueKey('location-search')), findsNothing);
      expect(
        find.descendant(
          of: await revealFold(tester, '位置'),
          matching: find.textContaining('臺北市・中山區・'),
        ),
        findsOneWidget,
      );
      // A save with gaps opens the first section to fix and flags the next.
      await tester.tap(find.text('建立停車點'));
      await tester.pumpAndSettle();
      expect(find.text('請填寫名稱'), findsOneWidget);
      expect(await sub('格位與停放條件', '有欄位要修正'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, '名稱'), '新的機車格');
      await openFold(tester, '格位與停放條件');
      expect(find.text('請填寫格位類型'), findsOneWidget);
      expect(await sub('基本資訊', '新的機車格・待確認'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('車種用三段按鈕、少量選項用膠囊；收起的段落保留已修改色帶', (tester) async {
      await show(tester, path: '/spots/$communityId');
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      await openFold(tester, '可停車種');
      final heavy = find.byKey(const ValueKey('heavy_allowed-false'));
      expect(tester.getSize(heavy).height, greaterThanOrEqualTo(48));
      await tester.tap(heavy);
      await tester.pumpAndSettle();
      await openFold(tester, '格位與停放條件');
      final underground = find.byKey(
        const ValueKey('spot-facility_types-underground'),
      );
      await Scrollable.ensureVisible(
        tester.element(underground),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(underground);
      await tester.pumpAndSettle();
      // Folded with an edit: the yellow band stays above it.
      // One over the check rows in the open section, one over 可停車種.
      expect(find.byType(ChangeBand, skipOffstage: false), findsAtLeast(2));
      expect(
        find.descendant(
          of: await revealFold(tester, '可停車種'),
          matching: find.text('普通機車可停・大型重機不可停'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates.single.$2, {
        'heavy_allowed': false,
        'facility_types': ['underground'],
      });
    });

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(402, 874),
      Size(820, 1180),
      Size(1180, 820),
      Size(1024, 1366),
      Size(1440, 960),
    ]) {
      testWidgets(
        '分段表單在 ${size.width.round()}×${size.height.round()} 每段都能展開、不溢出、標題至少 48 px',
        (tester) async {
          await show(tester, path: '/spots/$officialId', size: size);
          if (size.width < 680) {
            expect(find.byKey(const ValueKey('fold-位置')), findsOneWidget);
          }
          for (final title in [
            '位置',
            '基本資訊',
            '格位與停放條件',
            '可停車種',
            '計費規則與區域',
            '暫時無法停車',
            '補充',
            '資料來源',
          ]) {
            await openFold(tester, title);
            await tester.pumpAndSettle();
            final header = find.byKey(ValueKey('fold-$title'));
            expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
            expect(header.hitTestable(), findsOneWidget, reason: title);
            expect(tester.takeException(), isNull, reason: title);
          }
        },
      );
    }

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

/// Stands in for the Google map: reports a Taipei view once, and shows each
/// spot as a button.
class FakeSpotMap extends StatefulWidget {
  const FakeSpotMap({super.key, required this.view});
  final SpotMapView view;
  @override
  State<FakeSpotMap> createState() => _FakeSpotMapState();
}

class _FakeSpotMapState extends State<FakeSpotMap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.view.onViewport(
        const MapViewport(south: 24.9, west: 121.3, north: 25.2, east: 121.7),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    return ColoredBox(
      color: const Color(0xffdde3e6),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Wrap(
          children: [
            for (final spot in v.spots)
              TextButton(
                key: ValueKey('marker-${spot.id}'),
                onPressed: () => v.onSpotTap(spot),
                child: Text(
                  '${v.dimmed(spot) ? '淡' : ''}${v.eligibility(spot).status.name}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
