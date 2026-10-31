/// Zones and street segments as lists with stable ids, and the seven bay
/// kinds (#188, design canvas Ver.143 S3b, S4, P1).
///
/// Mirrors the `zone`, `segment` and `bay_kinds` sections of
/// supabase/functions/_shared/parking_contract.json; validate.ts
/// (`validZoneEntries`, `validSegments`, `bayKindOf`) and the generated SQL
/// (`valid_zones()`, `valid_segments()`, `condition_bay_kind()`) run the same
/// cases (test/parking_contract_test.dart). Pure Dart.
library;

import 'dart:convert';

import 'fee.dart';
import 'parking.dart' show ParkingAccess;
import 'parking_condition.dart';

/// The id of a zone or a segment, unique in its spot. The tables' trigger
/// gives one to every entry written without it; writers send it back so
/// that it survives renames.
const entryIdPattern = r'^[a-z0-9_-]{1,32}$';

/// The keys a segment may carry (`segment.keys`).
const segmentKeys = [
  'id',
  'name',
  'side',
  'range',
  'condition',
  'total',
  'guide',
  'evidence_url',
];
const segmentMaxEntries = 30;
const segmentNameMaxLength = 40;
const segmentRangeMaxLength = 100;
const segmentGuideMaxLength = 500;
const segmentTotalRange = (1, 9999);

/// Which side of the road a segment runs along (設計稿 S4 「哪一側」).
enum RoadSide {
  east('東側'),
  west('西側'),
  south('南側'),
  north('北側'),
  both('雙側');

  const RoadSide(this.label);
  final String label;
}

/// The seven bay kinds (`bay_kinds.order`): what is painted on the ground,
/// whatever it charges or limits. [wire] is the contract's value.
enum BayKind {
  /// 一般機車格: toll, free or unconfirmed; a time limit does not change it.
  motorcycle('motorcycle'),

  /// 普大共用格: posted for 普通 and 大型重機 all day (decision 64).
  scooterHeavy('scooter_heavy'),

  /// 重機專用格.
  heavy('heavy'),

  /// 汽機車共用格: cars and motorcycles by posted hours.
  carMotorcycle('car_motorcycle'),

  /// 汽車格.
  car('car'),

  /// 身障格: a car bay or a motorcycle bay for permit holders.
  disabled('disabled'),

  /// 充電格: electric motorcycles only.
  ev('ev');

  const BayKind(this.wire);
  final String wire;

  static BayKind? parse(Object? wire) =>
      values.where((k) => k.wire == wire).firstOrNull;
}

/// One `bay_kinds.rules` entry: every non-null field must match.
typedef BayKindRule = ({
  LimitKind? limit,
  ShareKind? share,
  Bay? bay,
  BayKind kind,
});

/// [bayKindOf] checks these in order; the first match wins.
const bayKindRules = <BayKindRule>[
  (
    limit: LimitKind.specialVehicle,
    share: null,
    bay: null,
    kind: BayKind.disabled,
  ),
  (limit: LimitKind.evOnly, share: null, bay: null, kind: BayKind.ev),
  (
    limit: null,
    share: ShareKind.carMotorcycle,
    bay: null,
    kind: BayKind.carMotorcycle,
  ),
  (
    limit: null,
    share: ShareKind.scooterHeavy,
    bay: null,
    kind: BayKind.scooterHeavy,
  ),
  (limit: null, share: null, bay: Bay.heavy, kind: BayKind.heavy),
  (limit: null, share: null, bay: Bay.car, kind: BayKind.car),
  (limit: null, share: null, bay: Bay.motorcycle, kind: BayKind.motorcycle),
];

/// The bay kind [condition] reads as; null when it is unconfirmed (no bay
/// and no deciding limit), as for a lot zone that only says who may park.
BayKind? bayKindOf(ParkingCondition? condition) {
  if (condition == null) return null;
  for (final r in bayKindRules) {
    if ((r.limit == null || condition.hasLimit(r.limit!)) &&
        (r.share == null || condition.share == r.share) &&
        (r.bay == null || condition.bay == r.bay)) {
      return r.kind;
    }
  }
  return null;
}

/// Whether [v] is a string of 1–[max] UTF-16 code units, not blank.
bool _text(Object? v, int max) =>
    v is String && v.trim().isNotEmpty && v.length <= max;

/// An https link within a basis link's limits (`contract_https()`).
bool validEntryUrl(Object? v) =>
    v is String &&
    v.length <= sourceUrlMaxLength &&
    RegExp(sourceUrlPattern).hasMatch(v);

/// Each id present is a string of [entryIdPattern], and no two share one.
bool _validIds(List<Object?> list) {
  final ids = [
    for (final e in list)
      if (e is Map && e.containsKey('id')) e['id'],
  ];
  final pattern = RegExp(entryIdPattern);
  return ids.every((id) => id is String && pattern.hasMatch(id)) &&
      ids.toSet().length == ids.length;
}

/// Whether [json] is a parking_zones list the contract accepts
/// (`valid_zones()`): objects with a valid fee, area and condition (whose
/// access agrees with it), an optional https evidence_url, and ids as
/// above. An entry may leave its id out.
bool validZoneList(Object? json) {
  if (json is! List) return false;
  for (final z in json) {
    if (z is! Map) return false;
    if (z.containsKey('fee') && !validFee(z['fee'])) return false;
    if (z.containsKey('area') &&
        !ZoneArea.values.any((a) => a.name == z['area'])) {
      return false;
    }
    if (z.containsKey('condition') &&
        !(validCondition(z['condition'], zone: true) &&
            zoneConditionConsistent(z.cast<String, Object?>()))) {
      return false;
    }
    if (z.containsKey('evidence_url') && !validEntryUrl(z['evidence_url'])) {
      return false;
    }
  }
  return _validIds(json);
}

/// Whether [json] is a parking_segments list the contract accepts
/// (`valid_segments()`): at most [segmentMaxEntries] named segments with an
/// optional side, range, guide, number of bays, https evidence_url and a
/// zone-style condition without `allow`.
bool validSegmentList(Object? json) {
  if (json is! List || json.length > segmentMaxEntries) return false;
  for (final s in json) {
    if (s is! Map ||
        !s.keys.every(segmentKeys.contains) ||
        !_text(s['name'], segmentNameMaxLength)) {
      return false;
    }
    if (s.containsKey('side') &&
        !RoadSide.values.any((v) => v.name == s['side'])) {
      return false;
    }
    if (s.containsKey('range') && !_text(s['range'], segmentRangeMaxLength)) {
      return false;
    }
    if (s.containsKey('guide') && !_text(s['guide'], segmentGuideMaxLength)) {
      return false;
    }
    final total = s['total'];
    if (s.containsKey('total') &&
        !(total is num &&
            total.isFinite &&
            total == total.truncate() &&
            total >= segmentTotalRange.$1 &&
            total <= segmentTotalRange.$2)) {
      return false;
    }
    final c = s['condition'];
    if (s.containsKey('condition') &&
        !(validCondition(c, zone: true) && !(c as Map).containsKey('allow'))) {
      return false;
    }
    if (s.containsKey('evidence_url') && !validEntryUrl(s['evidence_url'])) {
      return false;
    }
  }
  return _validIds(json);
}

/// [current] (a zone or segment list) with [patch] applied, as
/// `entries_patch()` in SQL applies a suggestion: an entry with an id
/// changes the current entry with that id, its keys replacing the current
/// ones and a null removing one; `{id, removed: true}` removes it; one
/// without an id is added at the end. Null when [patch] is not a list of
/// objects or names an id [current] lacks.
List<Map<String, Object?>>? entriesPatch(List<Object?> current, Object? patch) {
  if (patch is! List) return null;
  final out = [
    for (final e in current)
      if (e is Map) {...e.cast<String, Object?>()},
  ];
  Map<String, Object?> withoutNulls(Map<String, Object?> m) => {
    for (final MapEntry(:key, :value) in m.entries) key: ?value,
  };
  for (final e in patch) {
    if (e is! Map) return null;
    final entry = e.cast<String, Object?>();
    if (!entry.containsKey('id')) {
      if (entry.containsKey('removed')) return null;
      out.add(withoutNulls(entry));
      continue;
    }
    final i = out.indexWhere((z) => z['id'] == entry['id']);
    if (i < 0) return null;
    if (entry.containsKey('removed')) {
      if (entry['removed'] != true || entry.length != 2) return null;
      out.removeAt(i);
    } else {
      final z = withoutNulls({...out[i], ...entry});
      // As entries_patch() in SQL: a fee sent leaves the plan it copied;
      // an access sent without a condition brings the condition's allow,
      // and bay, in line with it, or takes it away with the access.
      if (entry.containsKey('fee') && !entry.containsKey('fee_plan')) {
        z.remove('fee_plan');
      }
      if (entry.containsKey('access') &&
          !entry.containsKey('condition') &&
          z['condition'] is Map) {
        final access = ParkingAccess.values.asNameMap()[z['access']];
        final like = access == null ? null : conditionByAccess[access];
        if (like == null) {
          z.remove('condition');
        } else {
          final c = {
            ...(z['condition'] as Map).cast<String, Object?>(),
            'allow': like.allow!.toJson(),
          };
          if (like.bay != null && c['bay'] != like.bay!.name) {
            c
              ..remove('use')
              ..remove('share')
              ..['bay'] = like.bay!.name;
          }
          z['condition'] = c;
        }
      }
      out[i] = z;
    }
  }
  return out;
}

/// The patch that turns [current] into [next] (the inverse of
/// [entriesPatch]): each entry of [current] that [next] changes, with its
/// changed keys (null for one taken out); each it no longer has, removed;
/// each new one, without an id. Unchanged entries are left out, so a review
/// conflict is only about what the patch touches.
List<Map<String, Object?>> entriesDiff(
  List<Object?> current,
  List<Object?> next,
) {
  String text(Object? v) => jsonEncode(_sorted(v));
  final byId = {
    for (final e in current)
      if (e is Map && e['id'] is String) e['id'] as String: e,
  };
  final kept = <String>{};
  final out = <Map<String, Object?>>[];
  for (final e in next) {
    if (e is! Map) continue;
    final id = e['id'];
    final old = id is String ? byId[id] : null;
    if (old == null) {
      out.add({
        for (final MapEntry(:key, :value) in e.entries)
          if (key != 'id') '$key': value,
      });
      continue;
    }
    kept.add(id as String);
    final change = <String, Object?>{'id': id};
    for (final key in {...old.keys, ...e.keys}) {
      if (key == 'id') continue;
      if (text(old[key]) != text(e[key])) change['$key'] = e[key];
    }
    if (change.length > 1) out.add(change);
  }
  for (final id in byId.keys) {
    if (!kept.contains(id)) out.add({'id': id, 'removed': true});
  }
  return out;
}

Object? _sorted(Object? v) => switch (v) {
  Map() => {
    for (final k in v.keys.map((k) => '$k').toList()..sort()) k: _sorted(v[k]),
  },
  List() => [for (final x in v) _sorted(x)],
  _ => v,
};
