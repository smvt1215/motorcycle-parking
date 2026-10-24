import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<CityRule>> load(List<Map<String, dynamic>> remote) =>
      RulesRepository(
        SupabaseClient(
          'https://example.supabase.co',
          'anon',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode(remote),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
              request: request,
            ),
          ),
        ),
      ).load();

  Map<String, dynamic> newTaipei(int version, String fee) => {
    'city': '新北市',
    'vehicle': 'heavy',
    'allowed_space_types': ['heavyOnly', 'car'],
    'fee_note': fee,
    'exceptions': '管理者修改',
    'source_url': 'https://example.gov.tw',
    'version': version,
    'effective_date': '2026-07-01',
  };
  CityRule heavy(List<CityRule> rules) => rules.firstWhere(
    (r) => r.city == '新北市' && r.vehicle == VehicleType.heavy,
  );

  test('遠端與內建同版本時採用管理者維護的遠端規則', () async {
    // The bundled New Taipei rule is version 2.
    expect(heavy(await load([newTaipei(2, '管理者費率')])).feeNote, '管理者費率');
    expect(heavy(await load([newTaipei(3, '更新費率')])).feeNote, '更新費率');
  });

  test('遠端版本較舊時保留內建規則', () async {
    expect(heavy(await load([newTaipei(1, '舊費率')])).feeNote, isNot('舊費率'));
  });
}
