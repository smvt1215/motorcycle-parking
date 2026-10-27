// Riders' on-site sightings (#154): the display rules, the map badge and
// the detail row. A sighting is never a count: no 「剩 N」, ever.
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/data/sighting_repository.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/sighting_display.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/report/sighting_sheet.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/rider_sighting.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'availability_fixtures.dart';
import 'availability_ui_test.dart' show openDetails, useSize;

RiderSighting seen(
  String spot,
  SightingState state, {
  int minutes = 8,
  int since = 8,
}) => RiderSighting(
  spotId: spot,
  state: state,
  latestAt: availabilityNow.subtract(Duration(minutes: minutes)),
  since: availabilityNow.subtract(Duration(minutes: since)),
);

Future<AppStore> sightingStore(
  List<ParkingSpot> spots,
  List<RiderSighting> sightings, {
  List<AvailabilitySnapshot> counts = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    parkingRepository: FixedParking(spots),
    availabilitySource: FakeAvailabilitySource(() => counts),
    sightingSource: FakeSightingSource(() => sightings),
    clock: () => availabilityNow,
  );
  await store.init();
  return store;
}

void main() {
  final now = availabilityNow;

  group('display rules', () {
    test('8 minutes ago, spaces: the canvas sentence', () {
      final line = sightingLine(seen('a', SightingState.available), now)!;
      expect(line.title, '8 分鐘前有騎士回報「有空位」');
      expect(line.caption, '車友目擊，不是官方即時資料；抵達時可能已變。');
    });

    test('full, and just now', () {
      expect(
        sightingLine(seen('a', SightingState.full, minutes: 0), now)!.title,
        '剛剛有騎士回報「停滿」',
      );
    });

    test('riders disagree: 近期回報不一致, no side taken', () {
      final line = sightingLine(
        seen('a', SightingState.conflict, minutes: 2, since: 5),
        now,
      )!;
      expect(line.title, '近期回報不一致');
      expect(line.caption, '5 分鐘內有人說有空位、有人說停滿');
    });

    test('shown for 30 minutes, then gone; a future time is not shown', () {
      expect(
        sightingLine(seen('a', SightingState.full, minutes: 30), now),
        isNotNull,
      );
      expect(
        sightingLine(seen('a', SightingState.full, minutes: 31), now),
        isNull,
      );
      expect(
        sightingLine(seen('a', SightingState.full, minutes: -5), now),
        isNull,
      );
      expect(sightingLine(null, now), isNull);
    });

    test('the map badge: 15 minutes, never for a conflict', () {
      expect(
        sightingBadge(seen('a', SightingState.available, minutes: 15), now),
        isTrue,
      );
      expect(
        sightingBadge(seen('a', SightingState.full, minutes: 16), now),
        isFalse,
      );
      expect(
        sightingBadge(seen('a', SightingState.conflict, minutes: 1), now),
        isFalse,
      );
    });

    test('never 「剩 N」 and never a count of spaces', () {
      for (final state in SightingState.values) {
        for (final minutes in [0, 1, 8, 15, 29]) {
          final line = sightingLine(
            seen('a', state, minutes: minutes, since: minutes + 1),
            now,
          )!;
          final text = '${line.title}${line.caption}';
          expect(text, isNot(contains('剩')));
          expect(text, isNot(contains('格')));
          expect(text, isNot(contains('官方即時：')));
        }
      }
    });
  });

  group('rows and refusals', () {
    test('spot_sightings rows; bad rows are dropped', () {
      final rows = sightingsFromRows([
        {
          'spot_id': 'official:x',
          'state': 'available',
          'latest_at': '2026-10-26T09:00:00Z',
          'since': '2026-10-26T08:58:00Z',
        },
        {'spot_id': 'b', 'state': 'maybe', 'latest_at': '2026-10-26T09:00:00Z'},
        {'spot_id': 'c', 'state': 'full'},
      ]);
      expect(rows.keys, ['official:x']);
      expect(rows['official:x']!.state, SightingState.available);
    });

    test('only spots stored in the backend can be sighted', () {
      expect(canSight(lotAt('official:abc', 0, 0)), isTrue);
      expect(
        canSight(
          lotAt('00000000-0000-4000-8000-000000000004', 0, 0, source: 'import'),
        ),
        isTrue,
      );
      expect(canSight(lotAt('tdx-1', 0, 0, source: 'tdx')), isFalse);
      expect(canSight(lotAt('demo-1', 0, 0, source: 'community')), isFalse);
    });

    test('refusals riders can act on have a sentence', () {
      expect(
        sightingRefusal(429, {'error': 'sighting too soon'}),
        '10 分鐘內已回報過這個停車點。',
      );
      expect(
        sightingRefusal(429, {'error': 'daily sighting limit reached'}),
        '今天的現場回報已達上限，明天再試。',
      );
      expect(
        sightingRefusal(403, {'error': 'sighting suspended'}),
        '現場回報暫停中，請稍後再試。',
      );
      expect(sightingRefusal(500, null), isNull);
    });

    test('kinds go out as the server names them', () {
      expect(SightingKind.values.map((k) => k.wire), [
        'available',
        'full',
        'closed',
      ]);
      expect(SightingKind.values.map((k) => k.label), [
        '剛看到有空位',
        '現場停滿',
        '無法停車／施工中',
      ]);
    });
  });

  group('map badge', () {
    testWidgets('16 px, alone or beside the space-kind badge', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Row(
            children: [
              SpotMarker(look: (EligibilityStatus.allowed, null), rider: true),
              SpotMarker(
                look: (EligibilityStatus.allowed, null),
                badge: SpaceBadge.heavyOnly,
                rider: true,
              ),
              SpotMarker(look: (EligibilityStatus.allowed, null)),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('rider-badge')), findsNWidgets(2));
      expect(
        tester.getSize(find.byKey(const ValueKey('rider-badge')).first),
        const Size(16, 16),
      );
      expect(find.byType(SpaceBadgeDot), findsOneWidget);
      // Beside the space badge, it takes the other corner.
      final both = find.byType(SpotMarker).at(1);
      final rider = tester.getCenter(
        find.descendant(
          of: both,
          matching: find.byKey(const ValueKey('rider-badge')),
        ),
      );
      final space = tester.getCenter(
        find.descendant(of: both, matching: find.byType(SpaceBadgeDot)),
      );
      expect(rider.dx, lessThan(space.dx));
    });

    testWidgets('on the map within 15 minutes, never with a number, and '
        'not where an official count shows', (tester) async {
      useSize(tester, 390);
      final spots = [
        lotAt('official:recent', -80, -60),
        lotAt('official:old', 80, -60),
        lotAt('official:mixed', -80, 100),
        lotAt('official:counted', 80, 100),
      ];
      final store = (await tester.runAsync(
        () => sightingStore(
          spots,
          [
            seen('official:recent', SightingState.available, minutes: 8),
            seen('official:old', SightingState.full, minutes: 20),
            seen('official:mixed', SightingState.conflict, minutes: 3),
            seen('official:counted', SightingState.available, minutes: 2),
          ],
          counts: [count('official:counted', AvailabilityVehicle.scooter)],
        ),
      ))!;
      // The provider disposes the store with the app.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [storeProvider.overrideWith((ref) => store)],
          child: const ParkingApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byKey(const ValueKey('rider-badge')), findsOneWidget);
      final marker = find.ancestor(
        of: find.byKey(const ValueKey('rider-badge')),
        matching: find.byType(SpotMarker),
      );
      expect(
        tester.getCenter(marker).dx,
        lessThan(tester.getCenter(find.byType(FlutterMap)).dx),
      );
      expect(find.textContaining('剩 12'), findsOneWidget);
      expect(find.textContaining('剩'), findsOneWidget);
    });
  });

  group('details', () {
    for (final width in [320.0, 390.0, 402.0, 820.0]) {
      testWidgets('the row and 回報現場狀況 at $width', (tester) async {
        useSize(tester, width, width > 700 ? 1180 : 844);
        final spot = lotAt(
          '00000000-0000-4000-8000-000000000004',
          0,
          0,
          source: 'community',
          type: SpaceType.paidMotorcycle,
        );
        final store = (await tester.runAsync(
          () => sightingStore([spot], [seen(spot.id, SightingState.available)]),
        ))!;
        addTearDown(store.dispose);
        await openDetails(tester, store, spot);
        // Where three stacked actions fill the peeking sheet, drag it up by
        // its heading.
        if (find.byKey(const ValueKey('rider-sighting')).evaluate().isEmpty) {
          await tester.drag(find.text(spot.name), const Offset(0, -500));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(find.text('8 分鐘前有騎士回報「有空位」'), findsOneWidget);
        expect(find.text(sightingCaption), findsOneWidget);
        expect(find.textContaining('剩'), findsNothing);
        final action = find.byKey(const ValueKey('sighting-action'));
        expect(action, findsOneWidget);
        expect(find.text('修改建議'), findsOneWidget);
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        final navigate = tester.getRect(find.text('導航到這裡'));
        final at = tester.getRect(action);
        if (width >= 568) {
          // A tablet's sheet (640 wide at most) fits all three in a row.
          expect(at.center.dy, closeTo(navigate.center.dy, 1));
        } else if (width >= 380) {
          // A phone: navigation keeps the first row to itself (canvas).
          expect(at.top, greaterThan(navigate.bottom));
          expect(
            tester.getCenter(find.text('修改建議')).dy,
            closeTo(at.center.dy, 1),
          );
        } else {
          // Too narrow for two in a row: only navigation stays pinned.
          expect(find.text('導航到這裡').hitTestable(), findsOneWidget);
        }
      });
    }

    testWidgets('the three choices; a sighting shows at once', (tester) async {
      useSize(tester, 390);
      final spot = lotAt(
        '00000000-0000-4000-8000-000000000004',
        0,
        0,
        source: 'community',
        type: SpaceType.paidMotorcycle,
      );
      final store = (await tester.runAsync(() => sightingStore([spot], [])))!;
      addTearDown(store.dispose);
      await openDetails(tester, store, spot);
      expect(find.byKey(const ValueKey('rider-sighting')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('sighting-action')));
      await tester.tap(find.byKey(const ValueKey('sighting-action')));
      await tester.pumpAndSettle();
      expect(find.byType(SightingChoices), findsOneWidget);
      for (final label in ['剛看到有空位', '現場停滿', '無法停車／施工中']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('sighting-full')));
      await tester.pumpAndSettle();
      expect(find.byType(SightingChoices), findsNothing);
      expect(find.text('剛剛有騎士回報「停滿」'), findsOneWidget);
    });

    testWidgets('無法停車／施工中 continues to the suggestion form', (tester) async {
      useSize(tester, 390);
      final spot = lotAt(
        '00000000-0000-4000-8000-000000000004',
        0,
        0,
        source: 'community',
        type: SpaceType.paidMotorcycle,
      );
      final store = (await tester.runAsync(() => sightingStore([spot], [])))!;
      addTearDown(store.dispose);
      await openDetails(tester, store, spot);
      await tester.ensureVisible(find.byKey(const ValueKey('sighting-action')));
      await tester.tap(find.byKey(const ValueKey('sighting-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sighting-closed')));
      await tester.pumpAndSettle();
      expect(find.text('這裡已經不能停車'), findsWidgets);
      expect(find.text('施工中'), findsOneWidget);
    });
  });
}
