import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
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

  test('審核頁讀取點位時包含每個可審核欄位', () async {
    final selects = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-test',
      httpClient: MockClient((request) async {
        selects.add(request.url.queryParameters['select'] ?? '');
        return http.Response('[]', 200, request: request);
      }),
    );
    addTearDown(client.dispose);
    await SupabaseAdminGateway(client).reviewSpots([
      '11111111-1111-4111-8111-111111111111',
      'official:22222222-2222-4222-8222-222222222222',
    ]);
    expect(selects, hasLength(2));
    for (final select in selects) {
      final columns = select.split(',');
      for (final field in reviewFields) {
        // Visibility is per table: status on community, hidden on official.
        if (field.key == 'status' || field.key == 'hidden') continue;
        expect(columns, contains(field.key), reason: select);
      }
    }
  });
}
