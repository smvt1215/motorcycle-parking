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

  test('each kind keeps the bays painted as it, whatever they charge', () {
    final paid = _spot(SpaceType.paidMotorcycle);
    final free = _spot(SpaceType.freeMotorcycle);
    final timed = _spot(SpaceType.timedMotorcycle);
    for (final s in [paid, free, timed]) {
      expect(matchesSpaceFilter(s, SpaceKind.motorcycle, scooter), isTrue);
      expect(matchesSpaceFilter(s, SpaceKind.heavy, scooter), isFalse);
      expect(matchesSpaceFilter(s, SpaceKind.scooterHeavy, scooter), isFalse);
    }
    for (final (type, kind) in [
      (SpaceType.heavyOnly, SpaceKind.heavy),
      (SpaceType.car, SpaceKind.car),
      (SpaceType.flexShared, SpaceKind.carMotorcycle),
      (SpaceType.disabledMotorcycle, SpaceKind.disabled),
      (SpaceType.evMotorcycle, SpaceKind.ev),
      (SpaceType.offStreet, SpaceKind.offStreet),
    ]) {
      final spot = _spot(type);
      expect(
        [
          for (final k in SpaceKind.values)
            if (matchesSpaceFilter(spot, k, scooter)) k,
        ],
        [kind],
        reason: '$type',
      );
    }
  });

  test('普大共用格 keeps street bays posted for both classes, time limited too', () {
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
    expect(matchesSpaceFilter(paid, SpaceKind.scooterHeavy, scooter), isTrue);
    // Its own kind only: not also a 一般機車格.
    expect(matchesSpaceFilter(paid, SpaceKind.motorcycle, scooter), isFalse);
    final timed = ParkingSpot(
      id: 'timed',
      name: '限時共用',
      lat: 25.03,
      lng: 121.56,
      city: '臺北市',
      spaceType: SpaceType.timedMotorcycle,
      condition: const ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.share,
        share: ShareKind.scooterHeavy,
        limits: [ParkingLimit(LimitKind.timeLimit)],
      ),
    );
    expect(matchesSpaceFilter(timed, SpaceKind.scooterHeavy, scooter), isTrue);
  });

  test('a street spot also matches the kinds of its segments (#188)', () {
    final spot = ParkingSpot.fromJson({
      'id': 'seg',
      'name': '南京東路三段',
      'lat': 25.05,
      'lng': 121.54,
      'city': '臺北市',
      'space_type': 'paidMotorcycle',
      'parking_segments': [
        {
          'id': 's1',
          'name': '南側',
          'condition': {
            'bay': 'car',
            'use': 'share',
            'share': 'car_motorcycle',
          },
        },
      ],
    });
    expect(matchesSpaceFilter(spot, SpaceKind.motorcycle, scooter), isTrue);
    expect(matchesSpaceFilter(spot, SpaceKind.carMotorcycle, scooter), isTrue);
    expect(matchesSpaceFilter(spot, SpaceKind.car, scooter), isFalse);
  });

  test('複選格位：空集合等於全部格位，多選取聯集（P1）', () {
    final paid = _spot(SpaceType.paidMotorcycle);
    final heavyBay = _spot(SpaceType.heavyOnly);
    final lot = _spot(SpaceType.offStreet);
    for (final spot in [paid, heavyBay, lot]) {
      expect(matchesSpaceKinds(spot, const {}, scooter), isTrue);
    }
    const picked = {SpaceKind.motorcycle, SpaceKind.offStreet};
    expect(matchesSpaceKinds(paid, picked, scooter), isTrue);
    expect(matchesSpaceKinds(lot, picked, scooter), isTrue);
    expect(matchesSpaceKinds(heavyBay, picked, scooter), isFalse);
    expect(matchesSpaceKinds(heavyBay, {SpaceKind.heavy}, heavy), isTrue);
    expect(matchesSpaceKinds(paid, {SpaceKind.heavy}, heavy), isFalse);
  });
}
