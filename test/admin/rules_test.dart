import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/rules/rule_models.dart';
import 'package:motorcycle_parking/admin/rules/rules_controller.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart'
    show taiwanCities;
import 'package:motorcycle_parking/models/parking.dart';

import 'fake_admin_gateway.dart';

List<Map<String, dynamic>> bundledFile() => (jsonDecode(
  File('assets/rules/parking_rules.json').readAsStringSync(),
) as List<dynamic>).cast<Map<String, dynamic>>();

/// The bundled rules as the database returns them, every column present.
Map<String, dynamic> asRow(Map<String, dynamic> r) => {
  'district_space_types': <String, dynamic>{},
  'restriction': null,
  ...r,
};

void main() {
  group('規則資料', () {
    test('縣市清單與 App 回報用的 22 縣市一致', () {
      expect(ruleCities, ['全國', ...taiwanCities]);
    });

    test('每條內建規則讀入表單再輸出，內容不變', () {
      for (final r in bundledFile()) {
        final vehicle = VehicleType.values.byName(r['vehicle'] as String);
        final draft = RuleDraft.fromRow(r['city'] as String, vehicle, asRow(r));
        final values = draft.toValues();
        for (final key in values.keys) {
          expect(
            jsonEncode(values[key]),
            jsonEncode(asRow(r)[key]),
            reason: '${r['city']} ${r['vehicle']} $key',
          );
        }
        expect(draft.errors(), isEmpty, reason: '${r['city']}');
      }
    });

    test('重機可停的機車格依縣市規則，不預設只限收費格', () {
      final r = bundledFile().firstWhere(
        (r) => r['city'] == '桃園市' && r['vehicle'] == 'heavy',
      );
      final draft = RuleDraft.fromRow('桃園市', VehicleType.heavy, asRow(r));
      expect(draft.access[SpaceType.freeMotorcycle], StreetAccess.open);
      expect(draft.access[SpaceType.paidMotorcycle], StreetAccess.open);
      final fresh = RuleDraft.fromRow('基隆市', VehicleType.heavy, null);
      expect(fresh.access.values.toSet(), {StreetAccess.closed});
    });

    test('只開放部分行政區的格位寫入 district_space_types，不列入可停', () {
      final r = bundledFile().firstWhere(
        (r) => r['city'] == '新北市' && r['vehicle'] == 'heavy',
      );
      final draft = RuleDraft.fromRow('新北市', VehicleType.heavy, asRow(r));
      expect(draft.access[SpaceType.freeMotorcycle], StreetAccess.open);
      expect(draft.typeDistricts[SpaceType.freeMotorcycle], ['板橋區', '新店區']);
      draft.typeDistricts[SpaceType.paidMotorcycle] = ['板橋區'];
      final v = draft.toValues();
      expect(v['allowed_space_types'], ['heavyOnly', 'car']);
      expect((v['district_space_types'] as Map).keys, {
        'freeMotorcycle',
        'paidMotorcycle',
      });
    });

    test('普通機車汽車格限定行政區時，預覽在區內可停、區外不可停', () {
      final r = bundledFile().firstWhere(
        (r) => r['city'] == '臺北市' && r['vehicle'] == 'scooter',
      );
      final draft = RuleDraft.fromRow('臺北市', VehicleType.scooter, asRow(r));
      draft.access[SpaceType.car] = StreetAccess.open;
      draft.typeDistricts[SpaceType.car] = ['中山區'];
      EligibilityStatus at(String district) => preview(
        draft,
        DateTime(2026, 12, 1),
        district,
      ).firstWhere((row) => row.type == SpaceType.car).result.status;
      expect(at('中山區'), EligibilityStatus.allowed);
      expect(at(otherDistrict), EligibilityStatus.notAllowed);
    });

    test('有條件未選限制類型時擋下；沒有有條件格位時不送限制類型', () {
      final draft = RuleDraft.fromRow(
        '臺北市',
        VehicleType.heavy,
        asRow(sampleRules().first),
      );
      draft.access[SpaceType.freeMotorcycle] = StreetAccess.conditional;
      expect(draft.errors()['restriction'], '有條件開放的格位需要選限制類型');
      draft.restriction = 'signage';
      expect(draft.errors(), isEmpty);
      expect(draft.toValues()['conditional_space_types'], [
        'offStreet',
        'freeMotorcycle',
      ]);
      draft.access[SpaceType.freeMotorcycle] = StreetAccess.closed;
      expect(draft.toValues()['restriction'], isNull);
    });

    test('新規則沿用內建規則的路外停車場設定，欄位依資料庫限制驗證', () {
      final draft = RuleDraft.fromRow('基隆市', VehicleType.scooter, null);
      expect(draft.isNew, isTrue);
      expect(draft.nextVersion, 1);
      expect(
        streetTypes(VehicleType.scooter),
        isNot(contains(SpaceType.heavyOnly)),
      );
      expect(draft.toValues()['conditional_space_types'], ['offStreet']);
      expect(draft.errors().keys, {
        'fee_note',
        'exceptions',
        'source_url',
        'effective_date',
      });
      draft.effectiveDate = '2026-02-30';
      expect(draft.errors().containsKey('effective_date'), isTrue);
      draft.sourceUrl = 'http://example.test';
      expect(draft.errors().containsKey('source_url'), isTrue);
    });

    test('預覽以共用 eligibility() 反映生效日與行政區', () {
      final r = bundledFile().firstWhere(
        (r) => r['city'] == '新北市' && r['vehicle'] == 'heavy',
      );
      final draft = RuleDraft.fromRow('新北市', VehicleType.heavy, asRow(r));
      final today = DateTime(2026, 10, 25);
      EligibilityStatus at(SpaceType t, DateTime d, String district) => preview(
        draft,
        d,
        district,
      ).firstWhere((row) => row.type == t).result.status;
      expect(previewDistricts(draft), [
        '板橋區',
        '新店區',
        otherDistrict,
        unknownDistrict,
      ]);
      expect(
        at(SpaceType.freeMotorcycle, today, '板橋區'),
        EligibilityStatus.allowed,
      );
      expect(
        at(SpaceType.freeMotorcycle, today, otherDistrict),
        EligibilityStatus.notAllowed,
      );
      expect(
        at(SpaceType.freeMotorcycle, today, unknownDistrict),
        EligibilityStatus.unverified,
      );
      // Timed bays follow paid ones, then the posted hours.
      expect(
        at(SpaceType.timedMotorcycle, today, otherDistrict),
        EligibilityStatus.conditional,
      );
      draft.effectiveDate = '2026-12-01';
      expect(
        at(SpaceType.paidMotorcycle, today, otherDistrict),
        EligibilityStatus.unverified,
      );
      expect(
        at(SpaceType.paidMotorcycle, DateTime(2026, 12, 1), otherDistrict),
        EligibilityStatus.allowed,
      );
    });
  });

  group('規則發布', () {
    late FakeAdminGateway gateway;
    late RulesController rules;

    setUp(() async {
      gateway = FakeAdminGateway(access: adminAal2);
      rules = RulesController(
        gateway,
        bundled: () async => [
          {'city': '臺北市', 'vehicle': 'heavy', 'version': 1},
          {'city': '新北市', 'vehicle': 'heavy', 'version': 1},
        ],
      );
      await rules.load();
      await Future<void>.delayed(Duration.zero);
    });
    tearDown(() => gateway.dispose());

    test('清單列出 23 個地區兩種車種，標出與 App 內建版本不同的規則', () {
      expect(rules.summaries, hasLength(46));
      final ntpc = rules.summaries.firstWhere(
        (s) => s.city == '新北市' && s.vehicle == VehicleType.heavy,
      );
      expect((ntpc.version, ntpc.unsynced), (2, true));
      expect(rules.unsyncedCount, 1);
      expect(
        rules.summaries.firstWhere((s) => s.city == '基隆市').version,
        isNull,
      );
    });

    test('發布帶開啟時的版本，伺服器遞增；復原以新版本恢復原內容', () async {
      rules.select('臺北市', VehicleType.heavy);
      expect(rules.dirty, isFalse);
      rules.update((d) => d.feeNote = '每次 50 元');
      expect(rules.dirty, isTrue);
      expect(rules.changed('fee_note'), isTrue);
      final previous = rules.base!.copy();
      final row = await rules.publish('依新公告');
      expect(row!['version'], 2);
      final (city, vehicle, values, base, note) = gateway.published.single;
      expect((city, vehicle, base, note), ('臺北市', 'heavy', 1, '依新公告'));
      expect(values['fee_note'], '每次 50 元');
      expect(rules.base!.version, 2);
      expect(rules.dirty, isFalse);
      final undone = await rules.undo(previous, 2);
      expect(undone!['version'], 3);
      expect(undone['fee_note'], '一般計次每次 40 元');
    });

    test('開啟後他人已發布：不覆蓋，保留修改並提示重新載入', () async {
      rules.select('臺北市', VehicleType.heavy);
      gateway.ruleRows['臺北市:heavy']!['version'] = 5;
      rules.update((d) => d.feeNote = '每次 50 元');
      expect(await rules.publish(''), isNull);
      expect(rules.stale, isTrue);
      expect(rules.publishError, contains('其他人發布新版本'));
      expect(rules.draft!.feeNote, '每次 50 元');
    });

    test('發布中不能重新載入，發布結果不會被丟掉', () async {
      rules.select('臺北市', VehicleType.heavy);
      rules.update((d) => d.feeNote = '每次 50 元');
      final publishing = rules.publish('');
      expect(rules.publishing, isTrue);
      await rules.load();
      final row = await publishing;
      expect(row!['version'], 2);
      expect(rules.publishing, isFalse);
      expect(rules.base!.version, 2);
    });

    test('發布進行中不接受修改，發布後的表單就是已發布的版本', () async {
      rules.select('臺北市', VehicleType.heavy);
      rules.update((d) => d.feeNote = '每次 50 元');
      final publishing = rules.publish('');
      rules.update((d) => d.feeNote = '發布中改的內容');
      expect(rules.draft!.feeNote, '每次 50 元');
      await publishing;
      expect(rules.draft!.feeNote, '每次 50 元');
      expect(rules.dirty, isFalse);
    });

    test('欄位有誤時不送出', () async {
      rules.select('基隆市', VehicleType.heavy);
      rules.update((d) => d.access[SpaceType.car] = StreetAccess.open);
      expect(await rules.publish(''), isNull);
      expect(rules.shownErrors, isNotEmpty);
      expect(gateway.published, isEmpty);
    });
  });

  group('規則畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    setUp(() => gateway = FakeAdminGateway(access: adminAal2));
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(
      WidgetTester tester, {
      String path = '/rules',
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
          bundledRules: () async => [
            for (final r in sampleRules())
              {'city': r['city'], 'vehicle': r['vehicle'], 'version': 1},
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder form() => find
        .descendant(
          of: find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('rule-form-'),
          ),
          matching: find.byType(Scrollable),
        )
        .first;

    testWidgets('改成有條件後必須選限制類型才能發布', (tester) async {
      await show(tester);
      expect(find.text('選擇一條規則'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rule-臺北市-heavy')));
      await tester.pumpAndSettle();
      expect(find.text('臺北市大型重機規則'), findsOneWidget);
      expect(find.text('發布第 2 版'), findsOneWidget);
      final free = find.descendant(
        of: find.byKey(const ValueKey('access-freeMotorcycle')),
        matching: find.text('有條件'),
      );
      await tester.tap(free);
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('publish-rule')));
      await tester.pumpAndSettle();
      expect(find.text('有條件開放的格位需要選限制類型'), findsOneWidget);
      expect(gateway.published, isEmpty);
      final signage = find.byKey(const ValueKey('restriction-signage'));
      await tester.scrollUntilVisible(signage, 300, scrollable: form());
      await tester.pumpAndSettle();
      await tester.tap(signage);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('publish-rule')));
      await tester.pumpAndSettle();
      expect(find.text('發布臺北市大型重機第 2 版？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '發布第 2 版').last);
      await tester.pumpAndSettle();
      expect(gateway.published.single.$3['restriction'], 'signage');
      expect(find.text('已發布臺北市大型重機第 2 版'), findsOneWidget);
      expect(find.text('發布第 3 版'), findsOneWidget);
    });

    testWidgets('預覽反映生效日', (tester) async {
      await show(tester, path: '/rules/臺北市/heavy');
      final date = find.widgetWithText(TextFormField, '生效日期');
      await tester.scrollUntilVisible(date, 300, scrollable: form());
      await tester.enterText(date, '2099-01-01');
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('preview-date'));
      await tester.scrollUntilVisible(toggle, 300, scrollable: form());
      expect(find.textContaining('此地區尚無已生效的停車規則資料'), findsWidgets);
      await tester.tap(find.text('生效後'));
      await tester.pumpAndSettle();
      expect(find.textContaining('此地區尚無已生效的停車規則資料'), findsNothing);
    });

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(700, 900),
      Size(1280, 900),
    ]) {
      testWidgets('規則表單在 ${size.width.round()} px 不溢出、按鈕可點', (tester) async {
        await show(tester, path: '/rules/新北市/heavy', size: size);
        expect(tester.takeException(), isNull);
        final segment = find.byKey(const ValueKey('access-car'));
        await tester.scrollUntilVisible(segment, 300, scrollable: form());
        await tester.pumpAndSettle();
        expect(tester.getSize(segment).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(segment).right, lessThanOrEqualTo(size.width));
        final chip = find.byKey(const ValueKey('preview-district-板橋區'));
        await tester.scrollUntilVisible(chip, 300, scrollable: form());
        await tester.pumpAndSettle();
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('publish-rule')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('手機深色、1.6 倍字級：先列表再表單，可返回', (tester) async {
      await show(
        tester,
        size: const Size(320, 640),
        textScale: 1.6,
        theme: ThemeMode.dark,
      );
      expect(find.text('選擇一條規則'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('rule-臺北市-heavy')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('rule-臺北市-heavy')));
      await tester.pumpAndSettle();
      expect(find.text('返回規則清單'), findsOneWidget);
      final segment = find.byKey(const ValueKey('access-heavyOnly'));
      await tester.scrollUntilVisible(segment, 300, scrollable: form());
      expect(tester.getRect(segment).right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('返回規則清單'),
        -300,
        scrollable: form(),
      );
      await tester.tap(find.text('返回規則清單'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rule-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有未發布的修改時，重新載入規則前先確認', (tester) async {
      await show(tester, path: '/rules/臺北市/heavy');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('access-car')),
          matching: find.text('不開放'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('重新載入規則'));
      await tester.pumpAndSettle();
      expect(find.text('放棄未發布的修改？'), findsOneWidget);
      await tester.tap(find.text('繼續編輯'));
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsWidgets);
      await tester.tap(find.byTooltip('重新載入規則'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放棄修改').last);
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsNothing);
    });

    testWidgets('有未發布的修改時，換規則前先確認', (tester) async {
      await show(tester, path: '/rules/臺北市/heavy');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('access-car')),
          matching: find.text('不開放'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rule-新北市-heavy')));
      await tester.pumpAndSettle();
      expect(find.text('放棄未發布的修改？'), findsOneWidget);
      await tester.tap(find.text('放棄修改').last);
      await tester.pumpAndSettle();
      expect(find.text('新北市大型重機規則'), findsOneWidget);
    });

    Future<void> editCar(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('access-car')),
          matching: find.text('不開放'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('有未發布的修改時，點上方「規則」分頁先確認，繼續編輯會保留草稿', (tester) async {
      await show(tester, path: '/rules/臺北市/heavy');
      await editCar(tester);
      await tester.tap(find.byKey(const ValueKey('nav/rules')));
      await tester.pumpAndSettle();
      expect(find.text('放棄未發布的修改？'), findsOneWidget);
      await tester.tap(find.text('繼續編輯'));
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsWidgets);
      expect(find.text('臺北市大型重機規則'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav/rules')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放棄修改').last);
      await tester.pumpAndSettle();
      expect(find.text('已修改'), findsNothing);
      expect(find.text('臺北市大型重機規則'), findsNothing);
    });

    testWidgets('有未發布的修改時切到其他分頁，返回「規則」分頁先確認', (tester) async {
      await show(tester, path: '/rules/臺北市/heavy');
      await editCar(tester);
      await tester.tap(find.byKey(const ValueKey('nav/users')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav/rules')));
      await tester.pumpAndSettle();
      expect(find.text('放棄未發布的修改？'), findsOneWidget);
      await tester.tap(find.text('繼續編輯'));
      await tester.pumpAndSettle();
      expect(find.text('臺北市大型重機規則'), findsOneWidget);
      expect(find.text('已修改'), findsWidgets);
    });
  });
}
