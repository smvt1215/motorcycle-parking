/// Parking conditions and their single conversion to the legacy
/// `space_type` and zone `access` values
/// (docs/designs/2026-10-26-parking-conditions-and-fees.md §1.2–§1.4, §4).
///
/// The contract lives in supabase/functions/_shared/parking_contract.json;
/// validate.ts imports it, tool/gen_contract_sql.py generates the SQL from
/// it, and this file mirrors it as constants that
/// test/parking_contract_test.dart compares field by field. All three sides
/// run parking_contract_cases.json. Pure Dart: the app and the admin site
/// share it.
library;

import 'dart:convert';

import 'parking.dart';

const parkingContractVersion = 1;

/// The kind of bay painted on the ground.
enum Bay { motorcycle, heavy, car }

/// Whether a bay serves its own vehicles or a posted shared use.
enum BayUse { usual, share }

/// The two shared uses, each painted on one kind of bay (§1.1, 需求 4).
enum ShareKind {
  scooterHeavy('scooter_heavy', Bay.motorcycle),
  carMotorcycle('car_motorcycle', Bay.car);

  const ShareKind(this.wire, this.bay);
  final String wire;

  /// The only bay this shared use may be painted on.
  final Bay bay;
}

/// Toll or free; a toll bay whose first period costs 0 is still toll.
enum Charge { toll, free }

enum LimitKind {
  timeLimit('time_limit'),
  specialVehicle('special_vehicle'),
  evOnly('ev_only');

  const LimitKind(this.wire);
  final String wire;
}

/// Vehicles a `special_vehicle` limit names.
enum SpecialVehicle {
  /// 經監理單位檢驗合格的身障特製機車；持識別證本身不足.
  disabledModified('disabled_modified');

  const SpecialVehicle(this.wire);
  final String wire;
}

/// Vehicles a schedule slot lets park.
enum SlotVehicle { scooter, heavy, car }

/// Which off-street spaces and facilities place a spot off the street.
const offStreetSpaceTypes = {SpaceType.offStreet};
const offStreetFacilityTypes = {
  FacilityType.multiStorey,
  FacilityType.underground,
  FacilityType.surface,
};

/// Whether a spot is off the street (§1.1 placement); never stored.
bool isOffStreet(SpaceType type, FacilityType? facility) =>
    offStreetSpaceTypes.contains(type) ||
    offStreetFacilityTypes.contains(facility);

const timePattern = r'^([01][0-9]|2[0-3]):[0-5][0-9]$';
const datePattern = r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$';
const scheduleDayPresets = ['all', 'weekday', 'holiday'];
const scheduleWeekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const scheduleMaxEntries = 8;
const conditionKeys = [
  'bay',
  'use',
  'share',
  'charge',
  'limits',
  'schedule',
  'basis',
];
const conditionZoneKeys = ['allow'];
const allowKeys = ['scooter', 'heavy'];

/// The keys each limit kind must and may carry, with whole-number ranges.
const limitKeys =
    <LimitKind, ({List<String> required, Map<String, (int, int)> optional})>{
      LimitKind.timeLimit: (required: [], optional: {'max_minutes': (1, 1440)}),
      LimitKind.specialVehicle: (required: ['vehicle'], optional: {}),
      LimitKind.evOnly: (required: [], optional: {}),
    };

/// A street bay on a motorcycle bay must say toll or free unless one of
/// these limits already decides its legacy space type (§4.3).
const streetChargeOptionalWith = {
  LimitKind.timeLimit,
  LimitKind.specialVehicle,
  LimitKind.evOnly,
};
const basisKeys = ['source_url', 'evidence_id', 'effective_date', 'expires_on'];

/// One of these must be present; reserved keys are refused until the
/// verification plan's P2 photo evidence ships (§1.4).
const basisRequiredOneOf = ['source_url', 'evidence_id'];
const basisReserved = ['evidence_id'];
const sourceUrlPattern = r'^https://\S+$';
const sourceUrlMaxLength = 2048;

/// The rule data of the fee contract (§2.2), mirrored as the JSON holds it.
/// `Fee` and `Rate` still read the v1 shape; the fee v2 PR switches them.
const Map<String, Object?> feeContract = {
  'max_bytes': 4096,
  'vehicles': ['scooter', 'heavy', 'car'],
  'follow': {
    'vehicles': ['heavy'],
    'modes': ['same_as_scooter', 'same_as_car'],
    'optional': {
      'factor_pct': {'min': 100, 'max': 1000},
    },
  },
  'modes': {
    'free': {'required': <String, Object?>{}, 'optional': <String, Object?>{}},
    'posted': {
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'hourly': {
      'required': {
        'amount': {'min': 0, 'max': 10000},
        'per_minutes': {'min': 1, 'max': 1440},
      },
      'optional': {
        'unit_minutes': {'min': 1, 'max': 'per_minutes'},
        'free_minutes': {'min': 1, 'max': 1440},
        'daily_cap': {'min': 0, 'max': 10000},
        'cap_reset': 'cap_reset',
      },
    },
    'per_visit': {
      'required': {
        'amount': {'min': 0, 'max': 10000},
      },
      'optional': {
        'max_minutes': {'min': 1, 'max': 1440},
        'renew': 'renew',
        'extension': 'extension',
      },
    },
    'daily': {
      'required': {
        'amount': {'min': 0, 'max': 10000},
      },
      'optional': {'cap_reset': 'cap_reset'},
    },
    'by_time': {
      'required': {'periods': 'periods'},
      'optional': {'cross_period': 'cross_period'},
    },
  },
  'enums': {
    'cap_reset': ['calendar_day', 'rolling_24h', 'per_entry'],
    'renew': ['none', 'midnight'],
    'cross_period': ['each_period', 'entry_only'],
  },
  'extension': {
    'required': {
      'amount': {'min': 0, 'max': 10000},
      'max_times': {'min': 1, 'max': 10},
    },
    'optional': {
      'minutes': {'min': 1, 'max': 1440},
    },
  },
  'periods': {
    'max_entries': 6,
    'keys': ['days', 'from', 'to', 'rate'],
    'nested_modes': ['free', 'posted', 'hourly', 'per_visit', 'daily'],
  },
};

class ParkingLimit {
  const ParkingLimit(this.kind, {this.maxMinutes, this.vehicle});
  final LimitKind kind;

  /// Only for [LimitKind.timeLimit]; null is unconfirmed.
  final int? maxMinutes;

  /// Only for [LimitKind.specialVehicle], where it is required.
  final SpecialVehicle? vehicle;

  Map<String, Object> toJson() => {
    'kind': kind.wire,
    'max_minutes': ?maxMinutes,
    'vehicle': ?vehicle?.wire,
  };
}

/// When the posted vehicles may park; `from > to` crosses midnight.
class ScheduleSlot {
  const ScheduleSlot({
    required this.days,
    required this.from,
    required this.to,
    required this.vehicles,
  });

  /// `all`, `weekday` or `holiday`, or a list of weekdays such as `mon`.
  final Object days;
  final String from, to;
  final List<SlotVehicle> vehicles;

  Map<String, Object> toJson() => {
    'days': days,
    'from': from,
    'to': to,
    'vehicles': [for (final v in vehicles) v.name],
  };
}

/// The notice a condition rests on (§1.4).
class ConditionBasis {
  const ConditionBasis({
    required this.sourceUrl,
    this.effectiveDate,
    this.expiresOn,
  });
  final String sourceUrl;

  /// `YYYY-MM-DD`; null when the notice does not say.
  final String? effectiveDate, expiresOn;

  Map<String, Object> toJson() => {
    'source_url': sourceUrl,
    'effective_date': ?effectiveDate,
    'expires_on': ?expiresOn,
  };
}

/// A zone's explicit opening or exclusion per vehicle; null keys follow the
/// law and notices.
class ZoneAllow {
  const ZoneAllow({this.scooter, this.heavy});
  final bool? scooter, heavy;

  Map<String, Object> toJson() => {'scooter': ?scooter, 'heavy': ?heavy};
}

/// A bay's (or a zone's) parking condition (§1.2). Every facet may be null:
/// null is unconfirmed and never falls back to another vehicle, zone or
/// spot.
class ParkingCondition {
  const ParkingCondition({
    this.bay,
    this.use,
    this.share,
    this.charge,
    this.limits = const [],
    this.schedule = const [],
    this.basis,
    this.allow,
  });

  final Bay? bay;
  final BayUse? use;
  final ShareKind? share;
  final Charge? charge;

  /// In [LimitKind] order, at most one of each kind.
  final List<ParkingLimit> limits;
  final List<ScheduleSlot> schedule;
  final ConditionBasis? basis;

  /// Zones only.
  final ZoneAllow? allow;

  bool hasLimit(LimitKind kind) => limits.any((l) => l.kind == kind);

  /// The condition in [json], or null — unconfirmed as a whole — when any
  /// part breaks the contract. A broken limit must never read as no limit.
  static ParkingCondition? fromJson(Object? json, {bool zone = false}) {
    if (!validCondition(json, zone: zone)) return null;
    final c = json! as Map;
    T? pick<T>(List<T> values, String key, String Function(T) wire) =>
        values.where((v) => wire(v) == c[key]).firstOrNull;
    final limits = [
      for (final l in (c['limits'] as List?) ?? const [])
        ParkingLimit(
          LimitKind.values.firstWhere((k) => k.wire == l['kind']),
          maxMinutes: l['max_minutes'] as int?,
          vehicle: SpecialVehicle.values
              .where((v) => v.wire == l['vehicle'])
              .firstOrNull,
        ),
    ]..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    final basis = c['basis'] as Map?;
    final allow = c['allow'] as Map?;
    return ParkingCondition(
      bay: pick(Bay.values, 'bay', (v) => v.name),
      use: pick(BayUse.values, 'use', (v) => v.name),
      share: pick(ShareKind.values, 'share', (v) => v.wire),
      charge: pick(Charge.values, 'charge', (v) => v.name),
      limits: limits,
      schedule: [
        for (final s in (c['schedule'] as List?) ?? const [])
          ScheduleSlot(
            days: s['days'] is List
                ? List<String>.from(s['days'] as List)
                : s['days'] as String,
            from: s['from'] as String,
            to: s['to'] as String,
            vehicles: [
              for (final v in s['vehicles'] as List)
                SlotVehicle.values.byName(v as String),
            ],
          ),
      ],
      basis: basis == null
          ? null
          : ConditionBasis(
              sourceUrl: basis['source_url'] as String,
              effectiveDate: basis['effective_date'] as String?,
              expiresOn: basis['expires_on'] as String?,
            ),
      allow: allow == null
          ? null
          : ZoneAllow(
              scooter: allow['scooter'] as bool?,
              heavy: allow['heavy'] as bool?,
            ),
    );
  }

  Map<String, Object> toJson() => {
    'bay': ?bay?.name,
    'use': ?use?.name,
    'share': ?share?.wire,
    'charge': ?charge?.name,
    if (limits.isNotEmpty) 'limits': [for (final l in limits) l.toJson()],
    if (schedule.isNotEmpty) 'schedule': [for (final s in schedule) s.toJson()],
    if (basis != null) 'basis': basis!.toJson(),
    if (allow != null) 'allow': allow!.toJson(),
  };

  ParkingCondition _copy({
    Bay? Function()? bay,
    BayUse? Function()? use,
    ShareKind? Function()? share,
    Charge? Function()? charge,
    List<ParkingLimit>? limits,
    ConditionBasis? Function()? basis,
  }) => ParkingCondition(
    bay: bay == null ? this.bay : bay(),
    use: use == null ? this.use : use(),
    share: share == null ? this.share : share(),
    charge: charge == null ? this.charge : charge(),
    limits: limits ?? this.limits,
    schedule: schedule,
    basis: basis == null ? this.basis : basis(),
    allow: allow,
  );

  @override
  bool operator ==(Object other) =>
      other is ParkingCondition &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => jsonEncode(toJson());
}

bool _whole(Object? v, int min, int max) => v is int && v >= min && v <= max;

bool _realDate(Object? v) {
  if (v is! String || !RegExp(datePattern).hasMatch(v)) return false;
  final d = DateTime.tryParse(v);
  return d != null && d.toIso8601String().startsWith(v);
}

/// A non-empty list of distinct strings drawn from [values].
bool _subset(Object? v, List<String> values, {int? max}) =>
    v is List &&
    v.isNotEmpty &&
    (max == null || v.length <= max) &&
    v.every((x) => x is String && values.contains(x)) &&
    v.toSet().length == v.length;

/// `days`, `from` and `to` of a schedule slot or a fee period.
bool validSlotTimes(Map<Object?, Object?> slot) {
  final days = slot['days'];
  final time = RegExp(timePattern);
  return (days is String
          ? scheduleDayPresets.contains(days)
          : _subset(days, scheduleWeekdays)) &&
      slot['from'] is String &&
      slot['to'] is String &&
      time.hasMatch(slot['from'] as String) &&
      time.hasMatch(slot['to'] as String) &&
      slot['from'] != slot['to'];
}

/// Whether [json] is a condition the contract accepts; the same rules as
/// `validCondition` in validate.ts and `valid_condition()` in SQL. A zone
/// may carry `allow` and may leave the bay unconfirmed; a street condition
/// must name its bay and, on a motorcycle bay, toll or free unless a limit
/// decides the legacy space type.
bool validCondition(Object? json, {bool zone = false}) {
  if (json is! Map || json.isEmpty) return false;
  final c = json;
  if (!c.keys.every(
    (k) => conditionKeys.contains(k) || (zone && conditionZoneKeys.contains(k)),
  )) {
    return false;
  }
  bool inEnum<T extends Enum>(
    String key,
    List<T> values,
    String Function(T) w,
  ) => !c.containsKey(key) || values.any((v) => w(v) == c[key]);
  if (!inEnum('bay', Bay.values, (v) => v.name) ||
      !inEnum('use', BayUse.values, (v) => v.name) ||
      !inEnum('share', ShareKind.values, (v) => v.wire) ||
      !inEnum('charge', Charge.values, (v) => v.name)) {
    return false;
  }
  if (!zone && !c.containsKey('bay')) return false;
  final share = ShareKind.values.where((s) => s.wire == c['share']).firstOrNull;
  if ((share != null) != (c['use'] == 'share')) return false;
  if (share != null && c['bay'] != share.bay.name) return false;

  final kinds = <LimitKind>{};
  if (c.containsKey('limits')) {
    final limits = c['limits'];
    if (limits is! List ||
        limits.isEmpty ||
        limits.length > LimitKind.values.length) {
      return false;
    }
    for (final l in limits) {
      if (l is! Map) return false;
      final kind = LimitKind.values
          .where((k) => k.wire == l['kind'])
          .firstOrNull;
      if (kind == null || !kinds.add(kind)) return false;
      final spec = limitKeys[kind]!;
      for (final MapEntry(:key, :value) in l.entries) {
        if (key == 'kind' || spec.required.contains(key)) continue;
        final range = spec.optional[key];
        if (range == null || !_whole(value, range.$1, range.$2)) return false;
      }
      if (!spec.required.every(l.containsKey)) return false;
      if (l.containsKey('vehicle') &&
          !SpecialVehicle.values.any((v) => v.wire == l['vehicle'])) {
        return false;
      }
    }
  }
  if (!zone &&
      c['bay'] == Bay.motorcycle.name &&
      !c.containsKey('charge') &&
      !kinds.any(streetChargeOptionalWith.contains)) {
    return false;
  }

  if (c.containsKey('allow')) {
    final allow = c['allow'];
    if (allow is! Map ||
        allow.isEmpty ||
        !allow.entries.every(
          (e) => allowKeys.contains(e.key) && e.value is bool,
        )) {
      return false;
    }
    if (allow['scooter'] == true && c['bay'] == Bay.heavy.name) return false;
  }

  if (c.containsKey('schedule')) {
    final schedule = c['schedule'];
    if (schedule is! List ||
        schedule.isEmpty ||
        schedule.length > scheduleMaxEntries) {
      return false;
    }
    for (final s in schedule) {
      if (s is! Map ||
          s.length != 4 ||
          !validSlotTimes(s) ||
          !_subset(s['vehicles'], [
            for (final v in SlotVehicle.values) v.name,
          ])) {
        return false;
      }
    }
  }

  if (c.containsKey('basis')) {
    final basis = c['basis'];
    if (basis is! Map || !basis.keys.every(basisKeys.contains)) return false;
    for (final key in basisReserved) {
      if (basis[key] != null) return false;
    }
    if (!basisRequiredOneOf.any((k) => basis[k] != null)) return false;
    final url = basis['source_url'];
    if (basis.containsKey('source_url') &&
        (url is! String ||
            url.length > sourceUrlMaxLength ||
            !RegExp(sourceUrlPattern).hasMatch(url))) {
      return false;
    }
    for (final key in ['effective_date', 'expires_on']) {
      if (basis[key] != null && !_realDate(basis[key])) return false;
    }
    final from = basis['effective_date'], to = basis['expires_on'];
    if (from is String && to is String && to.compareTo(from) <= 0) {
      return false;
    }
  }
  return true;
}

/// How a legacy `space_type` reads as a condition (§1.3); null for
/// `offStreet`, whose zones carry the conditions.
const conditionBySpaceType = <SpaceType, ParkingCondition?>{
  SpaceType.paidMotorcycle: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    charge: Charge.toll,
  ),
  SpaceType.freeMotorcycle: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    charge: Charge.free,
  ),
  SpaceType.heavyOnly: ParkingCondition(bay: Bay.heavy, use: BayUse.usual),
  SpaceType.car: ParkingCondition(bay: Bay.car, use: BayUse.usual),
  SpaceType.offStreet: null,
  SpaceType.disabledMotorcycle: ParkingCondition(
    bay: Bay.motorcycle,
    limits: [
      ParkingLimit(
        LimitKind.specialVehicle,
        vehicle: SpecialVehicle.disabledModified,
      ),
    ],
  ),
  SpaceType.timedMotorcycle: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    limits: [ParkingLimit(LimitKind.timeLimit)],
  ),
  SpaceType.flexShared: ParkingCondition(
    bay: Bay.car,
    use: BayUse.share,
    share: ShareKind.carMotorcycle,
  ),
  SpaceType.evMotorcycle: ParkingCondition(
    bay: Bay.motorcycle,
    limits: [ParkingLimit(LimitKind.evOnly)],
  ),
};

/// How a legacy zone `access` reads as a zone condition (§1.3); every
/// exclusion lands in `allow`.
const conditionByAccess = <ParkingAccess, ParkingCondition>{
  ParkingAccess.scooterOnly: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    allow: ZoneAllow(scooter: true, heavy: false),
  ),
  ParkingAccess.scooterHeavy: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.share,
    share: ShareKind.scooterHeavy,
    allow: ZoneAllow(scooter: true, heavy: true),
  ),
  ParkingAccess.heavyCar: ParkingCondition(
    bay: Bay.car,
    use: BayUse.usual,
    allow: ZoneAllow(scooter: false, heavy: true),
  ),
  ParkingAccess.heavyOnly: ParkingCondition(
    bay: Bay.heavy,
    use: BayUse.usual,
    allow: ZoneAllow(scooter: false, heavy: true),
  ),
  ParkingAccess.noMotorcycle: ParkingCondition(
    allow: ZoneAllow(scooter: false, heavy: false),
  ),
};

/// One `to_space_type` rule: every non-null field must match.
typedef SpaceTypeRule = ({
  bool? offStreet,
  LimitKind? limit,
  ShareKind? share,
  Bay? bay,
  Charge? charge,
  SpaceType spaceType,
});

/// `legacySpaceType` checks these in order; the first match wins (§1.3).
const legacySpaceTypeRules = <SpaceTypeRule>[
  (
    offStreet: true,
    limit: null,
    share: null,
    bay: null,
    charge: null,
    spaceType: SpaceType.offStreet,
  ),
  (
    offStreet: null,
    limit: LimitKind.specialVehicle,
    share: null,
    bay: null,
    charge: null,
    spaceType: SpaceType.disabledMotorcycle,
  ),
  (
    offStreet: null,
    limit: LimitKind.evOnly,
    share: null,
    bay: null,
    charge: null,
    spaceType: SpaceType.evMotorcycle,
  ),
  (
    offStreet: null,
    limit: null,
    share: ShareKind.carMotorcycle,
    bay: null,
    charge: null,
    spaceType: SpaceType.flexShared,
  ),
  (
    offStreet: null,
    limit: LimitKind.timeLimit,
    share: null,
    bay: null,
    charge: null,
    spaceType: SpaceType.timedMotorcycle,
  ),
  (
    offStreet: null,
    limit: null,
    share: null,
    bay: Bay.heavy,
    charge: null,
    spaceType: SpaceType.heavyOnly,
  ),
  (
    offStreet: null,
    limit: null,
    share: null,
    bay: Bay.car,
    charge: null,
    spaceType: SpaceType.car,
  ),
  (
    offStreet: null,
    limit: null,
    share: null,
    bay: Bay.motorcycle,
    charge: Charge.toll,
    spaceType: SpaceType.paidMotorcycle,
  ),
  (
    offStreet: null,
    limit: null,
    share: null,
    bay: Bay.motorcycle,
    charge: Charge.free,
    spaceType: SpaceType.freeMotorcycle,
  ),
];

/// Legacy-safe comparison (§1.3): facets that are always unsafe, and the
/// charge old apps assume for a space type whose condition leaves it open.
const legacyUnsafeKeys = ['schedule'];
const legacyUnsafeBasisKeys = ['expires_on'];
const legacyLossyShare = ShareKind.scooterHeavy;
const legacyLossyLimitKeys = ['max_minutes'];
const legacyAssumedCharge = {SpaceType.timedMotorcycle: Charge.toll};

/// The condition a legacy row without one stands for.
ParkingCondition? conditionOf(SpaceType type) => conditionBySpaceType[type];

/// The zone condition a legacy `access` stands for; null stays unconfirmed.
ParkingCondition? zoneConditionOf(ParkingAccess? access) =>
    access == null ? null : conditionByAccess[access];

/// The `space_type` a condition is stored under; null when no rule matches,
/// which a valid street condition never hits.
SpaceType? legacySpaceType(
  ParkingCondition condition, {
  required bool offStreet,
}) {
  for (final r in legacySpaceTypeRules) {
    if ((r.offStreet == null || r.offStreet == offStreet) &&
        (r.limit == null || condition.hasLimit(r.limit!)) &&
        (r.share == null || condition.share == r.share) &&
        (r.bay == null || condition.bay == r.bay) &&
        (r.charge == null || condition.charge == r.charge)) {
      return r.spaceType;
    }
  }
  return null;
}

/// The legacy `access` a zone condition is written back as: the entry with
/// the same `allow` and, when the entry names one, the same bay.
ParkingAccess? legacyAccess(ParkingCondition? zone) {
  final allow = zone?.allow;
  if (allow == null) return null;
  for (final MapEntry(:key, :value) in conditionByAccess.entries) {
    if (value.allow!.scooter == allow.scooter &&
        value.allow!.heavy == allow.heavy &&
        (value.bay == null || value.bay == zone!.bay)) {
      return key;
    }
  }
  return null;
}

/// Whether [original] reads back as [back] after the legacy round trip,
/// losing only what old apps already treat as unconfirmed (§1.3, (a)–(d)).
bool _survives(
  ParkingCondition original,
  ParkingCondition back,
  Charge? assumed,
) {
  if (original.schedule.isNotEmpty) return false;
  if (original.basis?.expiresOn != null) return false;
  if (assumed != null &&
      back.charge == null &&
      original.charge != null &&
      original.charge != assumed) {
    return false;
  }
  final lossyShare =
      original.share == legacyLossyShare &&
      back.use == BayUse.usual &&
      back.share == null;
  final kept = original._copy(
    // (b) a basis without an end date.
    basis: () => null,
    // (c) a time limit's minutes.
    limits: [
      for (final l in original.limits) ParkingLimit(l.kind, vehicle: l.vehicle),
    ],
    // (a) shared scooter and heavy bays read back as usual.
    use: lossyShare ? () => BayUse.usual : null,
    share: lossyShare ? () => null : null,
    // (d) any facet the legacy value leaves unconfirmed.
    bay: back.bay == null ? () => null : null,
    charge: back.charge == null ? () => null : null,
  );
  final cmp = back.use == null
      ? kept._copy(use: () => null, share: () => null)
      : kept;
  return cmp == back;
}

/// Whether old apps reading only `space_type` see the same street condition,
/// or a more conservative one.
bool legacySafe(ParkingCondition? condition) {
  if (condition == null) return true;
  final type = legacySpaceType(condition, offStreet: false);
  final back = type == null ? null : conditionOf(type);
  return back != null && _survives(condition, back, legacyAssumedCharge[type]);
}

/// Whether a zone condition is fully expressed by its legacy `access`.
bool legacySafeZone(ParkingCondition? zone) {
  if (zone == null) return true;
  if (zone.limits.isNotEmpty) return false;
  final back = zoneConditionOf(legacyAccess(zone));
  return back != null && _survives(zone, back, null);
}

/// Whether a whole spot is legacy-safe: a lot only when every zone is.
bool legacySafeSpot({
  required bool offStreet,
  ParkingCondition? condition,
  Iterable<ParkingCondition?> zones = const [],
}) => offStreet
    ? condition == null && zones.every(legacySafeZone)
    : legacySafe(condition);
