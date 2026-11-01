/// Parking decisions (docs/designs/2026-10-26-parking-conditions-and-fees.md
/// §3): whether a vehicle may park at a spot, on what basis, zone by zone,
/// and what the rider pays there, kept apart from the eligibility.
///
/// [decideParking] judges in the design's order: trust in the data (step 0),
/// the law (1), local notices — city rules and a condition's own notice —
/// (2), then the lot, its zones or the bay (3); prices come last (4) and
/// never change the eligibility. [ruleVerdict] is step 2 alone, the pure
/// rule function the rule prescreen engine calls
/// (CONTRIBUTION_TIERS_FEASIBILITY.md §5.7); `rule_verdict()` in SQL and
/// `ruleVerdict` in supabase/functions/_shared/rule_verdict.ts share its
/// vectors in supabase/functions/_shared/rule_verdict_cases.json.
library;

import '../models/closure.dart';
import '../models/condition_text.dart' show limitPeriodText;
import '../models/fee.dart';
import '../models/fee_plan.dart';
import '../models/holiday_calendar.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import 'eligibility.dart';

/// What the city rules say about one kind of street bay (§3.2 step 2).
enum RuleVerdictKind {
  /// The rule opens the bay.
  open,

  /// The rule opens it with a limit, see [RuleVerdict.restriction].
  conditional,

  /// The rule closes it (not listed, or outside its districts).
  closed,

  /// No rule in force for this city and vehicle.
  noRule,

  /// The rule depends on a district the spot does not name, or names one
  /// the rule's notice does not cover.
  unknownDistrict,

  /// The rule in force ended (`expires_on`); never falls back to another.
  expired,

  /// Rules equally specific say different things.
  conflict,
}

class RuleVerdict {
  const RuleVerdict(this.kind, this.reason, {this.restriction, this.rule});
  final RuleVerdictKind kind;
  final String reason;

  /// Only for [RuleVerdictKind.conditional].
  final RuleRestriction? restriction;

  /// The rule the verdict rests on; null for [RuleVerdictKind.noRule] and
  /// [RuleVerdictKind.conflict].
  final CityRule? rule;

  /// Whether the rule alone answers it (the engine's reading, §5.7).
  bool get answers =>
      kind == RuleVerdictKind.open || kind == RuleVerdictKind.closed;

  @override
  String toString() => '${kind.name}(${restriction?.key ?? ''})';
}

const noRuleReason = '此地區尚無已生效的停車規則資料，請以現場標誌標線為準';
const ruleExpiredReason = '此地區的規則已過期，請以現場標誌標線為準';
const noticeConflictReason = '公告不一致，請以現場公告為準';
const communityUncheckedReason = '社群資訊尚未查核或可能過時，請確認現場';
const lotUncheckedReason = '場站資料未確認開放目前車種，請以入口公告為準';

/// Why a lot or zone whose official data does not state [vehicle] (#201) is
/// unconfirmed.
String notStatedReason(VehicleType vehicle, {String where = '場站'}) =>
    '$where官方未標示是否開放${vehicle.label}，請以入口公告為準';

/// A heavy bike on a heavy-bike or car bay after the city rule ended
/// (decision 44).
const lawfulReason = '大型重機依法可停此格位，請勿超出格線';

/// `YYYY-MM-DD` of [time] in Taiwan, the day `expires_on` is compared with,
/// as `(now() at time zone 'Asia/Taipei')::date` in SQL.
String taipeiDay(DateTime time) =>
    _ymd(time.toUtc().add(const Duration(hours: 8)));

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Whether [rule] has ended by [now]: `now ≥ expires_on`, in Taiwan.
bool ruleExpired(CityRule rule, DateTime now) =>
    rule.expiresOn != null &&
    taipeiDay(now).compareTo(_ymd(rule.expiresOn!)) >= 0;

RuleVerdict _single(CityRule rule, SpaceType kind, String district) {
  final openIn = rule.districtSpaceTypes[kind];
  if (openIn != null) {
    if (district.isEmpty) {
      return RuleVerdict(
        RuleVerdictKind.unknownDistrict,
        '僅${openIn.join('、')}開放，無法判斷此停車點所在行政區',
        rule: rule,
      );
    }
    if (!openIn.contains(district)) {
      return RuleVerdict(
        RuleVerdictKind.closed,
        '僅${openIn.join('、')}開放，$district不開放',
        rule: rule,
      );
    }
  }
  final limited = rule.conditionalSpaceTypes.contains(kind);
  if (limited && rule.restriction == RuleRestriction.unverified) {
    return RuleVerdict(
      RuleVerdictKind.conditional,
      rule.exceptions,
      restriction: RuleRestriction.unverified,
      rule: rule,
    );
  }
  if (!limited && openIn == null && !rule.allowedSpaceTypes.contains(kind)) {
    return RuleVerdict(RuleVerdictKind.closed, rule.exceptions, rule: rule);
  }
  if (rule.districts.isNotEmpty && !rule.districts.contains(district)) {
    return RuleVerdict(
      RuleVerdictKind.unknownDistrict,
      '不在規則公告的開放行政區內，請以現場標誌標線為準',
      rule: rule,
    );
  }
  if (limited) {
    return RuleVerdict(
      RuleVerdictKind.conditional,
      rule.exceptions,
      restriction: rule.restriction,
      rule: rule,
    );
  }
  return RuleVerdict(
    RuleVerdictKind.open,
    rule.canUseTwoSpaces ? '可斜停兩格，請依公告停放' : '依地方規則開放，請勿超出格線',
    rule: rule,
  );
}

/// Bays the law opens to [rule]'s vehicle whatever a local notice says
/// (§3.2 step 1): a heavy bike on a heavy-bike bay or a car bay.
bool _lawful(CityRule rule, SpaceType kind) =>
    rule.vehicle == VehicleType.heavy &&
    (kind == SpaceType.heavyOnly || kind == SpaceType.car);

/// What [rules] — the rules of one city and vehicle, already matched —
/// say about the street bay [kind] in [district] at [now] (§3.2 step 2).
/// Dates are Taiwan's, as in SQL. Rules not yet in force are ignored;
/// expired ones count only when no other is in force, and then the answer
/// is [RuleVerdictKind.expired], never another rule's — except on a bay the
/// law opens to the vehicle, which the expired rules still judge as before
/// they ended (decision 44). Rules in force that disagree are a
/// [RuleVerdictKind.conflict].
RuleVerdict ruleVerdict(
  Iterable<CityRule> rules,
  SpaceType kind,
  String district, {
  required DateTime now,
}) {
  final started = [
    for (final r in rules)
      if (_ymd(r.effectiveDate).compareTo(taipeiDay(now)) <= 0) r,
  ];
  if (started.isEmpty) {
    return const RuleVerdict(RuleVerdictKind.noRule, noRuleReason);
  }
  var current = [
    for (final r in started)
      if (!ruleExpired(r, now)) r,
  ];
  // Decision 44: an ended rule voids only what it opened. A bay the law
  // opens to its vehicle (§3.2 step 1) is judged as before the rule ended.
  final lawful = current.isEmpty && started.every((r) => _lawful(r, kind));
  if (lawful) current = started;
  if (current.isEmpty) {
    return RuleVerdict(
      RuleVerdictKind.expired,
      ruleExpiredReason,
      rule: started.first,
    );
  }
  final verdicts = [for (final r in current) _single(r, kind, district)];
  final first = verdicts.first;
  if (verdicts.every(
    (v) => v.kind == first.kind && v.restriction == first.restriction,
  )) {
    // The rule no longer says it; the law does.
    if (lawful && first.kind == RuleVerdictKind.open) {
      return RuleVerdict(first.kind, lawfulReason, rule: first.rule);
    }
    return first;
  }
  return const RuleVerdict(RuleVerdictKind.conflict, noticeConflictReason);
}

/// The rules [decideParking] reads for [spot]: those of its city and
/// [vehicle], else the national ones.
List<CityRule> matchingRules(
  Iterable<CityRule> rules,
  ParkingSpot spot,
  VehicleType vehicle,
) {
  final own = [
    for (final r in rules)
      if (r.vehicle == vehicle && r.city == spot.city) r,
  ];
  if (own.isNotEmpty) return own;
  return [
    for (final r in rules)
      if (r.vehicle == vehicle && r.city == '全國') r,
  ];
}

/// The legacy kinds a city rule judges a bay as (§3.2, replacing
/// `ruleSpaceType`): a motorcycle bay by its charge, both kinds when the
/// charge is unconfirmed; none when the bay is.
List<SpaceType> ruleKindsOf(ParkingCondition condition) =>
    switch (condition.bay) {
      Bay.heavy => const [SpaceType.heavyOnly],
      Bay.car => const [SpaceType.car],
      Bay.motorcycle => switch (condition.charge) {
        Charge.toll => const [SpaceType.paidMotorcycle],
        Charge.free => const [SpaceType.freeMotorcycle],
        null => const [SpaceType.paidMotorcycle, SpaceType.freeMotorcycle],
      },
      null => const [],
    };

/// How rule pages and previews show [type]: its legacy condition, except a
/// timed bay, shown as the toll bay riders meet (Taipei pktype 20, 首 20
/// 分鐘 0 元) rather than one whose charge is unconfirmed.
ParkingCondition? typicalCondition(SpaceType type) =>
    type == SpaceType.timedMotorcycle
    ? const ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        charge: Charge.toll,
        limits: [ParkingLimit(LimitKind.timeLimit)],
      )
    : conditionOf(type);

/// Why a decision is unverified, or what the rider should know (§3.3).
enum DecisionGap {
  zonesIncomplete,
  zonesConflict,
  noticeExpired,
  noticeConflict,
  districtUnknown,
  scheduleUnknown,
  chargeUnknown,

  /// 官方未標示 (#201): the official data (for a lot, its operator's notice
  /// too) does not say whether the vehicle may park; judged unconfirmed.
  notStated,
}

/// Where a decision comes from (§3.3); #91 tiers the banner by it.
enum BasisKind {
  /// Government open data.
  official,

  /// An administrator set this vehicle's access, within 180 days.
  adminVerified,

  /// An administrator's check older than that.
  adminLapsed,

  /// Only a rider's report (or an import of one).
  communityReport,

  /// A city rule.
  cityRule,

  /// The law itself (bay class, special vehicles).
  law,

  /// The condition's or the zone's own notice (`basis`).
  notice,

  /// No source states it.
  none,
}

class DecisionBasis {
  const DecisionBasis(
    this.kind, {
    this.date,
    this.url,
    this.effectiveDate,
    this.expiresOn,
    this.expired = false,
    this.zone,
    this.rule,
  });
  final BasisKind kind;

  /// When the source was updated or checked (official, admin, report).
  final DateTime? date;
  final String? url;

  /// A notice's dates, `YYYY-MM-DD`.
  final String? effectiveDate, expiresOn;

  /// The notice or rule has ended.
  final bool expired;

  /// The zone a notice belongs to; null for the spot's own.
  final String? zone;
  final CityRule? rule;
}

enum PriceKind { known, partial, unknown }

/// What the rider pays at one place (§3.2 step 4), apart from whether they
/// may park there.
class PriceAnswer {
  const PriceAnswer.known(this.rate, this.text)
    : kind = PriceKind.known,
      gaps = const [];
  const PriceAnswer.partial(this.rate, this.text, this.gaps)
    : kind = PriceKind.partial;

  /// No structured rate; [text] is the legacy note or 「…費率未提供」.
  const PriceAnswer.unknown([this.text])
    : kind = PriceKind.unknown,
      rate = null,
      gaps = const [];

  final PriceKind kind;

  /// The vehicle's rate with a follow worked out (amounts may have
  /// decimals); null when unknown.
  final Map<String, Object?>? rate;
  final String? text;

  /// What is unconfirmed about a [PriceKind.partial] rate, e.g. 隔日是否另計.
  final List<String> gaps;
}

String _feeVehicle(VehicleType v) =>
    v == VehicleType.heavy ? 'heavy' : 'scooter';

void _rateGaps(Map<Object?, Object?> rate, Set<String> gaps) {
  switch (rate['mode']) {
    case 'per_visit':
      if (!rate.containsKey('renew')) gaps.add('隔日是否另計');
    case 'hourly' when rate.containsKey('daily_cap'):
      if (!rate.containsKey('cap_reset')) gaps.add('上限計算方式');
    case 'by_time':
      final periods = (rate['periods'] as List?) ?? const [];
      var visits = 0;
      for (final p in periods) {
        if (p case {'rate': final Map<Object?, Object?> r}) {
          if (r['mode'] == 'per_visit') visits++;
          _rateGaps(r, gaps);
        }
      }
      // Asked once a per-visit period has another to cross into (C7).
      if (visits >= 1 &&
          periods.length >= 2 &&
          !rate.containsKey('cross_period')) {
        gaps.add('跨時段如何計費');
      }
      // A time no period covers is unconfirmed (§2.2), as a posted one is
      // (#155 item 17); days are the start day's (decision 47).
      final covered = feeWeekCoverage([
        for (final p in periods)
          if (p case final Map<Object?, Object?> m)
            (
              days: m['days'],
              from: m['from'] as String?,
              to: m['to'] as String?,
            ),
      ]);
      if (covered.contains(false)) gaps.add('部分時段費率');
  }
}

/// [vehicle]'s price in [fee] (a stored `fee`), with [legacyText] when it
/// has no structured rate. A follow resolves within the same fee only; a
/// follow of an unconfirmed vehicle is unknown, 「大型重機費率未提供」.
PriceAnswer priceAnswer(
  Object? fee,
  VehicleType vehicle, {
  String legacyText = '',
}) {
  final legacy = legacyText.trim().isEmpty ? null : legacyText;
  final structured = structuredFee(fee);
  if (structured == null) return PriceAnswer.unknown(legacy);
  final key = _feeVehicle(vehicle);
  final text = structured.textOf(key);
  // With a structured fee, `fee_note` is its sentence for every vehicle,
  // not this vehicle's legacy text: an unknown rate stays unknown, and the
  // rider reads 「費率未確認，請依現場公告」 (decision 29).
  if (text == null) {
    return PriceAnswer.unknown(
      structured.riderText(key) != null ? '${vehicle.label}費率未提供' : null,
    );
  }
  final rate = resolveFee(fee! as Map)[key];
  if (rate is! Map) return const PriceAnswer.unknown();
  final gaps = <String>{};
  _rateGaps(rate, gaps);
  final json = {for (final e in rate.entries) '${e.key}': e.value};
  return gaps.isEmpty
      ? PriceAnswer.known(json, text)
      : PriceAnswer.partial(json, text, gaps.toList());
}

/// One zone of a lot, judged for the vehicle (§3.2 step 3).
class ZoneDecision {
  const ZoneDecision({
    required this.name,
    required this.status,
    required this.reason,
    this.restriction,
    this.notice,
    this.price,
    this.gaps = const {},
    this.hasData = true,
  });
  final String name;
  final EligibilityStatus status;
  final RuleRestriction? restriction;
  final String reason;

  /// The zone's own notice, when it has one.
  final DecisionBasis? notice;

  /// Only for a zone open to the vehicle.
  final PriceAnswer? price;
  final Set<DecisionGap> gaps;

  /// False when neither a condition nor an access says anything.
  final bool hasData;

  bool get open =>
      status == EligibilityStatus.allowed ||
      status == EligibilityStatus.conditional;
}

class ParkingDecision {
  const ParkingDecision(
    this.status,
    this.reason, {
    this.restriction,
    this.basis = const [],
    this.zones = const [],
    this.segments = const [],
    this.price,
    this.gaps = const {},
  });
  final EligibilityStatus status;
  final String reason;
  final RuleRestriction? restriction;

  /// A street spot's segments, each judged with its own condition, who it
  /// lets park and its own fee or the whole road's (#188 layer 2:
  /// eligibility goes with the bay).
  final List<ZoneDecision> segments;

  /// Sources, most decisive first: the data's own (official, admin,
  /// report), then the rule or law, then notices.
  final List<DecisionBasis> basis;
  final List<ZoneDecision> zones;

  /// A street bay's, or a lot's without zones.
  final PriceAnswer? price;
  final Set<DecisionGap> gaps;

  Eligibility get eligibility =>
      Eligibility(status, reason, restriction: restriction);

  /// The zones open to the vehicle, in the lot's order.
  List<ZoneDecision> get openZones => [
    for (final z in zones)
      if (z.open) z,
  ];

  ParkingDecision _with({
    EligibilityStatus? status,
    String? reason,
    RuleRestriction? Function()? restriction,
    Iterable<DecisionBasis> moreBasis = const [],
    Iterable<DecisionGap> moreGaps = const [],
    PriceAnswer? price,
    List<ZoneDecision>? zones,
  }) => ParkingDecision(
    status ?? this.status,
    reason ?? this.reason,
    restriction: restriction == null ? this.restriction : restriction(),
    basis: [...basis, ...moreBasis],
    zones: zones ?? this.zones,
    segments: segments,
    price: price ?? this.price,
    gaps: {...gaps, ...moreGaps},
  );
}

/// An administrator set [vehicle]'s access on this spot within the last 180
/// days, the same window a ground confirmation stays fresh for.
bool recentlyVerified(ParkingSpot spot, VehicleType vehicle, DateTime now) {
  final at = spot.verifiedAt(vehicle);
  return at != null && now.difference(at).inDays <= 180;
}

/// A community spot confirmed on the ground within the last 180 days. With
/// no confirmation time its freshness is unknown, never assumed.
bool recentlyConfirmed(ParkingSpot spot, DateTime now) {
  final at = spot.lastConfirmedAt;
  return spot.status == TrustStatus.confirmed &&
      at != null &&
      now.difference(at).inDays <= 180;
}

/// Whether a notice holds on [day] (`YYYY-MM-DD`): started and not ended.
/// No notice holds nothing back.
bool _noticeHolds(ConditionBasis? basis, String day) =>
    basis == null ||
    ((basis.effectiveDate == null ||
            basis.effectiveDate!.compareTo(day) <= 0) &&
        (basis.expiresOn == null || day.compareTo(basis.expiresOn!) < 0));

bool _noticeEnded(ConditionBasis? basis, String day) =>
    basis?.expiresOn != null && day.compareTo(basis!.expiresOn!) >= 0;

DecisionBasis _notice(ConditionBasis basis, String day, {String? zone}) =>
    DecisionBasis(
      BasisKind.notice,
      url: basis.sourceUrl,
      effectiveDate: basis.effectiveDate,
      expiresOn: basis.expiresOn,
      expired: _noticeEnded(basis, day),
      zone: zone,
    );

String _days(Object days) => switch (days) {
  'all' => '每天',
  'weekday' => '平日',
  'holiday' => '假日',
  final List<Object?> list =>
    '週${list.map((d) => const {'mon': '一', 'tue': '二', 'wed': '三', 'thu': '四', 'fri': '五', 'sat': '六', 'sun': '日'}[d] ?? '').join('、')}',
  _ => '',
};

/// A schedule slot as riders read it, e.g. 平日 20:00–隔日 07:00.
String slotText(ScheduleSlot s) {
  if (s.from == null || s.to == null) return '${_days(s.days)}全天';
  final next = s.from!.compareTo(s.to!) > 0 ? '隔日 ' : '';
  return '${_days(s.days)} ${s.from}–$next${s.to}';
}

SlotVehicle _slotVehicle(VehicleType v) =>
    v == VehicleType.heavy ? SlotVehicle.heavy : SlotVehicle.scooter;

/// The slots [condition] lets [vehicle] park in.
List<ScheduleSlot> _slotsFor(ParkingCondition condition, VehicleType v) => [
  for (final s in condition.schedule)
    if (s.vehicles.contains(_slotVehicle(v))) s,
];

/// The slots a heavy bike may park in on a shared car bay
/// (PM_ANS_20261031_21), in the notice's order, each once: the car slots,
/// since car bays are painted for heavy bikes too (標誌標線號誌設置規則
/// §190); the scooter slots only where [rules] open the matching motorcycle
/// bay to heavy bikes (Taipei's toll bays from 2026-10-06), both kinds
/// agreeing when the charge is unconfirmed; and the slots the notice names
/// for heavy bikes. With the basis of each kind of slot used, and the limit
/// a conditional rule puts on the scooter slots (Taichung: only bays marked
/// 「大重機共用」), which holds in those slots and must reach the rider.
({List<ScheduleSlot> slots, List<DecisionBasis> basis, RuleVerdict? ruleLimit})
_heavyShareSlots(
  ParkingCondition condition,
  List<CityRule> rules,
  String district,
  DateTime at,
) {
  final verdicts = [
    for (final k in switch (condition.charge) {
      Charge.toll => const [SpaceType.paidMotorcycle],
      Charge.free => const [SpaceType.freeMotorcycle],
      null => const [SpaceType.paidMotorcycle, SpaceType.freeMotorcycle],
    })
      ruleVerdict(rules, k, district, now: at),
  ];
  // Only a rule in force that opens the bay counts: an ended, unverified,
  // closing or district-unknown rule opens no scooter slot.
  final ruleOpens = verdicts.every(
    (v) =>
        v.kind == RuleVerdictKind.open ||
        (v.kind == RuleVerdictKind.conditional &&
            v.restriction != RuleRestriction.unverified),
  );
  var byLaw = false, byRule = false, byNotice = false;
  final slots = <ScheduleSlot>[];
  for (final s in condition.schedule) {
    final car = s.vehicles.contains(SlotVehicle.car);
    final scooter = ruleOpens && s.vehicles.contains(SlotVehicle.scooter);
    final heavy = s.vehicles.contains(SlotVehicle.heavy);
    if (!(car || scooter || heavy)) continue;
    slots.add(s);
    byLaw |= car;
    byRule |= scooter;
    byNotice |= heavy;
  }
  final rule = verdicts.first.rule;
  return (
    slots: slots,
    ruleLimit: byRule
        ? verdicts
              .where((v) => v.kind == RuleVerdictKind.conditional)
              .firstOrNull
        : null,
    basis: [
      if (byLaw) const DecisionBasis(BasisKind.law),
      if (byRule && rule != null)
        DecisionBasis(
          BasisKind.cityRule,
          rule: rule,
          url: rule.sourceUrl,
          date: rule.effectiveDate,
        ),
      if (byNotice) const DecisionBasis(BasisKind.notice),
    ],
  );
}

/// How the rider is reminded that a shared car bay with no slots on file
/// still rotates by its sign.
const _shareSignReminder = '汽機車共用格請依現場牌面時段停放';

String _clockText(int minute) {
  final m = minute % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

/// Whether [slots] let the rider park at [now] (#120): 現在可停, or 現在不可停
/// with when the next slot opens (20:00, 明天 08:00, 週一 08:00). 平日 and
/// 假日 follow [calendar] (decision 61) and a period across midnight
/// belongs to the day it starts (decision 47); where the calendar lacks
/// the year, the weekend decides and the text says so.
String slotNowText(
  List<ScheduleSlot> slots,
  DateTime now, {
  HolidayCalendar? calendar,
}) {
  final cal = calendar ?? HolidayCalendar.current;
  final (today, at) = taipeiDateMinute(now);
  const last = 7;
  final spans = [
    for (final s in slots)
      ...datedSpans(s.days, s.from, s.to, today, cal, last: last),
  ];
  String text;
  if (spans.any((s) => s.$1 <= at && at < s.$2)) {
    text = '現在可停';
  } else {
    final starts = [
      for (final (start, _) in spans)
        if (start > at) start,
    ]..sort();
    if (starts.isEmpty) {
      text = '現在不可停';
    } else {
      final next = starts.first, day = next ~/ 1440;
      final date = DateTime.utc(today.year, today.month, today.day + day);
      final when = switch (day) {
        0 => _clockText(next),
        1 => '明天 ${_clockText(next)}',
        _ => '週${'一二三四五六日'[date.weekday - 1]} ${_clockText(next)}',
      };
      text = '現在不可停，$when 起可停';
    }
  }
  final fellBack = calendarFellBack(
    [for (final s in slots) s.days],
    today,
    cal,
    last: last,
  );
  return fellBack ? '$text（$holidayFallbackNote）' : text;
}

const _disabledReason =
    '身障專用格：須是經監理站檢驗合格的特製機車，且身障者本人騎乘或同行，'
    '並持專用停車位識別證或掛專用牌照，才可停放';
const _evReason = '限電動機車停放或充換電，燃油機車不可停';
const _timedReason = '限時停車：請依現場牌面的時段與時限停放，超時須移車';

/// The period of [periods] that holds at [now], if any: 平日 and 假日
/// follow [calendar], and a period across midnight belongs to the day it
/// starts (decision 47).
LimitPeriod? _periodAt(
  List<LimitPeriod> periods,
  DateTime now,
  HolidayCalendar calendar,
) {
  final (today, at) = taipeiDateMinute(now);
  for (final p in periods) {
    final spans = datedSpans(p.days, p.from, p.to, today, calendar);
    if (spans.any((s) => s.$1 <= at && at < s.$2)) return p;
  }
  return null;
}

/// 每次限停 2 小時，可延長 1 次.
String _stayText(LimitPeriod p) {
  final stay = '每次限停 ${FeeWords.span(p.maxMinutes!)}';
  return switch (p.extensions) {
    null => stay,
    0 => '$stay，不能延長',
    final n => '$stay，可延長 $n 次',
  };
}

/// Whether [c] limits how long or when anyone parks (#188 layer 2): a time
/// limit or 時段性禁停.
bool _timeBound(ParkingCondition c) =>
    c.hasLimit(LimitKind.timeLimit) || c.hasLimit(LimitKind.noParking);

/// The time limit and 時段性禁停 of [c] as reasons (#188 layer 2): what holds
/// at [now], then every period. An old time limit without its periods
/// reads as before; 禁停 holds for everyone.
List<String> _timeReasons(
  ParkingCondition c,
  DateTime now,
  HolidayCalendar calendar,
) => [
  for (final l in c.limits)
    if (l.kind == LimitKind.timeLimit)
      l.timePeriods.isEmpty
          ? _timedReason
          : '限時停車：${switch (_periodAt(l.timePeriods, now, calendar)) {
              final p? when p.maxMinutes != null => '現在${_stayText(p)}',
              _ => '現在不在限時時段',
            }}；限時時段：${l.timePeriods.map(limitPeriodText).join('；')}，超時須移車'
    else if (l.kind == LimitKind.noParking)
      '${_periodAt(l.periods, now, calendar) == null ? '' : '現在是禁停時段，不可停放；'}'
          '禁停時段：${l.periods.map(limitPeriodText).join('；')}',
];
const _carBayReason = '汽車格為小型車及大型重機停放線，普通機車停放屬車種不依規定';

/// Whether [vehicle] may park at [spot] under [rules] at [now] (§3.2),
/// with its basis, zones and prices. [rules] may hold every city's rules;
/// the spot's city's are read, else the national ones.
ParkingDecision decideParking(
  ParkingSpot spot,
  VehicleType vehicle,
  Iterable<CityRule> rules, {
  DateTime? now,
  HolidayCalendar? calendar,
}) {
  final at = now ?? DateTime.now();
  final day = taipeiDay(at);
  final cal = calendar ?? HolidayCalendar.current;
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  // Step 0. Only trusted data may deny outright; a pending, stale or
  // undated community claim falls through to the rules, which keep it
  // unverified. Confirming a community spot shows the bay exists, not that
  // its reported vehicle fields are right; an administrator setting them
  // does, for as long as official data would stay fresh.
  final verified = explicit != null && recentlyVerified(spot, vehicle, at);
  final trusted = spot.isOfficial || verified || recentlyConfirmed(spot, at);
  final source = sourceBasis(spot, vehicle, at, verified: verified);
  // Works or a closure (#116) while it holds: nobody parks, whatever the
  // bay allows. Once its date has passed the spot reads as before, with
  // the details asking riders to confirm.
  if (spot.closure case final closure?
      when closure.stateOn(at) == ClosureState.active) {
    return ParkingDecision(
      EligibilityStatus.notAllowed,
      '${closure.reason.label}期間暫停開放',
      basis: [source],
      price: priceAnswer(spot.fee?.toJson(), vehicle, legacyText: spot.feeNote),
    );
  }
  if (explicit == false && trusted) {
    return ParkingDecision(
      EligibilityStatus.notAllowed,
      '此停車點標示不開放目前車種',
      basis: [source],
    );
  }
  if (spot.spaceType == SpaceType.offStreet) {
    return _lot(spot, vehicle, at, day, explicit, verified, source, cal);
  }
  final price = priceAnswer(
    spot.fee?.toJson(),
    vehicle,
    legacyText: spot.feeNote,
  );
  final matched = matchingRules(rules, spot, vehicle);
  if (spot.segments.isNotEmpty) {
    return _segmented(
      spot,
      vehicle,
      matched,
      at,
      day,
      trusted,
      source,
      cal,
    )._with(price: price);
  }
  final decision = _street(
    spot,
    vehicle,
    matched,
    at,
    day,
    trusted,
    source,
    cal,
  );
  return decision._with(price: price);
}

/// A street spot judged segment by segment (#188 layer 2), as a lot is
/// zone by zone: each segment's allow first (a trusted 不能停 closes it,
/// 官方未標示 leaves it unconfirmed), then its own condition (else the
/// spot's) under the city's rules. The spot is as open as its most open
/// segment.
ParkingDecision _segmented(
  ParkingSpot spot,
  VehicleType vehicle,
  List<CityRule> rules,
  DateTime at,
  String day,
  bool trusted,
  DecisionBasis source,
  HolidayCalendar calendar,
) {
  final segments = [
    for (final seg in spot.segments)
      _segment(seg, spot, vehicle, rules, at, day, trusted, source, calendar),
  ];
  String named(ZoneDecision z) =>
      '${z.name.trim().isEmpty ? '未命名路段' : z.name.trim()}：${z.reason}';
  final open = [
    for (final z in segments)
      if (z.open) z,
  ];
  final EligibilityStatus status;
  final String reason;
  final RuleRestriction? restriction;
  if (open.isNotEmpty) {
    final limited = open
        .where((z) => z.status == EligibilityStatus.conditional)
        .firstOrNull;
    status = limited == null
        ? EligibilityStatus.allowed
        : EligibilityStatus.conditional;
    reason = segments.length == 1
        ? segments.single.reason
        : open.map(named).join('；');
    restriction = limited?.restriction;
  } else if (segments.every((z) => z.status == EligibilityStatus.notAllowed)) {
    status = EligibilityStatus.notAllowed;
    reason = segments.length == 1
        ? segments.single.reason
        : '各路段都不開放${vehicle.label}';
    restriction = null;
  } else {
    status = EligibilityStatus.unverified;
    reason = segments.length == 1
        ? segments.single.reason
        : segments.map(named).join('；');
    restriction = null;
  }
  return ParkingDecision(
    status,
    reason,
    restriction: restriction,
    basis: [source],
    segments: segments,
    gaps: {for (final z in segments) ...z.gaps},
  );
}

/// A segment's condition as judged: its own, with what it leaves out
/// (the bay, its use, the charge, limits and slots) taken from the spot's
/// when it names no bay of its own; null takes the spot's whole.
ParkingCondition? _segmentCondition(
  ParkingCondition? seg,
  ParkingCondition? spot,
) {
  if (seg == null || seg.bay != null || spot == null) return seg;
  return ParkingCondition(
    bay: spot.bay,
    use: spot.use,
    share: spot.share,
    charge: seg.charge ?? spot.charge,
    limits: seg.limits.isEmpty ? spot.limits : seg.limits,
    schedule: seg.schedule.isEmpty ? spot.schedule : seg.schedule,
    basis: seg.basis ?? spot.basis,
    allow: seg.allow,
  );
}

ZoneDecision _segment(
  ParkingSegment seg,
  ParkingSpot spot,
  VehicleType vehicle,
  List<CityRule> rules,
  DateTime at,
  String day,
  bool trusted,
  DecisionBasis source,
  HolidayCalendar calendar,
) {
  final allow = seg.condition?.allow;
  final allowed = vehicle == VehicleType.heavy ? allow?.heavy : allow?.scooter;
  final notStated = vehicle == VehicleType.heavy
      ? allow?.heavyNotStated ?? false
      : allow?.scooterNotStated ?? false;
  // The segment's own rate, else the whole road's (C3).
  final price = priceAnswer(
    (seg.fee ?? spot.fee)?.toJson(),
    vehicle,
    legacyText: seg.fee == null ? spot.feeNote : '',
  );
  ZoneDecision z(
    EligibilityStatus status,
    String reason, {
    RuleRestriction? restriction,
    Set<DecisionGap> gaps = const {},
  }) => ZoneDecision(
    name: seg.name,
    status: status,
    reason: reason,
    restriction: restriction,
    price:
        status == EligibilityStatus.allowed ||
            status == EligibilityStatus.conditional
        ? price
        : null,
    gaps: gaps,
  );
  if (allowed == false) {
    return trusted
        ? z(EligibilityStatus.notAllowed, '此路段標示不開放${vehicle.label}')
        : z(EligibilityStatus.unverified, communityUncheckedReason);
  }
  if (notStated) {
    return z(
      EligibilityStatus.unverified,
      notStatedReason(vehicle, where: '此路段'),
      gaps: {DecisionGap.notStated},
    );
  }
  final d = _street(
    spot,
    vehicle,
    rules,
    at,
    day,
    trusted,
    source,
    calendar,
    condition: _segmentCondition(
      seg.condition,
      spot.condition ?? conditionOf(spot.spaceType),
    ),
  );
  return z(d.status, d.reason, restriction: d.restriction, gaps: d.gaps);
}

/// Who states [vehicle]'s access at [spot] (step 0): government data, an
/// administrator's check (current or lapsed), a rider's report, or nobody.
DecisionBasis sourceBasis(
  ParkingSpot spot,
  VehicleType vehicle,
  DateTime now, {
  required bool verified,
}) {
  if (spot.isOfficial) {
    return DecisionBasis(BasisKind.official, date: spot.updatedAt);
  }
  final at = spot.verifiedAt(vehicle);
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  if (verified) return DecisionBasis(BasisKind.adminVerified, date: at);
  if (explicit != null && at != null) {
    return DecisionBasis(BasisKind.adminLapsed, date: at);
  }
  if (explicit != null) {
    return DecisionBasis(BasisKind.communityReport, date: spot.createdAt);
  }
  return DecisionBasis(BasisKind.none, date: spot.createdAt);
}

ParkingDecision _street(
  ParkingSpot spot,
  VehicleType vehicle,
  List<CityRule> rules,
  DateTime at,
  String day,
  bool trusted,
  DecisionBasis source,
  HolidayCalendar calendar, {
  ParkingCondition? condition,
}) {
  final c = condition ?? spot.condition ?? conditionOf(spot.spaceType);
  if (c == null) {
    return ParkingDecision(
      EligibilityStatus.unverified,
      '格位類型未確認，請以現場標誌標線為準',
      basis: [source],
    );
  }
  final notices = [if (c.basis case final b?) _notice(b, day)];
  final noticeHolds = _noticeHolds(c.basis, day);
  final noticeGaps = [if (!noticeHolds) DecisionGap.noticeExpired];
  ParkingDecision done(
    EligibilityStatus status,
    String reason, {
    RuleRestriction? restriction,
    BasisKind? by,
    Iterable<DecisionBasis> more = const [],
    Iterable<DecisionGap> gaps = const [],
  }) => ParkingDecision(
    status,
    reason,
    restriction: restriction,
    basis: [
      source,
      // A notice-backed answer lists the notice itself, with its dates.
      if (by != null && !(by == BasisKind.notice && notices.isNotEmpty))
        DecisionBasis(by),
      ...more,
      ...notices,
    ],
    gaps: {...gaps, ...noticeGaps},
  );

  final carShare = c.share == ShareKind.carMotorcycle;
  final special = c.hasLimit(LimitKind.specialVehicle);
  final ev = c.hasLimit(LimitKind.evOnly);
  final timed = _timeBound(c);
  final timeReasons = _timeReasons(c, at, calendar);
  // Step 1. The bay's own class first: no limit or notice opens a heavy bay
  // to scooters, nor a car bay unless a city rule does.
  if (c.bay == Bay.heavy && vehicle == VehicleType.scooter) {
    return done(EligibilityStatus.notAllowed, '大型重機專用格', by: BasisKind.law);
  }
  // Car bays are painted for small cars and heavy bikes (標誌標線號誌設置規則
  // §190); an ordinary scooter there is the wrong vehicle class unless a
  // city rule opens them (道路交通安全規則 §112, last paragraph), also in
  // named districts only; the district check below closes the others. A
  // shared car bay's own notice decides below.
  if (c.bay == Bay.car &&
      !carShare &&
      vehicle == VehicleType.scooter &&
      !rules.any(
        (r) =>
            r.allowedSpaceTypes.contains(SpaceType.car) ||
            r.conditionalSpaceTypes.contains(SpaceType.car) ||
            r.districtSpaceTypes.containsKey(SpaceType.car),
      )) {
    return done(EligibilityStatus.notAllowed, _carBayReason, by: BasisKind.law);
  }
  // Bays reserved by vehicle, whatever the city rule says.
  if (!trusted && (special || ev || carShare)) {
    return done(EligibilityStatus.unverified, communityUncheckedReason);
  }

  // A shared car bay opens to scooters only in the slots its notice names
  // (§7 item 1), whatever else limits it (#155 item 16); heavy bikes are
  // judged as on a car bay here, and by their own slots below.
  final shareSlots = carShare && vehicle == VehicleType.scooter
      ? noticeHolds
            ? _slotsFor(c, vehicle)
            : const <ScheduleSlot>[]
      : null;
  if (shareSlots != null && shareSlots.isEmpty) {
    return done(
      EligibilityStatus.unverified,
      noticeHolds
          ? '公告沒有列出${vehicle.label}的開放時段，請看現場牌面'
          : _expiredNoticeReason(c.basis!, day),
      gaps: [DecisionGap.scheduleUnknown],
    );
  }

  ParkingDecision result;
  final heavyShare =
      vehicle == VehicleType.heavy && c.share == ShareKind.scooterHeavy;
  if (special || ev) {
    // The rider using the app may qualify, but a permit alone does not: the
    // bay is for 特製機車 passed by the motor vehicles office, used by or
    // carrying the permit holder (身心障礙者專用停車位設置管理辦法 §12).
    // Every limit is kept; the slots below still apply.
    result = done(
      EligibilityStatus.conditional,
      [
        if (special) _disabledReason,
        if (ev) _evReason,
        ...timeReasons,
      ].join('；'),
      restriction: ev
          ? RuleRestriction.evOnly
          : timed
          ? RuleRestriction.timeLimited
          : null,
      by: BasisKind.law,
    );
  } else if (shareSlots != null) {
    final slots = shareSlots;
    return done(
      EligibilityStatus.conditional,
      [
        '汽機車依時段輪替使用，${slotNowText(slots, at, calendar: calendar)}；'
            '${vehicle.label}可停時段：${slots.map(slotText).join('；')}，請看現場牌面',
        ...timeReasons,
      ].join('；'),
      restriction: RuleRestriction.timeLimited,
      by: BasisKind.notice,
    );
  } else {
    final kinds = ruleKindsOf(c);
    if (kinds.isEmpty) {
      return done(EligibilityStatus.unverified, '格位類型未確認，請以現場標誌標線為準');
    }
    // Step 2. A shared-use sign is itself a notice, more specific than the
    // city rule, while it holds.
    if (heavyShare && noticeHolds) {
      result = trusted
          ? done(
              EligibilityStatus.allowed,
              '普大共用格：依現場共用標示停放，請勿超出格線',
              by: BasisKind.notice,
            )
          : done(EligibilityStatus.unverified, communityUncheckedReason);
    } else {
      final verdicts = [
        for (final k in kinds) ruleVerdict(rules, k, spot.district, now: at),
      ];
      final judged = [for (final v in verdicts) _fromVerdict(v, trusted)];
      final first = judged.first;
      if (judged.every(
        (j) => j.status == first.status && j.restriction == first.restriction,
      )) {
        final v = verdicts.first;
        result = done(
          first.status,
          first.reason,
          restriction: first.restriction,
          more: [
            // An ended rule a lawful bay is still judged by (decision 44)
            // is not its basis any more: the law is.
            if (v.rule case final rule?
                when v.kind != RuleVerdictKind.expired && ruleExpired(rule, at))
              const DecisionBasis(BasisKind.law)
            else if (v.rule case final rule?)
              DecisionBasis(
                BasisKind.cityRule,
                rule: rule,
                url: rule.sourceUrl,
                date: rule.effectiveDate,
                expired: v.kind == RuleVerdictKind.expired,
              ),
          ],
          gaps: [
            if (v.kind == RuleVerdictKind.expired) DecisionGap.noticeExpired,
            if (v.kind == RuleVerdictKind.conflict) DecisionGap.noticeConflict,
            if (v.kind == RuleVerdictKind.unknownDistrict)
              DecisionGap.districtUnknown,
          ],
        );
      } else {
        result = done(
          EligibilityStatus.unverified,
          '無法確認此格是收費格或免費格，請看現場牌面',
          gaps: [DecisionGap.chargeUnknown],
        );
      }
      // A shared-use sign whose notice ended opens nothing the rule does
      // not.
      if (heavyShare && !result.open) {
        result = result._with(
          status: EligibilityStatus.unverified,
          reason: _expiredNoticeReason(c.basis!, day),
          restriction: () => null,
        );
      }
    }
    // Posted limits apply where the bay is open.
    if (result.status == EligibilityStatus.allowed && timed) {
      result = result._with(
        status: EligibilityStatus.conditional,
        reason: timeReasons.join('；'),
        restriction: () => RuleRestriction.timeLimited,
      );
    }
  }

  // Time slots (§3.3): shown with whether they hold now (#120), which the
  // reason says without switching the status, so markers and search keep
  // the bay's standing. Heavy bikes on a car bay park by law whatever the
  // slots say, except on a shared car bay, where they park in the car
  // slots, the scooter slots a city rule opens to them and the slots the
  // notice names for them (PM_ANS_20261031_21).
  final heavyOnShare = carShare && vehicle == VehicleType.heavy;
  if (c.schedule.isNotEmpty &&
      !(vehicle == VehicleType.heavy && c.bay == Bay.car && !carShare) &&
      result.status != EligibilityStatus.notAllowed) {
    final share = heavyOnShare && noticeHolds
        ? _heavyShareSlots(c, rules, spot.district, at)
        : null;
    final slots = !noticeHolds
        ? const <ScheduleSlot>[]
        : share?.slots ?? _slotsFor(c, vehicle);
    if (slots.isEmpty) {
      result = result._with(
        status: EligibilityStatus.unverified,
        reason: !noticeHolds
            ? _expiredNoticeReason(c.basis!, day)
            : heavyOnShare
            ? '公告沒有列出汽車時段或對${vehicle.label}開放的機車時段，請看現場牌面'
            : '公告沒有列出${vehicle.label}的開放時段，請看現場牌面',
        restriction: () => null,
        moreGaps: [DecisionGap.scheduleUnknown],
      );
    } else if (result.open) {
      // The slots add to what already limits the bay (a city rule's
      // signage, a limit), never replace it.
      final limited = result.status == EligibilityStatus.conditional;
      final kept = result.restriction;
      final listed = {for (final b in result.basis) b.kind};
      // A conditional rule's limit holds in the scooter slots it opens.
      final ruleLimit = share?.ruleLimit;
      result = result._with(
        status: EligibilityStatus.conditional,
        reason:
            '${limited ? '${result.reason}；' : ''}'
            '${heavyOnShare ? '汽機車依時段輪替使用，' : ''}'
            '${slotNowText(slots, at, calendar: calendar)}；'
            '${vehicle.label}可停時段：${slots.map(slotText).join('；')}，請看現場牌面'
            '${ruleLimit == null ? '' : '；機車時段：${ruleLimit.reason}'}',
        restriction: () => limited && kept != null
            ? kept
            : ruleLimit?.restriction ?? RuleRestriction.timeLimited,
        moreBasis: [
          for (final b in share?.basis ?? const <DecisionBasis>[])
            if (!listed.contains(b.kind) ||
                (b.kind == BasisKind.cityRule &&
                    !result.basis.any((r) => r.rule == b.rule)))
              b,
        ],
      );
    }
  } else if (heavyOnShare && c.schedule.isEmpty && result.open) {
    // Judged as a car bay; its sign still says when cars and scooters
    // take turns.
    result = result._with(reason: '${result.reason}；$_shareSignReminder');
  }
  return result;
}

extension on ParkingDecision {
  bool get open =>
      status == EligibilityStatus.allowed ||
      status == EligibilityStatus.conditional;
}

/// Why a notice that does not hold today opens nothing: it ended, or has not
/// started yet.
String _expiredNoticeReason(ConditionBasis basis, String day) =>
    _noticeEnded(basis, day)
    ? '公告已於 ${basis.expiresOn} 到期，請看現場公告'
    : '公告 ${basis.effectiveDate} 起生效，請看現場公告';

Eligibility _fromVerdict(RuleVerdict v, bool trusted) => switch (v.kind) {
  RuleVerdictKind.noRule ||
  RuleVerdictKind.expired ||
  RuleVerdictKind.conflict ||
  RuleVerdictKind.unknownDistrict => Eligibility(
    EligibilityStatus.unverified,
    v.reason,
  ),
  RuleVerdictKind.closed => Eligibility(EligibilityStatus.notAllowed, v.reason),
  // A rule not verified yet opens nothing for certain.
  RuleVerdictKind.conditional
      when v.restriction == RuleRestriction.unverified =>
    Eligibility(EligibilityStatus.unverified, v.reason),
  _ when !trusted => const Eligibility(
    EligibilityStatus.unverified,
    communityUncheckedReason,
  ),
  // Known limits only once the spot itself is trusted.
  RuleVerdictKind.conditional => Eligibility(
    EligibilityStatus.conditional,
    v.reason,
    restriction: v.restriction,
  ),
  RuleVerdictKind.open => Eligibility(EligibilityStatus.allowed, v.reason),
};

ZoneDecision _zone(
  ParkingZone z,
  VehicleType vehicle,
  DateTime at,
  String day,
  PriceAnswer? price,
  HolidayCalendar calendar,
) {
  final c = z.condition ?? zoneConditionOf(z.access);
  final name = z.name;
  // Unknown is not closed (#155 item 7): a zone with neither a condition
  // nor an access stays unconfirmed and inherits nothing.
  if (c == null) {
    return ZoneDecision(
      name: name,
      status: EligibilityStatus.unverified,
      reason: '此分區的開放資訊未確認',
      hasData: false,
    );
  }
  final notice = c.basis == null ? null : _notice(c.basis!, day, zone: name);
  ZoneDecision zone(
    EligibilityStatus status,
    String reason, {
    RuleRestriction? restriction,
    Set<DecisionGap> gaps = const {},
  }) => ZoneDecision(
    name: name,
    status: status,
    reason: reason,
    restriction: restriction,
    notice: notice,
    price:
        status == EligibilityStatus.allowed ||
            status == EligibilityStatus.conditional
        ? price
        : null,
    gaps: gaps,
  );
  final allowed = vehicle == VehicleType.heavy
      ? c.allow?.heavy
      : c.allow?.scooter;
  if (allowed == false) {
    return zone(EligibilityStatus.notAllowed, '此分區標示不開放${vehicle.label}');
  }
  // allow only opens the lot's side; the law still applies (step 1).
  if (vehicle == VehicleType.scooter && c.bay == Bay.heavy) {
    return zone(EligibilityStatus.notAllowed, '大型重機專用格');
  }
  // A notice that ended (or has not started) voids only what it opens, as
  // on the street: a zone it closes stays closed.
  if (!_noticeHolds(c.basis, day)) {
    return zone(
      EligibilityStatus.unverified,
      _expiredNoticeReason(c.basis!, day),
      gaps: {DecisionGap.noticeExpired},
    );
  }
  if (allowed == null) {
    final notStated = vehicle == VehicleType.heavy
        ? c.allow?.heavyNotStated ?? false
        : c.allow?.scooterNotStated ?? false;
    return notStated
        ? zone(
            EligibilityStatus.unverified,
            notStatedReason(vehicle, where: '此分區'),
            gaps: {DecisionGap.notStated},
          )
        : zone(EligibilityStatus.unverified, '此分區的開放資訊未確認');
  }
  if (vehicle == VehicleType.scooter && c.bay == Bay.car) {
    return zone(EligibilityStatus.unverified, '汽車格開放普通機車須有公告，請依入口公告');
  }
  // Every limit, the slots and a trial's end date are kept together.
  final ev = c.hasLimit(LimitKind.evOnly);
  final timed = _timeBound(c);
  final slots = _slotsFor(c, vehicle);
  if (c.schedule.isNotEmpty && slots.isEmpty) {
    return zone(
      EligibilityStatus.unverified,
      '公告沒有列出${vehicle.label}的開放時段',
      gaps: {DecisionGap.scheduleUnknown},
    );
  }
  final limits = [
    if (c.hasLimit(LimitKind.specialVehicle)) _disabledReason,
    if (ev) _evReason,
    if (slots.isNotEmpty)
      '${slotNowText(slots, at, calendar: calendar)}；'
          '可停時段：${slots.map(slotText).join('；')}',
    ..._timeReasons(c, at, calendar),
    // A trial with an end date: open while it lasts, and the rider should
    // know it ends.
    if (c.basis?.expiresOn case final end?) '試辦至 $end',
  ];
  if (limits.isNotEmpty) {
    return zone(
      EligibilityStatus.conditional,
      limits.join('；'),
      restriction: ev
          ? RuleRestriction.evOnly
          : slots.isNotEmpty || timed
          ? RuleRestriction.timeLimited
          : null,
    );
  }
  return zone(EligibilityStatus.allowed, '此分區標示開放${vehicle.label}');
}

/// The zone names as one phrase: 「機車區與汽車區」, 「A、B 等 3 區」.
String zoneNames(List<ZoneDecision> zones) {
  final names = [
    for (final z in zones) z.name.trim().isEmpty ? '未命名分區' : z.name.trim(),
  ];
  return switch (names.length) {
    0 => '',
    1 => names.first,
    2 => '${names[0]}與${names[1]}',
    _ => '${names[0]}、${names[1]}等 ${names.length} 區',
  };
}

ParkingDecision _lot(
  ParkingSpot spot,
  VehicleType vehicle,
  DateTime at,
  String day,
  bool? explicit,
  bool verified,
  DecisionBasis source,
  HolidayCalendar calendar,
) {
  // Prices (step 4): a zone's own fee; the lot's only when no zone has one.
  final lotPrice = priceAnswer(
    spot.fee?.toJson(),
    vehicle,
    legacyText: spot.feeNote,
  );
  final anyZoneFee = spot.zones.any((z) => z.fee != null);
  final zones = [
    for (final z in spot.zones)
      _zone(
        z,
        vehicle,
        at,
        day,
        z.fee != null
            ? priceAnswer(z.fee!.toJson(), vehicle)
            // C2 (#188 layer 2): a zone without its own rate takes the
            // lot-wide one; only with no structured rate anywhere does a
            // zone read its own text (as the details list it zone by
            // zone), then the lot's.
            : spot.fee != null
            ? lotPrice
            : switch (_zoneLegacyText(z, vehicle)) {
                final text? => PriceAnswer.unknown(text),
                null when anyZoneFee => const PriceAnswer.unknown(),
                null => lotPrice,
              },
        calendar,
      ),
  ];
  final notices = [for (final z in zones) ?z.notice];
  // Community claims never override legal rules, and only official or
  // admin-verified data may open a lot: confirmed existence never verifies a
  // community "可停".
  final official = explicit == true && spot.isOfficial && !spot.stale;
  final open = official || (explicit == true && verified);
  ParkingDecision decision(
    EligibilityStatus status,
    String reason, {
    RuleRestriction? restriction,
    Set<DecisionGap> gaps = const {},
  }) => ParkingDecision(
    status,
    reason,
    restriction: restriction,
    basis: [source, ...notices],
    zones: zones,
    price: spot.zones.isEmpty ? lotPrice : null,
    gaps: gaps,
  );
  if (!open) {
    return spot.notStated(vehicle)
        ? decision(
            EligibilityStatus.unverified,
            notStatedReason(vehicle),
            gaps: {DecisionGap.notStated},
          )
        : decision(EligibilityStatus.unverified, lotUncheckedReason);
  }
  // The headline already says 可停 and the basis line says who checked it
  // and when (#132), so the reason only adds the reminder.
  final remind = official ? '場站資料標示可停，請確認現場公告' : '請確認現場公告';
  // Zones that say nothing leave the lot as its own data says (§3.2: no
  // zone data).
  if (!zones.any((z) => z.hasData)) {
    return decision(EligibilityStatus.allowed, remind);
  }
  final reachable = [
    for (final z in zones)
      if (z.open) z,
  ];
  if (reachable.isNotEmpty) {
    final limited = reachable
        .where((z) => z.status == EligibilityStatus.conditional)
        .firstOrNull;
    return decision(
      limited == null
          ? EligibilityStatus.allowed
          : EligibilityStatus.conditional,
      // A conditional lot says which zones and what limits them; the
      // wrapper keeps only this reason.
      limited == null
          ? remind
          : '${[for (final z in reachable)
              if (z.status == EligibilityStatus.conditional) '${z.name.trim().isEmpty ? '未命名分區' : z.name.trim()}：${z.reason}'].join('；')}。$remind',
      restriction: limited?.restriction,
      gaps: {for (final z in zones) ...z.gaps},
    );
  }
  // Open to the vehicle, but no listed zone is (§7 item 6): never inferred
  // closed, since the list may be partial or the two sources disagree.
  if (spot.zonesComplete &&
      zones.every((z) => z.status == EligibilityStatus.notAllowed)) {
    return decision(
      EligibilityStatus.unverified,
      '場站與分區資料不一致，請依入口公告',
      gaps: {DecisionGap.zonesConflict},
    );
  }
  return decision(
    EligibilityStatus.unverified,
    '場站開放${vehicle.label}，但已知分區沒有標示可停區域，請依入口公告',
    gaps: {DecisionGap.zonesIncomplete, for (final z in zones) ...z.gaps},
  );
}

String? _orNull(String text) => text.trim().isEmpty ? null : text;

String? _zoneLegacyText(ParkingZone z, VehicleType vehicle) =>
    (vehicle == VehicleType.heavy
        ? _orNull(z.heavyFeeNote)
        : _orNull(z.scooterFeeNote)) ??
    _orNull(z.feeNote);
