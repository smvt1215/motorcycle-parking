import 'package:flutter/foundation.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'availability_fixtures.dart' show FixedParking;

/// 「現在可停」 by the hour (#244): only the spots a scooter may park in
/// now stay, and the 能不能停 plate reads 現在禁停 during a 禁停 period.
const _lat = 25.0339, _lng = 121.5623;

/// 2026-11-03 (Tuesday) 10:00, 14:20 (禁停 14:00–15:00) and 21:00 in Taiwan.
final _morning = DateTime.utc(2026, 11, 3, 2);
final _banned = DateTime.utc(2026, 11, 3, 6, 20);
final _night = DateTime.utc(2026, 11, 3, 13);

/// A spot [dx], [dy] pixels from the map centre at zoom 16.
ParkingSpot _spot(String id, double dx, double dy, Map<String, dynamic> json) =>
    ParkingSpot.fromJson({
      'id': id,
      'name': '時段 $id',
      'lat': _lat - dy * 1.95e-5,
      'lng': _lng + dx * 2.15e-5,
      'city': '臺北市',
      'district': '信義區',
      'source': 'official',
      ...json,
    });

/// A toll motorcycle bay under 禁停 14:00–15:00 every day.
final _noParking = _spot('禁停', 120, -60, {
  'space_type': 'paidMotorcycle',
  'facility_type': 'roadside',
  'parking_segments': [
    {
      'id': 'n1',
      'name': '北側一般機車格',
      'side': 'north',
      'condition': {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'limits': [
          {
            'kind': 'no_parking',
            'periods': [
              {'days': 'all', 'from': '14:00', 'to': '15:00'},
            ],
          },
        ],
      },
    },
  ],
});

/// For a scooter: a toll bay open all day, the bay above, a lot open only
/// 20:00–23:00, a heavy-only bay (不能停) and a lot that does not say
/// whether scooters may park (待確認).
final _spots = [
  _spot('全天', -120, -60, {
    'space_type': 'paidMotorcycle',
    'facility_type': 'roadside',
  }),
  _noParking,
  _spot('夜間', -120, 120, {
    'space_type': 'offStreet',
    'facility_type': 'underground',
    'scooter_allowed': true,
    'condition': {
      'bay': 'car',
      'use': 'usual',
      'schedule': [
        {
          'days': 'all',
          'from': '20:00',
          'to': '23:00',
          'vehicles': ['scooter'],
        },
      ],
    },
  }),
  _spot('重機', 120, 120, {
    'space_type': 'heavyOnly',
    'facility_type': 'roadside',
  }),
  _spot('待確認', 0, 200, {
    'space_type': 'offStreet',
    'facility_type': 'underground',
  }),
];

const _ids = ['全天', '禁停', '夜間', '重機', '待確認'];

Finder _marker(String id) => find.descendant(
  of: find.byType(FlutterMap),
  matching: find.byWidgetPredicate(
    (w) => w is Semantics && (w.properties.label ?? '').startsWith('時段 $id '),
  ),
);

Set<String> _shown() => {
  for (final id in _ids)
    if (_marker(id).evaluate().isNotEmpty) id,
};

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  const sizes = [Size(390, 844), Size(820, 1180)];
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final size in sizes) {
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

      testWidgets('$name 現在可停：白天、禁停時段、晚上各自只留現在能停的點', (tester) async {
        setUp(tester);
        var now = _morning;
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          final s = AppStore(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
            parkingRepository: FixedParking(_spots),
            availabilitySource: const NoAvailabilitySource(),
            clock: () => now,
          );
          await s.init();
          return s;
        }))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: const ParkingApp(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(_shown(), _ids.toSet());

        final chip = find.byKey(const ValueKey('parkable-filter'));
        expect(chip.hitTestable(), findsOneWidget);
        await _tap(tester, chip);
        expect(_shown(), {'全天', '禁停'}, reason: '10:00');

        // The filter reads the clock again on the next build.
        for (final (at, expected) in [
          (_banned, {'全天'}),
          (_night, {'全天', '禁停', '夜間'}),
        ]) {
          now = at;
          await _tap(tester, chip);
          expect(_shown(), _ids.toSet());
          await _tap(tester, chip);
          expect(_shown(), expected, reason: '$at');
        }
        // Without touching the filter: time alone moves the map across a
        // boundary. 22:59:30 still shows the night lot; at 23:00 it closes.
        now = DateTime.utc(2026, 11, 3, 14, 59, 30);
        await _tap(tester, chip);
        await _tap(tester, chip);
        expect(_shown(), {'全天', '禁停', '夜間'});
        now = DateTime.utc(2026, 11, 3, 15);
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(_shown(), {'全天', '禁停'});
        // Turned off, nothing is left ticking.
        await _tap(tester, chip);
        expect(_shown(), _ids.toSet());
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('$name 禁停時段：能不能停路牌寫現在禁停、幾點起可停，朗讀一致', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          final s = AppStore(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
            clock: () => _banned,
          );
          await s.init();
          return s;
        }))!;
        store.vehicle = VehicleType.scooter;
        addTearDown(store.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                // The app's bridge for CNBottomSheet's Material localizations.
                // ignore: deprecated_member_use
                MaterialUiCompatibilityBridge(child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSpot(context, store, _noParking),
                  child: const Text('開啟點位'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('開啟點位'));
        await tester.pumpAndSettle();
        final verdict = find.byKey(const ValueKey('four-sign-verdict'));
        expect(verdict.hitTestable(), findsOneWidget);
        expect(
          find.descendant(of: verdict, matching: find.text('現在禁停')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: verdict, matching: find.text('15:00 起可停')),
          findsOneWidget,
        );
        final handle = tester.ensureSemantics();
        expect(
          tester.getSemantics(verdict),
          matchesSemantics(
            label: '能不能停：現在禁停，15:00 起可停',
            isButton: true,
            hasTapAction: true,
          ),
        );
        handle.dispose();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
