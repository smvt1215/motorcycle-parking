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
}
