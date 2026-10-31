import '../models/parking.dart';
import '../models/parking_condition.dart';
import '../models/zone_entries.dart';
import 'eligibility.dart';
import 'parking_decision.dart';

/// The rules page (P7): what one city rule means for each of the seven bay
/// kinds, one row each. Every verdict comes from [eligibility], the same
/// judgement the map markers use; this file only reads it and words it.

/// What a rules row's plate says.
String rulePillLabel(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => '可停',
  EligibilityStatus.conditional => '有條件',
  EligibilityStatus.unverified => '待確認',
  EligibilityStatus.notAllowed => '不能停',
};

/// 7 類格位的正式名稱（FIX-DECISIONS）.
String bayKindLabel(BayKind kind) => switch (kind) {
  BayKind.motorcycle => '一般機車格',
  BayKind.scooterHeavy => '普大共用格',
  BayKind.heavy => '重機專用格',
  BayKind.carMotorcycle => '汽機車共用格',
  BayKind.car => '汽車格',
  BayKind.disabled => '身障格',
  BayKind.ev => '充電格',
};

/// One judged part of a bay kind: the motorcycle bay is judged as its toll
/// and its free bays, every other kind as one.
class _Part {
  const _Part(this.name, this.status, this.restriction, this.districts);
  final String name;
  final EligibilityStatus status;
  final RuleRestriction? restriction;

  /// The districts the rule opens this part in only; null when citywide.
  final List<String>? districts;

  bool get open =>
      status == EligibilityStatus.allowed ||
      status == EligibilityStatus.conditional;

  /// Districts are named only where the part is open there.
  String get text => switch (districts) {
    final d? when open => '$name僅${d.join('、')}${rulePillLabel(status)}',
    _ => '$name${rulePillLabel(status)}',
  };
}

/// One row of the rules page.
class RuleRow {
  const RuleRow({
    required this.kind,
    required this.status,
    required this.detail,
    this.note = '',
  });
  final BayKind kind;
  final EligibilityStatus status;

  /// The small line under the name.
  final String detail;

  /// The rule's own remarks (`exceptions`, e.g. 「可斜停兩格，勿阻礙通行。」),
  /// shown in small print under the row they are about; empty for others.
  final String note;

  String get label => bayKindLabel(kind);
  String get pill => rulePillLabel(status);
}

/// The street bay a kind is judged as: its legacy kind for the rule, and
/// the condition [decideParking] reads.
List<(String, SpaceType, ParkingCondition?)> _judgedAs(BayKind kind) =>
    switch (kind) {
      BayKind.motorcycle => [
        (
          '收費格',
          SpaceType.paidMotorcycle,
          typicalCondition(SpaceType.paidMotorcycle),
        ),
        (
          '免費巷弄格',
          SpaceType.freeMotorcycle,
          typicalCondition(SpaceType.freeMotorcycle),
        ),
      ],
      BayKind.scooterHeavy => const [
        (
          '',
          SpaceType.paidMotorcycle,
          ParkingCondition(
            bay: Bay.motorcycle,
            use: BayUse.share,
            share: ShareKind.scooterHeavy,
          ),
        ),
      ],
      BayKind.heavy => [
        ('', SpaceType.heavyOnly, typicalCondition(SpaceType.heavyOnly)),
      ],
      BayKind.carMotorcycle => [
        ('', SpaceType.flexShared, typicalCondition(SpaceType.flexShared)),
      ],
      BayKind.car => [('', SpaceType.car, typicalCondition(SpaceType.car))],
      BayKind.disabled => [
        (
          '',
          SpaceType.disabledMotorcycle,
          typicalCondition(SpaceType.disabledMotorcycle),
        ),
      ],
      BayKind.ev => [
        ('', SpaceType.evMotorcycle, typicalCondition(SpaceType.evMotorcycle)),
      ],
    };

/// Each kind's line when nothing about the rule needs saying.
String _kindDetail(BayKind kind, EligibilityStatus status) => switch (kind) {
  BayKind.motorcycle => '',
  BayKind.scooterHeavy => '標示普通機車與大型重機共用',
  BayKind.heavy => '標示大型重機專用',
  BayKind.carMotorcycle => '依牌面時段開放',
  BayKind.car =>
    status == EligibilityStatus.allowed ? '依規定可停，照汽車費率' : '小型車及大型重機停放線',
  BayKind.disabled => '限身障特製車輛，持識別證',
  BayKind.ev => '限電動機車充換電',
};

/// The seven rows for [rule] and [vehicle], in the official order. Each
/// part is judged as a verified official bay in the rule's city; a kind the
/// rule opens in named districts only is judged as it is there, and its
/// line names them.
List<RuleRow> ruleRows(CityRule rule, VehicleType vehicle, {DateTime? now}) => [
  for (final kind in BayKind.values) _row(rule, vehicle, kind, now),
];

RuleRow _row(CityRule rule, VehicleType vehicle, BayKind kind, DateTime? now) {
  final parts = [
    for (final (name, type, condition) in _judgedAs(kind))
      () {
        final districts = rule.districtSpaceTypes[ruleSpaceType(type)];
        final e = eligibility(
          ParkingSpot(
            id: 'rule',
            name: 'rule',
            lat: 0,
            lng: 0,
            city: rule.city,
            district: districts?.first ?? '',
            spaceType: type,
            condition: condition,
            status: TrustStatus.confirmed,
            source: 'official',
          ),
          vehicle,
          rule,
          now: now,
        );
        return _Part(name, e.status, e.restriction, districts);
      }(),
  ];
  final first = parts.first;
  final same = parts.every(
    (p) => p.status == first.status && p.restriction == first.restriction,
  );
  // Districts limit only a part that is open there; a part the data
  // cannot judge (e.g. its rule ended) stays what it is.
  final limited = parts.any((p) => p.districts != null && p.open);
  // Parts that disagree, or that hold in some districts only, are open
  // with a condition — but only when some part really is open: the line
  // says which. Otherwise the row stays unknown unless every part is
  // closed.
  final status = same && !limited
      ? first.status
      : parts.any((p) => p.open)
      ? EligibilityStatus.conditional
      : parts.every((p) => p.status == EligibilityStatus.notAllowed)
      ? EligibilityStatus.notAllowed
      : EligibilityStatus.unverified;
  final String detail;
  if (parts.length > 1) {
    detail = same && !limited
        ? '${parts.map((p) => p.name).join('、')}都${rulePillLabel(first.status)}'
              '${first.restriction == null ? '' : '：${first.restriction!.label}'}'
        : parts.map((p) => p.text).join('，');
  } else if (limited) {
    detail = '僅${first.districts!.join('、')}${rulePillLabel(first.status)}';
  } else {
    detail = _kindDetail(kind, status);
  }
  return RuleRow(
    kind: kind,
    status: status,
    detail: detail,
    // A city rule's remarks are about the motorcycle bays it opens or
    // closes, so they sit under that row.
    note: kind == BayKind.motorcycle ? rule.exceptions.trim() : '',
  );
}

/// 「規則依臺北市公告整理。核對日期 2026-10-06，版本 1。」
String ruleCheckedLine(CityRule rule) =>
    '規則依${rule.city}公告整理。核對日期 ${rule.effectiveDate.toIso8601String().substring(0, 10)}，'
    '版本 ${rule.version}。';

const rulesIntro = '停之前，先看規則。各縣市開放的格位和收費不同。';
const rulesDisclaimer =
    '本指南僅供參考，不取代現場標誌、標線與管理單位公告。'
    '社群回報與剩餘格數可能有延遲，請確認車身完整位於允許的格線內。';

String noRuleText(String city, VehicleType vehicle) =>
    '$city尚無${vehicle.label}的停車規則資料。';

/// The notice shown when the backend's rules could not be read and the
/// bundled file stands in.
const bundledRulesWarning = '遠端規則讀取失敗，顯示內建規則';

/// The notice shown when rules from the last download stand in; the date is
/// the download's, in Taiwan time.
String cachedRulesWarning(DateTime downloadedAt) {
  final taiwan = downloadedAt.toUtc().add(const Duration(hours: 8));
  return '遠端規則讀取失敗，使用上次下載的規則（${taiwan.month}月${taiwan.day}日）';
}

/// [cachedRulesWarning] when cached rules are in use ([cachedAt] is their
/// download time), [bundledRulesWarning] otherwise.
String rulesFallbackWarning(DateTime? cachedAt) =>
    cachedAt == null ? bundledRulesWarning : cachedRulesWarning(cachedAt);
