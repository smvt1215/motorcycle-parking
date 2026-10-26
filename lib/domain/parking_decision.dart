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

import '../models/fee.dart';
import '../models/fee_plan.dart';
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

/// What [rules] — the rules of one city and vehicle, already matched —
/// say about the street bay [kind] in [district] at [now] (§3.2 step 2).
/// Dates are Taiwan's, as in SQL. Rules not yet in force are ignored; expired ones count only when no
/// other is in force, and then the answer is [RuleVerdictKind.expired],
/// never another rule's. Rules in force that disagree are a
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
  final current = [
    for (final r in started)
      if (!ruleExpired(r, now)) r,
  ];
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
      // 首段 0 元 (0 with a valid time) is never renewed (§2.5).
      final firstFree = rate['amount'] == 0 && rate['max_minutes'] != null;
      if (!firstFree && !rate.containsKey('renew')) gaps.add('隔日是否另計');
      if (rate['extension'] case final Map<Object?, Object?> ext
          when !ext.containsKey('minutes')) {
        gaps.add('延長時長');
      }
    case 'hourly' when rate.containsKey('daily_cap'):
      if (!rate.containsKey('cap_reset')) gaps.add('上限計算方式');
    case 'daily':
      if (!rate.containsKey('cap_reset')) gaps.add('上限計算方式');
    case 'by_time':
      final periods = (rate['periods'] as List?) ?? const [];
      var visits = 0;
      for (final p in periods) {
        if (p case {'rate': final Map<Object?, Object?> r}) {
          if (r['mode'] == 'posted') gaps.add('部分時段費率');
          if (r['mode'] == 'per_visit') visits++;
          _rateGaps(r, gaps);
        }
      }
      if (visits >= 2 && !rate.containsKey('cross_period')) {
        gaps.add('跨時段如何計費');
      }
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
  if (text == null) {
    return PriceAnswer.unknown(
      structured.riderText(key) != null ? '${vehicle.label}費率未提供' : legacy,
    );
  }
  final rate = resolveFee(fee! as Map)[key];
  if (rate is! Map) return PriceAnswer.unknown(legacy);
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
    this.price,
    this.gaps = const {},
  });
  final EligibilityStatus status;
  final String reason;
  final RuleRestriction? restriction;

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

const _disabledReason =
    '身障專用格：須是經監理站檢驗合格的特製機車，且身障者本人騎乘或同行，'
    '並持專用停車位識別證或掛專用牌照，才可停放';
const _evReason = '限電動機車停放或充換電，燃油機車不可停';
const _timedReason = '限時停車：請依現場牌面的時段與時限停放，超時須移車';
const _carBayReason = '汽車格為小型車及大型重機停放線，普通機車停放屬車種不依規定';

/// Whether [vehicle] may park at [spot] under [rules] at [now] (§3.2),
/// with its basis, zones and prices. [rules] may hold every city's rules;
/// the spot's city's are read, else the national ones.
ParkingDecision decideParking(
  ParkingSpot spot,
  VehicleType vehicle,
  Iterable<CityRule> rules, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final day = taipeiDay(at);
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
  final source = _sourceBasis(spot, vehicle, at, verified: verified);
  if (explicit == false && trusted) {
    return ParkingDecision(
      EligibilityStatus.notAllowed,
      '此停車點標示不開放目前車種',
      basis: [source],
    );
  }
  if (spot.spaceType == SpaceType.offStreet) {
    return _lot(spot, vehicle, at, day, explicit, verified, source);
  }
  final price = priceAnswer(
    spot.fee?.toJson(),
    vehicle,
    legacyText: spot.feeNote,
  );
  final decision = _street(
    spot,
    vehicle,
    matchingRules(rules, spot, vehicle),
    at,
    day,
    trusted,
    source,
  );
  return decision._with(price: price);
}

DecisionBasis _sourceBasis(
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
) {
  final c = spot.condition ?? conditionOf(spot.spaceType);
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
  final timed = c.hasLimit(LimitKind.timeLimit);
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
        if (timed) _timedReason,
      ].join('；'),
      restriction: ev
          ? RuleRestriction.evOnly
          : timed
          ? RuleRestriction.timeLimited
          : null,
      by: BasisKind.law,
    );
  } else if (carShare && vehicle == VehicleType.scooter) {
    // A shared car bay opens to scooters only in the slots its notice names
    // (§7 item 1); heavy bikes park on car bays by law, shared or not.
    final slots = noticeHolds ? _slotsFor(c, vehicle) : const <ScheduleSlot>[];
    if (slots.isEmpty) {
      return done(
        EligibilityStatus.unverified,
        noticeHolds
            ? '公告沒有列出${vehicle.label}的開放時段，請看現場牌面'
            : _expiredNoticeReason(c.basis!, day),
        gaps: [DecisionGap.scheduleUnknown],
      );
    }
    return done(
      EligibilityStatus.conditional,
      [
        '汽機車依時段輪替使用，${vehicle.label}可停時段：'
            '${slots.map(slotText).join('；')}，請看現場牌面',
        if (timed) _timedReason,
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
            if (v.rule case final rule?)
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
        reason: _timedReason,
        restriction: () => RuleRestriction.timeLimited,
      );
    }
  }

  // Time slots (§3.3): shown, not switched by the clock (§7 item 4). Heavy
  // bikes on a car bay park by law whatever the slots say.
  if (c.schedule.isNotEmpty &&
      !(vehicle == VehicleType.heavy && c.bay == Bay.car) &&
      result.status != EligibilityStatus.notAllowed) {
    final slots = noticeHolds ? _slotsFor(c, vehicle) : const <ScheduleSlot>[];
    if (slots.isEmpty) {
      result = result._with(
        status: EligibilityStatus.unverified,
        reason: noticeHolds
            ? '公告沒有列出${vehicle.label}的開放時段，請看現場牌面'
            : _expiredNoticeReason(c.basis!, day),
        restriction: () => null,
        moreGaps: [DecisionGap.scheduleUnknown],
      );
    } else if (result.open) {
      final limits = special || ev ? '${result.reason}；' : '';
      result = result._with(
        status: EligibilityStatus.conditional,
        reason:
            '$limits${vehicle.label}可停時段：${slots.map(slotText).join('；')}，請看現場牌面',
        restriction: () =>
            ev ? RuleRestriction.evOnly : RuleRestriction.timeLimited,
      );
    }
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
  String day,
  PriceAnswer? price,
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
    return zone(EligibilityStatus.unverified, '此分區的開放資訊未確認');
  }
  if (vehicle == VehicleType.scooter && c.bay == Bay.car) {
    return zone(EligibilityStatus.unverified, '汽車格開放普通機車須有公告，請依入口公告');
  }
  // Every limit, the slots and a trial's end date are kept together.
  final ev = c.hasLimit(LimitKind.evOnly);
  final timed = c.hasLimit(LimitKind.timeLimit);
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
    if (slots.isNotEmpty) '可停時段：${slots.map(slotText).join('；')}',
    if (timed) _timedReason,
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
        day,
        z.fee != null
            ? priceAnswer(z.fee!.toJson(), vehicle)
            : anyZoneFee
            ? PriceAnswer.unknown(
                (vehicle == VehicleType.heavy
                        ? _orNull(z.heavyFeeNote)
                        : _orNull(z.scooterFeeNote)) ??
                    _orNull(z.feeNote),
              )
            : lotPrice,
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
  if (!open) return decision(EligibilityStatus.unverified, lotUncheckedReason);
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
