import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/features/map/spot_details.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';

/// C2 (docs/designs/2026-10-26-parking-conditions-and-fees.md §5.2–§5.4):
/// ParkingSpot reads and writes conditions; favorites keep older builds
/// conservative with `exact_v2`.
void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
          .toList();
  CityRule rule(VehicleType vehicle) =>
      rules.firstWhere((r) => r.city == '臺北市' && r.vehicle == vehicle);

  ParkingCondition street(Map<String, Object?> json) =>
      ParkingCondition.fromJson(json)!;
  ParkingCondition zone(Map<String, Object?> json) =>
      ParkingCondition.fromJson(json, zone: true)!;

  ParkingSpot spot({
    SpaceType type = SpaceType.paidMotorcycle,
    ParkingCondition? condition,
    FacilityType? facility,
    List<ParkingZone> zones = const [],
    bool zonesComplete = false,
    String source = 'official',
  }) => ParkingSpot(
    id: 'fav',
    name: '收藏',
    lat: 25.03,
    lng: 121.56,
    city: '臺北市',
    source: source,
    spaceType: type,
    status: TrustStatus.confirmed,
    scooterAllowed: true,
    heavyAllowed: true,
    lastConfirmedAt: DateTime.now().subtract(const Duration(days: 1)),
    facilityType: facility,
    zones: zones,
    zonesComplete: zonesComplete,
    condition: condition,
  );

  final freeTimed = street({
    'bay': 'motorcycle',
    'use': 'usual',
    'charge': 'free',
    'limits': [
      {'kind': 'time_limit', 'max_minutes': 30},
    ],
  });
  final scheduledHeavy = street({
    'bay': 'heavy',
    'use': 'usual',
    'schedule': [
      {
        'days': 'all',
        'from': '07:00',
        'to': '20:00',
        'vehicles': ['heavy'],
      },
    ],
  });
  final tollTimed = street({
    'bay': 'motorcycle',
    'use': 'usual',
    'charge': 'toll',
    'limits': [
      {'kind': 'time_limit', 'max_minutes': 20},
    ],
  });
  // §2.4 (b): the trial's motorcycle zone has an expiry.
  final trialZone = ParkingZone(
    name: '機車區',
    access: ParkingAccess.scooterHeavy,
    condition: zone({
      'bay': 'motorcycle',
      'use': 'share',
      'share': 'scooter_heavy',
      'charge': 'toll',
      'allow': {'scooter': true, 'heavy': true},
      'basis': {
        'source_url': 'https://pma.gov.taipei/x',
        'effective_date': '2026-04-06',
        'expires_on': '2026-10-05',
      },
    }),
  );
  final carZone = ParkingZone(
    name: '汽車區',
    access: ParkingAccess.heavyCar,
    condition: zone({
      'bay': 'car',
      'use': 'usual',
      'allow': {'scooter': false, 'heavy': true},
    }),
  );

  /// What a build from before conditions does with a favorite: it merges
  /// `exact` (it knows that one), reads only the keys it knows, and writes
  /// them back the way it did — `exact` again for a newer kind.
  Map<String, dynamic> resavedByOldBuild(Map<String, dynamic> json) {
    final j = {...json, ...?json['exact'] as Map<String, dynamic>?};
    const newKinds = {
      'disabledMotorcycle',
      'timedMotorcycle',
      'flexShared',
      'evMotorcycle',
    };
    final legacy = newKinds.contains(j['space_type']);
    return {
      for (final MapEntry(:key, :value) in j.entries)
        if (!const {
          'exact',
          'exact_v2',
          'condition',
          'zones_complete',
          'parking_zones',
        }.contains(key))
          key: value,
      'space_type': legacy ? 'offStreet' : j['space_type'],
      'heavy_allowed': legacy ? null : j['heavy_allowed'],
      'scooter_allowed': legacy ? null : j['scooter_allowed'],
      'status': legacy ? 'pending' : j['status'],
      if (legacy)
        'exact': {
          'space_type': j['space_type'],
          'heavy_allowed': j['heavy_allowed'],
          'scooter_allowed': j['scooter_allowed'],
          'status': j['status'],
        },
      if (j['parking_zones'] case final List<dynamic> zones)
        'parking_zones': [
          for (final z in zones.cast<Map<String, dynamic>>())
            {
              for (final MapEntry(:key, :value) in z.entries)
                if (!const {'area', 'condition'}.contains(key)) key: value,
            },
        ],
    };
  }

  /// An old build reading a favorite as written (it ignores `exact_v2` and
  /// the condition keys, and merges `exact`).
  ParkingSpot readByOldBuild(Map<String, dynamic> json) =>
      ParkingSpot.fromJson(resavedByOldBuild(json));

  void expectUnverifiedEverywhere(ParkingSpot old, String reason) {
    for (final vehicle in VehicleType.values) {
      expect(
        eligibility(old, vehicle, rule(vehicle)).status,
        EligibilityStatus.unverified,
        reason: '$reason/${vehicle.name}',
      );
    }
  }

  group('ParkingSpot reads and writes conditions', () {
    test('a v3 row carries its condition and zones_complete', () {
      final s = ParkingSpot.fromJson({
        'id': 'a',
        'name': 'a',
        'lat': 25.0,
        'lng': 121.5,
        'city': '臺北市',
        'space_type': 'timedMotorcycle',
        'condition': freeTimed.toJson(),
        'zones_complete': false,
      });
      expect(s.condition, freeTimed);
      expect(s.zonesComplete, isFalse);
      final lot = ParkingSpot.fromJson({
        'id': 'b',
        'name': 'b',
        'lat': 25.0,
        'lng': 121.5,
        'city': '臺北市',
        'space_type': 'offStreet',
        'zones_complete': true,
        'parking_zones': [
          {...carZone.toJson(), 'guide': 'B2'},
        ],
      });
      expect(lot.zonesComplete, isTrue);
      expect(lot.zones.single.condition, carZone.condition);
      expect(lot.zones.single.guide, 'B2');
    });

    test('a condition that breaks the contract reads as unconfirmed', () {
      final s = ParkingSpot.fromJson({
        'id': 'a',
        'name': 'a',
        'lat': 25.0,
        'lng': 121.5,
        'city': '臺北市',
        'space_type': 'paidMotorcycle',
        'condition': {'bay': 'motorcycle', 'use': 'share', 'charge': 'toll'},
        'parking_zones': [
          {
            'name': 'B1',
            'area': 'roof',
            'condition': {'bay': 'spaceship'},
          },
        ],
      });
      expect(s.condition, isNull);
      expect(s.zones.single.condition, isNull);
    });

    test('old JSON without the new keys reads as before', () {
      // A favorite saved by an earlier build, and a v2 row.
      final old = {
        'id': 'a',
        'name': 'a',
        'lat': 25.0,
        'lng': 121.5,
        'city': '臺北市',
        'source': 'official',
        'space_type': 'offStreet',
        'scooter_allowed': null,
        'heavy_allowed': null,
        'status': 'pending',
        'exact': {
          'space_type': 'evMotorcycle',
          'scooter_allowed': true,
          'heavy_allowed': false,
          'status': 'confirmed',
        },
        'parking_zones': [
          {'name': 'B1', 'access': 'scooterOnly'},
        ],
      };
      final s = ParkingSpot.fromJson(old);
      expect(s.spaceType, SpaceType.evMotorcycle);
      expect(s.heavyAllowed, isFalse);
      expect(s.status, TrustStatus.confirmed);
      expect(s.condition, isNull);
      expect(s.zonesComplete, isFalse);
      expect(s.zones.single.condition, isNull);
      expect(s.isLegacySafe, isTrue);
      // Written again, it is what this build wrote before: no new keys.
      final again = s.toJson();
      for (final key in ['condition', 'zones_complete', 'exact_v2']) {
        expect(again.containsKey(key), isFalse, reason: key);
      }
      expect(again['exact'], old['exact']);
      expect(again['parking_zones'], old['parking_zones']);
    });

    test('without conditions, toJson is unchanged for every kind', () {
      for (final type in SpaceType.values) {
        final json = spot(type: type).toJson();
        expect(json.containsKey('exact_v2'), isFalse, reason: type.name);
        expect(json.containsKey('condition'), isFalse, reason: type.name);
        expect(json.containsKey('zones_complete'), isFalse, reason: type.name);
      }
    });
  });

  group('favorites round trip: this build → an older build → this build', () {
    test('a legacy-safe condition is written as is', () {
      final s = spot(type: SpaceType.timedMotorcycle, condition: tollTimed);
      expect(s.isLegacySafe, isTrue);
      final json = s.toJson();
      expect(json['condition'], tollTimed.toJson());
      expect(json.containsKey('exact_v2'), isFalse);
      // A newer kind still uses `exact` for the builds that know it.
      expect(json['space_type'], 'offStreet');
      expect((json['exact'] as Map)['space_type'], 'timedMotorcycle');
      final back = ParkingSpot.fromJson(json);
      expect(back.condition, tollTimed);
      expect(back.spaceType, SpaceType.timedMotorcycle);
      expect(back.heavyAllowed, isTrue);
      // The older build reads it as the timed toll bay it is.
      expect(readByOldBuild(json).spaceType, SpaceType.timedMotorcycle);
    });

    test('an unsafe street bay: projected on top, exact in exact_v2', () {
      for (final (type, condition) in [
        (SpaceType.timedMotorcycle, freeTimed),
        (SpaceType.heavyOnly, scheduledHeavy),
      ]) {
        final reason = type.name;
        final s = spot(type: type, condition: condition);
        expect(s.isLegacySafe, isFalse, reason: reason);
        final json = s.toJson();
        expect(json['space_type'], 'offStreet', reason: reason);
        expect(json['scooter_allowed'], isNull, reason: reason);
        expect(json['heavy_allowed'], isNull, reason: reason);
        expect(json['status'], 'pending', reason: reason);
        expect(json.containsKey('condition'), isFalse, reason: reason);
        // Not `exact`: older builds merge it and would restore the loose
        // reading.
        expect(json.containsKey('exact'), isFalse, reason: reason);
        // This build restores everything.
        final back = ParkingSpot.fromJson(json);
        expect(back.spaceType, type, reason: reason);
        expect(back.condition, condition, reason: reason);
        expect(back.heavyAllowed, isTrue, reason: reason);
        expect(back.status, TrustStatus.confirmed, reason: reason);
        // An older build reads it as an unverified lot...
        final old = readByOldBuild(json);
        expect(old.spaceType, SpaceType.offStreet, reason: reason);
        expectUnverifiedEverywhere(old, reason);
        // ...and re-saving it there loses information, not safety.
        final resaved = resavedByOldBuild(json);
        final after = ParkingSpot.fromJson(resaved);
        expect(after.spaceType, SpaceType.offStreet, reason: reason);
        expect(after.condition, isNull, reason: reason);
        expectUnverifiedEverywhere(after, reason);
      }
    });

    test('an unsafe lot: unsafe zones lose their access on top', () {
      final s = spot(
        type: SpaceType.offStreet,
        facility: FacilityType.underground,
        zones: [trialZone, carZone],
        zonesComplete: true,
      );
      expect(trialZone.legacySafe, isFalse);
      expect(carZone.legacySafe, isTrue);
      expect(s.isLegacySafe, isFalse);
      final json = s.toJson();
      final zones = (json['parking_zones'] as List)
          .cast<Map<String, dynamic>>();
      expect(zones[0].containsKey('access'), isFalse);
      expect(zones[1]['access'], 'heavyCar');
      expect(json['heavy_allowed'], isNull);
      expect(json['zones_complete'], isTrue);
      final back = ParkingSpot.fromJson(json);
      expect(back.zones.map((z) => z.access), [
        ParkingAccess.scooterHeavy,
        ParkingAccess.heavyCar,
      ]);
      expect(back.zones.first.condition, trialZone.condition);
      expect(back.heavyAllowed, isTrue);
      expect(back.zonesComplete, isTrue);
      final old = readByOldBuild(json);
      expect(old.zones.first.access, isNull);
      expectUnverifiedEverywhere(old, 'lot');
      expectUnverifiedEverywhere(
        ParkingSpot.fromJson(resavedByOldBuild(json)),
        'lot re-saved',
      );
    });

    test('a zone whose access contradicts its condition is not safe', () {
      final contradicting = ParkingZone(
        name: '汽車區',
        access: ParkingAccess.scooterHeavy,
        condition: carZone.condition,
      );
      expect(contradicting.legacySafe, isFalse);
      final s = spot(type: SpaceType.offStreet, zones: [contradicting]);
      expect(s.isLegacySafe, isFalse);
    });

    test('a lot whose zones are all safe is written as is', () {
      final s = spot(type: SpaceType.offStreet, zones: [carZone]);
      expect(s.isLegacySafe, isTrue);
      final json = s.toJson();
      expect(json.containsKey('exact_v2'), isFalse);
      expect(json['heavy_allowed'], isTrue);
      expect(
        ParkingSpot.fromJson(json).zones.single.condition,
        carZone.condition,
      );
    });

    test('favorite() keeps exact_v2 and drops the contributor name', () {
      final json = spot(
        type: SpaceType.heavyOnly,
        condition: scheduledHeavy,
      ).toJson();
      final read = ParkingSpot.favorite({...json, 'contributor_name': '某車友'})
          .single;
      expect(read.spaceType, SpaceType.heavyOnly);
      expect(read.condition, scheduledHeavy);
      expect(read.contributorName, isEmpty);
    });
  });

  group('reportedAccess reads the bay through the conversion layer', () {
    test('a stored scooter_heavy share is 普大共用', () {
      final shared = spot(
        condition: street({
          'bay': 'motorcycle',
          'use': 'share',
          'share': 'scooter_heavy',
          'charge': 'toll',
        }),
      );
      expect(
        reportedAccess(
          ParkingSpot.fromJson({
            ...shared.toJson(),
            'scooter_allowed': null,
            'heavy_allowed': null,
          }),
        ),
        ParkingAccess.scooterHeavy,
      );
    });

    test('a stored heavy bay is 大重專用, a flex car bay never 大汽共用', () {
      expect(
        reportedAccess(
          spot(type: SpaceType.heavyOnly, condition: scheduledHeavy),
        ),
        ParkingAccess.heavyOnly,
      );
      final flex = spot(
        type: SpaceType.flexShared,
        condition: street({
          'bay': 'car',
          'use': 'share',
          'share': 'car_motorcycle',
        }),
      );
      expect(reportedAccess(flex), isNull);
      expect(
        reportedAccess(
          ParkingSpot.fromJson({...flex.toJson(), 'scooter_allowed': false}),
        ),
        isNull,
      );
    });

    test('reserved motorcycle bays are never 普大共用', () {
      final disabled = spot(
        type: SpaceType.disabledMotorcycle,
        condition: street({
          'bay': 'motorcycle',
          'use': 'usual',
          'charge': 'free',
          'limits': [
            {'kind': 'special_vehicle', 'vehicle': 'disabled_modified'},
          ],
        }),
      );
      expect(reportedAccess(disabled), isNull);
    });
  });
}
