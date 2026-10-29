import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/space_filter.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/models/space_kind.dart';

ParkingSpot _spot(SpaceType type, {Object? fee, Object? condition}) =>
    ParkingSpot.fromJson({
      'id': 'x',
      'name': '機車格',
      'lat': 25.03,
      'lng': 121.56,
      'city': '臺北市',
      'space_type': type.name,
      'fee': ?fee,
      'condition': ?condition,
    });

void main() {
  const scooter = VehicleType.scooter, heavy = VehicleType.heavy;

  test('免費 keeps only free rates; a toll bay whose first minutes cost 0 元 is not free (§2.3)', () {
    // Taipei's timed bay: first 20 minutes 0 元, then pay to extend.
    final timed = _spot(
      SpaceType.timedMotorcycle,
      condition: {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'limits': [
          {'kind': 'time_limit', 'max_minutes': 20},
        ],
      },
      fee: {
        'heavy': {'mode': 'per_visit', 'amount': 0, 'max_minutes': 20},
      },
    );
    expect(freeFor(timed, heavy), isFalse);
    // Free minutes before an hourly rate are not free either.
    final grace = _spot(
      SpaceType.timedMotorcycle,
      fee: {
        'scooter': {
          'mode': 'hourly',
          'amount': 10,
          'per_minutes': 60,
          'free_minutes': 30,
        },
      },
    );
    expect(freeFor(grace, scooter), isFalse);
    expect(
      freeFor(
        _spot(
          SpaceType.paidMotorcycle,
          fee: {
            'scooter': {'mode': 'free'},
          },
        ),
        scooter,
      ),
      isFalse,
      reason: 'a toll bay never counts, whatever its rate says',
    );
  });

  test('a free bay counts by its rate for the rider, else by its charge', () {
    expect(freeFor(_spot(SpaceType.freeMotorcycle), scooter), isTrue);
    final heavyPays = _spot(
      SpaceType.freeMotorcycle,
      fee: {
        'scooter': {'mode': 'free'},
        'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
      },
    );
    expect(freeFor(heavyPays, scooter), isTrue);
    expect(freeFor(heavyPays, heavy), isFalse);
    final follows = _spot(
      SpaceType.freeMotorcycle,
      fee: {
        'scooter': {'mode': 'free'},
        'heavy': {'mode': 'same_as_scooter'},
      },
    );
    expect(freeFor(follows, heavy), isTrue);
    // A 限時 bay marked free is a free bay too.
    final timedFree = _spot(
      SpaceType.timedMotorcycle,
      condition: {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'free',
        'limits': [
          {'kind': 'time_limit', 'max_minutes': 60},
        ],
      },
    );
    expect(freeFor(timedFree, scooter), isTrue);
  });

  test('lots, car bays and bays for some vehicles only are not 免費機車格', () {
    expect(
      freeFor(
        _spot(
          SpaceType.offStreet,
          fee: {
            'scooter': {'mode': 'free'},
          },
        ),
        scooter,
      ),
      isFalse,
    );
    expect(
      freeFor(
        _spot(
          SpaceType.car,
          fee: {
            'heavy': {'mode': 'free'},
          },
        ),
        heavy,
      ),
      isFalse,
    );
    for (final type in [SpaceType.disabledMotorcycle, SpaceType.evMotorcycle]) {
      expect(
        freeFor(
          _spot(type, fee: const Fee(scooter: Rate(FeeMode.free)).toJson()),
          scooter,
        ),
        isFalse,
        reason: type.name,
      );
    }
  });

  test('a lot by its facility type is not a 免費機車格 either', () {
    final lot = ParkingSpot.fromJson({
      'id': 'x',
      'name': '平面停車場',
      'lat': 25.03,
      'lng': 121.56,
      'city': '臺北市',
      'space_type': 'freeMotorcycle',
      'facility_type': 'surface',
    });
    expect(freeFor(lot, VehicleType.scooter), isFalse);
  });

  bool keeps(ParkingSpot spot, SpaceFilter filter, [VehicleType v = scooter]) =>
      filter.matches(spot, v);

  test('六種格位依條件篩選；限時機車格算一般機車格（決定 62）', () {
    final paid = _spot(SpaceType.paidMotorcycle);
    expect(keeps(paid, const SpaceFilter(kind: SpaceKind.motorcycle)), isTrue);
    expect(keeps(paid, const SpaceFilter(kind: SpaceKind.heavyOnly)), isFalse);
    expect(keeps(paid, const SpaceFilter(kind: SpaceKind.shared)), isFalse);
    final timed = _spot(SpaceType.timedMotorcycle);
    expect(keeps(timed, const SpaceFilter(kind: SpaceKind.motorcycle)), isTrue);
    expect(
      keeps(
        _spot(SpaceType.flexShared),
        const SpaceFilter(kind: SpaceKind.shared),
      ),
      isTrue,
    );
    expect(
      keeps(
        _spot(SpaceType.evMotorcycle),
        const SpaceFilter(kind: SpaceKind.evMotorcycle),
      ),
      isTrue,
    );
    expect(
      keeps(
        _spot(SpaceType.offStreet),
        const SpaceFilter(kind: SpaceKind.offStreet),
      ),
      isTrue,
    );
    expect(const SpaceFilter().label, '全部格位');
    expect(
      const SpaceFilter(
        kind: SpaceKind.motorcycle,
        charge: Charge.free,
        limits: {LimitKind.noParking},
      ).label,
      '一般機車格・免費・時段性禁停',
    );
  });

  test('普大共用與汽機共用都是共用格；收費／免費照費率或收費屬性', () {
    const shared = ParkingCondition(
      bay: Bay.motorcycle,
      use: BayUse.share,
      share: ShareKind.scooterHeavy,
      charge: Charge.toll,
    );
    final paid = ParkingSpot(
      id: 'shared',
      name: '普大共用',
      lat: 25.03,
      lng: 121.56,
      city: '臺北市',
      spaceType: SpaceType.paidMotorcycle,
      condition: shared,
    );
    expect(keeps(paid, const SpaceFilter(kind: SpaceKind.shared)), isTrue);
    expect(keeps(paid, const SpaceFilter(kind: SpaceKind.motorcycle)), isFalse);
    expect(keeps(paid, const SpaceFilter(charge: Charge.toll)), isTrue);
    expect(keeps(paid, const SpaceFilter(charge: Charge.free)), isFalse);
    // A free bay whose heavy rate is hourly: free for scooters only.
    final heavyPays = _spot(
      SpaceType.freeMotorcycle,
      fee: {
        'scooter': {'mode': 'free'},
        'heavy': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
      },
    );
    expect(keeps(heavyPays, const SpaceFilter(charge: Charge.free)), isTrue);
    expect(
      keeps(
        heavyPays,
        const SpaceFilter(charge: Charge.free),
        VehicleType.heavy,
      ),
      isFalse,
    );
    // A heavy bay with a free rate counts as free too.
    expect(
      keeps(
        _spot(
          SpaceType.heavyOnly,
          fee: {
            'heavy': {'mode': 'free'},
          },
        ),
        const SpaceFilter(charge: Charge.free),
        VehicleType.heavy,
      ),
      isTrue,
    );
    expect(
      keeps(_spot(SpaceType.heavyOnly), const SpaceFilter(charge: Charge.free)),
      isFalse,
    );
  });

  test('加註條件：限時與時段性禁停（分區也算）', () {
    final banned = _spot(
      SpaceType.paidMotorcycle,
      condition: {
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'limits': [
          {
            'kind': 'no_parking',
            'periods': [
              {'days': 'weekday', 'from': '07:00', 'to': '09:00'},
            ],
          },
        ],
      },
    );
    const ban = SpaceFilter(limits: {LimitKind.noParking});
    const timedOnly = SpaceFilter(limits: {LimitKind.timeLimit});
    expect(keeps(banned, ban), isTrue);
    expect(keeps(banned, timedOnly), isFalse);
    expect(keeps(_spot(SpaceType.timedMotorcycle), timedOnly), isTrue);
    final lot = ParkingSpot.fromJson({
      'id': 'lot',
      'name': '停車場',
      'lat': 25.03,
      'lng': 121.56,
      'city': '臺北市',
      'space_type': 'offStreet',
      'parking_zones': [
        {
          'name': 'B1',
          'access': 'scooterOnly',
          'condition': {
            'bay': 'motorcycle',
            'use': 'usual',
            'allow': {'scooter': true, 'heavy': false},
            'limits': [
              {'kind': 'time_limit'},
            ],
          },
        },
      ],
    });
    expect(keeps(lot, timedOnly), isTrue);
    expect(keeps(lot, ban), isFalse);
  });
}
