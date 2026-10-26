import '../models/parking.dart';
import 'eligibility.dart';
import 'parking_decision.dart';

/// What an [Eligibility] result rests on, for display only. The tiers never
/// change the result: a rider's claim stays [EligibilityStatus.unverified]
/// however it reads.
enum EligibilityTier {
  /// Law, official data or an administrator's current check decided it.
  decided,

  /// Only an unchecked rider claim (or an expired check) says it is open.
  reportedAllowed,

  /// Only an unchecked rider claim (or an expired check) says it is closed.
  reportedNotAllowed,

  /// No source states this vehicle's access to the lot.
  noData,

  /// Undecided for another reason (no rule in force, unknown district,
  /// unchecked roadside bay); the result's reason says which.
  other,
}

/// How the details banner words an [Eligibility] result.
/// A notice with an end date under the banner's basis line (§8.3): 「機車區
/// 試辦至 2026-12-31」, or once ended 「機車區試辦已於 2026-10-05 到期，請看
/// 現場公告」. Shown with a calendar icon, never by colour alone.
class NoticeLine {
  const NoticeLine(this.text, {required this.expired, this.cityRule = false});
  final String text;

  /// Ended, or not started yet: it holds nothing now.
  final bool expired;

  /// A city rule's end, not a notice of the spot or a zone.
  final bool cityRule;
}

/// One zone of a lot as the banner lists it (逐區資格).
class ZoneLine {
  const ZoneLine({
    required this.name,
    required this.status,
    required this.label,
    required this.reason,
    this.restriction,
  });
  final String name, label;

  /// Why the zone is conditional or unknown, without what the banner's
  /// [EligibilityDisplay.notices] already say (試辦至…, ended, not started);
  /// empty when nothing else limits it.
  final String reason;
  final EligibilityStatus status;
  final RuleRestriction? restriction;
}

class EligibilityDisplay {
  const EligibilityDisplay({
    required this.tier,
    required this.label,
    required this.explanation,
    this.basis,
    this.lapsed = false,
    this.notices = const [],
    this.zones = const [],
  });
  final EligibilityTier tier;

  /// The claim is an administrator's check past [verificationDays], not a
  /// rider's report: the banner keeps the question mark, not the people.
  final bool lapsed;

  /// The banner headline, e.g. 「可停」 or 「車友回報可停」.
  final String label;
  final String explanation;

  /// Who stated it and when, e.g. 「管理員確認，2026-10-25」; null when the
  /// result comes from a city rule or nothing dates it.
  final String? basis;

  /// Notices with an end date, the spot's or its zones' (§3.3).
  final List<NoticeLine> notices;

  /// Each zone's eligibility, when any zone says something.
  final List<ZoneLine> zones;

  bool get reported =>
      tier == EligibilityTier.reportedAllowed ||
      tier == EligibilityTier.reportedNotAllowed;
}

/// Days an administrator's check stays current, as in [eligibility].
const verificationDays = 180;

String formatSpotDate(DateTime value) =>
    value.toLocal().toString().substring(0, 10);

/// The display tier of [result], judged for [vehicle] at [spot]. Only a
/// community lot's own vehicle fields are tiered: roadside bays follow the
/// city rule, and official lots keep their source's wording. With the
/// [decision] the result came from, the tier and basis line read its
/// sources (§3.3, #91), and its notices and zones are listed; without one,
/// the spot's own source stands in.
EligibilityDisplay eligibilityDisplay(
  ParkingSpot spot,
  VehicleType vehicle,
  Eligibility result, {
  DateTime? now,
  ParkingDecision? decision,
}) {
  final at = now ?? DateTime.now();
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  final source =
      decision?.basis.firstOrNull ??
      sourceBasis(
        spot,
        vehicle,
        at,
        verified: explicit != null && recentlyVerified(spot, vehicle, at),
      );
  final checked =
      source.kind == BasisKind.official ||
      source.kind == BasisKind.adminVerified;
  // A zone's notice is part of the zone data, listed on the same terms.
  final notices = decision == null
      ? const <NoticeLine>[]
      : noticeLines(decision, at, zones: checked);
  // Zones are listed only from data that may decide: a rider's zones are
  // part of the same unchecked claim.
  final zones = decision == null || !checked
      ? const <ZoneLine>[]
      : zoneLines(decision, at);
  final sourceLine = _sourceLine(source);
  // The notice line already says it ended; the explanation does not repeat
  // it in other words.
  final repeated =
      notices.any((n) => n.text == result.reason) ||
      (result.reason == ruleExpiredReason && notices.any((n) => n.cityRule));
  String explanationOf(String text) => repeated ? '' : text;
  if (result.status != EligibilityStatus.unverified) {
    return EligibilityDisplay(
      tier: EligibilityTier.decided,
      label: _decidedLabel(result, decision),
      explanation: explanationOf(result.reason),
      basis: sourceLine,
      notices: notices,
      zones: zones,
    );
  }
  final lot = spot.spaceType == SpaceType.offStreet && !spot.isOfficial;
  final claim =
      source.kind == BasisKind.communityReport ||
      source.kind == BasisKind.adminLapsed;
  if (lot && explicit != null && claim) {
    final lapsed = source.kind == BasisKind.adminLapsed;
    final open = explicit;
    final explanation = spot.status == TrustStatus.confirmed && !spot.stale
        ? '此處確實有停車點，可停放車種未經確認，請以入口公告為準。'
        : '可停放車種未經確認，請以入口公告為準。';
    return EligibilityDisplay(
      tier: open
          ? EligibilityTier.reportedAllowed
          : EligibilityTier.reportedNotAllowed,
      // An expired check was an administrator's, not a rider's report.
      label: lapsed
          ? (open ? '曾確認可停' : '曾確認不可停')
          : (open ? '車友回報可停' : '車友回報不可停'),
      explanation: explanation,
      lapsed: lapsed,
      basis: lapsed
          ? '管理員確認，${formatSpotDate(source.date!)}，已超過 $verificationDays 天'
          : _reportBasis(spot),
      notices: notices,
      zones: zones,
    );
  }
  // Official or checked data that still leaves it open (zones, notices):
  // the source line stays, the reason says what is missing.
  return EligibilityDisplay(
    tier: spot.spaceType == SpaceType.offStreet && explicit == null
        ? EligibilityTier.noData
        : EligibilityTier.other,
    label: spot.isFacility ? '開放資訊待確認' : result.label,
    // Checked access left open by zones or notices keeps its own reason;
    // only unchecked access reads 「可停放車種未經確認」.
    explanation: explanationOf(
      checked ? result.reason : decisionExplanation(spot, result),
    ),
    basis: checked && (decision?.gaps.isNotEmpty ?? false) ? sourceLine : null,
    notices: notices,
    zones: zones,
  );
}

/// The headline: the result's label, naming the zones open to the vehicle
/// when only some of a lot's zones are, with conditions
/// (「有條件・機車區與汽車區可停」); a plain 可停 stays as it is.
String _decidedLabel(Eligibility result, ParkingDecision? decision) {
  final open = decision?.openZones ?? const [];
  if (open.isEmpty || result.status != EligibilityStatus.conditional) {
    return result.label;
  }
  return '有條件・${zoneNames(open)}可停';
}

String? _sourceLine(DecisionBasis source) => switch (source.kind) {
  BasisKind.official =>
    source.date == null
        ? '依政府公開資料'
        : '依政府公開資料，更新於 ${formatSpotDate(source.date!)}',
  BasisKind.adminVerified => '管理員確認，${formatSpotDate(source.date!)}',
  _ => null,
};

/// Whether a notice has not started on [day] (`YYYY-MM-DD`).
bool _notStarted(DecisionBasis b, String day) =>
    b.effectiveDate != null && b.effectiveDate!.compareTo(day) > 0;

/// The notices with dates behind [decision], each once: a zone's trial
/// (「試辦」), a bay's notice (「公告」), an ended city rule. A notice not in
/// force yet says when it starts. Zones' notices only when [zones].
List<NoticeLine> noticeLines(
  ParkingDecision decision,
  DateTime now, {
  bool zones = true,
}) {
  final day = taipeiDay(now);
  final lines = <NoticeLine>[];
  final seen = <String>{};
  for (final b in decision.basis) {
    final String text;
    var holds = true;
    var cityRule = false;
    switch (b.kind) {
      case BasisKind.notice when b.zone != null && !zones:
        continue;
      case BasisKind.notice when _notStarted(b, day):
        final what = b.zone == null ? '公告' : '${b.zone}試辦';
        text = '$what ${b.effectiveDate} 起生效，請看現場公告';
        holds = false;
      case BasisKind.notice when b.expiresOn != null:
        final what = b.zone == null ? '公告' : '${b.zone}試辦';
        text = b.expired
            ? '$what已於 ${b.expiresOn} 到期，請看現場公告'
            : '$what至 ${b.expiresOn}';
        holds = !b.expired;
      case BasisKind.cityRule when b.expired && b.rule?.expiresOn != null:
        text =
            '${b.rule!.city}的規則已於 ${formatSpotDate(b.rule!.expiresOn!)} 到期，請看現場公告';
        holds = false;
        cityRule = true;
      default:
        continue;
    }
    if (seen.add(text)) {
      lines.add(NoticeLine(text, expired: !holds, cityRule: cityRule));
    }
  }
  return lines;
}

/// Each zone of [decision] as listed under the banner; empty when no zone
/// says anything about access.
List<ZoneLine> zoneLines(ParkingDecision decision, DateTime now) {
  if (!decision.zones.any((z) => z.hasData)) return const [];
  return [
    for (final z in decision.zones)
      ZoneLine(
        name: z.name.trim().isEmpty ? '未命名分區' : z.name.trim(),
        status: z.status,
        restriction: z.restriction,
        label: Eligibility(
          z.status,
          z.reason,
          restriction: z.restriction,
        ).label,
        reason: _zoneReason(z),
      ),
  ];
}

/// [z]'s reason less the parts the notice lines say: an ended or not yet
/// started notice is the whole reason; a trial's end is one part.
String _zoneReason(ZoneDecision z) {
  if (z.gaps.contains(DecisionGap.noticeExpired)) return '';
  return z.reason
      .split('；')
      .where((part) => !part.startsWith('試辦至 '))
      .join('；');
}

/// [result]'s reason, except that a confirmed community lot says its
/// existence is checked and its access is not (§2.1 R1).
String decisionExplanation(ParkingSpot spot, Eligibility result) =>
    result.status == EligibilityStatus.unverified &&
        spot.isFacility &&
        !spot.isOfficial &&
        spot.status == TrustStatus.confirmed &&
        !spot.stale
    ? '此處確實有停車點；可停放車種未經確認，請以入口公告為準。'
    : result.reason;

/// A rider sets a lot's vehicle fields only when adding it (an owner's edit
/// keeps them), so the creation time dates the claim. `updated_at` moves
/// with every vote and status change, and `last_confirmed_at` dates the
/// spot's existence, never its access (§2.1 R1).
String _reportBasis(ParkingSpot spot) {
  final created = spot.createdAt;
  final imported = spot.contributorRole == 'import' || spot.source == 'import';
  if (created == null) return imported ? '匯入時間未提供' : '回報時間未提供';
  return '${imported ? '匯入於' : '回報於'} ${formatSpotDate(created)}';
}

/// When an administrator checked [vehicle]'s access, while that check is
/// current; null for an official spot, an unknown flag or no current check.
DateTime? currentVerification(
  ParkingSpot spot,
  VehicleType vehicle, {
  DateTime? now,
}) {
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  final at = spot.verifiedAt(vehicle);
  if (spot.isOfficial || explicit == null || at == null) return null;
  return (now ?? DateTime.now()).difference(at).inDays <= verificationDays
      ? at
      : null;
}

/// The 確認狀態 rows of the data section (#141, decisions 27 and 30): one
/// row per kind among DESIGN.md's twelve fields 1–9 that an administrator
/// confirmed, 「停放車種・管理員確認，2026-10-25」. Only 停放車種 is
/// recorded so far; the other kinds wait for the verification plan's P2,
/// so they are not listed rather than shown with made-up states. Empty
/// when nothing is confirmed.
List<String> confirmationLines(ParkingSpot spot, {DateTime? now}) {
  if (spot.isOfficial) return const [];
  final checked = [
    for (final vehicle in VehicleType.values)
      if ((
            vehicle == VehicleType.heavy
                ? spot.heavyAllowed
                : spot.scooterAllowed,
            spot.verifiedAt(vehicle),
          )
          case (_?, final at?))
        (vehicle, at),
  ];
  String line(String kind, DateTime at, VehicleType vehicle) =>
      '$kind・管理員確認，${formatSpotDate(at)}'
      '${currentVerification(spot, vehicle, now: now) == null ? '，已超過 $verificationDays 天' : ''}';
  bool lapsed(VehicleType v) => currentVerification(spot, v, now: now) == null;
  if (checked.length == 2 &&
      formatSpotDate(checked[0].$2) == formatSpotDate(checked[1].$2) &&
      lapsed(checked[0].$1) == lapsed(checked[1].$1)) {
    return [line('停放車種', checked[0].$2, checked[0].$1)];
  }
  return [
    for (final (vehicle, at) in checked)
      line('停放車種（${vehicle.label}）', at, vehicle),
  ];
}

/// The short status beside a spot in a list: a rider's claim keeps its
/// wording, everything else the result's own label.
String eligibilityListLabel(
  ParkingSpot spot,
  VehicleType vehicle,
  Eligibility result, {
  DateTime? now,
}) {
  final display = eligibilityDisplay(spot, vehicle, result, now: now);
  return display.reported ? display.label : result.label;
}
