import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const bounds = MapViewport(
    south: 25.02,
    west: 121.55,
    north: 25.04,
    east: 121.57,
  );
  Map<String, dynamic> row(String id, String type) => {
    'id': id,
    'name': id,
    'lat': 25.03,
    'lng': 121.56,
    'city': '臺北市',
    'space_type': type,
  };

  /// A backend with the viewport RPCs up to [version] (1 = the originals).
  Future<(List<String>, List<ParkingSpot>)> load({required int version}) async {
    final called = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      httpClient: MockClient((request) async {
        final name = request.url.pathSegments.last;
        called.add(name);
        final v = name.endsWith('_v3')
            ? 3
            : name.endsWith('_v2')
            ? 2
            : 1;
        if (v > version) {
          return http.Response(
            jsonEncode({'code': 'PGRST202', 'message': 'not found'}),
            404,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        final rows = name.startsWith('official')
            ? <Map<String, dynamic>>[]
            : [
                row('a', 'paidMotorcycle'),
                if (v >= 2) row('b', 'evMotorcycle'),
                // A free timed bay: as stored in v3, projected in v2.
                if (v == 3)
                  {
                    ...row('c', 'timedMotorcycle'),
                    'condition': {
                      'bay': 'motorcycle',
                      'use': 'usual',
                      'charge': 'free',
                      'limits': [
                        {'kind': 'time_limit'},
                      ],
                    },
                  },
                if (v == 2) {...row('c', 'offStreet'), 'status': 'pending'},
              ];
        return http.Response(
          jsonEncode(rows),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    final result = await ParkingRepository(client).inViewport(bounds);
    return (called, result.spots);
  }

  test('新版讀取 _v3 RPC，取得停放條件', () async {
    final (called, spots) = await load(version: 3);
    expect(
      called,
      containsAll(['viewport_spots_v3', 'official_viewport_spots_v3']),
    );
    expect(called, isNot(contains('viewport_spots_v2')));
    expect(spots.map((s) => s.id), ['a', 'b', 'c']);
    final c = spots.last;
    expect(c.spaceType, SpaceType.timedMotorcycle);
    expect(c.condition?.charge, Charge.free);
  });

  test('後端只有 _v2 時退回 _v2，讀到保守投影', () async {
    final (called, spots) = await load(version: 2);
    expect(called, containsAll(['viewport_spots_v3', 'viewport_spots_v2']));
    expect(called, isNot(contains('viewport_spots')));
    expect(spots.map((s) => s.id), ['a', 'b', 'c']);
    expect(spots.last.spaceType, SpaceType.offStreet);
    expect(spots.last.condition, isNull);
  });

  test('後端尚未套用 migration 時退回原 RPC', () async {
    final (called, spots) = await load(version: 1);
    expect(
      called,
      containsAll([
        'viewport_spots_v3',
        'viewport_spots_v2',
        'viewport_spots',
        'official_viewport_spots',
      ]),
    );
    expect(spots.map((s) => s.id), ['a']);
  });
}
