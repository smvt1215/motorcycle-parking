import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_admin_gateway.dart';

void main() {
  late FakeAdminGateway gateway;
  late AdminController controller;

  setUp(() {
    gateway = FakeAdminGateway();
    controller = AdminController(gateway);
  });
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
    // Subscribe inside the widget test's clock zone so auth events are pumpable.
    controller.dispose();
    controller = AdminController(gateway);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await controller.refresh();
    await tester.pumpWidget(
      AdminApp(controller: controller, initialLocation: path, themeMode: mode),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未登入直接進入管理網址仍只顯示登入', (tester) async {
    await show(tester, path: '/users');
    expect(find.text('登入管理介面'), findsOneWidget);
    expect(find.text('使用 Google 帳號登入'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav/users')), findsNothing);
    expect(gateway.countRequests, 0);
  });

  testWidgets('非管理者顯示原因，能登出切換帳號', (tester) async {
    gateway.access = const AdminAccess(
      userId: 'rider',
      email: 'rider@example.test',
      aal2: true,
    );
    await show(tester);
    expect(find.text('這個帳號沒有管理權限'), findsOneWidget);
    expect(gateway.factorRequests, 0);
    expect(gateway.countRequests, 0);
    await tester.tap(find.text('登出並切換帳號'));
    await tester.pumpAndSettle();
    expect(find.text('登入管理介面'), findsOneWidget);
  });

  testWidgets('缺 aal2 導向驗證，選擇備援方式成功後才顯示待審數', (tester) async {
    gateway.access = adminAal1;
    await show(tester);
    expect(find.text('請先完成第二步驗證'), findsOneWidget);
    expect(gateway.countRequests, 0);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('備援驗證器').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '123456');
    await tester.tap(find.text('確認驗證碼'));
    await tester.pumpAndSettle();
    expect(gateway.verifiedWith.single, startsWith('備援驗證器/'));
    expect(find.text('待審回報'), findsOneWidget);
    expect(find.text('有 7 筆回報等待確認'), findsOneWidget);
    expect(
      gateway.factorRequests,
      2,
    ); // No recursive listFactors/token-refresh loop.
  });

  testWidgets('錯誤驗證碼保留驗證畫面，重試成功', (tester) async {
    gateway.access = adminAal1;
    gateway.failVerify = true;
    await show(tester);
    await tester.enterText(find.byType(TextFormField).last, '000000');
    await tester.tap(find.text('確認驗證碼'));
    await tester.pumpAndSettle();
    expect(find.text('驗證碼不正確或已過期，請輸入最新的驗證碼後重試。'), findsOneWidget);
    expect(gateway.countRequests, 0);
    gateway.failVerify = false;
    await tester.enterText(find.byType(TextFormField).last, '123456');
    await tester.tap(find.text('確認驗證碼'));
    await tester.pumpAndSettle();
    expect(find.text('待審回報'), findsOneWidget);
  });

  testWidgets('admin 五個分頁可切換，未知待審數不顯示為零', (tester) async {
    gateway.access = adminAal2;
    gateway.failCount = true;
    await show(tester);
    expect(find.text('待審數載入失敗，請重試。'), findsOneWidget);
    expect(find.text('目前沒有待審回報'), findsNothing);
    gateway.failCount = false;
    await tester.tap(find.text('更新待審數'));
    await tester.pumpAndSettle();
    expect(find.text('7'), findsOneWidget);
    for (final entry in {
      '/spots': '停車點位',
      '/rules': '各縣市停車規則',
      '/imports': '匯入停車資料',
      '/users': '使用者管理',
      '/review': '待審回報',
    }.entries) {
      await tester.tap(find.byKey(ValueKey('nav${entry.key}')));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets('手機深色版面與鍵盤焦點可用', (tester) async {
    gateway.access = adminAal2;
    await show(tester, size: const Size(320, 740), mode: ThemeMode.dark);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    for (final path in ['/spots', '/rules', '/imports', '/users']) {
      await tester.tap(find.byKey(ValueKey('nav$path')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('首次登記顯示 QR code 與備援提醒，取消會撤銷未驗證因子', (tester) async {
    gateway.access = adminAal1;
    gateway.factors = [];
    await show(tester);
    expect(find.textContaining('請至少登記兩個驗證器 App'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '手機');
    await tester.tap(find.text('開始登記'));
    await tester.pumpAndSettle();
    expect(controller.enrollment, isNotNull);
    expect(find.text('設定密鑰'), findsOneWidget);
    final cancel = find.text('取消這次登記');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(gateway.cancelled, ['new-factor']);
    expect(controller.enrollment, isNull);
    expect(find.text('開始登記'), findsOneWidget);
  });

  testWidgets('簡訊驗證需先傳送，切換方式不沿用 challenge', (tester) async {
    gateway.access = adminAal1;
    gateway.factors = [factor('手機簡訊', type: FactorType.phone), factor('備援驗證器')];
    await show(tester);
    await tester.enterText(find.byType(TextFormField).last, '123456');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '確認驗證碼'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('傳送簡訊驗證碼'));
    await tester.pumpAndSettle();
    expect(find.text('驗證碼已傳送，請查看手機簡訊。'), findsOneWidget);
    final challenge = controller.challenge!.id;
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('備援驗證器').last);
    await tester.pumpAndSettle();
    expect(controller.challenge, isNull);
    await tester.enterText(find.byType(TextFormField).last, '654321');
    await tester.tap(find.text('確認驗證碼'));
    await tester.pumpAndSettle();
    expect(gateway.verifiedWith.single, isNot(contains(challenge)));
  });

  testWidgets('失去 aal2 即刻離開工作區', (tester) async {
    gateway.access = adminAal2;
    await show(tester);
    gateway.emit(adminAal1);
    await tester.pumpAndSettle();
    expect(controller.refreshing, isFalse);
    expect(gateway.factorRequests, 2);
    expect(find.text('請先完成第二步驗證'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav/review')), findsNothing);
    expect(controller.pendingCount, isNull);
  });

  test('登出後較晚返回的待審數不能恢復管理資料', () async {
    gateway.access = adminAal2;
    gateway.delayedCount = Completer<int>();
    final refresh = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.countRequests, 1);
    await controller.signOut();
    gateway.delayedCount!.complete(99);
    await refresh;
    expect(controller.stage, AdminStage.signedOut);
    expect(controller.pendingCount, isNull);
    expect(controller.factors, isEmpty);
  });

  test('讀取驗證方式失敗會封鎖工作區，重試可恢復', () async {
    gateway.access = adminAal2;
    gateway.failFactors = true;
    await controller.refresh();
    expect(controller.stage, AdminStage.unavailable);
    expect(gateway.countRequests, 0);
    gateway.failFactors = false;
    await controller.refresh();
    expect(controller.stage, AdminStage.ready);
    expect(controller.pendingCount, 7);
  });

  testWidgets('重新整理後能取消未完成登記，再以相同名稱登記', (tester) async {
    gateway.access = adminAal1;
    gateway.factors = [factor('手機', status: FactorStatus.unverified)];
    await show(tester);
    expect(find.text('未完成的登記'), findsOneWidget);
    final name = find.byType(TextFormField).first;
    await tester.ensureVisible(name);
    await tester.enterText(name, '手機');
    await tester.ensureVisible(find.text('開始登記'));
    await tester.tap(find.text('開始登記'));
    await tester.pumpAndSettle();
    expect(controller.enrollment, isNull);
    expect(controller.error, isNotNull);
    final cancel = find.byKey(const ValueKey('discard/手機'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(gateway.cancelled, ['手機']);
    expect(find.text('未完成的登記'), findsNothing);
    await tester.ensureVisible(find.text('開始登記'));
    await tester.tap(find.text('開始登記'));
    await tester.pumpAndSettle();
    expect(controller.enrollment, isNotNull);
  });

  test('取消前重新確認狀態，不移除已在另一分頁驗證完成的方式', () async {
    gateway.access = adminAal1;
    gateway.factors = [factor('手機', status: FactorStatus.unverified)];
    await controller.refresh();
    gateway.factors = [factor('手機')];
    await controller.discardUnfinished('手機');
    expect(gateway.cancelled, isEmpty);
    expect(controller.verifiedFactors.single.id, '手機');
    expect(controller.unfinishedFactors, isEmpty);
    expect(controller.error, contains('已完成或已移除'));
  });

  testWidgets('未設定後端不提供管理示範模式', (tester) async {
    final unconfigured = AdminController(null);
    addTearDown(unconfigured.dispose);
    await unconfigured.refresh();
    await tester.pumpWidget(AdminApp(controller: unconfigured));
    await tester.pumpAndSettle();
    expect(find.text('登入管理介面'), findsOneWidget);
    expect(find.textContaining('尚未連接登入服務'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
