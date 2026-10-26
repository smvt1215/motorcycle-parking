import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';

/// The contract and cases validate.ts and the generated SQL also use.
const _dir = 'supabase/functions/_shared';
Map<String, Object?> _json(String name) =>
    jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, Object?>;

List<String> _wires<T>(Iterable<T> values, String Function(T) wire) => [
  for (final v in values) wire(v),
];

void main() {
  final contract = _json('parking_contract.json');
  final cases = _json('parking_contract_cases.json');
  final cond = contract['condition']! as Map<String, Object?>;
  final conversion = contract['conversion']! as Map<String, Object?>;

  group('the Dart mirror matches parking_contract.json', () {
    test('version, space types and access kinds', () {
      expect(contract['version'], parkingContractVersion);
      expect(contract['space_types'], _wires(SpaceType.values, (v) => v.name));
      expect(
        contract['access_kinds'],
        _wires(ParkingAccess.values, (v) => v.name),
      );
    });

    test('placement, time and date', () {
      final placement = contract['placement']! as Map<String, Object?>;
      expect(
        placement['off_street_space_types'],
        _wires(offStreetSpaceTypes, (v) => v.name),
      );
      expect(
        placement['off_street_facility_types'],
        _wires(offStreetFacilityTypes, (v) => v.name),
      );
      final time = contract['time']! as Map<String, Object?>;
      expect(time['pattern'], timePattern);
      expect(time['days'], scheduleDayPresets);
      expect(time['weekdays'], scheduleWeekdays);
      expect(time['optional_pair'], timeOptionalPair);
      expect((contract['date']! as Map)['pattern'], datePattern);
    });

    test('condition enums and keys', () {
      expect(cond['keys'], conditionKeys);
      expect(cond['zone_keys'], conditionZoneKeys);
      expect(cond['bay'], _wires(Bay.values, (v) => v.name));
      expect(cond['use'], _wires(BayUse.values, (v) => v.name));
      expect(cond['share'], {
        for (final s in ShareKind.values) s.wire: s.bay.name,
      });
      expect(cond['charge'], _wires(Charge.values, (v) => v.name));
      expect(
        cond['special_vehicles'],
        _wires(SpecialVehicle.values, (v) => v.wire),
      );
      expect(
        cond['street_charge_optional_with'],
        _wires(streetChargeOptionalWith, (v) => v.wire),
      );
      expect(cond['allow_keys'], allowKeys);
      expect(cond['schedule'], {
        'keys': scheduleKeys,
        'max_entries': scheduleMaxEntries,
        'vehicles': _wires(SlotVehicle.values, (v) => v.name),
      });
    });

    test('limit kinds and their keys', () {
      expect(cond['limits'], {
        for (final MapEntry(:key, :value) in limitKeys.entries)
          key.wire: {
            'required': value.required,
            'optional': {
              for (final MapEntry(key: k, value: (min, max))
                  in value.optional.entries)
                k: {'min': min, 'max': max},
            },
          },
      });
      expect(limitKeys.keys, LimitKind.values);
    });

    test('basis', () {
      final basis = cond['basis']! as Map<String, Object?>;
      expect(basis['keys'], basisKeys);
      expect(basis['required_one_of'], basisRequiredOneOf);
      expect(basis['reserved'], basisReserved);
      expect(basis['source_url'], {
        'pattern': sourceUrlPattern,
        'max_length': sourceUrlMaxLength,
      });
    });

    test('conversion tables', () {
      expect(conversion['from_space_type'], {
        for (final MapEntry(:key, :value) in conditionBySpaceType.entries)
          key.name: value?.toJson(),
      });
      expect(conditionBySpaceType.keys, SpaceType.values);
      expect(conversion['from_access'], {
        for (final MapEntry(:key, :value) in conditionByAccess.entries)
          key.name: value.toJson(),
      });
      expect(conditionByAccess.keys, unorderedEquals(ParkingAccess.values));
      expect(conversion['to_space_type'], [
        for (final r in legacySpaceTypeRules)
          {
            'when': {
              if (r.offStreet != null) 'placement': 'off_street',
              'limit': ?r.limit?.wire,
              'share': ?r.share?.wire,
              'bay': ?r.bay?.name,
              'charge': ?r.charge?.name,
            },
            'space_type': r.spaceType.name,
          },
      ]);
      expect(legacySpaceTypeRules.where((r) => r.offStreet == false), isEmpty);
    });

    test('legacy-safe rules', () {
      final safe = conversion['legacy_safe']! as Map<String, Object?>;
      expect(safe['unsafe_keys'], legacyUnsafeKeys);
      expect(safe['unsafe_basis_keys'], legacyUnsafeBasisKeys);
      expect(safe['lossy_share'], legacyLossyShare.wire);
      expect(safe['lossy_limit_keys'], legacyLossyLimitKeys);
      expect(safe['assumed_charge'], {
        for (final MapEntry(:key, :value) in legacyAssumedCharge.entries)
          key.name: value.name,
      });
    });

    test('fee rule data', () {
      final fee = contract['fee']! as Map<String, Object?>;
      expect(fee.keys, feeContract.keys);
      for (final key in fee.keys) {
        expect(fee[key], feeContract[key], reason: key);
      }
    });
  });

  group('shared cases', () {
    test('validCondition accepts exactly the valid conditions', () {
      final list = (cases['conditions']! as List).cast<Map<String, Object?>>();
      expect(list, isNotEmpty);
      for (final c in list) {
        final zone = c['zone']! as bool;
        final name = c['name']! as String;
        expect(
          validCondition(c['condition'], zone: zone),
          c['valid'],
          reason: name,
        );
        final read = ParkingCondition.fromJson(c['condition'], zone: zone);
        expect(read != null, c['valid'], reason: name);
        if (read == null) continue;
        // Writing back keeps the condition valid and reads the same.
        expect(validCondition(read.toJson(), zone: zone), isTrue, reason: name);
        expect(
          ParkingCondition.fromJson(read.toJson(), zone: zone),
          read,
          reason: name,
        );
      }
    });

    test('legacy space types and legacy-safe street conditions', () {
      for (final c in (cases['legacy']! as List).cast<Map<String, Object?>>()) {
        final name = c['name']! as String;
        final offStreet = c['off_street']! as bool;
        final condition = ParkingCondition.fromJson(
          c['condition'],
          zone: offStreet,
        )!;
        expect(
          legacySpaceType(condition, offStreet: offStreet)?.name,
          c['space_type'],
          reason: name,
        );
        if (c['safe'] != null) {
          expect(legacySafe(condition), c['safe'], reason: name);
        }
      }
    });

    test('legacy access and legacy-safe zones', () {
      for (final c in (cases['zones']! as List).cast<Map<String, Object?>>()) {
        final name = c['name']! as String;
        final zone = ParkingCondition.fromJson(c['condition'], zone: true)!;
        expect(legacyAccess(zone)?.name, c['access'], reason: name);
        expect(legacySafeZone(zone), c['safe'], reason: name);
      }
    });
  });

  group('conversion', () {
    test('every legacy space type round-trips through its condition', () {
      for (final type in SpaceType.values) {
        final condition = conditionOf(type);
        if (type == SpaceType.offStreet) {
          expect(condition, isNull);
          continue;
        }
        expect(validCondition(condition!.toJson()), isTrue, reason: '$type');
        expect(legacySpaceType(condition, offStreet: false), type);
        expect(legacySafe(condition), isTrue, reason: '$type');
      }
    });

    test('every legacy access round-trips through its zone condition', () {
      for (final access in ParkingAccess.values) {
        final zone = zoneConditionOf(access)!;
        expect(validCondition(zone.toJson(), zone: true), isTrue);
        expect(legacyAccess(zone), access);
        expect(legacySafeZone(zone), isTrue, reason: '$access');
      }
      expect(zoneConditionOf(null), isNull);
      expect(legacyAccess(null), isNull);
      expect(legacySafeZone(null), isTrue);
    });

    test('9 space types × 5 accesses: legacy rows are always legacy-safe', () {
      for (final type in SpaceType.values) {
        for (final access in [...ParkingAccess.values, null]) {
          final offStreet = isOffStreet(type, null);
          final zones = offStreet ? [zoneConditionOf(access)] : const <Null>[];
          final reason = '$type × $access';
          expect(
            legacySafeSpot(
              offStreet: offStreet,
              condition: conditionOf(type),
              zones: zones,
            ),
            isTrue,
            reason: reason,
          );
          if (offStreet) {
            expect(legacyAccess(zones.single), access, reason: reason);
          } else {
            expect(
              legacySpaceType(conditionOf(type)!, offStreet: false),
              type,
              reason: reason,
            );
          }
        }
      }
    });

    test('one unsafe zone makes the whole lot unsafe', () {
      final unsafe = ParkingCondition.fromJson({
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'allow': {'scooter': true, 'heavy': true},
        'basis': {'source_url': 'https://e.tw/', 'expires_on': '2026-10-05'},
      }, zone: true);
      expect(unsafe, isNotNull);
      expect(
        legacySafeSpot(
          offStreet: true,
          zones: [zoneConditionOf(ParkingAccess.heavyCar), unsafe],
        ),
        isFalse,
      );
      // A lot never carries a top-level condition.
      expect(
        legacySafeSpot(
          offStreet: true,
          condition: conditionOf(SpaceType.paidMotorcycle),
        ),
        isFalse,
      );
    });

    test('placement follows the space type or a lot facility', () {
      expect(isOffStreet(SpaceType.offStreet, null), isTrue);
      expect(
        isOffStreet(SpaceType.paidMotorcycle, FacilityType.surface),
        isTrue,
      );
      expect(
        isOffStreet(SpaceType.paidMotorcycle, FacilityType.roadside),
        isFalse,
      );
      expect(isOffStreet(SpaceType.car, null), isFalse);
    });
  });
}
