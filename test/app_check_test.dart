import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/core/app_check.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  tearDown(() => AppCheck.debugSource = null);

  group('fetchAppCheckToken', () {
    test('returns the token', () async {
      expect(await fetchAppCheckToken(() async => 'token-1'), 'token-1');
    });

    test('is null without a source, a token or an empty token', () async {
      expect(await fetchAppCheckToken(null), isNull);
      expect(await fetchAppCheckToken(() async => null), isNull);
      expect(await fetchAppCheckToken(() async => ''), isNull);
    });

    test('gives up after the timeout', () async {
      final never = Completer<String?>();
      final stopwatch = Stopwatch()..start();
      final token = await fetchAppCheckToken(
        () => never.future,
        timeout: const Duration(milliseconds: 50),
      );
      expect(token, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('defaults to a three second timeout', () {
      expect(AppCheck.timeout, const Duration(seconds: 3));
    });

    test('swallows errors, thrown or asynchronous', () async {
      expect(await fetchAppCheckToken(() => throw StateError('x')), isNull);
      expect(
        await fetchAppCheckToken(() async => throw Exception('network')),
        isNull,
      );
    });
  });

  group('AppCheck', () {
    test('headers carry the token, or are null without one', () async {
      expect(await AppCheck.headers(() async => 'abc'), {
        'X-Firebase-AppCheck': 'abc',
      });
      expect(await AppCheck.headers(() async => null), isNull);
    });

    test('starts switched off without the Firebase dart-defines', () async {
      // Tests run without --dart-define, like local runs and PR CI.
      expect(appCheckOptions(), isNull);
      await AppCheck.start();
      expect(await AppCheck.token(), isNull);
      expect(await AppCheck.headers(), isNull);
    });

    test('options need every value and a mobile platform', () {
      String? check({
        String apiKey = 'key',
        bool web = false,
        TargetPlatform platform = TargetPlatform.android,
      }) => appCheckOptions(
        apiKey: apiKey,
        appId: '1:123:android:abc',
        messagingSenderId: '123',
        projectId: 'demo',
        web: web,
        platform: platform,
      )?.projectId;

      expect(check(), 'demo');
      expect(check(platform: TargetPlatform.iOS), 'demo');
      expect(check(apiKey: ''), isNull);
      expect(check(web: true), isNull);
      expect(check(platform: TargetPlatform.linux), isNull);
    });

    test('token reads the active source', () async {
      AppCheck.debugSource = () async => 'live';
      expect(await AppCheck.token(), 'live');
    });
  });

  group('submit-report', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<http.Request> send(AppCheckTokenSource token) async {
      late http.Request sent;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'anon',
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({'id': 'r1'}),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      await ParkingRepository(
        client,
        appCheckToken: token,
      ).report({'type': 'new_spot'});
      return sent;
    }

    test('sends the App Check token in its header', () async {
      final request = await send(() async => 'app-check-token');
      expect(request.url.path, '/functions/v1/submit-report');
      expect(request.headers['x-firebase-appcheck'], 'app-check-token');
    });

    test('goes out without the header when there is no token', () async {
      for (final AppCheckTokenSource token in [
        () async => null,
        () async => throw Exception('attestation failed'),
      ]) {
        final request = await send(token);
        expect(request.url.path, '/functions/v1/submit-report');
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-firebase-appcheck')),
        );
      }
    });
  });
}
