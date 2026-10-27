import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/import/fee_reading.dart';
import 'package:motorcycle_parking/admin/import/import_controller.dart';
import 'package:motorcycle_parking/admin/import/import_page.dart';
import 'package:motorcycle_parking/admin/import/import_models.dart';

import 'fake_admin_gateway.dart';

const updatedId = 'official:30000000-0000-4000-8000-000000000001';
const conflictId = 'official:30000000-0000-4000-8000-000000000002';
const newOfficialId = 'official:30000000-0000-4000-8000-000000000003';
const newCommunityId = '30000000-0000-4000-8000-000000000004';

Map<String, dynamic> spot(String id, String name, String feeNote) => {
  'id': id,
  'source': id.startsWith('official:') ? 'official' : 'import',
  'name': name,
  'lat': 25.04,
  'lng': 121.51,
  'city': '臺北市',
  'district': '中正區',
  'space_type': 'offStreet',
  'fee_note': feeNote,
};

final file = jsonEncode([
  spot(updatedId, '公園路地下停車場', '機車計次20元;機車月租300元;'),
  spot(conflictId, '信義廣場地下停車場', '小型車計時30元;機車計時10元;'),
  spot(newOfficialId, '中正紀念堂地下停車場', '機車免費;'),
  spot(newCommunityId, '家樂福 桂林店', '免費（大型重機比照機車費率）'),
]);

Map<String, ImportEntry> plan() => {
  updatedId: const ImportEntry(
    sourceId: updatedId,
    official: true,
    status: ImportStatus.update,
    reason: '',
    name: '公園路地下停車場',
    city: '臺北市',
    district: '中正區',
    baseUpdatedAt: '2026-10-17T00:00:00+00:00',
    changes: [ImportChange(field: 'note', current: '', incoming: '官方資料更新')],
  ),
  conflictId: ImportEntry(
    sourceId: conflictId,
    official: true,
    status: ImportStatus.conflict,
    reason: '',
    name: '信義廣場地下停車場（管理員命名，名稱很長需要換行顯示）',
    city: '臺北市',
    district: '信義區',
    baseUpdatedAt: '2026-10-24T08:00:00+00:00',
    hidden: true,
    changes: [
      ImportChange(
        field: 'name',
        current: '信義廣場地下停車場（管理員命名，名稱很長需要換行顯示）',
        incoming: '信義廣場地下停車場',
        adminAt: DateTime.utc(2026, 10, 24, 8),
        adminAction: 'update_spot',
      ),
      const ImportChange(field: 'scooter_total', current: 120, incoming: 150),
    ],
  ),
};

void main() {
  group('匯入控制', () {
    late FakeAdminGateway gateway;
    late ImportController imports;
    var applied = <Set<String>>[];
    setUp(() {
      applied = [];
      gateway = FakeAdminGateway(access: adminAal2)..importPlan = plan();
      imports = ImportController(gateway, onApplied: applied.add);
    });
    tearDown(() => gateway.dispose());

    test('不是 JSON 或不是點位清單時說明怎麼修，不送出', () async {
      await imports.load('notes.txt', 'hello');
      expect(imports.error, contains('不是 JSON'));
      await imports.load('x.json', '{"id":1}');
      expect(imports.error, contains('不是停車點清單'));
      expect(gateway.previewed, isEmpty);
    });

    test('試算時帶入可確定的結構化費率，只預設勾選可匯入的點位', () async {
      await imports.load('spots.json', file);
      final sent = {for (final s in gateway.previewed.single) s['id']: s};
      expect(sent[updatedId]!['fee'], {
        'scooter': {'mode': 'per_visit', 'amount': 20},
      });
      // 機車計時10元 has no period: left for a person, not sent as a fee.
      expect(sent[conflictId]!.containsKey('fee'), isFalse);
      expect(imports.feesRead, 3);
      expect(imports.count(ImportStatus.added), 2);
      expect(imports.selected, {
        updatedId,
        conflictId,
        newOfficialId,
        newCommunityId,
      });
      expect(imports.needsDate, isTrue);
    });

    test('套用時帶回試算的版本，管理員欄位只覆寫勾選的', () async {
      await imports.load('spots.json', file);
      imports.toggle(newCommunityId, false);
      imports.setOverwrite(conflictId, 'name', true);
      imports.setEffectiveDate('2026-10-26');
      await imports.apply(' 十月匯入 ');
      final (spots, choices, date, note) = gateway.imported.single;
      expect(spots.map((s) => s['id']), [updatedId, conflictId, newOfficialId]);
      expect(choices[conflictId], {
        'base_updated_at': '2026-10-24T08:00:00+00:00',
        'overwrite': ['name'],
      });
      expect(choices[newOfficialId], {
        'base_updated_at': null,
        'overwrite': <String>[],
      });
      expect((date, note), ('2026-10-26', '十月匯入'));
      expect(imports.result!.inserted, 1);
      expect(imports.result!.updated, 2);
      // The spots page and the review queue are told to read again (決定 49).
      expect(applied, [
        {updatedId, conflictId, newOfficialId},
      ]);
      // The file is previewed again, so the list shows what is now stored.
      expect(gateway.previewed, hasLength(2));
      expect(imports.selected, isEmpty);
    });

    test('新官方點沒有有效生效日期時不送出', () async {
      await imports.load('spots.json', file);
      imports.setEffectiveDate('10/26');
      await imports.apply('');
      expect(gateway.imported, isEmpty);
    });

    test('大檔案分批試算與匯入，每批最多 500 筆', () async {
      final many = [
        for (var i = 0; i < 1201; i++)
          spot(
            'official:40000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            '停車場 $i',
            '請依現場公告',
          ),
      ];
      await imports.load('spots.json', jsonEncode(many));
      expect(gateway.previewed.map((p) => p.length), [500, 500, 201]);
      imports.setEffectiveDate('2026-10-26');
      await imports.apply('');
      expect(gateway.imported.map((c) => c.$1.length), [500, 500, 201]);
    });

    test('費率與收費資訊一起保留或覆寫', () async {
      await imports.load('spots.json', file);
      imports.setOverwrite(conflictId, 'fee_note', true);
      expect(imports.overwrite[conflictId], {'fee', 'fee_note'});
      imports.setOverwrite(conflictId, 'fee', false);
      expect(imports.overwrite[conflictId], isEmpty);
    });

    test('重設後不寫回舊的試算結果', () async {
      gateway.delayedPreview = Completer<void>();
      final loading = imports.load('spots.json', file);
      imports.reset();
      gateway.delayedPreview!.complete();
      await loading;
      expect(imports.entries, isEmpty);
      expect(imports.selected, isEmpty);
      expect(imports.loading, isFalse);
    });

    test('連線失敗時說明已匯入的部分不受影響', () async {
      await imports.load('spots.json', file);
      gateway.importError = StateError('offline');
      await imports.apply('');
      expect(imports.error, contains('連線失敗'));
    });
  });

  group('費率轉換控制', () {
    late FakeAdminGateway gateway;
    late FeeConversionController fees;
    var converted = 0;
    setUp(() {
      gateway = FakeAdminGateway(access: adminAal2)
        ..backlog = [
          for (final (i, note) in [
            '機車計次20元;機車月租300元;',
            '機車計次20元;機車月租300元;',
            '免費（大型重機另訂費率）',
            '請依現場公告',
            '大型重機依路段收費方式：計次每次 40 元',
          ].indexed)
            FeeBacklogItem(
              sourceId: 'official:50000000-0000-4000-8000-00000000000$i',
              official: true,
              name: '點位 $i',
              city: '臺北市',
              district: '中正區',
              spaceType: 'offStreet',
              feeNote: note,
            ),
        ];
      converted = 0;
      fees = FeeConversionController(gateway, onApplied: (_) => converted++);
    });
    tearDown(() => gateway.dispose());

    test('依寫法分組，分列可轉換、需人工確認、無法判斷', () async {
      await fees.load();
      expect(fees.spots(FeeVerdict.convertible), 2);
      expect(fees.spots(FeeVerdict.manual), 2);
      expect(fees.spots(FeeVerdict.unknown), 1);
      // Only certain readings start chosen.
      expect(fees.selectedSpots, 2);
    });

    test('同一寫法在不同格位判讀不同時分開列，不合併預設勾選', () async {
      gateway.backlog = [
        for (final (i, type) in ['heavyOnly', 'car'].indexed)
          FeeBacklogItem(
            sourceId: 'official:60000000-0000-4000-8000-00000000000$i',
            official: true,
            name: '點位 $i',
            city: '新北市',
            district: '板橋區',
            spaceType: type,
            feeNote: '每 4 小時 30 元',
          ),
      ];
      await fees.load();
      expect(fees.groups, hasLength(2));
      expect(fees.spots(FeeVerdict.convertible), 1);
      expect(fees.spots(FeeVerdict.manual), 1);
      expect(fees.selectedSpots, 1);
    });

    test('重設後不寫回舊的待轉換清單', () async {
      gateway.delayedBacklog = Completer<void>();
      final loading = fees.load();
      fees.reset();
      gateway.delayedBacklog!.complete();
      expect(await loading, isFalse);
      expect(fees.groups, isEmpty);
      expect(fees.loaded, isFalse);
      expect(fees.selected, isEmpty);
    });

    test('寫入失敗時重新讀取清單仍保留錯誤', () async {
      await fees.load();
      gateway.convertError = StateError('offline');
      await fees.convert('');
      expect(converted, 0);
      expect(fees.error, contains('連線失敗'));
      expect(fees.loaded, isTrue);
    });

    test('只寫入確認的費率，並帶讀取時的收費資訊', () async {
      await fees.load();
      fees.show(FeeVerdict.manual);
      final suggestion = fees.visible.firstWhere((g) => g.reading.fee != null);
      final none = fees.visible.firstWhere((g) => g.reading.fee == null);
      fees.toggle(suggestion, true);
      fees.toggle(none, true);
      expect(fees.selectedSpots, 3);
      await fees.convert('確認');
      expect(converted, 1);
      final (items, note) = gateway.conversions.single;
      expect(note, '確認');
      expect(items, hasLength(3));
      expect(items.first, {
        'source_id': 'official:50000000-0000-4000-8000-000000000000',
        'fee_note': '機車計次20元;機車月租300元;',
        'space_type': 'offStreet',
        'fee': {
          'scooter': {'mode': 'per_visit', 'amount': 20},
        },
      });
      expect(fees.result!.updated, 3);
      // Read again: what was written is gone from the backlog.
      expect(fees.spots(FeeVerdict.convertible), 0);
    });
  });

  group('匯入頁面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;
    setUp(() {
      gateway = FakeAdminGateway(access: adminAal2)
        ..importPlan = plan()
        ..backlog = [
          const FeeBacklogItem(
            sourceId: 'official:50000000-0000-4000-8000-000000000001',
            official: true,
            name: '公園路地下停車場',
            city: '臺北市',
            district: '中正區',
            spaceType: 'offStreet',
            feeNote: '機車計次20元;機車月租300元;身障機車月租150元;',
          ),
          const FeeBacklogItem(
            sourceId: '50000000-0000-4000-8000-000000000002',
            official: false,
            name: '新北市路邊機車格',
            city: '新北市',
            district: '板橋區',
            spaceType: 'paidMotorcycle',
            feeNote: '每 4 小時 30 元',
          ),
        ];
    });
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(
      WidgetTester tester, {
      String path = '/imports',
      Size size = const Size(1280, 900),
      double textScale = 1,
      ThemeMode theme = ThemeMode.light,
    }) async {
      controller = AdminController(gateway);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await controller.refresh();
      await tester.pumpWidget(
        AdminApp(
          controller: controller,
          initialLocation: path,
          themeMode: theme,
          reviewMapBuilder: (_, _) => const SizedBox(),
          pickFile: () async => (name: 'spots.json', text: file),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The page's list builds lazily: scroll an item into view first.
    Future<void> reveal(WidgetTester tester, Finder finder) async {
      final list = find.descendant(
        of: find.byType(ImportPage),
        matching: find.byType(Scrollable),
      );
      for (final delta in [-300.0, 150.0]) {
        if (finder.evaluate().isNotEmpty) break;
        try {
          await tester.scrollUntilVisible(
            finder,
            delta,
            scrollable: list.first,
            maxScrolls: 40,
          );
        } on StateError {
          // Not in this direction.
        }
      }
      expect(finder, findsOneWidget);
    }

    Future<void> tapVisible(WidgetTester tester, Finder finder) async {
      await reveal(tester, finder);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(finder.hitTestable(), findsOneWidget);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    for (final (size, scale, theme) in const [
      (Size(320, 640), 1.0, ThemeMode.light),
      (Size(390, 844), 1.0, ThemeMode.dark),
      (Size(320, 640), 1.6, ThemeMode.dark),
      (Size(700, 900), 1.0, ThemeMode.light),
      (Size(1280, 900), 1.0, ThemeMode.light),
    ]) {
      final label = '${size.width.round()} px、字級 $scale';
      testWidgets('$label：選檔、保留或覆寫管理員修改、匯入', (tester) async {
        await show(tester, size: size, textScale: scale, theme: theme);
        expect(find.text('匯入停車資料'), findsOneWidget);
        await tapVisible(tester, find.text('選擇 spots.json'));
        await reveal(tester, find.textContaining('spots.json：4 筆'));
        // A conflict opens with the administrator's value kept.
        await reveal(tester, find.text('保留管理員修改'));
        await reveal(tester, find.textContaining('管理員2026/10/24'));
        await reveal(tester, find.textContaining('地圖上已隱藏'));
        await tapVisible(tester, find.text('保留管理員修改'));
        await reveal(tester, find.text('以匯入值覆寫'));
        await tapVisible(tester, find.text('匯入勾選的 4 筆'));
        final (_, choices, _, _) = gateway.imported.single;
        expect(choices[conflictId]['overwrite'], ['name']);
        await reveal(tester, find.textContaining('已匯入：新增 2 筆、更新 2 筆'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('$label：費率轉換分列並寫入勾選的費率', (tester) async {
        await show(
          tester,
          path: '/imports/fees',
          size: size,
          textScale: scale,
          theme: theme,
        );
        await tapVisible(tester, find.text('讀取尚未轉換的點位'));
        await reveal(tester, find.text('可轉換 1 筆'));
        await reveal(tester, find.text('機車每次 20 元（隔日是否另計未確認）；大型重機費率未確認'));
        await tapVisible(tester, find.text('需人工確認 1 筆'));
        await reveal(tester, find.text('機車每 4 小時 30 元；大型重機費率未確認'));
        await tapVisible(tester, find.text('可轉換 1 筆'));
        await tapVisible(tester, find.text('寫入 1 筆費率'));
        expect(
          gateway.conversions.single.$1.single['source_id'],
          endsWith('01'),
        );
        await reveal(tester, find.textContaining('已寫入 1 筆費率'));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('區段切換保留在網址中', (tester) async {
      await show(tester);
      await tapVisible(tester, find.text('費率轉換'));
      expect(find.text('讀取尚未轉換的點位'), findsOneWidget);
      await tapVisible(tester, find.text('匯入檔案'));
      expect(find.text('選擇 spots.json'), findsOneWidget);
    });
  });
}
