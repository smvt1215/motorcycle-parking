import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/features/map/availability_capsule.dart';
import 'package:motorcycle_parking/features/map/space_type_sheet.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/space_kind.dart';

import 'availability_fixtures.dart';

const _lat = 25.0339, _lng = 121.5623;

/// A spot [dx], [dy] pixels from the map centre at zoom 16; a street bay
/// unless [lot].
ParkingSpot _spot(
  String id,
  SpaceType type,
  double dx,
  double dy, {
  bool lot = false,
}) => ParkingSpot(
  id: id,
  name: '篩選 $id',
  lat: _lat - dy * 1.95e-5,
  lng: _lng + dx * 2.15e-5,
  city: '臺北市',
  district: '信義區',
  spaceType: type,
  facilityType: lot ? FacilityType.underground : null,
  source: 'official',
  status: TrustStatus.confirmed,
  scooterAllowed: lot ? true : null,
  scooterTotal: lot ? 80 : null,
  updatedAt: DateTime(2026, 10, 20),
);

/// For a scooter: a toll motorcycle bay (可停), a heavy-only bay and a car
/// bay (不能停) and a lot with a fresh count.
final _spots = [
  _spot('機車', SpaceType.paidMotorcycle, -120, -60),
  _spot('重機', SpaceType.heavyOnly, 120, -60),
  _spot('汽車', SpaceType.car, -120, 120),
  _spot('場站', SpaceType.offStreet, 120, 120, lot: true),
];

final _counts = [count('場站', AvailabilityVehicle.scooter)];

Finder _marker(String id) => find.descendant(
  of: find.byType(FlutterMap),
  matching: find.byWidgetPredicate(
    (w) => w is Semantics && (w.properties.label ?? '').startsWith('篩選 $id '),
  ),
);

/// Which of the four spots the map shows.
Set<String> _shown() => {
  for (final id in ['機車', '重機', '汽車', '場站'])
    if (_marker(id).evaluate().isNotEmpty) id,
};

Finder _chip(String key) => find.byKey(ValueKey(key));

bool? _toggled(WidgetTester tester, String key) => tester
    .widget<Semantics>(
      find.descendant(of: _chip(key), matching: find.byType(Semantics)).first,
    )
    .properties
    .toggled;

Future<AppStore> _pump(WidgetTester tester) async {
  final store = (await tester.runAsync(
    () => availabilityStore(_spots, _counts),
  ))!;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  return store;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    final minHeight = platform == TargetPlatform.iOS ? 44.0 : 48.0;
    for (final size in const [
      Size(390, 844),
      Size(820, 1180),
      Size(1180, 820),
    ]) {
      final name =
          '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';

      void setUp(WidgetTester tester) {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      testWidgets('$name 篩選列：車種、現在可停、有即時空位可點並切換', (tester) async {
        setUp(tester);
        // The Beta tag is set in Outfit; the test font's wide glyphs would
        // push the third chip out of a phone's width.
        final outfit = FontLoader('Outfit')
          ..addFont(rootBundle.load('assets/fonts/Outfit.ttf'));
        await tester.runAsync(outfit.load);
        await _pump(tester);
        expect(_shown(), {'機車', '重機', '汽車', '場站'});
        // Main: the three chips lead, at the platform's touch height, in
        // view without scrolling.
        final keys = [
          'vehicle-filter',
          'parkable-filter',
          'availability-filter',
        ];
        final labels = ['普通機車', '現在可停', '有即時空位'];
        for (final (i, key) in keys.indexed) {
          final chip = _chip(key);
          expect(chip, findsOneWidget);
          expect(
            find.descendant(of: chip, matching: find.text(labels[i])),
            findsOneWidget,
          );
          final rect = tester.getRect(chip);
          expect(rect.height, minHeight);
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(chip.hitTestable(), findsOneWidget);
        }
        expect(
          tester.getRect(_chip(keys[0])).left,
          lessThan(tester.getRect(_chip(keys[1])).left),
        );
        expect(
          tester.getRect(_chip(keys[1])).left,
          lessThan(tester.getRect(_chip(keys[2])).left),
        );
        expect(_chip('clear-filters'), findsNothing);

        // 現在可停 hides what a scooter may not park at.
        expect(_toggled(tester, 'parkable-filter'), isFalse);
        await _tap(tester, _chip('parkable-filter'));
        expect(_toggled(tester, 'parkable-filter'), isTrue);
        expect(_shown(), {'機車', '場站'});
        expect(_chip('clear-filters'), findsOneWidget);
        await _tap(tester, _chip('parkable-filter'));
        expect(_toggled(tester, 'parkable-filter'), isFalse);
        expect(_shown(), {'機車', '重機', '汽車', '場站'});

        // 有即時空位 keeps the lot with a fresh count; street bays turn
        // into grey dots.
        expect(_toggled(tester, 'availability-filter'), isFalse);
        await _tap(tester, _chip('availability-filter'));
        expect(_toggled(tester, 'availability-filter'), isTrue);
        expect(_shown(), {'場站'});
        expect(find.byType(ExcludedSpotDot), findsNWidgets(3));
        await _tap(tester, _chip('availability-filter'));
        expect(_toggled(tester, 'availability-filter'), isFalse);
        expect(find.byType(ExcludedSpotDot), findsNothing);

        // The vehicle chip opens the vehicle sheet.
        await _tap(tester, _chip('vehicle-filter'));
        expect(find.text('大型重機'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('$name P1 格位複選：空集合等於全部格位', (tester) async {
        setUp(tester);
        await _pump(tester);
        final space = _chip('space-filter');
        expect(
          find.descendant(of: space, matching: find.text('全部格位')),
          findsOneWidget,
        );
        expect(tester.getRect(space).height, minHeight);
        await _tap(tester, space);

        expect(find.text('可複選，只顯示選定類型的停車點。'), findsOneWidget);
        expect(find.bySemanticsLabel('格位類型，可複選'), findsOneWidget);
        // 全部格位, the seven bay kinds and the lot, in order.
        final rows = [
          const ValueKey('space-multi-all'),
          for (final kind in SpaceKind.values)
            ValueKey('space-multi-${kind.name}'),
        ];
        var top = double.negativeInfinity;
        for (final key in rows) {
          final row = find.byKey(key);
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          final rect = tester.getRect(row);
          expect(rect.height, greaterThanOrEqualTo(60));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(row.hitTestable(), findsOneWidget);
          expect(tester.getTopLeft(row).dy, isNot(lessThan(top)));
          top = tester.getTopLeft(row).dy;
        }
        expect(
          [
            for (final kind in SpaceKind.values)
              tester
                  .widget<Text>(
                    find
                        .descendant(
                          of: find.byKey(ValueKey('space-multi-${kind.name}')),
                          matching: find.byType(Text),
                        )
                        .first,
                  )
                  .data,
          ],
          ['一般機車格', '普大共用格', '重機專用格', '汽機車共用格', '汽車格', '身障格', '充電格', '停車場'],
        );
        // No shortcut for the rider's own vehicle.
        expect(find.textContaining('我的車種'), findsNothing);
        expect(find.byType(SpaceKindMultiList), findsOneWidget);
        expect(find.byType(SpaceKindList), findsNothing);

        bool checked(String name) => isSemantics(isChecked: true).matches(
          tester.getSemantics(find.byKey(ValueKey('space-multi-$name'))),
          {},
        );
        expect(checked('all'), isTrue);
        expect(find.textContaining('顯示全部格位。'), findsOneWidget);

        // Two kinds at once; the sheet stays open.
        await _tap(
          tester,
          find.byKey(const ValueKey('space-multi-motorcycle')),
        );
        await _tap(tester, find.byKey(const ValueKey('space-multi-offStreet')));
        expect(checked('all'), isFalse);
        expect(checked('motorcycle'), isTrue);
        expect(checked('offStreet'), isTrue);
        expect(checked('heavy'), isFalse);
        expect(find.textContaining('已選 2 類。'), findsOneWidget);
        expect(find.textContaining('數字是目前地圖範圍內的數量。'), findsOneWidget);
        expect(_shown(), {'機車', '場站'});
        await _tap(tester, find.byTooltip('關閉'));
        expect(
          find.descendant(of: space, matching: find.text('格位 2 類')),
          findsOneWidget,
        );
        expect(_shown(), {'機車', '場站'});

        // 全部格位 clears the picks.
        await _tap(tester, space);
        await _tap(tester, find.byKey(const ValueKey('space-multi-all')));
        expect(checked('all'), isTrue);
        expect(checked('motorcycle'), isFalse);
        expect(_shown(), {'機車', '重機', '汽車', '場站'});

        // Unpicking the last kind returns to 全部格位.
        await _tap(tester, find.byKey(const ValueKey('space-multi-heavy')));
        expect(_shown(), {'重機'});
        await _tap(tester, find.byKey(const ValueKey('space-multi-heavy')));
        expect(checked('all'), isTrue);
        expect(_shown(), {'機車', '重機', '汽車', '場站'});
        await _tap(tester, find.byTooltip('關閉'));
        expect(
          find.descendant(of: space, matching: find.text('全部格位')),
          findsOneWidget,
        );
        expect(_chip('clear-filters'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('${platform.name} 大字級時篩選列加高、不溢出', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 2.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester);
      final chip = _chip('parkable-filter');
      expect(tester.getRect(chip).height, greaterThan(minHeight));
      await _tap(tester, chip);
      await _tap(tester, _chip('space-filter'));
      await _tap(tester, find.byKey(const ValueKey('space-multi-disabled')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
