import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The full-page details' demo data (FIX-DECISIONS, canvas v154 A2, A8,
/// A10): 松壽地下停車場 with three zones, 南京東路三段 with three
/// segments, and a street bay without segments.

/// 2026-11-03 (Tuesday) 14:20 in Taiwan.
final detailDay = DateTime.utc(2026, 11, 3, 6, 20);

/// The same Tuesday at 21:00 in Taiwan.
final detailNight = DateTime.utc(2026, 11, 3, 13);

const _hourly20 = {
  'mode': 'hourly',
  'amount': 20,
  'per_minutes': 60,
  'daily_cap': 100,
  'cap_reset': 'calendar_day',
};

final detailLotJson = <String, dynamic>{
  'id': 'songshou',
  'name': '松壽地下停車場',
  'lat': 25.036,
  'lng': 121.567,
  'city': '臺北市',
  'district': '信義區',
  'address': '臺北市信義區松壽路',
  'space_type': 'offStreet',
  'facility_type': 'underground',
  'source': 'official',
  'scooter_allowed': true,
  'heavy_allowed': true,
  'entrance_note': '松壽路側車道下坡，機車走右側',
  'photo_urls': [
    'https://example.com/a.jpg',
    'https://example.com/b.jpg',
    'https://example.com/c.jpg',
    'https://example.com/d.jpg',
    'https://example.com/e.jpg',
  ],
  'fee': {'scooter': _hourly20, 'heavy': _hourly20},
  'parking_zones': [
    {
      'id': 'b1',
      'name': 'B1 機車區',
      'condition': {
        'bay': 'motorcycle',
        'use': 'usual',
        'allow': {'scooter': true, 'heavy': false},
      },
    },
    {
      'id': 'b2',
      'name': 'B2 重機專區',
      'guide': '電梯旁，地面標「重機」',
      'condition': {
        'bay': 'heavy',
        'use': 'usual',
        'allow': {'heavy': true},
        'limits': [
          {
            'kind': 'time_limit',
            'periods': [
              {'days': 'all', 'max_minutes': 120, 'extensions': 1},
            ],
          },
          {
            'kind': 'no_parking',
            'periods': [
              {'days': 'all', 'from': '23:00', 'to': '07:00'},
              {'days': 'holiday'},
            ],
          },
        ],
      },
    },
    {
      'id': 'b3',
      'name': 'B3 汽車區',
      'guide': '靠出口第一排',
      'condition': {
        'bay': 'car',
        'use': 'share',
        'share': 'car_motorcycle',
        'allow': {'heavy': true},
        'schedule': [
          {
            'days': 'all',
            'from': '20:00',
            'to': '23:00',
            'vehicles': ['heavy'],
          },
        ],
      },
    },
  ],
};
final detailLot = ParkingSpot.fromJson(detailLotJson);

final detailStreetJson = <String, dynamic>{
  'id': 'nanjing',
  'name': '南京東路三段路邊機車格',
  'lat': 25.052,
  'lng': 121.541,
  'city': '臺北市',
  'district': '中山區',
  'address': '臺北市中山區南京東路三段',
  'space_type': 'paidMotorcycle',
  'facility_type': 'roadside',
  'source': 'official',
  'fee': {
    'scooter': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
  },
  'parking_segments': [
    {
      'id': 'n1',
      'name': '北側一般機車格',
      'side': 'north',
      'range': '建國北路口 → 松江路口',
      'total': 18,
      'guide': '靠松江路口 6 格較寬，重機好停',
      'fee': {
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
            },
            {
              'days': 'all',
              'from': '20:00',
              'to': '08:00',
              'rate': {'mode': 'free'},
            },
          ],
        },
        'heavy': {'mode': 'same_as_scooter'},
      },
      'condition': {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'limits': [
          {
            'kind': 'no_parking',
            'periods': [
              {
                'days': ['mon'],
                'from': '06:00',
                'to': '08:00',
              },
            ],
          },
        ],
      },
    },
    {
      'id': 'n2',
      'name': '北側汽機車共用格',
      'side': 'north',
      'range': '松江路口前 40 公尺',
      'total': 6,
      'guide': '沿路緣停一排，不可併排',
      'condition': {
        'bay': 'car',
        'use': 'share',
        'share': 'car_motorcycle',
        'schedule': [
          {
            'days': 'all',
            'from': '20:00',
            'to': '08:00',
            'vehicles': ['scooter'],
          },
        ],
      },
    },
    {
      'id': 's1',
      'name': '南側汽機車共用格',
      'side': 'south',
      'range': '南側路緣',
      'total': 12,
      'guide': '和汽車共用，看清地面標線再停',
      'fee': {
        'scooter': {'mode': 'hourly', 'amount': 30, 'per_minutes': 60},
        'heavy': {'mode': 'hourly', 'amount': 30, 'per_minutes': 60},
      },
      'condition': {
        'bay': 'car',
        'use': 'share',
        'share': 'car_motorcycle',
        'limits': [
          {
            'kind': 'time_limit',
            'periods': [
              {
                'days': 'weekday',
                'from': '07:00',
                'to': '20:00',
                'max_minutes': 120,
                'extensions': 1,
              },
            ],
          },
        ],
        'schedule': [
          {
            'days': 'all',
            'from': '08:00',
            'to': '20:00',
            'vehicles': ['scooter', 'heavy'],
          },
        ],
      },
    },
  ],
};
final detailStreet = ParkingSpot.fromJson(detailStreetJson);

/// A street bay with no segments: the spot stands as one.
final detailBayJson = <String, dynamic>{
  'id': 'plain-bay',
  'name': '民生東路路邊機車格',
  'lat': 25.058,
  'lng': 121.545,
  'city': '臺北市',
  'district': '中山區',
  'road_segment': '民生東路二段：松江路口至伊通街口，南側',
  'space_type': 'paidMotorcycle',
  'facility_type': 'roadside',
  'source': 'official',
  'scooter_total': 24,
  'fee': {
    'scooter': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
    'heavy': {'mode': 'same_as_scooter'},
  },
};
final detailBay = ParkingSpot.fromJson(detailBayJson);

/// A lot only cars may use (A2b): neither motorcycle may park anywhere.
final detailCarLotJson = <String, dynamic>{
  'id': 'car-lot',
  'name': '測試汽車停車場',
  'lat': 25.04,
  'lng': 121.56,
  'city': '臺北市',
  'district': '信義區',
  'address': '臺北市信義區測試路 1 號',
  'space_type': 'offStreet',
  'facility_type': 'underground',
  'source': 'official',
  'scooter_allowed': false,
  'heavy_allowed': false,
  'entrance_note': '側門車道，只供汽車進出',
  'note': '機車請改停對面的機車停車場。',
  'fee': {
    'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
  },
  'parking_zones': [
    {
      'id': 'c1',
      'name': 'B1 汽車區',
      'condition': {
        'bay': 'car',
        'use': 'usual',
        'allow': {'scooter': false, 'heavy': false},
      },
    },
    {
      'id': 'c2',
      'name': 'B2 汽車區',
      'condition': {
        'bay': 'car',
        'use': 'usual',
        'allow': {'scooter': false, 'heavy': false},
      },
    },
  ],
};
final detailCarLot = ParkingSpot.fromJson(detailCarLotJson);

Future<AppStore> detailStore(
  WidgetTester tester,
  VehicleType vehicle, {
  DateTime? now,
}) async {
  final at = now ?? detailDay;
  final s = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({'vehicle': vehicle.name});
    final s = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      clock: () => at,
    );
    await s.init();
    return s;
  }))!;
  s.vehicle = vehicle;
  addTearDown(s.dispose);
  return s;
}

/// Opens [spot]'s preview at [size]; with [full], pulls it up to the full
/// page.
Future<void> openDetail(
  WidgetTester tester,
  AppStore store,
  ParkingSpot spot, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool dark = false,
  bool full = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: brand,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // The app's bridge for CNBottomSheet's Material localizations.
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
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
  if (full) await pullUp(tester);
}

/// Drags the preview up to the full page.
Future<void> pullUp(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const ValueKey('parking-spot-sheet')),
    const Offset(0, -900),
  );
  await tester.pumpAndSettle();
}

/// The full page's scroll.
Finder get detailScrollable => find
    .descendant(
      of: find.byKey(const ValueKey('parking-spot-sheet')),
      matching: find.byType(Scrollable),
    )
    .first;
