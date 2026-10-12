import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/models/parking.dart';

final remoteRule = CityRule(
  city: '臺北市',
  vehicle: VehicleType.heavy,
  allowedSpaceTypes: const [SpaceType.heavyOnly],
  feeNote: '最新規則',
  exceptions: '',
  sourceUrl: 'https://example.gov.tw/rules',
  version: 42,
  effectiveDate: DateTime(2026, 10, 12),
);

class RecoveringRules extends RulesRepository {
  RecoveringRules() : super(null);
  bool offline = true;
  int calls = 0;
  @override
  Future<List<CityRule>> load() async {
    calls++;
    if (offline) throw StateError('offline');
    return [remoteRule];
  }
}

// Controls favorites synchronization independently of viewport requests.
class RecoveringStore extends AppStore {
  RecoveringStore(LocalRepository local, RecoveringRules rules)
    : super(local, null, rulesRepository: rules);
  bool offline = true;
  int favoritesCalls = 0;
  @override
  Future<void> loadFavorites() async {
    favoritesCalls++;
    if (offline) {
      error = favoritesWarning = '雲端收藏同步失敗，顯示本機收藏';
    } else {
      favoritesWarning = null;
      favorites = [
        ParkingSpot(
          id: 'recovered',
          name: '雲端收藏',
          lat: 25.03,
          lng: 121.56,
          city: '臺北市',
          spaceType: SpaceType.heavyOnly,
        ),
      ];
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('警示列重試會恢復規則與收藏，清除提示並更新畫面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final rules = RecoveringRules();
    final store = (await tester.runAsync(() async {
      final store = RecoveringStore(
        LocalRepository(await SharedPreferences.getInstance()),
        rules,
      );
      await store.init();
      return store;
    }))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: const ParkingApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('遠端規則讀取失敗，顯示內建規則'), findsOneWidget);
    rules.offline = store.offline = false;
    await tester.tap(find.byTooltip('重新整理'));
    await tester.pumpAndSettle();
    expect(store.rules, [remoteRule]);
    expect(store.favorites.single.id, 'recovered');
    expect(store.rulesWarning, isNull);
    expect(store.favoritesWarning, isNull);
    expect(store.error, isNull);
    expect(find.byTooltip('重新整理'), findsNothing);
  });

  test('重試仍斷線時維持後備資料與提示', () async {
    SharedPreferences.setMockInitialValues({});
    final rules = RecoveringRules();
    final store = RecoveringStore(
      LocalRepository(await SharedPreferences.getInstance()),
      rules,
    );
    addTearDown(store.dispose);
    await store.init();
    await store.init();
    expect(rules.calls, 2);
    expect(store.favoritesCalls, 2);
    expect(store.rules, isNotEmpty);
    expect(store.rulesWarning, isNotNull);
    expect(store.favoritesWarning, isNotNull);
    expect(store.spots, isNotEmpty);
  });
}
