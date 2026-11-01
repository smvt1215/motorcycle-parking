import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/api/v1/api_v1.g.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The generated api_v1 client (tool/gen_api_dart.py, #195 P1) against a
/// fake PostgREST.
void main() {
  late List<http.Request> requests;

  ApiV1Client clientAnswering(
    int status,
    Object body, {
    Future<Map<String, String>> Function()? headers,
  }) {
    requests = [];
    final supabase = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    return ApiV1Client(supabase, headers: headers);
  }

  const served = {
    'min_supported_app_version': '0.1.0',
    'rules_version': 25,
    'spots_version': 808,
  };

  test(
    'calls the RPC in the api_v1 schema and reads the typed result',
    () async {
      final api = clientAnswering(200, served);
      final config = await api.clientConfig();

      expect(
        config,
        const ClientConfig(
          minSupportedAppVersion: '0.1.0',
          rulesVersion: 25,
          spotsVersion: 808,
        ),
      );
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/client_config');
      expect(request.headers['Content-Profile'], 'api_v1');
    },
  );

  test(
    'raw keeps the JSON as served, for caches that store rows (#202)',
    () async {
      final api = clientAnswering(200, served);
      expect(await api.clientConfigRaw(), served);
    },
  );

  test('sends the injected headers on every call (App Check, #203)', () async {
    var asked = 0;
    final api = clientAnswering(
      200,
      served,
      headers: () async {
        asked++;
        return {'X-Firebase-AppCheck': 'token-$asked'};
      },
    );
    await api.clientConfig();
    await api.clientConfig();
    expect(asked, 2);
    expect(requests.map((r) => r.headers['X-Firebase-AppCheck']), [
      'token-1',
      'token-2',
    ]);
  });

  test(
    'turns a PostgREST error into ApiV1Exception with the stable code',
    () async {
      final api = clientAnswering(403, {
        'code': 'PT403',
        'message': 'auth.aal2_required',
        'details': '{"reason":"x"}',
        'hint': null,
      });
      await expectLater(
        api.clientConfig(),
        throwsA(
          isA<ApiV1Exception>()
              .having((e) => e.code, 'code', 'PT403')
              .having((e) => e.message, 'message', 'auth.aal2_required'),
        ),
      );
    },
  );

  test('models round-trip through JSON and compare by value', () {
    final config = ClientConfig.fromJson(served);
    expect(config.toJson(), served);
    expect(config, ClientConfig.fromJson(Map.of(served)));
    expect(config.hashCode, ClientConfig.fromJson(Map.of(served)).hashCode);
    expect(
      config == ClientConfig.fromJson({...served, 'rules_version': 26}),
      isFalse,
    );
  });
}
