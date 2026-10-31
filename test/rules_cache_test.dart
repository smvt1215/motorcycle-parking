import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/data/rules_cache.dart';
import 'package:motorcycle_parking/domain/rules_display.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> rule(
  String city,
  String vehicle,
  int version,
  String fee,
) => {
  'city': city,
  'vehicle': vehicle,
  'allowed_space_types': ['heavyOnly', 'car'],
  'fee_note': fee,
  'exceptions': '',
  'source_url': 'https://example.gov.tw',
  'version': version,
  'effective_date': '2026-07-01',
};

CityRule pick(List<CityRule> rules, String city, VehicleType vehicle) =>
    rules.singleWhere((r) => r.city == city && r.vehicle == vehicle);

SupabaseClient remote(List<Map<String, dynamic>> rows) => SupabaseClient(
  'https://example.supabase.co',
  'anon',
  httpClient: MockClient(
    (request) async => http.Response(
      jsonEncode(rows),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    ),
  ),
);

/// Always offline, with the cache the app would use.
class OfflineRepository extends RulesRepository {
  OfflineRepository(RulesCache cache) : super(null, cache: cache);
  @override
  Future<List<CityRule>> load() async => throw StateError('offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final downloaded = DateTime.utc(2026, 10, 29, 17); // 10月30日 in Taiwan.
  RulesCache cacheIn(Directory d) =>
      RulesCache(directory: () async => d, clock: () => downloaded);
  File cacheFile() => File('${dir.path}/${RulesCache.fileName}');
  void writeCache(Object json) =>
      cacheFile().writeAsStringSync(json is String ? json : jsonEncode(json));
  Map<String, dynamic> cacheJson(List<Map<String, dynamic>> rows) => {
    'schema': RulesCache.schema,
    'downloaded_at': downloaded.toIso8601String(),
    'rules': rows,
  };

  setUp(() => dir = Directory.systemTemp.createTempSync('rules_cache_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('遠端讀取成功時把合併後的規則寫入快取，並帶 schema 與下載時間', () async {
    final rules = await RulesRepository(
      remote([rule('臺北市', 'heavy', 7, '遠端費率')]),
      cache: cacheIn(dir),
    ).load();
    expect(pick(rules, '臺北市', VehicleType.heavy).feeNote, '遠端費率');

    final json = jsonDecode(cacheFile().readAsStringSync()) as Map;
    expect(json['schema'], RulesCache.schema);
    expect(DateTime.parse(json['downloaded_at'] as String), downloaded);
    expect((json['rules'] as List).length, rules.length);
    expect(File('${cacheFile().path}.tmp').existsSync(), isFalse);

    final offline = await offlineRules(cacheIn(dir));
    expect(pick(offline.rules, '臺北市', VehicleType.heavy).feeNote, '遠端費率');
    expect(offline.cachedAt, downloaded);
  });

  test('再次下載以新內容取代舊快取', () async {
    final cache = cacheIn(dir);
    await RulesRepository(
      remote([rule('臺北市', 'heavy', 7, '第一次')]),
      cache: cache,
    ).load();
    await RulesRepository(
      remote([rule('臺北市', 'heavy', 8, '第二次')]),
      cache: cache,
    ).load();
    final offline = await offlineRules(cache);
    expect(pick(offline.rules, '臺北市', VehicleType.heavy).feeNote, '第二次');
  });

  test('離線且有快取：使用快取，提示上次下載日期', () async {
    writeCache(cacheJson([rule('臺北市', 'heavy', 5, '快取費率')]));
    final offline = await offlineRules(cacheIn(dir));
    expect(pick(offline.rules, '臺北市', VehicleType.heavy).feeNote, '快取費率');
    // Rules the cache lacks still come from the bundled file.
    expect(pick(offline.rules, '高雄市', VehicleType.heavy).version, 2);
    expect(offline.cachedAt, downloaded);
    expect(rulesFallbackWarning(offline.cachedAt), '離線，使用上次下載的規則（10月30日）');
  });

  test('離線且沒有快取：使用內建規則', () async {
    final offline = await offlineRules(cacheIn(dir));
    final bundled = await RulesRepository(null).load();
    expect(offline.rules.map((r) => (r.city, r.vehicle, r.version)), [
      for (final r in bundled) (r.city, r.vehicle, r.version),
    ]);
    expect(offline.cachedAt, isNull);
    expect(rulesFallbackWarning(offline.cachedAt), bundledRulesWarning);
    expect((await offlineRules(null)).cachedAt, isNull);
  });

  test('快取比內建舊：逐條取版本較新的一份，同版本用快取', () async {
    writeCache(
      cacheJson([
        // staging serves version 1 while the bundled New Taipei rule is 2.
        rule('新北市', 'heavy', 1, '快取舊費率'),
        rule('臺北市', 'heavy', 1, '快取同版'),
      ]),
    );
    final offline = await offlineRules(cacheIn(dir));
    final newTaipei = pick(offline.rules, '新北市', VehicleType.heavy);
    expect(newTaipei.version, 2);
    expect(newTaipei.feeNote, isNot('快取舊費率'));
    expect(pick(offline.rules, '臺北市', VehicleType.heavy).feeNote, '快取同版');
    expect(offline.cachedAt, downloaded);
  });

  test('快取 v1、內建 v2：用內建，提示也說內建', () async {
    writeCache(cacheJson([rule('新北市', 'heavy', 1, '快取舊費率')]));
    final offline = await offlineRules(cacheIn(dir));
    expect(pick(offline.rules, '新北市', VehicleType.heavy).version, 2);
    expect(offline.cachedAt, isNull);
    expect(rulesFallbackWarning(offline.cachedAt), bundledRulesWarning);
  });

  for (final (name, content) in [
    ('不是 JSON', '{"schema": 1, "rules": ['),
    (
      'schema 不符',
      jsonEncode({
        'schema': 99,
        'downloaded_at': '2026-10-29T17:00:00Z',
        'rules': <Object>[],
      }),
    ),
    (
      '規則欄位錯誤',
      jsonEncode({
        'schema': 1,
        'downloaded_at': '2026-10-29T17:00:00Z',
        'rules': [
          {'city': '臺北市'},
        ],
      }),
    ),
    ('沒有下載時間', jsonEncode({'schema': 1, 'rules': <Object>[]})),
    ('最外層不是物件', '[]'),
  ]) {
    test('快取檔損毀（$name）：刪檔並退回內建', () async {
      writeCache(content);
      final offline = await offlineRules(cacheIn(dir));
      expect(offline.rules, isNotEmpty);
      expect(offline.cachedAt, isNull);
      expect(cacheFile().existsSync(), isFalse);
    });
  }

  test('快取目錄取不到時退回內建，不刪任何檔案', () async {
    final offline = await offlineRules(
      RulesCache(directory: () async => throw const FileSystemException('x')),
    );
    expect(offline.rules, isNotEmpty);
    expect(offline.cachedAt, isNull);
  });

  test('寫入失敗不影響遠端規則載入', () async {
    // The "directory" is a file, so neither the temporary file nor the
    // rename can succeed.
    final blocker = File('${dir.path}/blocker')..writeAsStringSync('');
    final unwritable = RulesRepository(
      remote([rule('臺北市', 'heavy', 7, '遠端費率')]),
      cache: RulesCache(directory: () async => Directory(blocker.path)),
    );
    final rules = await unwritable.load();
    expect(pick(rules, '臺北市', VehicleType.heavy).feeNote, '遠端費率');

    final noDirectory = RulesRepository(
      remote([rule('臺北市', 'heavy', 7, '遠端費率')]),
      cache: RulesCache(directory: () async => throw StateError('no dir')),
    );
    expect(pick(await noDirectory.load(), '臺北市', VehicleType.heavy).version, 7);
  });

  test('寫入失敗時保留舊快取', () async {
    writeCache(cacheJson([rule('臺北市', 'heavy', 5, '舊快取')]));
    // A directory where the temporary file should go makes the write fail.
    Directory('${cacheFile().path}.tmp').createSync();
    await cacheIn(dir).write([rule('臺北市', 'heavy', 6, '新快取')]);
    final offline = await offlineRules(cacheIn(dir));
    expect(pick(offline.rules, '臺北市', VehicleType.heavy).feeNote, '舊快取');
  });

  group('AppStore 離線載入', () {
    Future<AppStore> offlineStore(RulesCache cache) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        rulesRepository: OfflineRepository(cache),
      );
      await store.init();
      return store;
    }

    test('有快取時使用快取並顯示下載日期的提示', () async {
      writeCache(cacheJson([rule('臺北市', 'heavy', 5, '快取費率')]));
      final store = await offlineStore(cacheIn(dir));
      addTearDown(store.dispose);
      expect(pick(store.rules, '臺北市', VehicleType.heavy).feeNote, '快取費率');
      expect(store.rulesWarning, '離線，使用上次下載的規則（10月30日）');
    });

    test('快取損毀時不當掉，退回內建並顯示內建提示', () async {
      writeCache('not json');
      final store = await offlineStore(cacheIn(dir));
      addTearDown(store.dispose);
      expect(store.rules, isNotEmpty);
      expect(store.rulesWarning, bundledRulesWarning);
      expect(cacheFile().existsSync(), isFalse);
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('警示列顯示快取提示（${platform.name}）', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        writeCache(cacheJson([rule('臺北市', 'heavy', 5, '快取費率')]));
        final store = (await tester.runAsync(
          () => offlineStore(cacheIn(dir)),
        ))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: const ParkingApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('離線，使用上次下載的規則（10月30日）'), findsOneWidget);
        expect(find.text(bundledRulesWarning), findsNothing);
        expect(find.byTooltip('重新整理'), findsOneWidget);
        // The binding checks this before tear-downs run.
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
