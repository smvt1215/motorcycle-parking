import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('待審數使用 pending 篩選與精確 count，不下載回報內容', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-test',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          '',
          200,
          headers: {'content-range': '0-6/7'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    final count = await SupabaseAdminGateway(client).pendingCount();
    expect(count, 7);
    expect(requests.single.method, 'HEAD');
    expect(requests.single.url.path, '/rest/v1/moderation_queue');
    expect(requests.single.url.queryParameters['status'], 'eq.pending');
    expect(requests.single.headers['Prefer'], contains('count=exact'));
  });

  test('審核頁與點位表單經 admin_spot_rows 讀取完整欄位（含計費規則與原始公告文字）', () async {
    final calls = <(String, Object?)>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-test',
      httpClient: MockClient((request) async {
        calls.add((request.url.path, jsonDecode(request.body)));
        return http.Response(
          jsonEncode([
            {
              'source_id': '11111111-1111-4111-8111-111111111111',
              'id': '11111111-1111-4111-8111-111111111111',
              'name': '甲',
              'fee_plans': <Object?>[],
              'fee_source_text': '原文',
            },
          ]),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final gateway = SupabaseAdminGateway(client);
    final spots = await gateway.reviewSpots([
      '11111111-1111-4111-8111-111111111111',
      'official:22222222-2222-4222-8222-222222222222',
      'not-an-id',
    ]);
    expect(calls.single.$1, '/rest/v1/rpc/admin_spot_rows');
    expect((calls.single.$2! as Map)['p_source_ids'], [
      '11111111-1111-4111-8111-111111111111',
      'official:22222222-2222-4222-8222-222222222222',
    ]);
    expect(
      spots['11111111-1111-4111-8111-111111111111']!.values['fee_source_text'],
      '原文',
    );
    final record = await gateway.spot('11111111-1111-4111-8111-111111111111');
    expect(record!.values['fee_plans'], isEmpty);
    expect(await gateway.spot('nope'), isNull);
  });
}
