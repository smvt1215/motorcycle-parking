import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #120: the details say whether a time slot holds now, and follow the
/// clock while open.
void main() {
  final spot = ParkingSpot(
    id: 'slot',
    name: '夜間重機格',
    lat: 25.0339,
    lng: 121.5623,
    city: '臺北市',
    district: '信義區',
    spaceType: SpaceType.heavyOnly,
    source: 'official',
    condition: ParkingCondition.fromJson({
      'bay': 'heavy',
      'use': 'usual',
      'schedule': [
        {
          'days': 'weekday',
          'from': '20:00',
          'to': '07:00',
          'vehicles': ['heavy'],
        },
      ],
    }),
  );

  testWidgets('詳情開著跨過時段開始時，下一分鐘改成現在可停', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 2026-11-03 (Tuesday) 19:59:30 in Taiwan.
    var now = DateTime.utc(2026, 11, 3, 11, 59, 30);
    final store = (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({'vehicle': 'heavy'});
      final store = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        clock: () => now,
      );
      await store.init();
      return store;
    }))!;
    addTearDown(store.dispose);
    store.vehicle = VehicleType.heavy;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpot(context, store, spot),
              child: const Text('開啟點位'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟點位'));
    await tester.pumpAndSettle();
    expect(find.textContaining('現在不可停，20:00 起可停'), findsWidgets);
    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(find.textContaining('現在不可停'), findsNothing);
    expect(find.textContaining('現在可停'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
