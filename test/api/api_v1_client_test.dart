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
    'availability_beta_cities': ['臺北市'],
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
          availabilityBetaCities: ['臺北市'],
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
    // The Beta cities compare by content, not by list identity.
    final again = ClientConfig.fromJson({
      ...served,
      'availability_beta_cities': ['臺北市'],
    });
    expect(again, config);
    expect(again.hashCode, config.hashCode);
    expect(
      config ==
          ClientConfig.fromJson({...served, 'availability_beta_cities': []}),
      isFalse,
    );
  });

  const rules = {
    'rules_version': 25,
    'rules': [
      {
        'city': '臺北市',
        'vehicle': 'heavy',
        'allowed_space_types': ['heavyOnly'],
        'conditional_space_types': ['paidMotorcycle'],
        'district_space_types': {
          'freeMotorcycle': ['信義區'],
        },
        'districts': <String>[],
        'restriction': 'pilot_area',
        'fee_note': '請依現場收費公告',
        'exceptions': '',
        'can_use_two_spaces': false,
        'effective_date': '2026-10-11',
        'expires_on': null,
        'source_url': 'https://example.test/rule',
        'version': 3,
      },
    ],
  };

  test('city_rules reads every rule with the overall version', () async {
    final api = clientAnswering(200, rules);
    final read = await api.cityRules();
    expect(requests.single.url.path, '/rest/v1/rpc/city_rules');
    expect(read.rulesVersion, 25);
    final rule = read.rules.single;
    expect(rule.city, '臺北市');
    expect(rule.restriction, 'pilot_area');
    expect(rule.expiresOn, isNull);
    expect(rule.districtSpaceTypes, {
      'freeMotorcycle': ['信義區'],
    });
    expect(read.toJson(), rules);
    // The rules cache (#202) keeps the JSON exactly as served.
    expect(await clientAnswering(200, rules).cityRulesRaw(), rules);
  });

  test(
    'spots_in_viewport sends the box and keeps contract JSON as served',
    () async {
      const viewport = {
        'spots': [
          {
            'id': 'official:1',
            'source': 'official',
            'name': '官方點',
            'lat': 25.04,
            'lng': 121.51,
            'fee': {
              'scooter': {'mode': 'free'},
            },
            'parking_segments': null,
          },
        ],
        'truncated': false,
        'official_unavailable': false,
      };
      final api = clientAnswering(200, viewport);
      final read = await api.spotsInViewport(
        south: 25.03,
        west: 121.5,
        north: 25.06,
        east: 121.53,
      );
      expect(jsonDecode(requests.single.body), {
        'south': 25.03,
        'west': 121.5,
        'north': 25.06,
        'east': 121.53,
      });
      final spot = read.spots.single;
      expect(spot.id, 'official:1');
      expect(spot.fee, {
        'scooter': {'mode': 'free'},
      });
      expect(read.officialUnavailable, isFalse);
      expect(read, SpotsInViewport.fromJson(viewport));
    },
  );
}
