import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
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

  Future<(List<String>, List<String>)> load({required bool migrated}) async {
    final called = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon',
      httpClient: MockClient((request) async {
        final name = request.url.pathSegments.last;
        called.add(name);
        if (name.endsWith('_v2') && !migrated) {
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
                if (name.endsWith('_v2')) row('b', 'evMotorcycle'),
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
    return (called, result.spots.map((s) => s.id).toList());
  }

  test('新版讀取 _v2 RPC，取得所有格位種類', () async {
    final (called, ids) = await load(migrated: true);
    expect(
      called,
      containsAll(['viewport_spots_v2', 'official_viewport_spots_v2']),
    );
    expect(ids, ['a', 'b']);
  });

  test('後端尚未套用 migration 時退回原 RPC', () async {
    final (called, ids) = await load(migrated: false);
    expect(
      called,
      containsAll([
        'viewport_spots_v2',
        'viewport_spots',
        'official_viewport_spots',
      ]),
    );
    expect(ids, ['a']);
  });
}
