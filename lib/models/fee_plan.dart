/// Fee plans (docs/designs/2026-10-26-parking-conditions-and-fees.md §2.6):
/// a spot's named rates, which its zones (or a street spot itself) refer to
/// by id so bays at one price share one plan. Mirrors `fee_plans` in
/// supabase/functions/_shared/parking_contract.json, `valid_fee_plans()`
/// and the plan functions of supabase/functions/_shared/fee.ts; the shared
/// cases `fee_plans` and `fee_projections` run on every side
/// (test/fee_plan_test.dart).
///
/// A spot or zone that refers to a plan also carries the plan's fee as its
/// own `fee`, kept in step by the database, so builds that read `fee` alone
/// (and favorites) see the rates as they are.
library;

import 'dart:convert';

import 'fee.dart';
import 'parking.dart' show ParkingAccess;
import 'parking_condition.dart';

/// The `fee_plans` rule data of the contract, compared field by field with
/// the JSON in test/fee_plan_test.dart.
const Map<String, Object> feePlansContract = {
  'max_entries': 12,
  'keys': ['id', 'name', 'fee'],
  'id_pattern': r'^[a-z0-9_-]{1,20}$',
  'name_max_length': 20,
};

/// One plan: an [id] unique within the spot, a [name] only administrators
/// see, and its [fee].
class FeePlan {
  const FeePlan({required this.id, required this.name, required this.fee});
  final String id, name;
  final Fee fee;

  /// The plan in [json], or null when it is not one the column accepts.
  static FeePlan? fromJson(Object? json) =>
      json is Map && _validPlan(json, const {})
      ? FeePlan(
          id: json['id'] as String,
          name: json['name'] as String,
          fee: Fee.fromJson(json['fee']),
        )
      : null;

  Map<String, Object> toJson() => {'id': id, 'name': name, 'fee': fee.toJson()};
}

bool _validPlan(Map<Object?, Object?> p, Set<String> seen) {
  final keys = feePlansContract['keys']! as List;
  final id = p['id'], name = p['name'], fee = p['fee'];
  return p.keys.every(keys.contains) &&
      keys.every(p.containsKey) &&
      id is String &&
      RegExp(feePlansContract['id_pattern']! as String).hasMatch(id) &&
      !seen.contains(id) &&
      name is String &&
      name.trim().isNotEmpty &&
      // UTF-16 code units, as JS and the database count.
      name.length <= (feePlansContract['name_max_length']! as int) &&
      validFee(fee) &&
      (fee! as Map).isNotEmpty;
}

/// Whether a spot's fee plans, its own plan reference ([feePlan], with the
/// [fee] it carries) and its [zones]' and [segments]' are what
/// `valid_fee_plans()` and `valid_segment_fee_plans()` (#188 layer 2)
/// accept.
bool validFeePlans(
  Object? plans,
  Object? feePlan,
  Object? fee,
  Object? zones, [
  Object? segments,
]) {
  final byId = <String, Object?>{};
  if (plans != null) {
    if (plans is! List ||
        plans.isEmpty ||
        plans.length > (feePlansContract['max_entries']! as int)) {
      return false;
    }
    for (final p in plans) {
      if (p is! Map || !_validPlan(p, byId.keys.toSet())) return false;
      byId[p['id'] as String] = p['fee'];
    }
  }
  bool copies(Object? id, Object? copy) =>
      id is String && byId.containsKey(id) && _same(copy, byId[id]);
  if (feePlan != null && !copies(feePlan, fee)) return false;
  bool entriesCopy(Object? list) =>
      list is! List ||
      list.every(
        (z) =>
            z is! Map ||
            !z.containsKey('fee_plan') ||
            copies(z['fee_plan'], z['fee']),
      );
  return entriesCopy(zones) && entriesCopy(segments);
}

/// jsonb equality: the same values, object keys in any order.
bool _same(Object? a, Object? b) => switch ((a, b)) {
  (final List<Object?> x, final List<Object?> y) =>
    x.length == y.length &&
        [for (var i = 0; i < x.length; i++) i].every((i) => _same(x[i], y[i])),
  (final Map<Object?, Object?> x, final Map<Object?, Object?> y) =>
    x.length == y.length &&
        x.keys.every((k) => y.containsKey(k) && _same(x[k], y[k])),
  (final num x, final num y) => x == y,
  _ => a == b,
};

/// A plan's fee with a heavy follow worked out (§2.6 precheck, step 1): the
/// followed vehicle's rate (no factor since #188 layer 2), or no heavy rate
/// when that vehicle is unconfirmed or not applicable.
Map<String, Object?> resolveFee(Map<Object?, Object?> fee) {
  final out = <String, Object?>{
    for (final MapEntry(:key, :value) in fee.entries) key! as String: value,
  };
  if (fee['heavy'] case {'mode': final String mode}
      when mode == 'same_as_scooter' || mode == 'same_as_car') {
    final target = fee[mode == 'same_as_scooter' ? 'scooter' : 'car'];
    if (target is Map && target['mode'] != 'not_applicable') {
      out['heavy'] = {
        for (final MapEntry(:key, :value) in target.entries)
          key! as String: value,
      };
    } else {
      out.remove('heavy');
    }
  }
  return out;
}

/// The vehicles a zone's rate counts for (§2.6 precheck, step 2): a heavy
/// bay only heavy bikes; otherwise the motorcycles its allow lets park (read
/// from its access when it has no condition) and cars as they are.
List<String> zoneFeeVehicles(Map<Object?, Object?> zone) {
  final condition =
      ParkingCondition.fromJson(zone['condition'], zone: true) ??
      zoneConditionOf(
        ParkingAccess.values.where((a) => a.name == zone['access']).firstOrNull,
      );
  if (condition?.bay == Bay.heavy) return const ['heavy'];
  final allow = condition?.allow;
  return [
    if (allow?.scooter == true) 'scooter',
    if (allow?.heavy == true) 'heavy',
    'car',
  ];
}

/// A plan's fee as one zone's rates: resolved, then projected.
Map<String, Object?> projectZoneFee(
  Map<Object?, Object?> fee,
  Map<Object?, Object?> zone,
) {
  final vehicles = zoneFeeVehicles(zone);
  return {
    for (final MapEntry(:key, :value) in resolveFee(fee).entries)
      if (vehicles.contains(key)) key: value,
  };
}

/// [json] with object keys sorted, for comparing values by content.
String canonicalJson(Object? json) => jsonEncode(_sorted(json));

Object? _sorted(Object? v) => switch (v) {
  final Map<Object?, Object?> m => {
    for (final k in (m.keys.map((k) => '$k').toList()..sort()))
      k: _sorted(m[k]),
  },
  final List<Object?> l => l.map(_sorted).toList(),
  _ => v,
};
