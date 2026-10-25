import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/cluster_badge.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

Future<AppStore> clusterStore(int count) async {
  SharedPreferences.setMockInitialValues({});
  final repository = ParkingRepository(null);
  for (var i = 0; i < count; i++) {
    repository.addDemo(
      ParkingSpot(
        id: '$i',
        name: '機車停車點 $i',
        lat: 25.0339 + i * .0001,
        lng: 121.5623 + i * .0001,
        city: '臺北市',
        spaceType: SpaceType.freeMotorcycle,
        scooterAllowed: true,
      ),
    );
  }
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    parkingRepository: repository,
  );
  await store.init();
  return store;
}

Future<AppStore> mountClusterMap(WidgetTester tester, int count) async {
  final store = (await tester.runAsync(() => clusterStore(count)))!;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('離線地圖四點保留個別標記且可選取', (tester) async {
    final store = await mountClusterMap(tester, 4);
    expect(find.byType(ClusterBadge), findsNothing);
    expect(find.byType(SpotMarker), findsNWidgets(4));
    final marker = find.byType(SpotMarker).last;
    await tester.tap(marker);
    await tester.pumpAndSettle();
    expect(find.text(store.spots.last.name), findsOneWidget);
    expect(find.byKey(const ValueKey('selected-spot-marker')), findsOneWidget);
    expect(find.byType(ClusterBadge), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('離線地圖五點顯示群聚，點選放大至詳細層級會拆回各點', (tester) async {
    await mountClusterMap(tester, 5);
    expect(find.byType(ClusterBadge), findsOneWidget);
    expect(tester.widget<ClusterBadge>(find.byType(ClusterBadge)).count, 5);
    await tester.tap(find.byType(ClusterBadge));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(FlutterMap));
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    controller.move(controller.camera.center, 20);
    await tester.pumpAndSettle();
    expect(context.mounted, isTrue);
    expect(find.byType(ClusterBadge), findsNothing);
    expect(find.byType(SpotMarker), findsNWidgets(5));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
