import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/users/user_models.dart';
import 'package:motorcycle_parking/admin/users/users_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_admin_gateway.dart';

void main() {
  group('使用者資料', () {
    late FakeAdminGateway gateway;
    late UsersController users;

    setUp(() {
      gateway = FakeAdminGateway(access: adminAal2);
      users = UsersController(gateway);
    });
    tearDown(() async {
      users.dispose();
      await gateway.dispose();
    });

    test('搜尋時去掉前後空白，解析遮蔽後的 email 與統計', () async {
      users.query = '  小哲 ';
      await users.search();
      expect(gateway.userQueries.single, '小哲');
      final user = users.results.single;
      expect(user.email, 'ri***@example.test');
      expect(user.reports30d, 12);
      expect(user.banned, isFalse);
      await users.open(riderId);
      final detail = users.detail!;
      expect(detail.limits.today, 3);
      expect(detail.limits.sharedAccounts30d, 1);
      expect(detail.reports['flags_rejected'], 3);
      expect(detail.spots.first.contributorName, '夜騎小哲');
    });

    test('停權後更新詳情、清單與停權紀錄', () async {
      await users.search();
      await users.open(riderId);
      expect(await users.setBan(BanLength.month, '洗版回報'), isTrue);
      expect(gateway.bans.single, (riderId, BanLength.month, '洗版回報'));
      expect(users.detail!.user.banned, isTrue);
      expect(users.results.single.banned, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(users.detail!.history.single.label, '停權');
      expect(await users.setBan(null, '申訴成立'), isTrue);
      expect(users.detail!.user.banned, isFalse);
    });

    test('Edge Function 拒絕時說明原因，不改畫面狀態', () async {
      await users.open(riderId);
      gateway.banError = const FunctionException(
        status: 403,
        details: {'error': 'administrators cannot be banned here'},
      );
      expect(await users.setBan(BanLength.week, '測試'), isFalse);
      expect(users.writeError, '管理者帳號不能在這裡停權。');
      gateway.banError = const FunctionException(
        status: 403,
        details: {'error': 'admin with a second factor required'},
      );
      expect(await users.setBan(BanLength.week, '測試'), isFalse);
      expect(users.writeError, contains('兩步驟驗證'));
      gateway.banError = const FunctionException(
        status: 500,
        details: {'error': 'audit failed; the change was undone'},
      );
      expect(await users.setBan(BanLength.week, '測試'), isFalse);
      expect(users.writeError, contains('已還原'));
      expect(users.detail!.user.banned, isFalse);
    });

    test('清除公開名稱只改那一個點', () async {
      await users.open(riderId);
      expect(await users.clearName(communityId, '冒犯字眼'), isTrue);
      expect(gateway.clearedNames.single, (communityId, '冒犯字眼'));
      final spot = users.detail!.spots.first;
      expect((spot.nameCleared, spot.contributorName), (true, ''));
    });

    test('失去權限後清除所有使用者資料', () async {
      await users.search();
      await users.open(riderId);
      users.reset();
      expect(users.results, isEmpty);
      expect(users.detail, isNull);
      expect(users.searched, isFalse);
    });

    test('找不到帳號時提示', () async {
      await users.open('55555555-5555-4555-8555-555555555555');
      expect(users.openError, contains('找不到這個帳號'));
    });
  });

  group('使用者畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    setUp(() => gateway = FakeAdminGateway(access: adminAal2));
    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(
      WidgetTester tester, {
      String path = '/users',
      Size size = const Size(1280, 900),
      ThemeMode mode = ThemeMode.light,
      double textScale = 1,
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
          themeMode: mode,
          reviewMapBuilder: (_, _) => const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder detail() => find
        .descendant(
          of: find.byKey(const ValueKey('user-detail-$riderId')),
          matching: find.byType(Scrollable),
        )
        .first;

    testWidgets('從清單開啟帳號，停權需填原因並可選期間', (tester) async {
      await show(tester);
      expect(find.text('使用者管理'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('user-$riderId')));
      await tester.pumpAndSettle();
      expect(find.text('可以回報'), findsOneWidget);
      expect(find.textContaining('今天 3／10 次'), findsOneWidget);
      expect(find.textContaining('另有 1 個帳號'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ban')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-ban')));
      await tester.pumpAndSettle();
      expect(find.text('請填寫原因，之後查紀錄才知道為什麼。'), findsOneWidget);
      expect(gateway.bans, isEmpty);
      await tester.tap(find.byKey(const ValueKey('ban-length-30d')));
      await tester.enterText(find.byKey(const ValueKey('ban-reason')), '洗版回報');
      await tester.tap(find.byKey(const ValueKey('confirm-ban')));
      await tester.pumpAndSettle();
      expect(gateway.bans.single, (riderId, BanLength.month, '洗版回報'));
      expect(find.text('已停權：夜騎小哲'), findsOneWidget);
      expect(find.byKey(const ValueKey('lift-ban')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('原因：洗版回報'),
        300,
        scrollable: detail(),
      );
      expect(find.text('原因：洗版回報'), findsOneWidget);
    });

    testWidgets('取消停權對話框不寫入', (tester) async {
      await show(tester, path: '/users/$riderId');
      await tester.tap(find.byKey(const ValueKey('ban')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.bans, isEmpty);
      expect(find.text('可以回報'), findsOneWidget);
    });

    testWidgets('清除點位上的公開名稱', (tester) async {
      await show(tester, path: '/users/$riderId');
      final clear = find.byKey(const ValueKey('clear-name-$communityId'));
      await tester.scrollUntilVisible(clear, 300, scrollable: detail());
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('清除這個公開名稱？'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('clear-name-note')),
        '冒犯字眼',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-clear-name')));
      await tester.pumpAndSettle();
      expect(gateway.clearedNames.single, (communityId, '冒犯字眼'));
      expect(clear, findsNothing);
      expect(find.text('公開名稱已清除'), findsNWidgets(2));
    });

    testWidgets('管理者帳號不提供停權', (tester) async {
      gateway.userDetails[riderId] = {
        ...sampleUserDetail(),
        'user': sampleUserRow(admin: true),
      };
      await show(tester, path: '/users/$riderId');
      expect(find.text('管理者帳號'), findsOneWidget);
      expect(find.byKey(const ValueKey('ban')), findsNothing);
    });

    testWidgets('手機版先列表，點選後進詳情並可返回', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(find.text('可以回報'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('user-$riderId')));
      await tester.pumpAndSettle();
      expect(find.text('可以回報'), findsOneWidget);
      await tester.tap(find.text('返回使用者清單'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('user-$riderId')), findsOneWidget);
    });

    testWidgets('搜尋失敗時提示重試', (tester) async {
      gateway.failUsers = true;
      await show(tester);
      expect(find.text('使用者搜尋失敗，請檢查連線後重試。'), findsOneWidget);
    });

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(700, 900),
      Size(1280, 900),
    ]) {
      testWidgets('帳號詳情在 ${size.width.round()} px 不溢出、主要動作可點', (tester) async {
        await show(tester, path: '/users/$riderId', size: size);
        final ban = find.byKey(const ValueKey('ban'));
        await tester.scrollUntilVisible(ban, 200, scrollable: detail());
        await tester.ensureVisible(ban);
        await tester.pumpAndSettle();
        expect(ban.hitTestable(), findsOneWidget);
        expect(tester.getSize(ban).height, greaterThanOrEqualTo(48));
        final clear = find.byKey(const ValueKey('clear-name-$communityId'));
        await tester.scrollUntilVisible(clear, 300, scrollable: detail());
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        expect(clear.hitTestable(), findsOneWidget);
        expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('320 px 深色、1.6 倍字級的停權對話框可用', (tester) async {
      await show(
        tester,
        path: '/users/$riderId',
        size: const Size(320, 640),
        mode: ThemeMode.dark,
        textScale: 1.6,
      );
      expect(tester.takeException(), isNull);
      final ban = find.byKey(const ValueKey('ban'));
      await tester.scrollUntilVisible(ban, 200, scrollable: detail());
      await tester.ensureVisible(ban);
      await tester.pumpAndSettle();
      await tester.tap(ban);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byKey(const ValueKey('ban-reason')), '洗版');
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('confirm-ban'));
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(confirm.hitTestable(), findsOneWidget);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(gateway.bans.single.$1, riderId);
      expect(tester.takeException(), isNull);
    });
  });
}
