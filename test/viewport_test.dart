import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/parking.dart';

const taipei = MapViewport(
  south: 25.03,
  west: 121.55,
  north: 25.04,
  east: 121.57,
);
const taichung = MapViewport(
  south: 24.14,
  west: 120.66,
  north: 24.16,
  east: 120.68,
);

class ControlledParking extends ParkingRepository {
  ControlledParking() : super(null);
  final requests = <(MapViewport, Completer<ParkingResult>)>[];
  @override
  Future<ParkingResult> inViewport(MapViewport bounds) {
    final result = Completer<ParkingResult>();
    requests.add((bounds, result));
    return result.future;
  }
}

class FailingRules extends RulesRepository {
  FailingRules() : super(null);
  @override
  Future<List<CityRule>> load() => Future.error(StateError('offline'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('收藏只保留仍可見的社群與匯入點位，官方點位不受影響', () {
    ParkingSpot fav(String id, String source) => ParkingSpot.fromJson({
      'id': id,
      'name': id,
      'city': '臺北市',
      'lat': 25.03,
      'lng': 121.56,
      'space_type': 'paidMotorcycle',
      'source': source,
    });
    final kept = visibleFavorites(
      [
        fav('visible', 'community'),
        fav('hidden', 'community'),
        fav('imported', 'import'),
        fav('removed-import', 'import'),
        fav('tdx:1', 'tdx'),
      ],
      {'visible', 'imported'},
    );
    expect(kept.map((s) => s.id), ['visible', 'imported', 'tdx:1']);
  });
  test('雲端收藏同步失敗的提示在停車資料更新後仍保留', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
    );
    addTearDown(store.dispose);
    await store.init();
    store.favoritesWarning = '雲端收藏同步失敗，顯示本機收藏';
    await store.refresh();
    expect(store.spots, isNotEmpty);
    expect(store.error, '雲端收藏同步失敗，顯示本機收藏');
  });
  test('遠端規則失敗時，停車資料更新後仍保留內建規則提示', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      rulesRepository: FailingRules(),
    );
    addTearDown(store.dispose);
    await store.init();
    expect(store.rules, isNotEmpty);
    expect(store.spots, isNotEmpty);
    expect(store.error, '遠端規則讀取失敗，顯示內建規則');
    await store.refresh();
    expect(store.error, '遠端規則讀取失敗，顯示內建規則');
  });
  test('範例資料只回傳畫面範圍內的點位，移至別處後不沿用臺北資料', () async {
    final repo = ParkingRepository(null);
    final local = await repo.inViewport(taipei);
    expect(local.spots, isNotEmpty);
    expect(local.spots.every((s) => taipei.contains(s.lat, s.lng)), isTrue);
    expect((await repo.inViewport(taichung)).spots, isEmpty);
  });
  testWidgets('停下450毫秒才查詢，過時回應不能覆蓋新範圍', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
    final repo = ControlledParking();
    final store = AppStore(
      LocalRepository(prefs),
      null,
      parkingRepository: repo,
    );
    addTearDown(store.dispose);
    store.queueViewport(taipei);
    await tester.pump(const Duration(milliseconds: 300));
    store.queueViewport(taichung);
    await tester.pump(const Duration(milliseconds: 449));
    expect(repo.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repo.requests.single.$1, taichung);
    store.queueViewport(taipei);
    await tester.pump(const Duration(milliseconds: 450));
    final spot = ParkingSpot.fromJson({
      'id': 'fresh',
      'name': '新範圍',
      'city': '臺北市',
      'lat': 25.035,
      'lng': 121.56,
      'space_type': 'paidMotorcycle',
      'status': 'pending',
      'source': 'community',
    });
    repo.requests.last.$2.complete(ParkingResult([spot]));
    await tester.pump();
    repo.requests.first.$2.complete(const ParkingResult([], warning: '舊回應'));
    await tester.pump();
    expect(store.spots.single.id, 'fresh');
    expect(store.error, isNull);
    expect(store.loading, isFalse);
  });
  test('整島縮放與非法座標不能觸發過大查詢', () {
    expect(
      const MapViewport(south: 20, west: 118, north: 27, east: 123).canQuery,
      isFalse,
    );
    expect(
      const MapViewport(south: 25, west: 122, north: 25.1, east: 121).canQuery,
      isFalse,
    );
    expect(
      MapViewport(south: double.nan, west: 121, north: 25, east: 122).canQuery,
      isFalse,
    );
  });
}
