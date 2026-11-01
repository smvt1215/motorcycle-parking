import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const authSpot = ParkingSpot(
  id: 'test-spot',
  name: '測試機車停車點',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
);

class AuthTestStore extends AppStore {
  AuthTestStore(super.local, super.client);
  // Cloud synchronization has its own repository tests. Keep this suite
  // focused on the real auth event and the form reacting immediately.
  @override
  Future<void> loadFavorites() async {}
}

Future<AuthTestStore> authStore() async {
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
            'id': 'test-user',
            'email': 'rider@example.com',
            'created_at': '2026-10-01T00:00:00Z',
            'app_metadata': {'provider': 'google'},
            'user_metadata': {'full_name': '測試騎士'},
            'is_anonymous': false,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path.endsWith('/favorites')) {
        return http.Response('[]', 200);
      }
      throw StateError('Unexpected request: ${request.url.path}');
    }),
  );
  return AuthTestStore(
    LocalRepository(await SharedPreferences.getInstance()),
    client,
  )..spots = [authSpot];
}

/// Exercises Supabase's real callback parser and the AppStore auth listener.
Future<void> completeOAuth(AuthTestStore store) async {
  await store.client!.auth.getSessionFromUrl(
    Uri.parse(
      'tw.motopark://login-callback/'
      '#access_token=test-access&refresh_token=test-refresh'
      '&expires_in=3600&token_type=bearer',
    ),
  );
  await Future<void>.delayed(Duration.zero);
}

Future<AuthTestStore> mountAuthApp(
  WidgetTester tester, {
  bool restored = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = (await tester.runAsync(authStore))!;
  if (restored) await tester.runAsync(() => completeOAuth(store));
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
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

BuildContext appContext(WidgetTester tester) =>
    tester.element(find.byKey(const ValueKey('parking-search')));

void main() {
  late Directory cacheDirectory;
  late BuiltInMapCachingProvider mapCache;
  setUpAll(() async {
    // Plain `flutter test` also mounts OSM tiles. Widget tests have no native
    // path_provider plugin, so give the cache its own disposable directory.
    cacheDirectory = await Directory.systemTemp.createTemp('auth-flow-map-');
    mapCache = BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: cacheDirectory.path,
    );
  });
  tearDownAll(() async {
    await mapCache.destroy(deleteCache: true);
    await cacheDirectory.delete();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform 回報頁 OAuth 完成留在原表單、保留草稿並立即解鎖送出', (tester) async {
      final store = await mountAuthApp(tester);
      showReport(appContext(tester), store, authSpot.lat, authSpot.lng);
      await tester.pumpAndSettle();
      // The location section (map, search, GPS) comes first; the name field
      // may be below the list's build range.
      final form = find
          .descendant(
            of: find.byType(ReportForm),
            matching: find.byType(Scrollable),
          )
          .first;
      final name = find.widgetWithText(TextFormField, '停車點名稱');
      final namePart = find.byKey(const ValueKey('fold-名稱'));
      await tester.scrollUntilVisible(namePart, 300, scrollable: form);
      await tester.tap(namePart);
      await tester.pumpAndSettle();
      await tester.enterText(name, '尚未送出的停車點');
      // The sign-in prompt sits just above the name field.
      await tester.scrollUntilVisible(
        find.text('使用 Google 登入'),
        -100,
        scrollable: form,
      );
      await tester.tap(find.text('使用 Google 登入'));
      await tester.pumpAndSettle();
      expect(find.text('帳號與設定'), findsNothing);
      // Opening the browser alone is not a successful sign-in.
      expect(find.text('登入成功'), findsNothing);
      expect(store.canReport, isFalse);
      await tester.runAsync(() => completeOAuth(store));
      await tester.pumpAndSettle();
      expect(store.canReport, isTrue);
      expect(find.byType(ReportForm), findsOneWidget);
      expect(find.text('尚未送出的停車點'), findsOneWidget);
      expect(find.byType(SignInPrompt), findsNothing);
      expect(find.text('帳號與設定'), findsNothing);
      expect(find.byKey(const ValueKey('auth-success-toast')), findsOneWidget);
      final scrollable = find
          .descendant(
            of: find.byType(ReportForm),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('送出'),
        300,
        scrollable: scrollable,
      );
      expect(
        tester
            .widget<AdaptiveButton>(find.widgetWithText(AdaptiveButton, '送出'))
            .onPressed,
        isNotNull,
      );
      // Auth callbacks run in the real async zone (as the app-link does),
      // so wait on that clock before pumping the expired toast.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3100)),
      );
      await tester.pump();
      expect(find.text('登入成功'), findsNothing);
      // Repeated signed-in events and token refreshes do not repeat feedback.
      await tester.runAsync(() => completeOAuth(store));
      await tester.pumpAndSettle();
      expect(find.text('登入成功'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('修改建議 OAuth 完成保留原輸入並立即啟用送出', (tester) async {
    final store = await mountAuthApp(tester);
    showSpotSuggestions(appContext(tester), store, authSpot);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停車點名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('suggestion-input')),
      '正確的停車點名稱',
    );
    expect(
      tester
          .widget<AdaptiveButton>(find.widgetWithText(AdaptiveButton, '送出修改建議'))
          .onPressed,
      isNull,
    );
    await tester.runAsync(() => completeOAuth(store));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('suggestion-input')))
          .controller!
          .text,
      '正確的停車點名稱',
    );
    expect(find.byType(SignInPrompt), findsNothing);
    expect(find.text('帳號與設定'), findsNothing);
    expect(
      tester
          .widget<AdaptiveButton>(find.widgetWithText(AdaptiveButton, '送出修改建議'))
          .onPressed,
      isNotNull,
    );
    expect(find.text('登入成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('精簡登入選單成功後關閉，回到原頁並顯示提示', (tester) async {
    final store = await mountAuthApp(tester);
    showSignIn(appContext(tester), store);
    await tester.pumpAndSettle();
    expect(find.text('帳號與設定'), findsNothing);
    expect(find.byType(SignInButtons), findsOneWidget);
    await tester.runAsync(() => completeOAuth(store));
    await tester.pumpAndSettle();
    expect(find.byType(SignInButtons), findsNothing);
    expect(find.byKey(const ValueKey('parking-search')), findsOneWidget);
    expect(find.text('登入成功'), findsOneWidget);
  });

  testWidgets('貢獻頁登入完成後收起登入選單並立即移除未登入提示', (tester) async {
    final store = await mountAuthApp(tester);
    await tester.tap(find.text('貢獻'));
    await tester.pumpAndSettle();
    expect(find.text('登入後才能新增與修正停車資訊。'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '登入'));
    await tester.pumpAndSettle();
    expect(find.text('帳號與設定'), findsNothing);
    await tester.runAsync(() => completeOAuth(store));
    await tester.pumpAndSettle();
    expect(find.text('登入後才能新增與修正停車資訊。'), findsNothing);
    expect(find.byType(SignInButtons), findsNothing);
    expect(find.text('修正附近停車點'), findsOneWidget);
    expect(find.text('登入成功'), findsOneWidget);
  });

  testWidgets('已恢復登入的啟動不顯示登入成功提示', (tester) async {
    await mountAuthApp(tester, restored: true);
    expect(find.text('登入成功'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('登入成功'), findsNothing);
  });

  testWidgets('從帳號設定登入保留設定頁，更新帳號而非關閉原頁', (tester) async {
    final store = await mountAuthApp(tester);
    showSettings(appContext(tester), store);
    await tester.pumpAndSettle();
    expect(find.text('尚未登入'), findsOneWidget);
    await tester.runAsync(() => completeOAuth(store));
    await tester.pumpAndSettle();
    expect(find.text('帳號與設定'), findsOneWidget);
    expect(find.text('測試騎士'), findsOneWidget);
    expect(find.text('尚未登入'), findsNothing);
    expect(find.text('登出'), findsOneWidget);
    expect(find.text('登入成功'), findsOneWidget);
  });
}
