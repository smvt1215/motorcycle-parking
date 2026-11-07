/// The rules of S5 and S5b: 限時、禁停 and 共用時段 as a rider reads them on a
/// sign, one rule per sign line with the zones or segments it covers.
///
/// The contract keeps them per entry: one limit of a kind in a condition,
/// with its periods. So a rule is the same period across the entries it
/// covers: stored periods alike read as one rule ([rulesOf]), and a rule is
/// copied into each entry it covers ([applyRules]). Pure Dart.
library;

import 'dart:convert';

import '../../models/fee.dart' show FeeWords;
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import 'entry_drafts.dart';

/// What a rule does.
enum RuleKind {
  limit('限時'),
  noParking('禁停'),
  share('共用');

  const RuleKind(this.label);
  final String label;
}

/// How many periods of one kind a condition takes (`limits.*.periods`,
/// `schedule.max_entries`).
const rulePeriodsMax = 8;

/// 每次限停多久 steps from 30 minutes to 12 hours.
const ruleMinutesStep = 30, ruleMinutesMin = 30, ruleMinutesMax = 720;

/// 可以延長幾次.
const ruleExtensionsMax = 10;

const _vehicleLabels = {
  SlotVehicle.scooter: '普通機車',
  SlotVehicle.heavy: '大型重機',
  SlotVehicle.car: '汽車',
};

String slotVehicleLabel(SlotVehicle v) => _vehicleLabels[v]!;

/// One rule while a rider edits it.
class TimeRule {
  TimeRule.create()
    : kind = RuleKind.limit,
      all = true,
      scope = {},
      days = 'all',
      allDay = false,
      minutes = 120,
      extensions = 0,
      vehicles = {},
      removed = false,
      loaded = null;

  TimeRule._(
    this.kind, {
    required this.all,
    required this.scope,
    required this.days,
    required this.allDay,
    this.from,
    this.to,
    this.minutes = 120,
    this.extensions,
    this.vehicles = const {},
    this.removed = false,
    this.loaded,
  });

  RuleKind kind;

  /// Covers every entry, those added later too (整個停車場, 整條路).
  bool all;

  /// The entries it covers when not [all], by [EntryDraft.token].
  Set<Object> scope;

  /// `all`, `weekday`, `holiday` or a list of weekdays.
  Object days;

  /// 全天: the period goes without times. Off with none picked yet.
  bool allDay;
  String? from, to;

  /// 限時 only.
  int minutes;

  /// 限時 only; null is an old limit that does not say.
  int? extensions;

  /// 共用 only.
  Set<SlotVehicle> vehicles;

  /// 現場沒有這條規定了: a stored rule that goes when sent.
  bool removed;

  /// The rule as stored; null for a new one.
  final TimeRule? loaded;

  bool get isNew => loaded == null;

  TimeRule copy() => TimeRule._(
    kind,
    all: all,
    scope: {...scope},
    days: days is List ? [...days as List<String>] : days,
    allDay: allDay,
    from: from,
    to: to,
    minutes: minutes,
    extensions: extensions,
    vehicles: {...vehicles},
    removed: removed,
    loaded: loaded,
  );

  /// The same rule, its stored self kept as [loaded].
  TimeRule _withLoaded() => TimeRule._(
    kind,
    all: all,
    scope: {...scope},
    days: days,
    allDay: allDay,
    from: from,
    to: to,
    minutes: minutes,
    extensions: extensions,
    vehicles: {...vehicles},
    loaded: this,
  );

  /// What the period says, apart from who it covers.
  String get _periodKey => jsonEncode([
    kind.name,
    FeeWords.dayMask(days),
    days is String,
    allDay ? null : from,
    allDay ? null : to,
    if (kind == RuleKind.limit) ...[minutes, extensions ?? 0],
    if (kind == RuleKind.share) [for (final v in vehicles) v.name]..sort(),
  ]);

  bool _sameScope(TimeRule other) =>
      all == other.all &&
      (all ||
          (scope.length == other.scope.length &&
              scope.containsAll(other.scope)));

  /// Whether the rider changed it.
  bool get changed =>
      isNew ||
      removed ||
      _periodKey != loaded!._periodKey ||
      !_sameScope(loaded!);

  LimitPeriod get _period => LimitPeriod(
    days: days,
    from: allDay ? null : from,
    to: allDay ? null : to,
    maxMinutes: kind == RuleKind.limit ? minutes : null,
    extensions: kind == RuleKind.limit ? extensions ?? 0 : null,
  );

  ScheduleSlot get _slot => ScheduleSlot(
    days: days,
    from: allDay ? null : from,
    to: allDay ? null : to,
    vehicles: [
      for (final v in SlotVehicle.values)
        if (vehicles.contains(v)) v,
    ],
  );

  /// 平日 07:00–20:00; a period across midnight reads as posted.
  String get when {
    final label = FeeWords.dayLabel(FeeWords.dayMask(days));
    return allDay || from == null || to == null
        ? '$label全天'
        : '$label $from–$to';
  }

  /// What it asks: 每次限停 3 小時・可延長 1 次, 開放大型重機; empty for 禁停.
  String get detail => switch (kind) {
    RuleKind.limit =>
      '每次限停 ${minuteLabel(minutes)}・'
          '${(extensions ?? 0) == 0 ? '不能延長' : '可延長 $extensions 次'}',
    RuleKind.noParking => '',
    RuleKind.share => vehicles.isEmpty ? '' : '開放${_who(vehicles)}',
  };
}

/// Both motorcycles read as 機車, as a sign does.
String _who(Set<SlotVehicle> vehicles) {
  final motorcycles =
      vehicles.contains(SlotVehicle.scooter) &&
      vehicles.contains(SlotVehicle.heavy);
  return [
    if (motorcycles) '機車',
    for (final v in SlotVehicle.values)
      if (vehicles.contains(v) &&
          !(motorcycles &&
              (v == SlotVehicle.scooter || v == SlotVehicle.heavy)))
        slotVehicleLabel(v),
  ].join('、');
}

/// 30 分, 1 小時 30 分, 3 小時.
String minuteLabel(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  return [if (h > 0) '$h 小時', if (m > 0 || h == 0) '$m 分'].join(' ');
}

/// Where [c] says 限時, 禁停 and 共用時段, one rule per period.
List<TimeRule> _rulesIn(ParkingCondition? c) {
  TimeRule period(RuleKind kind, Object days, String? from, String? to) =>
      TimeRule._(
        kind,
        all: false,
        scope: {},
        days: days,
        allDay: from == null,
        from: from,
        to: to,
      );
  final limits = c?.limits ?? const <ParkingLimit>[];
  return [
    for (final l in limits)
      if (l.kind == LimitKind.timeLimit)
        for (final p in l.timePeriods)
          period(RuleKind.limit, p.days, p.from, p.to)
            ..minutes = p.maxMinutes ?? 120
            ..extensions = p.extensions,
    for (final l in limits)
      if (l.kind == LimitKind.noParking)
        for (final p in l.periods)
          period(RuleKind.noParking, p.days, p.from, p.to),
    for (final s in c?.schedule ?? const <ScheduleSlot>[])
      period(RuleKind.share, s.days, s.from, s.to)
        ..vehicles = s.vehicles.toSet(),
  ];
}

/// The rules [drafts] store: a period several entries hold alike is one
/// rule covering them, and one all of them hold covers every entry.
List<TimeRule> rulesOf(List<EntryDraft> drafts) {
  final found = <String, TimeRule>{};
  for (final d in drafts) {
    for (final rule in _rulesIn(d.stored)) {
      found.putIfAbsent(rule._periodKey, () => rule).scope.add(d.token);
    }
  }
  return [
    for (final rule in found.values)
      (rule..all = rule.scope.length == drafts.length)._withLoaded(),
  ];
}

/// The periods of [rules] for [d], by kind: `rule.all` covers it, or it is
/// named. Removed ones are left out.
({
  List<LimitPeriod> limit,
  List<LimitPeriod> noParking,
  List<ScheduleSlot> share,
})
_periodsFor(List<TimeRule> rules, EntryDraft d) {
  final live = [
    for (final r in rules)
      if (!r.removed && (r.all || r.scope.contains(d.token))) r,
  ];
  return (
    limit: [
      for (final r in live)
        if (r.kind == RuleKind.limit) r._period,
    ],
    noParking: [
      for (final r in live)
        if (r.kind == RuleKind.noParking) r._period,
    ],
    share: [
      for (final r in live)
        if (r.kind == RuleKind.share) r._slot,
    ],
  );
}

String _keyOf(Iterable<TimeRule> rules) =>
    ([for (final r in rules) r._periodKey]..sort()).join('|');

/// Copies [rules] into the entries they change. An entry whose periods stay
/// as stored keeps its condition untouched and is not sent.
void applyRules(List<TimeRule> rules, List<EntryDraft> drafts) {
  for (final d in drafts) {
    final live = [
      for (final r in rules)
        if (!r.removed && (r.all || r.scope.contains(d.token))) r,
    ];
    if (_keyOf(live) == _keyOf(_rulesIn(d.stored))) {
      d.signs = null;
      d.slots = null;
      continue;
    }
    final (:limit, :noParking, :share) = _periodsFor(rules, d);
    d.signs = [
      if (limit.isNotEmpty) ParkingLimit(LimitKind.timeLimit, periods: limit),
      if (noParking.isNotEmpty)
        ParkingLimit(LimitKind.noParking, periods: noParking),
    ];
    d.slots = share;
  }
}

/// Why [rule] cannot go as it stands, by field; empty when it can. [unit] is
/// 區 or 段.
Map<String, String> ruleProblems(TimeRule rule, String unit) {
  final days = rule.days;
  return {
    if (!rule.all && rule.scope.isEmpty) 'scope': '請選這條規定管哪幾$unit',
    if (days is List && days.isEmpty) 'days': '請選哪幾天',
    if (!rule.allDay && (rule.from == null || rule.to == null))
      'time': '請選開始和結束時間，或按「全天」'
    else if (!rule.allDay && rule.from == rule.to)
      'time': '結束和開始不能相同',
    if (rule.kind == RuleKind.share && rule.vehicles.isEmpty)
      'vehicles': '請選這段時間可停的車種，或刪除這個時段',
  };
}

/// Why [rules] cannot fit [drafts], or null: each entry takes
/// [rulePeriodsMax] periods of a kind.
String? rulesOverflow(List<TimeRule> rules, List<EntryDraft> drafts) {
  for (final d in drafts) {
    final (:limit, :noParking, :share) = _periodsFor(rules, d);
    if (limit.length > rulePeriodsMax ||
        noParking.length > rulePeriodsMax ||
        share.length > rulePeriodsMax) {
      return '「${d.displayName}」同一種規定最多 $rulePeriodsMax 條，請合併或刪除幾條';
    }
  }
  return null;
}

/// Who [rule] covers, in words: [allWord], or the entries' names.
String ruleScopeText(TimeRule rule, List<EntryDraft> drafts, String allWord) {
  if (rule.all) return allWord;
  final names = [
    for (final d in drafts)
      if (rule.scope.contains(d.token)) d.displayName,
  ];
  return names.isEmpty ? '還沒選' : names.join('、');
}

/// A rule on its collapsed card: 全場　平日 07:00–20:00 每次限停 2 小時.
String ruleSummary(TimeRule rule, List<EntryDraft> drafts, String allWord) =>
    '${ruleScopeText(rule, drafts, allWord)}　'
    '${[rule.when, if (rule.detail.isNotEmpty) rule.detail].join(' ')}';

/// 你要改的內容: one line per rule changed, naming only what differs.
List<ChangeLine> ruleChanges(
  List<TimeRule> rules,
  List<EntryDraft> drafts,
  String allWord,
) {
  String whole(TimeRule r) => ruleSummary(r, drafts, allWord);
  return [
    for (final r in rules)
      if (r.isNew)
        if (r.removed)
          ...const <ChangeLine>[]
        else
          ChangeLine(label: r.kind.label, from: '沒有', to: whole(r))
      else if (r.removed)
        ChangeLine(
          label: r.loaded!.kind.label,
          from: whole(r.loaded!),
          to: '沒有',
        )
      else if (r.changed)
        _changeOf(r, drafts, allWord),
  ];
}

ChangeLine _changeOf(TimeRule r, List<EntryDraft> drafts, String allWord) {
  final old = r.loaded!;
  final a = [ruleScopeText(old, drafts, allWord), old.when, old.detail];
  final b = [ruleScopeText(r, drafts, allWord), r.when, r.detail];
  String shown(List<String> parts) => [
    for (var i = 0; i < parts.length; i++)
      if (a[i] != b[i] && parts[i].isNotEmpty) parts[i],
  ].join(' ');
  return ChangeLine(
    label: r.kind.label,
    from: r.kind == old.kind ? shown(a).ifBlank('沒有') : a.join(' ').trim(),
    to: r.kind == old.kind ? shown(b).ifBlank('沒有') : b.join(' ').trim(),
  );
}

extension on String {
  String ifBlank(String other) => isEmpty ? other : this;
}

/// A street spot's own condition carrying [d]'s rules (a spot without
/// segments, S5b) as `proposed`: the condition with the space type it is
/// stored under, which the check reads together. A motorcycle bay that
/// loses its time limit states its charge again, from [free].
Map<String, Object?> spotRulesProposal(
  ParkingSpot spot,
  EntryDraft d, {
  required bool free,
}) {
  final base = spot.condition ?? conditionOf(spot.spaceType);
  final next = ParkingCondition(
    bay: base?.bay,
    use: base?.use,
    share: base?.share,
    charge:
        base?.charge ??
        (base?.bay == Bay.motorcycle
            ? (free ? Charge.free : Charge.toll)
            : null),
    limits: [
      for (final l in base?.limits ?? const <ParkingLimit>[])
        if (l.kind != LimitKind.timeLimit && l.kind != LimitKind.noParking) l,
      ...?d.signs,
    ],
    schedule: d.slots ?? base?.schedule ?? const [],
  );
  return {
    'condition': next.toJson(),
    'space_type':
        (legacySpaceType(next, offStreet: false) ?? spot.spaceType).name,
  };
}
