import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/api/v1/api_v1.g.dart';
import 'package:motorcycle_parking/data/account_status.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/account_status_display.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/auth/profile_editor.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const userId = '10000000-0000-4000-8000-000000000001';

/// 2026 年 11 月 12 日 14:00 in Taiwan.
final until = DateTime.utc(2026, 11, 12, 6);
const untilIso = '2026-11-12T06:00:00Z';

const sizes = [Size(390, 844), Size(820, 1180), Size(1180, 820)];
const platforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});

class _Store extends AppStore {
  _Store(super.local, super.client);
  @override
  Future<void> loadFavorites() async {}
}

/// A signed-in rider against a fake backend. [statusBody] answers
/// `api_v1.my_account_status` (null: HTTP 500); [keepProfile] makes the
/// profile keep its old values, as the suspension trigger does.
class _Backend {
  _Backend({this.statusBody, this.keepProfile = false});
  Object? statusBody;
  bool keepProfile;
  Map<String, dynamic> metadata = {
    'display_name': '阿哲',
    'avatar_url': 'https://example.test/provider.png',
  };
  final statusReads = <http.Request>[];
  late final SupabaseClient client = SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
    httpClient: MockClient(_handle),
  );
  late final _Store store;

  Map<String, dynamic> get user => {
    'id': userId,
    'email': 'rider@example.com',
    'created_at': '2026-10-01T00:00:00Z',
    'app_metadata': {'provider': 'google'},
    'user_metadata': metadata,
    'is_anonymous': false,
  };

  http.Response _json(http.Request request, Object body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
        request: request,
      );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/auth/v1/user') {
      if (request.method == 'PUT' && !keepProfile) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        metadata = {...metadata, ...(body['data'] as Map<String, dynamic>)};
      }
      return _json(request, user);
    }
    if (path == '/rest/v1/rpc/my_account_status') {
      statusReads.add(request);
      final body = statusBody;
      return body == null
          ? _json(request, {'message': 'boom'}, 500)
          : _json(request, body);
    }
    if (path == '/auth/v1/token') {
      return _json(request, {
        'access_token': 'test-access-2',
        'refresh_token': 'test-refresh-2',
        'expires_in': 3600,
        'token_type': 'bearer',
        'user': user,
      });
    }
    if (path.endsWith('/logout')) return http.Response('', 204);
    return _json(request, const []);
  }

  Future<void> open() async {
    SharedPreferences.setMockInitialValues({});
    store = _Store(
      LocalRepository(await SharedPreferences.getInstance()),
      client,
    );
    await client.auth.getSessionFromUrl(
      Uri.parse(
        'tw.motopark://login-callback/#access_token=test-access'
        '&refresh_token=test-refresh&expires_in=3600&token_type=bearer',
      ),
    );
  }

  Future<void> close() async {
    store.dispose();
    await client.dispose();
  }
}

AccountStatusController _status(Future<AccountStatus> Function() read) =>
    AccountStatusController(read, userId: () => userId);

void _size(WidgetTester tester, Size size, {double text = 1}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = text;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void _mockLauncher() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  messenger.setMockMethodCallHandler(channel, (_) async => true);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

/// A form in a sheet whose 送出 fails with [error], as a write would.
class _Form extends StatelessWidget {
  const _Form(this.error);
  final Object error;
  @override
  Widget build(BuildContext context) => ContentPage(
    children: [
      const TextField(key: ValueKey('form-note')),
      AdaptiveButton(
        key: const ValueKey('form-send'),
        label: '送出',
        onPressed: () => runAction(context, () async => throw error),
      ),
    ],
  );
}

Widget _host(void Function(BuildContext) open) => MaterialApp(
  // Match the app's bridge for CNBottomSheet's Material localizations.
  // ignore: deprecated_member_use
  builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const ValueKey('open'),
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('403 account.suspended 解析', () {
    test('Edge Function：HTTP 403，body 是 {error, until}', () {
      final dated = accountSuspendedFrom(
        const FunctionException(
          status: 403,
          details: {
            'error': 'account.suspended',
            'until': '2026-11-12T06:00:00Z',
          },
        ),
      );
      expect(dated?.until, until);
      final open = accountSuspendedFrom(
        const FunctionException(
          status: 403,
          details: {'error': 'account.suspended', 'until': null},
        ),
      );
      expect(open, isNotNull);
      expect(open!.until, isNull);
      // A body left as text is read the same.
      expect(
        accountSuspendedFrom(
          const FunctionException(
            status: 403,
            details: '{"error":"account.suspended","until":"2026-11-12T14:00:00+08:00"}',
          ),
        )?.until,
        until,
      );
    });

    test('api_v1 RPC：PT403，message 是 account.suspended，details 是 JSON 字串', () {
      const details = '{"until":"2026-11-12T06:00:00Z"}';
      expect(
        accountSuspendedFrom(
          const ApiV1Exception(
            code: 'PT403',
            message: 'account.suspended',
            details: details,
          ),
        )?.until,
        until,
      );
      expect(
        accountSuspendedFrom(
          const PostgrestException(
            code: 'PT403',
            message: 'account.suspended',
            details: details,
          ),
        )?.until,
        until,
      );
      final open = accountSuspendedFrom(
        const ApiV1Exception(
          code: 'PT403',
          message: 'account.suspended',
          details: '{"until":null}',
        ),
      );
      expect(open, isNotNull);
      expect(open!.until, isNull);
    });

    test('其他錯誤不算停權', () {
      for (final error in <Object>[
        const FunctionException(status: 403, details: {'error': 'forbidden'}),
        const FunctionException(
          status: 400,
          details: {'error': 'account.suspended'},
        ),
        const FunctionException(status: 403, details: 'nope'),
        const ApiV1Exception(code: 'PT403', message: 'auth.aal2_required'),
        const ApiV1Exception(code: 'PT409', message: 'hidden_riders.too_many'),
        StateError('x'),
      ]) {
        expect(accountSuspendedFrom(error), isNull, reason: '$error');
      }
    });

    test('submit-report 的 403 經資料層變成 AccountSuspended', () async {
      SharedPreferences.setMockInitialValues({});
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': 'account.suspended',
              'until': '2026-11-12T06:00:00Z',
            }),
            403,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      );
      addTearDown(client.dispose);
      final repo = ParkingRepository(client, appCheckToken: () async => null);
      await expectLater(
        repo.report({'action': 'flag', 'source_id': 'x'}),
        throwsA(isA<AccountSuspended>().having((e) => e.until, 'until', until)),
      );
    });

    test('api_v1 RPC 的 403 經 ApiV1Client 仍讀得到到期日', () async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'code': 'PT403',
              'message': 'account.suspended',
              'details': '{"until":null}',
              'hint': null,
            }),
            403,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      );
      addTearDown(client.dispose);
      Object? caught;
      try {
        await ApiV1Client(client).hiddenRidersList();
      } catch (e) {
        caught = e;
      }
      final suspended = accountSuspendedFrom(caught);
      expect(suspended, isNotNull);
      expect(suspended!.until, isNull);
    });
  });

  group('日期（台灣時間）', () {
    test('面板寫完整日期，換算成台灣時間', () {
      expect(suspendedDateLong(until), '2026 年 11 月 12 日 14:00');
      // 16:30 UTC is the next day, the next year, in Taiwan.
      expect(
        suspendedDateLong(DateTime.utc(2026, 12, 31, 16, 30)),
        '2027 年 1 月 1 日 00:30',
      );
      expect(
        suspendedDateLong(DateTime.parse('2026-03-05T09:05:00+08:00')),
        '2026 年 3 月 5 日 09:05',
      );
      expect(suspendedUntilSentence(until), '到 2026 年 11 月 12 日 14:00 為止。');
      expect(suspendedUntilSentence(null), '直到另行通知。');
    });

    test('P10 小卡省略同年的年份，跨年時加上', () {
      final now = DateTime.utc(2026, 11, 5, 4);
      expect(suspendedDateShort(until, now), '11 月 12 日 14:00');
      expect(suspendedCardTitle(until, now), '帳號暫停送出內容，到 11 月 12 日 14:00');
      expect(suspendedCardTitle(null, now), '帳號暫停送出內容，直到另行通知');
      // Taiwan is already in 2027 at 16:30 UTC on 31 December.
      expect(
        suspendedDateShort(
          DateTime.utc(2027, 1, 3, 2),
          DateTime.utc(2026, 12, 31, 15),
        ),
        '2027 年 1 月 3 日 10:00',
      );
      expect(
        suspendedDateShort(
          DateTime.utc(2027, 1, 3, 2),
          DateTime.utc(2026, 12, 31, 16, 30),
        ),
        '1 月 3 日 10:00',
      );
      expect(
        suspendedNameNote(until),
        '帳號暫停送出內容期間不能修改名稱，到 2026 年 11 月 12 日 14:00 為止。',
      );
      expect(suspendedNameNote(null), '帳號暫停送出內容期間不能修改名稱，直到另行通知。');
    });
  });

  group('my_account_status', () {
    test('讀 suspended 與 suspended_until', () {
      final status = AccountStatus.fromJson({
        'suspended': true,
        'suspended_until': '2026-11-12T06:00:00Z',
      });
      expect(status.suspended, isTrue);
      expect(status.until, until);
      final none = AccountStatus.fromJson({
        'suspended': false,
        'suspended_until': null,
      });
      expect(none.suspended, isFalse);
      expect(none.until, isNull);
      // Taiwan's offset is read as the same instant.
      expect(
        const AccountStatus(
          suspended: true,
          suspendedUntil: '2026-11-12T14:00:00+08:00',
        ).until,
        until,
      );
    });

    test('讀取失敗或換帳號時狀態變成未知，不擋任何事', () async {
      var fail = false;
      String? user = userId;
      final status = AccountStatusController(() async {
        if (fail) throw Exception('offline');
        return AccountStatus(suspended: true, suspendedUntil: untilIso);
      }, userId: () => user);
      await status.refresh();
      expect(status.suspension?.until, until);
      user = 'someone-else';
      expect(status.suspension, isNull);
      user = userId;
      fail = true;
      await status.refresh();
      expect(status.suspension, isNull);
      user = null;
      fail = false;
      await status.refresh();
      expect(status.suspension, isNull);
    });

    test('沒有後端（範例模式）時不讀', () async {
      final status = AccountStatusController(null, userId: () => userId);
      await status.refresh();
      expect(status.status, isNull);
    });
  });

  group('① ② 共用面板', () {
    for (final size in sizes) {
      for (final text in [1.0, 2.0]) {
        final label = '${size.width.toInt()}×${size.height.toInt()} 字級 $text';
        testWidgets('① 有到期日：$label，表單內容保留', (tester) async {
          _size(tester, size, text: text);
          await tester.pumpWidget(
            _host(
              (c) => showAdaptiveSheet<void>(
                c,
                (_) => _Form(AccountSuspended(until)),
              ),
            ),
          );
          await tester.tap(find.byKey(const ValueKey('open')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('form-note')),
            '松壽路側車道下坡',
          );
          await tester.tap(find.byKey(const ValueKey('form-send')));
          await tester.pumpAndSettle();

          expect(find.byKey(const ValueKey('suspended-panel')), findsOneWidget);
          expect(find.text(suspendedTitle), findsOneWidget);
          expect(find.text('到 2026 年 11 月 12 日 14:00 為止。'), findsOneWidget);
          expect(find.text(suspendedStillAllowed), findsOneWidget);
          expect(find.text(suspendedContact), findsOneWidget);
          // No ordinary error message.
          expect(find.byType(SnackBar), findsNothing);
          expect(tester.takeException(), isNull);

          final dismiss = find.byKey(const ValueKey('suspended-dismiss'));
          await tester.ensureVisible(dismiss);
          await tester.pumpAndSettle();
          await tester.tap(dismiss);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('suspended-panel')), findsNothing);
          expect(find.text('松壽路側車道下坡'), findsOneWidget);
        }, variant: platforms);
      }
    }

    testWidgets('② 無限期：直到另行通知；Edge Function 的錯誤直接傳進來也一樣', (tester) async {
      _size(tester, sizes.first, text: 2);
      await tester.pumpWidget(
        _host(
          (c) => showAdaptiveSheet<void>(
            c,
            (_) => const _Form(
              FunctionException(
                status: 403,
                details: {'error': 'account.suspended', 'until': null},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-send')));
      await tester.pumpAndSettle();
      expect(find.text('直到另行通知。'), findsOneWidget);
      expect(find.textContaining('為止'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: platforms);

    for (final size in sizes) {
      testWidgets('到期日未知：不顯示日期那一行，'
          '${size.width.toInt()}×${size.height.toInt()} 字級 2.0', (
        tester,
      ) async {
        _size(tester, size, text: 2);
        await tester.pumpWidget(
          _host(
            (c) => showAdaptiveSheet<void>(
              c,
              (_) => const _Form(AccountSuspended.untilUnknown()),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('form-send')));
        await tester.pumpAndSettle();
        expect(find.text(suspendedTitle), findsOneWidget);
        expect(find.text(suspendedStillAllowed), findsOneWidget);
        expect(find.byKey(const ValueKey('suspended-until')), findsNothing);
        expect(find.textContaining('直到另行通知'), findsNothing);
        expect(tester.takeException(), isNull);
        final dismiss = find.byKey(const ValueKey('suspended-dismiss'));
        await tester.ensureVisible(dismiss);
        await tester.pumpAndSettle();
        await tester.tap(dismiss);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('suspended-panel')), findsNothing);
      }, variant: platforms);
    }

    test('未知和無限期分開', () {
      const open = AccountSuspended(null);
      const unknown = AccountSuspended.untilUnknown();
      expect(open.untilKnown, isTrue);
      expect(open.until, isNull);
      expect(unknown.untilKnown, isFalse);
      expect(unknown.until, isNull);
      // The backend's null is indefinite, never unknown.
      expect(
        accountSuspendedFrom(
          const FunctionException(
            status: 403,
            details: {'error': 'account.suspended', 'until': null},
          ),
        )!.untilKnown,
        isTrue,
      );
      expect(accountSuspendedFrom(unknown)!.untilKnown, isFalse);
    });

    testWidgets('聯絡我們用 App 內瀏覽器開客服頁', (tester) async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(_host((c) => showSuspendedSheet(c, until)));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('suspended-contact')));
      await tester.pumpAndSettle();
      final launch = calls.where((c) => c.method.startsWith('launch')).single;
      final args = launch.arguments as Map;
      expect(args['url'], 'https://motoparking.smvtstudio.com/support');
      // LaunchMode.inAppBrowserView: SFSafariViewController / Custom Tabs.
      expect(args['useSafariVC'], isTrue);
    });

    testWidgets('一般錯誤仍顯示原本的訊息，不顯示停權面板', (tester) async {
      await tester.pumpWidget(
        _host(
          (c) => runAction(
            c,
            () async => throw const ApiV1Exception(
              code: 'PT409',
              message: 'hidden_riders.too_many',
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('suspended-panel')), findsNothing);
      expect(find.text('操作失敗，請確認連線後重試'), findsOneWidget);
    });
  });

  group('③ P10 常駐小卡', () {
    Future<_Backend> mount(
      WidgetTester tester,
      AccountStatusController status, {
      Size size = const Size(390, 844),
      double text = 1,
    }) async {
      _size(tester, size, text: text);
      _mockLauncher();
      final backend = _Backend();
      await tester.runAsync(backend.open);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(backend.close);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storeProvider.overrideWith((ref) => backend.store),
            accountStatusProvider.overrideWith((ref) => status),
          ],
          child: _host((c) => showSettings(c, backend.store)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      return backend;
    }

    for (final size in sizes) {
      for (final text in [1.0, 2.0]) {
        testWidgets('停權中顯示小卡：${size.width.toInt()}×${size.height.toInt()} '
            '字級 $text', (tester) async {
          var reads = 0;
          final status = _status(() async {
            reads++;
            return AccountStatus(suspended: true, suspendedUntil: untilIso);
          });
          final backend = await mount(tester, status, size: size, text: text);
          // Opening P10 reads the status.
          expect(reads, 1);
          expect(find.byKey(const ValueKey('suspended-card')), findsOneWidget);
          expect(
            find.text(suspendedCardTitle(until, backend.store.clock())),
            findsOneWidget,
          );
          expect(find.text(suspendedCardDetail), findsOneWidget);
          expect(find.text(suspendedContactShort), findsOneWidget);
          expect(tester.takeException(), isNull);
        }, variant: platforms);
      }
    }

    testWidgets('無限期寫「直到另行通知」', (tester) async {
      await mount(
        tester,
        _status(() async => const AccountStatus(suspended: true)),
      );
      expect(find.text('帳號暫停送出內容，直到另行通知'), findsOneWidget);
    });

    testWidgets('讀取失敗時不顯示小卡', (tester) async {
      await mount(tester, _status(() async => throw Exception('offline')));
      expect(find.byKey(const ValueKey('suspended-card')), findsNothing);
      expect(find.text('帳號與設定'), findsOneWidget);
    });

    testWidgets('沒有停權時不顯示小卡', (tester) async {
      await mount(
        tester,
        _status(() async => const AccountStatus(suspended: false)),
      );
      expect(find.byKey(const ValueKey('suspended-card')), findsNothing);
    });

    testWidgets('回到前景時重新讀取', (tester) async {
      var reads = 0;
      final status = _status(() async {
        reads++;
        return const AccountStatus(suspended: false);
      })..start();
      addTearDown(status.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reads, 1);
    });
  });

  group('④ P12 停權中', () {
    Future<_Backend> mount(
      WidgetTester tester, {
      required AccountStatusController status,
      _Backend? backend,
      Size size = const Size(390, 844),
      double text = 1,
    }) async {
      _size(tester, size, text: text);
      final b = backend ?? _Backend();
      await tester.runAsync(b.open);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(b.close);
      });
      await tester.pumpWidget(
        _host((c) => showProfileEditor(c, b.store, status: status)),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      return b;
    }

    for (final size in sizes) {
      for (final text in [1.0, 2.0]) {
        testWidgets('名稱唯讀、儲存與移除頭像停用：${size.width.toInt()}×'
            '${size.height.toInt()} 字級 $text', (tester) async {
          final status = _status(
            () async =>
                AccountStatus(suspended: true, suspendedUntil: untilIso),
          );
          await status.refresh();
          await mount(tester, status: status, size: size, text: text);

          final field = tester.widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('profile-name')),
              matching: find.byType(TextField),
            ),
          );
          expect(field.enabled, isFalse);
          expect(
            tester
                .widget<TextButton>(find.byKey(const ValueKey('profile-save')))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('profile-remove-avatar')),
                )
                .onPressed,
            isNull,
          );
          expect(find.text(suspendedNameNote(until)), findsOneWidget);
          expect(find.text(suspendedContactShort), findsOneWidget);
          expect(tester.takeException(), isNull);
        }, variant: platforms);
      }
    }

    testWidgets('狀態沒讀到、存檔後名稱沒變：顯示共用面板，內容保留', (tester) async {
      final backend = _Backend(
        keepProfile: true,
        statusBody: {
          'suspended': true,
          'suspended_until': '2026-11-12T06:00:00Z',
        },
      );
      final status = _status(() async => throw Exception('offline'));
      await mount(tester, status: status, backend: backend);

      await tester.enterText(find.byKey(const ValueKey('profile-name')), '新名字');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('profile-save')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(backend.statusReads, hasLength(1));
      expect(find.byKey(const ValueKey('suspended-panel')), findsOneWidget);
      expect(find.text('到 2026 年 11 月 12 日 14:00 為止。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suspended-dismiss')));
      await tester.pumpAndSettle();
      // Back on P12, showing the name the profile kept.
      expect(find.text('編輯個人資料'), findsOneWidget);
      expect(find.text('阿哲'), findsWidgets);
    });

    testWidgets('沒停權時照常存檔（存檔後仍會確認一次）', (tester) async {
      final backend = _Backend(statusBody: {'suspended': false});
      await mount(
        tester,
        status: _status(() async => throw Exception('offline')),
        backend: backend,
      );
      await tester.enterText(find.byKey(const ValueKey('profile-name')), '新名字');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('profile-save')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(backend.statusReads, hasLength(1));
      expect(backend.metadata['display_name'], '新名字');
      expect(find.byKey(const ValueKey('suspended-panel')), findsNothing);
    });

    testWidgets('狀態一直讀不到、名稱沒存進去：顯示面板（不寫日期）並改回舊名稱', (tester) async {
      final backend = _Backend(keepProfile: true);
      await mount(
        tester,
        status: _status(() async => throw Exception('offline')),
        backend: backend,
      );
      await tester.enterText(find.byKey(const ValueKey('profile-name')), '新名字');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('profile-save')));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('suspended-panel')), findsOneWidget);
      // No date line: unknown is not indefinite.
      expect(find.text(suspendedTitle), findsOneWidget);
      expect(find.text(suspendedStillAllowed), findsOneWidget);
      expect(find.byKey(const ValueKey('suspended-until')), findsNothing);
      expect(find.textContaining('直到另行通知'), findsNothing);
      expect(find.textContaining('為止'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('suspended-dismiss')));
      await tester.pumpAndSettle();
      expect(find.text('阿哲'), findsWidgets);
      expect(find.text('新名字'), findsNothing);
    });
  });

  test('預設平台沒有被測試改掉', () {
    expect(debugDefaultTargetPlatformOverride, isNull);
  });
}
