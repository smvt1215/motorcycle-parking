import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

class RecordingStore extends AppStore {
  RecordingStore(LocalRepository local) : super(local, null);
  final submissions = <Map<String, dynamic>>[];

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    submissions.add(body);
    return '已送交審核';
  }
}

void main() {
  Future<RecordingStore> openForm(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      // A known spot nearby fills in the city.
      return RecordingStore(
          LocalRepository(await SharedPreferences.getInstance()),
        )
        ..spots = const [
          ParkingSpot(
            id: 'near',
            name: '附近',
            lat: 25.0339,
            lng: 121.5623,
            city: '臺北市',
            spaceType: SpaceType.paidMotorcycle,
          ),
        ];
    }))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReport(context, store, 25.0339, 121.5623),
              child: const Text('新增'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    return store;
  }

  // The form's own list: the first scrollable in the sheet.
  final form = find.byType(Scrollable).first;

  Future<void> pickType(WidgetTester tester, SpaceType type) async {
    final tile = find.byKey(ValueKey('report-space-${type.name}'));
    // Back to the top of the form, where the picker is, then onto the tile.
    await tester.fling(form, const Offset(0, 2000), 3000);
    await tester.pumpAndSettle();
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<Map<String, dynamic>> send(
    WidgetTester tester,
    RecordingStore store,
  ) async {
    await tester.enterText(find.byType(TextFormField).first, '測試點');
    await tester.pumpAndSettle();
    // The button sits below the fold of a lazily built list.
    await tester.scrollUntilVisible(find.text('送出回報'), 200, scrollable: form);
    await tester.tap(find.text('送出回報'));
    await tester.pumpAndSettle();
    return store.submissions.single['spot'] as Map<String, dynamic>;
  }

  test('格位標線帶入的資格只寫出標線能確定的部分', () {
    expect(markedEligibility(SpaceType.paidMotorcycle), (
      scooter: true,
      heavy: null,
    ));
    expect(markedEligibility(SpaceType.heavyOnly), (
      scooter: false,
      heavy: true,
    ));
    expect(markedEligibility(SpaceType.car), (scooter: false, heavy: null));
    for (final type in [
      SpaceType.offStreet,
      SpaceType.disabledMotorcycle,
      SpaceType.flexShared,
      SpaceType.evMotorcycle,
    ]) {
      expect(markedEligibility(type), (scooter: null, heavy: null));
    }
  });

  testWidgets('依地面標線選格位，並帶入可停車種', (tester) async {
    final store = await openForm(tester);
    expect(find.byType(DropdownButtonFormField<SpaceType>), findsNothing);
    expect(find.text('地面畫的是哪一種格位？'), findsOneWidget);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('report-space-paidMotorcycle')),
      ),
      matchesSemantics(
        label: '路邊收費機車格',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
    await pickType(tester, SpaceType.offStreet);
    expect(find.textContaining('已依「路外停車場」帶入'), findsOneWidget);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'offStreet');
    // A lot's markings settle neither vehicle.
    expect(spot['scooter_allowed'], isNull);
    expect(spot['heavy_allowed'], isNull);
  });

  testWidgets('手動設定車種後，換格位不再覆蓋', (tester) async {
    final store = await openForm(tester);
    await pickType(tester, SpaceType.heavyOnly);
    final heavyAllowed = find.text('可停').last;
    await tester.ensureVisible(heavyAllowed);
    // Heavy-only bays already read "heavy: allowed"; the reporter overrides it.
    await tester.tap(find.text('未確認').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('已依'), findsNothing);
    await pickType(tester, SpaceType.paidMotorcycle);
    final spot = await send(tester, store);
    expect(spot['space_type'], 'paidMotorcycle');
    expect(spot['scooter_allowed'], false);
    expect(spot['heavy_allowed'], isNull);
  });
}
