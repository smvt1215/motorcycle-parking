import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/review/review_page.dart';
import 'package:motorcycle_parking/admin/rules/rules_page.dart';
import 'package:motorcycle_parking/admin/users/users_page.dart';

import 'fake_admin_gateway.dart';
import 'spots_test.dart' show FakeSpotMap;

/// The admin shell at the C6 canvas sizes (#118, 決定 48、49).
void main() {
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
    Size size = const Size(402, 874),
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
        spotMapBuilder: (_, view) => FakeSpotMap(view: view),
        locationMapBuilder: (_, _) => const SizedBox(key: ValueKey('mini-map')),
        bundledRules: () async => [
          for (final r in sampleRules())
            {'city': r['city'], 'vehicle': r['vehicle'], 'version': 1},
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  String location(WidgetTester tester, Type page) =>
      GoRouter.of(tester.element(find.byType(page)))
          .routerDelegate
          .currentConfiguration
          .uri
          .toString();

  Finder spotForm() => find
      .descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('spot-form-'),
        ),
        matching: find.byType(Scrollable),
      )
      .first;

  void moreReports() => gateway.reports = [
    ...sampleReports(),
    for (var i = 0; i < 20; i++)
      ReviewReport(
        id: 'r-more-$i',
        sourceId: communityId,
        reason: '位置或其他備註：第 $i 筆',
        createdAt: reportTime.add(Duration(minutes: 10 + i)),
      ),
  ];

  group('手機（iPhone 16 Pro 402×874）', () {
    testWidgets('單列頂欄寫頁名，底部導覽五個分頁，審核顯示待審數', (tester) async {
      await show(tester);
      expect(tester.takeException(), isNull);
      // The page name is in the top bar only, not repeated over the queue.
      expect(find.text('待審回報'), findsOneWidget);
      expect(tester.getRect(find.text('待審回報')).top, lessThan(56));
      for (final path in [
        '/review',
        '/spots',
        '/rules',
        '/imports',
        '/users',
      ]) {
        final tab = find.byKey(ValueKey('nav$path'));
        expect(tab, findsOneWidget);
        final rect = tester.getRect(tab);
        expect(rect.top, greaterThanOrEqualTo(874 - 72 - 1));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav/review')),
          matching: find.text('7'),
        ),
        findsOneWidget,
      );
      for (final (path, title) in [
        ('/spots', '停車點位'),
        ('/rules', '各縣市停車規則'),
        ('/imports', '匯入停車資料'),
        ('/users', '使用者管理'),
      ]) {
        await tester.tap(find.byKey(ValueKey('nav$path')));
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('帳號選單可進帳號安全與登出', (tester) async {
      await show(tester);
      final menu = find.byKey(const ValueKey('account-menu'));
      expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('帳號安全'));
      await tester.pumpAndSettle();
      expect(location(tester, Scaffold), '/security');
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('登出'));
      await tester.pumpAndSettle();
      expect(find.text('登入管理介面'), findsOneWidget);
    });

    testWidgets('驗證器提示縮成一行，可收起，換頁後仍收起', (tester) async {
      gateway.factors = [factor('手機驗證器')];
      await show(tester);
      final notice = find.text('還要再登記一個驗證器 App');
      expect(notice, findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('enroll-authenticator'))),
        isA<Size>().having((s) => s.height, 'height', greaterThanOrEqualTo(48)),
      );
      await tester.tap(find.byTooltip('暫時收起提示'));
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      await tester.tap(find.byKey(const ValueKey('nav/spots')));
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
    });

    testWidgets('320 px 篩選換行不截斷，全部可點', (tester) async {
      await show(tester, size: const Size(320, 640));
      final labels = ['全部', for (final k in ReviewKind.values) k.label];
      for (final label in labels) {
        final chip = find.textContaining(RegExp('^$label \\d+\$'));
        expect(chip, findsOneWidget, reason: label);
        expect(tester.getRect(chip).right, lessThanOrEqualTo(320));
        expect(chip.hitTestable(), findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('駁回原因開在最上層，蓋過底部導覽（R1）', (tester) async {
      await show(tester, path: '/review/r-type');
      final back = find.textContaining('返回佇列');
      expect(tester.getSize(back.first).height, greaterThan(0));
      expect(
        tester
            .getSize(find.ancestor(of: back, matching: find.byType(TextButton)))
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, '駁回'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(tester.getRect(sheet).bottom, 874);
      // Every reason is reachable above the fold of a tall phone.
      for (final k in ResolutionKind.values) {
        expect(find.byKey(ValueKey('reject-${k.name}')), findsOneWidget);
      }
    });
  });

  group('iPad Air 820×1180', () {
    testWidgets('頂欄單列分頁，沒有底部導覽；左欄標題一行、按鈕改圖示', (tester) async {
      await show(tester, size: const Size(820, 1180));
      final review = find.byKey(const ValueKey('nav/review'));
      expect(review, findsOneWidget);
      expect(tester.getRect(review).bottom, lessThanOrEqualTo(64));
      expect(tester.getRect(find.byKey(const ValueKey('nav/users'))).top, 0);
      // The pending count is a small pill, not the bar's full height.
      final badge = find.ancestor(
        of: find.descendant(of: review, matching: find.text('7')),
        matching: find.byType(Container),
      );
      expect(tester.getSize(badge.first).height, lessThanOrEqualTo(24));
      final title = find.text('待審回報');
      expect(tester.getSize(title).height, lessThan(40));
      expect(find.byTooltip('已隱藏的點位'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav/spots')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.text('停車點位')).height, lessThan(40));
      expect(find.byTooltip('新增停車點'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('點左欄只換右欄：佇列不重建，捲動、篩選、選取保留，網址同步（決定 48）', (tester) async {
      moreReports();
      await show(tester, size: const Size(820, 1180));
      final page = tester.state(find.byType(ReviewPage));
      final queue = find.descendant(
        of: find.byKey(const PageStorageKey('review-queue')),
        matching: find.byType(Scrollable),
      );
      final scroll = tester.state<ScrollableState>(queue);
      await tester.drag(queue, const Offset(0, -400));
      await tester.pumpAndSettle();
      final offset = scroll.position.pixels;
      expect(offset, greaterThan(0));
      final item = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('report-r-more'),
          )
          .hitTestable()
          .first;
      final id = (tester.widget(item).key! as ValueKey<String>).value
          .replaceFirst('report-', '');
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(location(tester, ReviewPage), '/review/$id');
      expect(identical(tester.state(find.byType(ReviewPage)), page), isTrue);
      expect(identical(tester.state<ScrollableState>(queue), scroll), isTrue);
      expect(scroll.position.pixels, offset);
      expect(find.textContaining('第 ${id.split('-').last} 筆'), findsWidgets);
    });

    testWidgets('使用者與規則雙欄點左欄也只換右欄（決定 48）', (tester) async {
      await show(tester, path: '/users', size: const Size(820, 1180));
      final users = tester.state(find.byType(UsersPage));
      await tester.tap(find.byKey(const ValueKey('user-$riderId')));
      await tester.pumpAndSettle();
      expect(location(tester, UsersPage), '/users/$riderId');
      expect(identical(tester.state(find.byType(UsersPage)), users), isTrue);

      await tester.tap(find.byKey(const ValueKey('nav/rules')));
      await tester.pumpAndSettle();
      final rules = tester.state(find.byType(RulesPage));
      final list = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('rule-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('rule-新北市-heavy')));
      await tester.pumpAndSettle();
      expect(Uri.decodeFull(location(tester, RulesPage)), '/rules/新北市/heavy');
      expect(identical(tester.state(find.byType(RulesPage)), rules), isTrue);
      expect(
        identical(
          tester.state<ScrollableState>(
            find.descendant(
              of: find.byKey(const ValueKey('rule-list')),
              matching: find.byType(Scrollable),
            ),
          ),
          list,
        ),
        isTrue,
      );
    });
  });

  group('矮螢幕（鍵盤開啟，可視高 < 500）', () {
    testWidgets('提示與底部導覽收起，審核操作列跟內容捲動', (tester) async {
      gateway.factors = [factor('手機驗證器')];
      await show(tester, path: '/review/r-type', size: const Size(402, 480));
      expect(find.text('還要再登記一個驗證器 App'), findsNothing);
      expect(find.byKey(const ValueKey('nav/review')), findsNothing);
      final apply = find.widgetWithText(FilledButton, '套用建議');
      await tester.scrollUntilVisible(
        apply,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.ancestor(of: apply, matching: find.byType(ListView)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      // The keyboard closes: the bar is pinned under the list again.
      tester.view.physicalSize = const Size(402, 874);
      await tester.pumpAndSettle();
      expect(
        find.ancestor(of: apply, matching: find.byType(ListView)),
        findsNothing,
      );
      expect(find.text('還要再登記一個驗證器 App'), findsOneWidget);
      expect(find.byKey(const ValueKey('nav/review')), findsOneWidget);
    });

    testWidgets('點位表單：小地圖收成「開地圖調整」，操作列跟內容捲動', (tester) async {
      await show(
        tester,
        path: '/spots/$communityId',
        size: const Size(402, 480),
      );
      final form = spotForm();
      await tester.scrollUntilVisible(
        find.text('開地圖調整'),
        200,
        scrollable: form,
      );
      expect(find.byKey(const ValueKey('mini-map')), findsNothing);
      final save = find.widgetWithText(FilledButton, '儲存並關閉');
      await tester.scrollUntilVisible(save, 300, scrollable: form);
      expect(
        find.ancestor(of: save, matching: find.byType(ListView)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(402, 874);
      await tester.pumpAndSettle();
      expect(find.text('開地圖調整'), findsNothing);
    });

    testWidgets('點位清單搜尋時鍵盤縮小視窗：搜尋、篩選與結果一起捲動，不溢出、不失焦', (tester) async {
      await show(tester, path: '/spots', size: const Size(390, 844));
      await tester.tap(find.text('清單'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('spot-search'));
      await tester.tap(search);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(390, 360);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.ancestor(of: find.byWidget(focused!.widget), matching: search),
        findsOneWidget,
      );
      final item = find.byKey(const ValueKey('spot-$officialId'));
      await tester.scrollUntilVisible(
        item,
        200,
        scrollable: find
            .ancestor(of: search, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      expect(item.hitTestable(), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('鍵盤縮小視窗時，聚焦的欄位捲到可見（G3、G4）', (tester) async {
      await show(
        tester,
        path: '/spots/$communityId',
        size: const Size(390, 844),
      );
      final note = find.byKey(const ValueKey('spot-note'));
      final form = spotForm();
      await tester.scrollUntilVisible(note, 300, scrollable: form);
      await tester.pumpAndSettle();
      await tester.tap(note);
      await tester.pumpAndSettle();
      expect(tester.getRect(note).bottom, greaterThan(508));
      tester.view.physicalSize = const Size(390, 508);
      await tester.pumpAndSettle();
      expect(tester.getRect(note).bottom, lessThanOrEqualTo(508));
      expect(tester.takeException(), isNull);
    });

    testWidgets('已捲離畫面的聚焦欄位不會在視窗變矮時被拉回', (tester) async {
      await show(
        tester,
        path: '/spots/$communityId',
        size: const Size(390, 844),
      );
      final note = find.byKey(const ValueKey('spot-note'));
      final form = spotForm();
      await tester.scrollUntilVisible(note, 300, scrollable: form);
      await tester.pumpAndSettle();
      await tester.tap(note);
      await tester.pumpAndSettle();
      // The admin scrolls back to the top, away from the focused field. By
      // the position: a drag could start on the form's map or check rows.
      final scroll = tester.state<ScrollableState>(form);
      scroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, 0);
      tester.view.physicalSize = const Size(390, 640);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, 0);
    });
  });

  group('寫入後畫面主動更新（決定 49）', () {
    testWidgets('審核套用後，點位清單與地圖標記重新讀取', (tester) async {
      await show(tester, path: '/spots', size: const Size(1280, 900));
      final searches = gateway.searchRequests;
      final maps = gateway.mapRequests.length;
      expect(maps, greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('nav/review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '套用建議'));
      await tester.pumpAndSettle();
      expect(find.text('6'), findsNothing);
      // Written after the undo window.
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$1, 'r-type');
      expect(gateway.searchRequests, greaterThan(searches));
      expect(gateway.mapRequests.length, greaterThan(maps));
      // The pending count follows too.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav/review')),
          matching: find.text('6'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('駁回不改點位，不重新讀取點位', (tester) async {
      await show(tester, path: '/spots', size: const Size(1280, 900));
      final searches = gateway.searchRequests;
      await tester.tap(find.byKey(const ValueKey('nav/review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-r-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '駁回'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reject-duplicate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reject-confirm')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(gateway.resolved.single.$2, 'rejected');
      expect(gateway.searchRequests, searches);
    });

    testWidgets('點位儲存後，審核佇列重新讀取目前值', (tester) async {
      await show(tester, size: const Size(1280, 900));
      final loads = gateway.reportRequests;
      await tester.tap(find.byKey(const ValueKey('nav/spots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spot-$communityId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '名稱'),
        '中山北路機車格',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('儲存並關閉'));
      await tester.pumpAndSettle();
      expect(gateway.spotUpdates, hasLength(1));
      expect(gateway.reportRequests, greaterThan(loads));
    });
  });
}
