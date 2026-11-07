import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/core/config.dart';
import 'package:motorcycle_parking/data/account_deletion.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/auth_flow.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_native_identity.dart';

String _jwt(String sub) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256'})}.'
      '${part({
        'sub': sub,
        'exp': now + 3600,
        'amr': [
          {'method': 'oauth', 'timestamp': now},
        ],
      })}.sig';
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// A Supabase backend that answers `id_token` sign-ins and records requests.
class _Backend {
  final tokenBodies = <Map<String, dynamic>>[];
  final userBodies = <Map<String, dynamic>>[];
  final revokeBodies = <Map<String, dynamic>>[];
  final log = <String>[];
  String userId = 'rider';
  http.Response Function()? tokenAnswer;
  http.Response Function()? revokeAnswer;

  late final client = SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
    httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/auth/v1/token')) {
        log.add('token');
        tokenBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final answer = tokenAnswer;
        if (answer != null) return answer();
        final provider = tokenBodies.last['provider'] as String;
        return _json({
          'access_token': _jwt(userId),
          'refresh_token': 'refresh-$userId',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': userId,
            'aud': 'authenticated',
            'email': '$userId@example.com',
            'created_at': '2026-10-01T00:00:00Z',
            'app_metadata': {'provider': provider},
            'user_metadata': <String, dynamic>{},
            'is_anonymous': false,
          },
        });
      }
      if (path.endsWith('/auth/v1/user')) {
        userBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _json({
          'id': userId,
          'aud': 'authenticated',
          'email': '$userId@example.com',
          'created_at': '2026-10-01T00:00:00Z',
          'app_metadata': {'provider': 'apple'},
          'user_metadata': {'full_name': '陳阿哲'},
        });
      }
      if (path.endsWith('/functions/v1/apple-revoke')) {
        log.add('revoke');
        revokeBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return revokeAnswer?.call() ?? _json({'revoked': true});
      }
      return http.Response('not found', 404);
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void onPlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  group('signInRoute', () {
    test('iOS Apple／Google 與 Android Google 走原生，Android Apple 走瀏覽器', () {
      onPlatform(TargetPlatform.iOS);
      expect(signInRoute(OAuthProvider.apple), SignInRoute.nativeApple);
      expect(signInRoute(OAuthProvider.google), SignInRoute.nativeGoogle);
      onPlatform(TargetPlatform.android);
      expect(signInRoute(OAuthProvider.google), SignInRoute.nativeGoogle);
      expect(signInRoute(OAuthProvider.apple), SignInRoute.browser);
    });

    test('其他平台走瀏覽器', () {
      onPlatform(TargetPlatform.linux);
      expect(signInRoute(OAuthProvider.google), SignInRoute.browser);
      expect(signInRoute(OAuthProvider.apple), SignInRoute.browser);
    });
  });

  test('hashNonce 是 raw nonce 的 SHA-256 十六進位字串', () {
    expect(
      hashNonce('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  group('appleFullName', () {
    test('中文姓在前不加空白，拉丁字母名在前', () {
      expect(appleFullName('阿哲', '陳'), '陳阿哲');
      expect(appleFullName('Ada', 'Lovelace'), 'Ada Lovelace');
    });

    test('只有一邊或都沒有', () {
      expect(appleFullName(null, 'Lovelace'), 'Lovelace');
      expect(appleFullName(' ', null), isNull);
      expect(appleFullName(null, null), isNull);
    });
  });

  group('AuthFlow', () {
    late _Backend backend;
    late FakeNativeIdentity identity;
    late AuthFlow flow;
    var now = DateTime.utc(2026, 11, 7, 12);

    setUp(() {
      now = DateTime.utc(2026, 11, 7, 12);
      SharedPreferences.setMockInitialValues({});
      backend = _Backend();
      identity = FakeNativeIdentity();
      flow = AuthFlow(backend.client, identity: identity, clock: () => now);
      addTearDown(backend.client.dispose);
    });

    test('iOS Apple：hash 給 Apple、raw nonce 給 Supabase，並留下授權碼', () async {
      onPlatform(TargetPlatform.iOS);
      identity.appleResults.add(
        const NativeCredential(
          idToken: 'apple-id-token',
          authorizationCode: 'code-1',
        ),
      );
      await flow.signIn(OAuthProvider.apple);
      final body = backend.tokenBodies.single;
      expect(body['provider'], 'apple');
      expect(body['id_token'], 'apple-id-token');
      expect(body['nonce'], isNotEmpty);
      expect(identity.appleNonces.single, hashNonce(body['nonce'] as String));
      expect(flow.appleCode, 'code-1');
      expect(backend.userBodies, isEmpty);
    });

    test('Apple 首次登入給的姓名存成 full_name，只當建議值', () async {
      onPlatform(TargetPlatform.iOS);
      identity.appleResults.add(
        const NativeCredential(idToken: 'id', fullName: '陳阿哲'),
      );
      await flow.signIn(OAuthProvider.apple);
      expect(backend.userBodies.single['data'], {'full_name': '陳阿哲'});
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      test('$platform Google：hash 給 Google、raw nonce 給 Supabase', () async {
        onPlatform(platform);
        await flow.signIn(OAuthProvider.google);
        final body = backend.tokenBodies.single;
        expect(body['provider'], 'google');
        expect(body['id_token'], 'google-id-token');
        expect(
          identity.googleNonces.single,
          hashNonce(body['nonce'] as String),
        );
        expect(flow.appleCode, isNull);
      });
    }

    test('同一次啟動的 Google 登入共用 nonce（initialize 只能呼叫一次）', () async {
      onPlatform(TargetPlatform.android);
      await flow.signIn(OAuthProvider.google);
      await flow.signIn(OAuthProvider.google);
      expect(identity.googleNonces.toSet(), hasLength(1));
      expect(backend.tokenBodies[0]['nonce'], backend.tokenBodies[1]['nonce']);
    });

    test('每次 Apple 登入都用新的 nonce', () async {
      onPlatform(TargetPlatform.iOS);
      await flow.signIn(OAuthProvider.apple);
      await flow.signIn(OAuthProvider.apple);
      expect(identity.appleNonces.toSet(), hasLength(2));
    });

    test('授權碼過了效期就不再提供，新的登入先清掉舊的', () async {
      onPlatform(TargetPlatform.iOS);
      identity.appleResults.add(
        const NativeCredential(idToken: 'id', authorizationCode: 'old'),
      );
      await flow.signIn(OAuthProvider.apple);
      now = now.add(appleCodeLifetime);
      expect(flow.appleCode, isNull);

      now = now.subtract(appleCodeLifetime);
      expect(flow.appleCode, 'old');
      identity.googleResults.add(const SignInCancelled());
      await expectLater(
        flow.signIn(OAuthProvider.google),
        throwsA(isA<SignInCancelled>()),
      );
      expect(flow.appleCode, isNull);
    });
  });

  group('AppStore.signIn', () {
    late _Backend backend;
    late FakeNativeIdentity identity;
    late AppStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      backend = _Backend();
      identity = FakeNativeIdentity();
      store = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        backend.client,
        authFlow: AuthFlow(backend.client, identity: identity),
      );
      addTearDown(store.dispose);
      addTearDown(backend.client.dispose);
    });

    test('關掉面板不算失敗', () async {
      onPlatform(TargetPlatform.iOS);
      identity.appleResults.add(const SignInCancelled());
      identity.googleResults.add(const SignInCancelled());
      await store.signIn(OAuthProvider.apple);
      await store.signIn(OAuthProvider.google);
      expect(backend.tokenBodies, isEmpty);
    });

    test('面板失敗或 Supabase 拒絕時往外丟，由畫面顯示錯誤', () async {
      onPlatform(TargetPlatform.android);
      identity.googleResults.add(StateError('panel'));
      await expectLater(
        store.signIn(OAuthProvider.google),
        throwsA(isA<StateError>()),
      );
      backend.tokenAnswer = () => _json({'msg': 'Nonces mismatch'}, 400);
      await expectLater(
        store.signIn(OAuthProvider.google),
        throwsA(isA<AuthException>()),
      );
    });

    test('Android Apple 用系統瀏覽器與 App callback', () async {
      onPlatform(TargetPlatform.android);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await store.signIn(OAuthProvider.apple);
      final args = calls.singleWhere((c) => c.method == 'launch').arguments;
      final url = Uri.parse((args as Map)['url'] as String);
      expect(url.queryParameters['provider'], 'apple');
      expect(url.queryParameters['redirect_to'], AppConfig.redirectUrl);
      expect(args['useSafariVC'], isFalse);
      expect(args['useWebView'], isFalse);
      expect(identity.appleNonces, isEmpty);
      expect(backend.tokenBodies, isEmpty);
    });
  });

  group('SupabaseAccountGateway', () {
    late _Backend backend;
    late FakeNativeIdentity identity;
    late AuthFlow flow;
    late SupabaseAccountGateway gateway;

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'test',
        packageName: 'tw.motopark.motorcycleParking.staging',
        version: '0.1.0',
        buildNumber: '1',
        buildSignature: '',
      );
      backend = _Backend();
      identity = FakeNativeIdentity();
      flow = AuthFlow(backend.client, identity: identity);
      gateway = SupabaseAccountGateway(backend.client, auth: flow);
      addTearDown(backend.client.dispose);
    });

    test('iOS 再驗證走原生，新授權碼與實際 bundle ID 送 apple-revoke', () async {
      onPlatform(TargetPlatform.iOS);
      identity.appleResults.add(
        const NativeCredential(idToken: 'id', authorizationCode: 'fresh'),
      );
      final me = await gateway.reauthenticate(apple: true);
      expect(me.apple, isTrue);
      expect(me.appleCode, 'fresh');
      await gateway.revokeAppleCode(me.appleCode!);
      expect(backend.revokeBodies.single, {
        'authorization_code': 'fresh',
        'bundle_id': 'tw.motopark.motorcycleParking.staging',
      });
      expect(backend.log, ['token', 'revoke']);
      expect(gateway.current?.appleCode, isNull, reason: '授權碼只能用一次');
    });

    test('Android 維持 token 路徑', () async {
      await gateway.revokeApple('rt', 'refresh_token');
      expect(backend.revokeBodies.single, {
        'token': 'rt',
        'token_type_hint': 'refresh_token',
      });
    });

    test('撤銷失敗的錯誤碼往外丟，管理者回 AdminCannotDelete', () async {
      backend.revokeAnswer = () =>
          _json({'error': 'apple.code_exchange_failed'}, 502);
      await expectLater(gateway.revokeAppleCode('c'), throwsException);
      expect(flow.appleCode, isNull);
      backend.revokeAnswer = () =>
          _json({'error': 'account.admin_cannot_self_delete'}, 403);
      await expectLater(
        gateway.revokeAppleCode('c'),
        throwsA(isA<AdminCannotDelete>()),
      );
    });

    test('關掉原生面板：ReauthCancelled；其他失敗：ReauthIncomplete', () async {
      onPlatform(TargetPlatform.android);
      identity.googleResults.add(const SignInCancelled());
      await expectLater(
        gateway.reauthenticate(apple: false),
        throwsA(isA<ReauthCancelled>()),
      );
      identity.googleResults.add(StateError('panel'));
      await expectLater(
        gateway.reauthenticate(apple: false),
        throwsA(isA<ReauthIncomplete>()),
      );
    });

    test('登入到別的帳號：還原時清掉那個帳號的授權碼', () async {
      onPlatform(TargetPlatform.iOS);
      identity.appleResults.add(
        const NativeCredential(idToken: 'id', authorizationCode: 'other'),
      );
      await gateway.reauthenticate(apple: true);
      await gateway.restorePrevious();
      expect(flow.appleCode, isNull);
    });
  });
}
