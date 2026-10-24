import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/core/config.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform Google 登入使用系統瀏覽器與 App callback', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({});
      final local = await SharedPreferences.getInstance();
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
          autoRefreshToken: false,
        ),
      );
      final store = AppStore(LocalRepository(local), client);
      addTearDown(client.dispose);
      addTearDown(store.dispose);
      await store.signIn(OAuthProvider.google);
      final launch = calls.singleWhere((call) => call.method == 'launch');
      final args = launch.arguments as Map;
      final url = Uri.parse(args['url'] as String);
      expect(url.host, 'example.supabase.co');
      expect(url.queryParameters['provider'], 'google');
      expect(url.queryParameters['redirect_to'], AppConfig.redirectUrl);
      expect(args['useSafariVC'], isFalse);
      expect(args['useWebView'], isFalse);
    });
  }
}
