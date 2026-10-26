import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/space_filter.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';

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

  test('other kinds filter by their space type', () {
    final paid = _spot(SpaceType.paidMotorcycle);
    expect(matchesSpaceFilter(paid, SpaceType.paidMotorcycle, scooter), isTrue);
    expect(
      matchesSpaceFilter(paid, SpaceType.freeMotorcycle, scooter),
      isFalse,
    );
    expect(matchesSpaceFilter(paid, SpaceType.heavyOnly, scooter), isFalse);
  });
}
