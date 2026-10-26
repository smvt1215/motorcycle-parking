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
      expect(
        (contract['zone']! as Map<String, Object?>)['area'],
        _wires(ZoneArea.values, (v) => v.name),
      );
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
      final url = basis['source_url']! as Map<String, Object?>;
      expect(url['pattern'], sourceUrlPattern);
      expect(url['max_length'], sourceUrlMaxLength);
      expect(url['length_unit'], sourceUrlLengthUnit);
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
      expect(safe['lossy_when_unconfirmed'], legacyLossyWhenUnconfirmed);
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
        // Stored with the access it writes back, as safe as its condition;
        // stored with another access, never (the same as the generated SQL).
        final access = legacyAccess(zone);
        expect(legacySafeStoredZone(zone, access), c['safe'], reason: name);
        final other = access == ParkingAccess.noMotorcycle
            ? ParkingAccess.scooterOnly
            : ParkingAccess.noMotorcycle;
        expect(legacySafeStoredZone(zone, other), isFalse, reason: name);
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

    test('every street condition the contract accepts: legacySafe agrees '
        'with an independent baseline', () {
      final all = _streetConditions();
      expect(all.length, greaterThan(500));
      var safe = 0;
      for (final json in all) {
        final c = ParkingCondition.fromJson(json)!;
        final type = legacySpaceType(c, offStreet: false)!;
        final got = legacySafe(c);
        expect(got, _streetBaseline(json, type), reason: '$json → $type');
        if (!got) continue;
        safe++;
        // Judged safe: old apps must never read it more loosely.
        expect(_oldReadsLooser(json, type), isFalse, reason: '$json');
      }
      expect(safe, inInclusiveRange(1, all.length - 1));
      // The loose direction exists and is caught.
      final loose = all.where((j) {
        final type = legacySpaceType(
          ParkingCondition.fromJson(j)!,
          offStreet: false,
        )!;
        return _oldReadsLooser(j, type);
      }).toList();
      expect(loose, isNotEmpty);
      for (final j in loose) {
        expect(legacySafe(ParkingCondition.fromJson(j)), isFalse, reason: '$j');
      }
    });

    test('every zone condition the contract accepts: legacySafeZone agrees '
        'with an independent baseline', () {
      final all = _zoneConditions();
      expect(all.length, greaterThan(500));
      var safe = 0;
      for (final json in all) {
        final z = ParkingCondition.fromJson(json, zone: true)!;
        final access = _zoneBaselineAccess(json);
        expect(legacyAccess(z)?.name, access, reason: '$json');
        final got = legacySafeZone(z);
        expect(got, _zoneBaseline(json, access), reason: '$json');
        if (!got) continue;
        safe++;
        // Judged safe: the old access opens exactly what the zone opens.
        final belief = _zoneBeliefs[access]!;
        expect(json['allow'], {
          'scooter': belief.scooter,
          'heavy': belief.heavy,
        }, reason: '$json');
        expect(
          ['limits', 'schedule'].any(json.containsKey),
          isFalse,
          reason: '$json',
        );
        expect(_expires(json), isFalse, reason: '$json');
      }
      expect(safe, inInclusiveRange(1, all.length - 1));
    });

    test('the legacy-safe rule data drives the decision', () {
      ParkingCondition c(Map<String, Object?> json) =>
          ParkingCondition.fromJson(json)!;
      const paid = {'bay': 'motorcycle', 'use': 'usual', 'charge': 'toll'};
      final timedFree = c({
        ...paid,
        'charge': 'free',
        'limits': [
          {'kind': 'time_limit'},
        ],
      });
      final timedMinutes = c({
        ...paid,
        'limits': [
          {'kind': 'time_limit', 'max_minutes': 20},
        ],
      });
      final expiring = c({
        ...paid,
        'basis': {'source_url': 'https://e.tw/', 'expires_on': '2027-01-01'},
      });
      final heavyToll = c({'bay': 'heavy', 'use': 'usual', 'charge': 'toll'});
      final shared = c({
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'charge': 'toll',
      });
      LegacySafeRules rules({
        List<String> unsafeKeys = legacyUnsafeKeys,
        List<String> unsafeBasisKeys = legacyUnsafeBasisKeys,
        ShareKind lossyShare = legacyLossyShare,
        List<String> lossyLimitKeys = legacyLossyLimitKeys,
        List<String> lossyWhenUnconfirmed = legacyLossyWhenUnconfirmed,
        Map<SpaceType, Charge> assumedCharge = legacyAssumedCharge,
      }) => (
        unsafeKeys: unsafeKeys,
        unsafeBasisKeys: unsafeBasisKeys,
        lossyShare: lossyShare,
        lossyLimitKeys: lossyLimitKeys,
        lossyWhenUnconfirmed: lossyWhenUnconfirmed,
        assumedCharge: assumedCharge,
      );
      expect(legacySafeRules, rules());
      for (final (condition, base, changed) in [
        (timedFree, false, rules(assumedCharge: {})),
        (timedMinutes, true, rules(lossyLimitKeys: [])),
        (timedMinutes, true, rules(unsafeKeys: ['schedule', 'limits'])),
        (expiring, false, rules(unsafeBasisKeys: [])),
        (heavyToll, true, rules(lossyWhenUnconfirmed: ['bay', 'use'])),
        (shared, true, rules(lossyShare: ShareKind.carMotorcycle)),
      ]) {
        expect(legacySafe(condition), base, reason: '$condition');
        expect(
          legacySafe(condition, rules: changed),
          !base,
          reason: '$condition with $changed',
        );
      }
      final zone = ParkingCondition.fromJson({
        'bay': 'motorcycle',
        'use': 'usual',
        'charge': 'toll',
        'allow': {'scooter': true, 'heavy': false},
      }, zone: true);
      expect(legacySafeZone(zone), isTrue);
      expect(
        legacySafeZone(zone, rules: rules(lossyWhenUnconfirmed: [])),
        isFalse,
      );
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

// An independent statement of what old apps read, kept apart from the
// implementation: for each legacy type the bay, the use and share (null when
// the old app does not say), the charge (null when unknown; `assumed` when
// old apps take it for granted) and the limit kinds.
typedef _Belief = ({
  String bay,
  String? use,
  String? share,
  String? charge,
  bool assumed,
  Set<String> limits,
});
const _beliefs = <SpaceType, _Belief>{
  SpaceType.paidMotorcycle: (
    bay: 'motorcycle',
    use: 'usual',
    share: null,
    charge: 'toll',
    assumed: false,
    limits: {},
  ),
  SpaceType.freeMotorcycle: (
    bay: 'motorcycle',
    use: 'usual',
    share: null,
    charge: 'free',
    assumed: false,
    limits: {},
  ),
  SpaceType.heavyOnly: (
    bay: 'heavy',
    use: 'usual',
    share: null,
    charge: null,
    assumed: false,
    limits: {},
  ),
  SpaceType.car: (
    bay: 'car',
    use: 'usual',
    share: null,
    charge: null,
    assumed: false,
    limits: {},
  ),
  SpaceType.disabledMotorcycle: (
    bay: 'motorcycle',
    use: null,
    share: null,
    charge: null,
    assumed: false,
    limits: {'special_vehicle'},
  ),
  SpaceType.timedMotorcycle: (
    bay: 'motorcycle',
    use: 'usual',
    share: null,
    charge: 'toll',
    assumed: true,
    limits: {'time_limit'},
  ),
  SpaceType.flexShared: (
    bay: 'car',
    use: 'share',
    share: 'car_motorcycle',
    charge: null,
    assumed: false,
    limits: {},
  ),
  SpaceType.evMotorcycle: (
    bay: 'motorcycle',
    use: null,
    share: null,
    charge: null,
    assumed: false,
    limits: {'ev_only'},
  ),
};

Set<String> _kinds(Map<String, Object?> json) => {
  for (final l in (json['limits'] as List?) ?? const [])
    (l as Map)['kind'] as String,
};

bool _expires(Map<String, Object?> json) =>
    (json['basis'] as Map?)?.containsKey('expires_on') ?? false;

/// Old apps read [json], stored as [type], more loosely than it is: a
/// limit, time window, end date, bay or stated charge they do not see.
bool _oldReadsLooser(Map<String, Object?> json, SpaceType type) {
  final b = _beliefs[type]!;
  final charge = json['charge'];
  return json.containsKey('schedule') ||
      _expires(json) ||
      json['bay'] != b.bay ||
      !_kinds(json).containsAll(b.limits) ||
      !b.limits.containsAll(_kinds(json)) ||
      (b.charge != null && charge != null && charge != b.charge);
}

bool _streetBaseline(Map<String, Object?> json, SpaceType type) {
  final b = _beliefs[type]!;
  if (_oldReadsLooser(json, type)) return false;
  final use = json['use'], share = json['share'], charge = json['charge'];
  final useOk = switch (b.use) {
    null => true,
    'usual' => (use == 'usual' && share == null) || share == 'scooter_heavy',
    _ => use == b.use && share == b.share,
  };
  final chargeOk =
      b.charge == null || charge == b.charge || (b.assumed && charge == null);
  return useOk && chargeOk;
}

/// Every combination of facets, kept when the contract accepts it.
List<Map<String, Object?>> _streetConditions() => [
  for (final bay in [null, 'motorcycle', 'heavy', 'car'])
    for (final (use, share) in _uses)
      for (final charge in [null, 'toll', 'free'])
        for (final limits in _limitSets)
          for (final schedule in [false, true])
            for (final basis in _bases)
              {
                'bay': ?bay,
                'use': ?use,
                'share': ?share,
                'charge': ?charge,
                if (limits.isNotEmpty) 'limits': limits,
                if (schedule) 'schedule': _slot,
                'basis': ?basis,
              },
].where(validCondition).toList();

const _uses = <(String?, String?)>[
  (null, null),
  ('usual', null),
  ('share', 'scooter_heavy'),
  ('share', 'car_motorcycle'),
  (null, 'scooter_heavy'),
];
const _slot = [
  {
    'days': 'all',
    'from': '07:00',
    'to': '20:00',
    'vehicles': ['heavy'],
  },
];
const _bases = <Map<String, Object?>?>[
  null,
  {'source_url': 'https://e.tw/', 'effective_date': '2026-04-06'},
  {'source_url': 'https://e.tw/', 'expires_on': '2026-10-05'},
];
final _limitSets = [
  for (final time in [
    null,
    {'kind': 'time_limit'},
    {'kind': 'time_limit', 'max_minutes': 20},
  ])
    for (final special in [false, true])
      for (final ev in [false, true])
        [
          ?time,
          if (special)
            {'kind': 'special_vehicle', 'vehicle': 'disabled_modified'},
          if (ev) {'kind': 'ev_only'},
        ],
];

// What each legacy access tells old apps about a zone.
typedef _ZoneBelief = ({
  bool scooter,
  bool heavy,
  String? bay,
  String? use,
  String? share,
});
const _zoneBeliefs = <String, _ZoneBelief>{
  'scooterOnly': (
    scooter: true,
    heavy: false,
    bay: 'motorcycle',
    use: 'usual',
    share: null,
  ),
  'scooterHeavy': (
    scooter: true,
    heavy: true,
    bay: 'motorcycle',
    use: 'share',
    share: 'scooter_heavy',
  ),
  'heavyCar': (
    scooter: false,
    heavy: true,
    bay: 'car',
    use: 'usual',
    share: null,
  ),
  'heavyOnly': (
    scooter: false,
    heavy: true,
    bay: 'heavy',
    use: 'usual',
    share: null,
  ),
  'noMotorcycle': (
    scooter: false,
    heavy: false,
    bay: null,
    use: null,
    share: null,
  ),
};

String? _zoneBaselineAccess(Map<String, Object?> json) {
  final allow = json['allow'] as Map?;
  for (final MapEntry(:key, value: b) in _zoneBeliefs.entries) {
    if (allow?['scooter'] == b.scooter &&
        allow?['heavy'] == b.heavy &&
        (b.bay == null || json['bay'] == b.bay)) {
      return key;
    }
  }
  return null;
}

bool _zoneBaseline(Map<String, Object?> json, String? access) {
  if (access == null ||
      ['limits', 'schedule'].any(json.containsKey) ||
      _expires(json)) {
    return false;
  }
  final b = _zoneBeliefs[access]!;
  final use = json['use'], share = json['share'];
  return switch (b.use) {
    null => true,
    'usual' => (use == 'usual' && share == null) || share == 'scooter_heavy',
    _ => use == b.use && share == b.share,
  };
}

List<Map<String, Object?>> _zoneConditions() => [
  for (final bay in [null, 'motorcycle', 'heavy', 'car'])
    for (final (use, share) in _uses)
      for (final charge in [null, 'toll'])
        for (final scooter in [null, true, false])
          for (final heavy in [null, true, false])
            for (final ev in [false, true])
              for (final schedule in [false, true])
                for (final basis in _bases)
                  {
                    'bay': ?bay,
                    'use': ?use,
                    'share': ?share,
                    'charge': ?charge,
                    if (ev)
                      'limits': [
                        {'kind': 'ev_only'},
                      ],
                    if (schedule) 'schedule': _slot,
                    'basis': ?basis,
                    if (scooter != null || heavy != null)
                      'allow': {'scooter': ?scooter, 'heavy': ?heavy},
                  },
].where((j) => validCondition(j, zone: true)).toList();
