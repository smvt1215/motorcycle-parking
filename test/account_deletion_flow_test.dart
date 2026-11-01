import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/account_deletion.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/settings/account_deletion_page.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'account_deletion_fakes.dart';

class _Store extends AppStore {
  _Store(super.local, super.client);
  @override
  Future<void> loadFavorites() async {}
}

Future<_Store> _signedInStore({String Function()? deletionStatus}) async {
  SharedPreferences.setMockInitialValues({});
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/user')) {
        return http.Response(
          jsonEncode({
            'id': 'rider',
            'email': 'rider@gmail.com',
            'created_at': '2026-10-01T00:00:00Z',
            'app_metadata': {'provider': 'google'},
            'user_metadata': {'full_name': '阿哲'},
            'is_anonymous': false,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path.endsWith('/logout')) return http.Response('', 204);
      if (request.url.path.endsWith('/rpc/account_deletion_status')) {
        return http.Response(
          deletionStatus?.call() ?? '"none"',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: request,
        );
      }
      return http.Response('[]', 200);
    }),
  );
  final store = _Store(
    LocalRepository(await SharedPreferences.getInstance()),
    client,
  );
  await client.auth.getSessionFromUrl(
    Uri.parse(
      'tw.motopark://login-callback/'
      '#access_token=test-access&refresh_token=test-refresh'
      '&expires_in=3600&token_type=bearer',
    ),
  );
  return store;
}

const phone = Size(390, 844);
const sizes = [phone, Size(820, 1180), Size(1180, 820)];
const platforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});
final now = DateTime.now().toUtc();

class _App {
  _App(this.store, this.gateway, this.deletion);
  final _Store store;
  final FakeDeletionGateway gateway;
  final AccountDeletionController deletion;
  var cleared = false;
}

Future<_App> _mount(
  WidgetTester tester,
  FakeDeletionGateway gateway, {
  Size size = phone,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = (await tester.runAsync(_signedInStore))!;
  late _App app;
  final deletion = AccountDeletionController(
    gateway,
    clearLocalData: () async => app.cleared = true,
  );
  app = _App(store, gateway, deletion);
  gateway.onSignOut = () async {
    try {
      await store.client!.auth.signOut();
    } catch (_) {}
  };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  messenger.setMockMethodCallHandler(channel, (_) async => true);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(store.client!.dispose);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storeProvider.overrideWith((ref) => store),
        accountDeletionProvider.overrideWith((ref) => deletion),
      ],
      child: const ParkingApp(),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

BuildContext _appContext(WidgetTester tester) =>
    tester.element(find.byKey(const ValueKey('parking-search')));

Future<void> _openPage(WidgetTester tester, _App app) async {
  final context = tester.element(find.byType(Navigator).first);
  openAccountDeletion(context, store: app.store, deletion: app.deletion);
  await tester.pumpAndSettle();
}

Future<void> _tapSubmit(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('deletion-submit'));
  await tester.scrollUntilVisible(
    button,
    300,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('deletion-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  expect(find.text('要刪除帳號嗎？'), findsOneWidget);
  await tester.tap(find.text('刪除帳號').last);
  await tester.pumpAndSettle();
}

void main() {
  late Directory cacheDirectory;
  late BuiltInMapCachingProvider mapCache;
  setUpAll(() async {
    cacheDirectory = await Directory.systemTemp.createTemp('deletion-map-');
    mapCache = BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: cacheDirectory.path,
    );
  });
  tearDownAll(() async {
    await mapCache.destroy(deleteCache: true);
    await cacheDirectory.delete();
  });
  tearDown(() => policyUrls = (privacy: '', terms: ''));

  testWidgets('P10：刪除帳號獨立一組，隱私權政策、服務條款與資料來源列', (tester) async {
    policyUrls = (
      privacy: 'https://example.com/privacy',
      terms: 'https://example.com/terms',
    );
    final app = await _mount(
      tester,
      FakeDeletionGateway(current: google(signedInAt: now)),
    );
    showSettings(_appContext(tester), app.store);
    await tester.pumpAndSettle();
    final sheet = find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first;
    for (final key in [
      'settings-data-license',
      'settings-privacy',
      'settings-terms',
      'settings-delete-account',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)),
        200,
        scrollable: sheet,
      );
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(find.text('服務條款'), findsOneWidget);
    expect(find.text('隱私權政策'), findsOneWidget);
    expect(find.text('資料來源與授權'), findsOneWidget);
    expect(find.text('申請後有 7 天冷靜期，期間登入時可以選擇取消。'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-delete-account')))
          .height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byKey(const ValueKey('settings-terms')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-delete-account')));
    await tester.pumpAndSettle();
    expect(find.text('刪除前，先看看你的資料會怎麼處理。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('P10：網址沒設定時不顯示隱私權政策與服務條款', (tester) async {
    final app = await _mount(
      tester,
      FakeDeletionGateway(current: google(signedInAt: now)),
    );
    showSettings(_appContext(tester), app.store);
    await tester.pumpAndSettle();
    expect(find.text('服務條款'), findsNothing);
    expect(find.text('隱私權政策'), findsNothing);
  });

  for (final size in sizes) {
    testWidgets('P15a 說明頁 ${size.width.toInt()}×${size.height.toInt()}：'
        '列出資料處理且按鈕可點', (tester) async {
      final app = await _mount(
        tester,
        FakeDeletionGateway(current: google(signedInAt: now)),
        size: size,
      );
      await _openPage(tester, app);
      expect(app.gateway.calls.where((c) => c == 'status'), hasLength(2));
      for (final text in ['7 天後才會刪除', '顯示名稱和頭像', '這支手機上的停車紀錄']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      final button = find.byKey(const ValueKey('deletion-submit'));
      await tester.scrollUntilVisible(
        button,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('deletion-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('保留匿名的防濫用雜湊'), findsOneWidget);
      expect(find.textContaining('保留 180 天後刪除'), findsOneWidget);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('P15c ①：管理員一進頁面就提示，不顯示刪除按鈕', (tester) async {
    final gateway = FakeDeletionGateway(current: google(signedInAt: now))
      ..statusFallback = deletionState(canSelfDelete: false);
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    expect(find.text('管理員帳號無法自行刪除'), findsWidgets);
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('deletion-submit')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('deletion-admin-note')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('deletion-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const ValueKey('deletion-admin-note')), findsOneWidget);
    expect(gateway.calls.contains('request'), isFalse);
  }, variant: platforms);

  testWidgets('剛登入的 Google：確認後直接申請，登出、清停車紀錄並顯示 ①，完成回地圖', (tester) async {
    final app = await _mount(
      tester,
      FakeDeletionGateway(current: google(signedInAt: now)),
    );
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(app.gateway.calls, containsAllInOrder(['request', 'signOut']));
    expect(app.cleared, isTrue);
    expect(find.text('已申請刪除帳號'), findsOneWidget);
    expect(find.text('帳號預計於 11 月 8 日後刪除。'), findsOneWidget);
    expect(find.text('已登出所有裝置'), findsOneWidget);
    expect(find.byKey(const ValueKey('apple-revoke-failed')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('deletion-notice-done')));
    await tester.pumpAndSettle();
    expect(find.text('已申請刪除帳號'), findsNothing);
    expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('確認對話框按取消不送出', (tester) async {
    final app = await _mount(
      tester,
      FakeDeletionGateway(current: google(signedInAt: now)),
    );
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.gateway.calls.contains('request'), isFalse);
  }, variant: platforms);

  testWidgets('超過 9 分鐘：先再登入一次，成功後送出', (tester) async {
    final gateway = FakeDeletionGateway(
      current: google(signedInAt: now.subtract(const Duration(minutes: 20))),
    )..reauths.add(google(signedInAt: now));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(find.text('再登入一次'), findsOneWidget);
    expect(find.text('r••••@gmail.com・Google'), findsOneWidget);
    expect(gateway.calls.contains('request'), isFalse);
    await tester.tap(find.byKey(const ValueKey('reauth-sign-in')));
    await tester.pumpAndSettle();
    expect(gateway.calls, containsAllInOrder(['reauth:google', 'request']));
    expect(find.text('已申請刪除帳號'), findsOneWidget);
  }, variant: platforms);

  for (final size in sizes) {
    testWidgets('再登入面板 ${size.width.toInt()}×${size.height.toInt()}：'
        '沒完成與登入成別的帳號都留在面板顯示錯誤', (tester) async {
      final gateway = FakeDeletionGateway(current: google(signedInAt: null))
        ..reauths.addAll([null, google(signedInAt: now, id: 'bob')]);
      final app = await _mount(tester, gateway, size: size);
      await _openPage(tester, app);
      await _tapSubmit(tester);
      await _confirm(tester);
      await tester.tap(find.byKey(const ValueKey('reauth-sign-in')));
      await tester.pumpAndSettle();
      expect(find.text('登入沒有完成，帳號沒有刪除。請再試一次。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reauth-sign-in')));
      await tester.pumpAndSettle();
      expect(
        find.text('你剛才登入的是 b••••@gmail.com，不是要刪除的帳號。帳號沒有刪除，也沒有切換。'),
        findsOneWidget,
      );
      expect(gateway.calls, contains('restore'));
      expect(gateway.calls.contains('request'), isFalse);
      expect(
        find.byKey(const ValueKey('reauth-sign-in')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('Apple：一律再用 Apple 登入，撤銷失敗不擋，完成畫面多一張提示卡', (tester) async {
    final gateway = FakeDeletionGateway(current: apple(signedInAt: now))
      ..revokes.add(Exception('apple.revoke_failed'));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(find.textContaining('撤銷「使用 Apple 登入」的授權'), findsOneWidget);
    expect(find.text('Apple ID・隱藏的電子郵件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reauth-sign-in')));
    await tester.pumpAndSettle();
    expect(gateway.calls, [
      'status',
      'status',
      'reauth:apple',
      'revoke:apple-rt:refresh_token',
      'request',
      'signOut',
    ]);
    expect(find.byKey(const ValueKey('apple-revoke-failed')), findsOneWidget);
    expect(find.textContaining('使用 Apple 登入」，選取本 App'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('網路失敗：顯示沒有送出，重試成功', (tester) async {
    final gateway = FakeDeletionGateway(current: google(signedInAt: now))
      ..requests.add(const SocketException('offline'));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(find.text('沒有送出'), findsOneWidget);
    await tester.tap(find.text('重試'));
    await tester.pumpAndSettle();
    expect(gateway.calls.where((c) => c == 'request'), hasLength(2));
    expect(find.text('已申請刪除帳號'), findsOneWidget);
  }, variant: platforms);

  testWidgets('後端回 recent_sign_in_required：再顯示登入面板', (tester) async {
    final gateway = FakeDeletionGateway(current: google(signedInAt: now))
      ..requests.add(apiError('auth.recent_sign_in_required'));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(find.text('再登入一次'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reauth-sign-in')));
    await tester.pumpAndSettle();
    expect(find.text('已申請刪除帳號'), findsOneWidget);
  });

  testWidgets('送出時 403：顯示管理員說明並移除按鈕', (tester) async {
    final gateway = FakeDeletionGateway(current: google(signedInAt: now))
      ..requests.add(apiError('account.admin_cannot_self_delete', 'PT403'));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(find.text('管理員帳號無法自行刪除'), findsWidgets);
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('deletion-submit')), findsNothing);
  }, variant: platforms);

  testWidgets('401：本機登出並開啟登入（P11）', (tester) async {
    final gateway = FakeDeletionGateway(current: google(signedInAt: now))
      ..requests.add(apiError('auth.sign_in_required'));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(gateway.calls, contains('signOut'));
    expect(find.text('刪除前，先看看你的資料會怎麼處理。'), findsNothing);
    expect(find.text('登入後可回報停車資訊與同步收藏。'), findsOneWidget);
  }, variant: platforms);

  testWidgets('400：一般錯誤', (tester) async {
    final gateway = FakeDeletionGateway(current: google(signedInAt: now))
      ..requests.add(apiError('request.invalid', 'PT400'));
    final app = await _mount(tester, gateway);
    await _openPage(tester, app);
    await _tapSubmit(tester);
    await _confirm(tester);
    expect(find.text('發生錯誤，請稍後再試。'), findsOneWidget);
  }, variant: platforms);

  group('P15b ② 冷靜期內登入', () {
    FakeDeletionGateway pendingGateway({AccountIdentity? who}) =>
        FakeDeletionGateway(current: who ?? google(signedInAt: now))
          ..statuses.add(pendingState());

    for (final size in sizes) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()}：'
          '確認頁是第一個畫面，返回關不掉', (tester) async {
        await _mount(tester, pendingGateway(), size: size);
        expect(find.text('帳號正在等待刪除'), findsOneWidget);
        expect(find.text('帳號預計於 11 月 8 日後刪除。'), findsOneWidget);
        expect(find.byKey(const ValueKey('parking-search')), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('帳號正在等待刪除'), findsOneWidget);
        for (final key in ['pending-cancel', 'pending-continue']) {
          final button = find.byKey(ValueKey(key));
          expect(button.hitTestable(), findsOneWidget, reason: key);
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        }
        expect(tester.takeException(), isNull);
      }, variant: platforms);
    }

    testWidgets('取消刪除：呼叫 cancel、進入 App 並提示', (tester) async {
      final app = await _mount(tester, pendingGateway());
      await tester.tap(find.byKey(const ValueKey('pending-cancel')));
      await tester.pumpAndSettle();
      expect(app.gateway.calls, contains('cancel'));
      expect(find.text('帳號正在等待刪除'), findsNothing);
      expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
      expect(
        find.text(
          debugDefaultTargetPlatformOverride == TargetPlatform.iOS
              ? '已取消刪除帳號'
              : '已取消刪除帳號，名稱已恢復',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('deletion-banner')), findsNothing);
    }, variant: platforms);

    testWidgets('繼續刪除：Apple 再撤銷一次（失敗不擋）並登出', (tester) async {
      final gateway = pendingGateway(who: apple(signedInAt: now))
        ..revokes.add(Exception('apple.revoke_failed'));
      await _mount(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('pending-continue')));
      await tester.pumpAndSettle();
      expect(gateway.calls, [
        'status',
        'revoke:apple-rt:refresh_token',
        'signOut',
      ]);
      expect(find.text('已維持刪除申請，並已登出'), findsOneWidget);
      expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
    }, variant: platforms);

    testWidgets('409：帳號正在刪除，按好後登出', (tester) async {
      final gateway = pendingGateway()
        ..cancels.add(apiError('account.deletion_in_progress', 'PT409'));
      await _mount(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('pending-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('帳號正在刪除'), findsOneWidget);
      expect(find.text('刪除已經開始，無法取消。'), findsOneWidget);
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();
      expect(gateway.calls.last, 'signOut');
      expect(find.text('帳號正在等待刪除'), findsNothing);
      expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
    }, variant: platforms);

    testWidgets('回到前景時讀 status，仍是 pending 就再顯示確認頁', (tester) async {
      final gateway = FakeDeletionGateway(current: google(signedInAt: now));
      await _mount(tester, gateway);
      expect(find.text('帳號正在等待刪除'), findsNothing);
      gateway.statuses.add(pendingState());
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text('帳號正在等待刪除'), findsOneWidget);
    });
  });

  for (final size in sizes) {
    testWidgets('舊 session ${size.width.toInt()}×${size.height.toInt()}：'
        '在別處申請過，本機登出並顯示 ①', (tester) async {
      final gateway = FakeDeletionGateway(
        current: google(signedInAt: DateTime.utc(2026, 10, 30)),
      )..statuses.add(pendingState());
      await _mount(tester, gateway, size: size);
      expect(gateway.calls, ['status', 'signOut']);
      expect(find.text('已申請刪除帳號'), findsOneWidget);
      expect(find.text('帳號正在等待刪除'), findsNothing);
      for (final key in ['deletion-notice-done', 'deletion-notice-sign-in']) {
        final button = find.byKey(ValueKey(key));
        expect(button.hitTestable(), findsOneWidget, reason: key);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
      }
      await tester.tap(find.byKey(const ValueKey('deletion-notice-sign-in')));
      await tester.pumpAndSettle();
      expect(find.text('登入後可回報停車資訊與同步收藏。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('不覆寫 provider：store 通知後 router 與設定頁仍是同一個仍在監聽的 controller', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = phone;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var status = 'none';
    String body() => jsonEncode({
      'status': status,
      'requested_at': status == 'pending' ? pendingRequestedAt : null,
      'scheduled_at': status == 'pending' ? pendingScheduledAt : null,
      'can_self_delete': true,
      'cannot_self_delete_reason': null,
    });
    final store = (await tester.runAsync(
      () => _signedInStore(deletionStatus: body),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(store.client!.dispose);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(_appContext(tester));
    final before = container.read(accountDeletionProvider);
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(identical(container.read(accountDeletionProvider), before), isTrue);
    // Disposed notifiers throw on addListener.
    before.addListener(() {});

    // The settings page reads the same instance.
    showSettings(_appContext(tester), store);
    await tester.pumpAndSettle();
    expect(
      identical(
        ProviderScope.containerOf(tester.element(find.text('帳號與設定')))
            .read(accountDeletionProvider),
        before,
      ),
      isTrue,
    );

    // And it still follows the app: a resume finds the pending request and
    // the router (listening to it) shows the choice.
    status = 'pending';
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    for (var i = 0; i < 5 && before.pending == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    await tester.pumpAndSettle();
    expect(before.pending?.status, 'pending');
    expect(find.text('帳號正在等待刪除'), findsOneWidget);
  });
}
