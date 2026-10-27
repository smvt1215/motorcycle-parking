/// A lot's fee plans and zones as the admin spot form edits them (design
/// §2.6, §8.4; stack C, C6b). The draft keeps the stored JSON — plans
/// `{id, name, fee}`, zones with `fee_plan` and the plan's fee as a copy —
/// and these helpers change it the way the database expects:
///
/// * a zone that picks a plan carries that plan's fee (202610270080: a
///   reference beside no fee is a cleared fee);
/// * a zone condition always states `allow`, and its `access` is the one
///   [legacyAccess] derives (decision 32);
/// * a plan still used by the spot or a zone cannot be removed
///   ('fee plan in use', 23503).
library;

import 'dart:convert';

import '../../models/fee.dart';
import '../../models/fee_plan.dart';
import '../../models/parking.dart' show ParkingAccess;
import '../../models/parking_condition.dart';

typedef Json = Map<String, dynamic>;

/// The draft keys of a lot's plans and zones, besides `fee`.
const lotKeys = ['fee_plans', 'fee_plan', 'parking_zones', 'zones_complete'];

/// [json] as a list of objects; anything else reads as empty.
List<Json> jsonList(Object? json) => [
  if (json is List)
    for (final e in json)
      if (e is Map) e.cast<String, dynamic>(),
];

/// A deep copy, so a draft never shares maps with the stored row.
Object? copyJson(Object? json) =>
    json == null ? null : jsonDecode(jsonEncode(json));

/// The plan with [id] in [plans], if any.
Json? planById(List<Json> plans, Object? id) =>
    plans.where((p) => p['id'] == id).firstOrNull;

/// Who uses plan [id]: the number of zones that refer to it (and keep a
/// fee), and whether the spot's whole fee does.
({int zones, bool spot}) planUse(String id, Object? topPlan, Object? zones) => (
  zones: jsonList(zones)
      .where((z) => z['fee_plan'] == id && z['fee'] is Map)
      .length,
  spot: topPlan == id,
);

/// Why plan [id] cannot be deleted, or null when nothing uses it (decision
/// 51: 「N 個分區在用，先改掉引用」).
String? planInUse(String id, Object? topPlan, Object? zones) {
  final use = planUse(id, topPlan, zones);
  return inUseText(use.zones, use.spot);
}

String? inUseText(int zones, bool spot) {
  if (zones == 0 && !spot) return null;
  final who = spot && zones > 0
      ? '全場費率和 $zones 個分區'
      : spot
      ? '全場費率'
      : '$zones 個分區';
  return '$who在用，先改掉引用';
}

/// The message for a refused write that removed a plan still in use: the
/// `detail` of 'fee plan in use' is `{"plans":[{id,name,zones,spot}]}`.
String? planInUseRefusal(Object? details) {
  final decoded = switch (details) {
    final String text => _tryDecode(text),
    final Map<Object?, Object?> map => map,
    _ => null,
  };
  final plans = decoded is Map ? decoded['plans'] : null;
  if (plans is! List || plans.isEmpty) return null;
  return [
    for (final p in plans)
      if (p is Map)
        '「${p['name'] ?? p['id']}」'
            '${inUseText((p['zones'] as num?)?.toInt() ?? 0, p['spot'] == true) ?? '仍在使用'}',
  ].join('；');
}

Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// A free plan id: p1, p2, … as the database names them.
String nextPlanId(List<Json> plans) {
  var n = 1;
  while (plans.any((p) => p['id'] == 'p$n')) {
    n++;
  }
  return 'p$n';
}

/// A plan name from its fee, as `fee_plan_name()` writes one: the vehicles,
/// then the mode they share (機車計時, 重機汽車計時), 混合 when they differ.
String planNameOf(Fee fee) {
  final json = fee.toJson();
  final vehicles = [
    if (json.containsKey('scooter')) '機車',
    if (json.containsKey('heavy')) '重機',
    if (json.containsKey('car')) '汽車',
  ].join();
  final modes = {
    for (final rate in [fee.scooter, fee.heavy, fee.car].nonNulls)
      if (!rate.mode.follows) rate.mode,
  };
  final mode = switch (modes.length) {
    0 => '比照',
    1 => switch (modes.single) {
      FeeMode.free => '免費',
      FeeMode.hourly => '計時',
      FeeMode.perVisit => '計次',
      FeeMode.daily => '每日',
      FeeMode.byTime => '時段',
      _ => '未確認',
    },
    _ => '混合',
  };
  return '$vehicles$mode';
}

/// [name] made unique among [plans] (other than [selfId]): 機車計時 2, 3, …
String uniquePlanName(String name, List<Json> plans, {String? selfId}) {
  bool taken(String n) => plans.any((p) => p['id'] != selfId && p['name'] == n);
  if (!taken(name)) return name;
  var k = 2;
  while (taken('$name $k')) {
    k++;
  }
  return '$name $k';
}

/// Why [plans] cannot be saved, or null: names 1–20 characters and unique,
/// at most 12, each with a complete fee and nothing followed that is not
/// known.
String? plansProblem(List<Json> plans) {
  final max = feePlansContract['max_entries']! as int;
  final nameMax = feePlansContract['name_max_length']! as int;
  if (plans.length > max) return '計費規則最多 $max 條';
  final names = <String>{};
  for (final p in plans) {
    final name = (p['name'] as String? ?? '').trim();
    if (name.isEmpty) return '每條計費規則都要有名稱';
    if (name.length > nameMax) return '規則名稱「$name」請在 $nameMax 個字以內';
    if (!names.add(name)) return '規則名稱「$name」重複了，請改成不同的名稱';
    final problem = planFeeProblem(Fee.fromJson(p['fee']));
    if (problem != null) return '「$name」：$problem';
  }
  return null;
}

/// Why one plan's fee cannot be saved, or null.
String? planFeeProblem(Fee fee) {
  if (fee.isEmpty) return '至少要有一個車種的收費方式';
  if ([fee.scooter, fee.heavy, fee.car].nonNulls.any((r) => !r.complete)) {
    return '請填完收費金額，計時另需選計費時間';
  }
  if (!fee.valid) return '金額請填 0 到 10000 的整數';
  return fee.followGap;
}

/// The zones of one area as the form shows them: zones with the same name
/// and area are one card (design §2.6: one bay per zone, several zones per
/// area), in the order they first appear.
class AreaCard {
  AreaCard(this.name, this.area, this.indexes);
  final String name;
  final String? area;

  /// Positions in `parking_zones`.
  final List<int> indexes;
}

List<AreaCard> areaCards(Object? zones) {
  final cards = <AreaCard>[];
  for (final (i, z) in jsonList(zones).indexed) {
    final name = z['name'] as String? ?? '';
    final area = z['area'] as String?;
    final card = cards.where((c) => c.name == name && c.area == area);
    if (card.isEmpty) {
      cards.add(AreaCard(name, area, [i]));
    } else {
      card.first.indexes.add(i);
    }
  }
  return cards;
}

/// A zone's condition as the editor starts from it: the stored one, else
/// the one its legacy access stands for, else nothing known.
ParkingCondition zoneCondition(Json zone) =>
    ParkingCondition.fromJson(zone['condition'], zone: true) ??
    zoneConditionOf(
      ParkingAccess.values.where((a) => a.name == zone['access']).firstOrNull,
    ) ??
    const ParkingCondition();

/// [zone] with [condition] written as decision 32 asks: `access` is what
/// the condition derives, or dropped when it derives none (the form then
/// refuses to save, see [zoneProblem]).
Json zoneWithCondition(Json zone, ParkingCondition condition) {
  // Nothing known is no condition: the contract refuses an empty one.
  if (condition.toJson().isEmpty) {
    return {...zone}
      ..remove('condition')
      ..remove('access');
  }
  final access = legacyAccess(condition);
  return {...zone, 'condition': condition.toJson(), 'access': ?access?.name}
    ..removeWhere((k, v) => k == 'access' && access == null);
}

/// [zone] resting on [basis] (`{source_url, effective_date?, expires_on?}`
/// as typed, or null for none). Written as typed so a bad link or date
/// blocks the save through [zoneProblem] instead of being dropped.
Json zoneWithBasis(Json zone, Json? basis) {
  final c = zoneCondition(zone);
  final json = c.toJson().cast<String, dynamic>()..remove('basis');
  if (basis != null) json['basis'] = basis;
  final access = legacyAccess(c);
  return {...zone, 'condition': json, 'access': ?access?.name}
    ..removeWhere((k, v) => k == 'access' && access == null);
}

/// [zone] using plan [id] of [plans] (its fee copied), or none.
Json zoneWithPlan(Json zone, String? id, List<Json> plans) {
  final plan = planById(plans, id);
  final out = {...zone}..remove('fee_plan');
  if (plan == null) {
    // Leaving a plan clears the zone's rate; it never keeps a stale copy.
    if (zone.containsKey('fee_plan')) out.remove('fee');
    return out;
  }
  return {...out, 'fee_plan': id, 'fee': copyJson(plan['fee'])};
}

/// [zones] with every reference to a plan of [plans] carrying its fee.
List<Json> zonesFollowingPlans(List<Json> zones, List<Json> plans) => [
  for (final z in zones)
    if (planById(plans, z['fee_plan']) case final plan?)
      {...z, 'fee': copyJson(plan['fee'])}
    else
      z,
];

/// Why [zone] cannot be saved, or null.
String? zoneProblem(Json zone) {
  final name = (zone['name'] as String? ?? '').trim();
  if (name.isEmpty) return '每個區域都要有名稱';
  if (name.length > 40) return '區域名稱「$name」請在 40 個字以內';
  if (!zone.containsKey('condition')) return null;
  final condition = ParkingCondition.fromJson(zone['condition'], zone: true);
  if (condition == null) {
    return zone['condition'] is Map &&
            (zone['condition'] as Map)['basis'] != null
        ? '「$name」的依據：網址需以 https:// 開頭，日期格式為 YYYY-MM-DD，到期日要晚於生效日'
        : '「$name」的停放條件格式不正確';
  }
  final allow = condition.allow;
  if (allow?.scooter == null || allow?.heavy == null) {
    return '「$name」請選普通機車與大型重機可不可停';
  }
  if (legacyAccess(condition) == null) {
    return '「$name」的格位和可停車種不一致：${switch (condition.bay) {
      Bay.heavy => '重機格不能開放普通機車',
      Bay.car => '汽車格目前只能登錄「只開放大型重機」或「機車都不可停」',
      _ => '機車格只開放大型重機時，請把格位改成重機格',
    }}';
  }
  return null;
}

/// The basis of the first zone in [card] that has one.
ConditionBasis? cardBasis(AreaCard card, List<Json> zones) {
  for (final i in card.indexes) {
    if (ParkingCondition.fromJson(zones[i]['condition'], zone: true)?.basis
        case final basis?) {
      return basis;
    }
  }
  return null;
}

/// The values a lot's form writes for its plans (design §2.6 on top of
/// fee_plans_sync()): `fee_plans` as edited (null when none is left), the
/// zones with their plans' fees, and for the whole fee only an explicit
/// change of plan. A plan edited in place reaches the whole fee through the
/// trigger, so `fee` and `fee_note` stay out of the write then; sending the
/// new copy beside an unchanged reference would read as a fee edited by a
/// writer that knows nothing of plans, which drops the plans nobody uses.
Json lotChanges(Json changed, Json draft) {
  final out = {...changed};
  final plans = jsonList(draft['fee_plans']);
  if (out.containsKey('fee_plans') && plans.isEmpty) out['fee_plans'] = null;
  if (out.containsKey('parking_zones') || out.containsKey('fee_plans')) {
    out['parking_zones'] = zonesFollowingPlans(
      jsonList(draft['parking_zones']),
      plans,
    );
  }
  if (out.containsKey('fee_plan')) {
    final plan = planById(plans, draft['fee_plan']);
    final fee = plan == null ? null : Fee.fromJson(plan['fee']);
    out['fee'] = fee?.toJson();
    out['fee_note'] = feeNoteOf(fee);
  } else {
    out.remove('fee');
    // Free text stays the admin's while no plan prices the whole lot.
    if (draft['fee_plan'] != null) out.remove('fee_note');
  }
  return out;
}
