import '../models/parking.dart';
import 'eligibility.dart';

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
class EligibilityDisplay {
  const EligibilityDisplay({
    required this.tier,
    required this.label,
    required this.explanation,
    this.basis,
    this.lapsed = false,
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
/// city rule, and official lots keep their source's wording.
EligibilityDisplay eligibilityDisplay(
  ParkingSpot spot,
  VehicleType vehicle,
  Eligibility result, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  if (result.status != EligibilityStatus.unverified) {
    return EligibilityDisplay(
      tier: EligibilityTier.decided,
      label: result.label,
      explanation: result.reason,
      basis: _decidedBasis(spot, vehicle, at),
    );
  }
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  final lot = spot.spaceType == SpaceType.offStreet && !spot.isOfficial;
  if (lot && explicit != null) {
    // [eligibility] trusts a current check, so only an expired one is left.
    final checked = currentVerification(spot, vehicle, now: at) == null
        ? spot.verifiedAt(vehicle)
        : null;
    final open = explicit;
    final explanation = spot.status == TrustStatus.confirmed && !spot.stale
        ? '此處確實有停車點，可停放車種未經確認，請以入口公告為準。'
        : '可停放車種未經確認，請以入口公告為準。';
    return EligibilityDisplay(
      tier: open
          ? EligibilityTier.reportedAllowed
          : EligibilityTier.reportedNotAllowed,
      // An expired check was an administrator's, not a rider's report.
      label: checked != null
          ? (open ? '曾確認可停' : '曾確認不可停')
          : (open ? '車友回報可停' : '車友回報不可停'),
      explanation: explanation,
      lapsed: checked != null,
      basis: checked != null
          ? '管理員確認，${formatSpotDate(checked)}，已超過 $verificationDays 天'
          : _reportBasis(spot),
    );
  }
  return EligibilityDisplay(
    tier: spot.spaceType == SpaceType.offStreet && explicit == null
        ? EligibilityTier.noData
        : EligibilityTier.other,
    label: spot.isFacility ? '開放資訊待確認' : result.label,
    explanation: decisionExplanation(spot, result),
  );
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

String? _decidedBasis(ParkingSpot spot, VehicleType vehicle, DateTime now) {
  if (spot.isOfficial) {
    final updated = spot.updatedAt;
    return updated == null
        ? '依政府公開資料'
        : '依政府公開資料，更新於 ${formatSpotDate(updated)}';
  }
  final checked = currentVerification(spot, vehicle, now: now);
  return checked == null ? null : '管理員確認，${formatSpotDate(checked)}';
}

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

/// One line per vehicle an administrator has checked on a community spot,
/// e.g. 「普通機車可停：管理員確認，2026-10-25」; empty when none has.
List<String> verifiedFieldLines(ParkingSpot spot, {DateTime? now}) => [
  if (!spot.isOfficial)
    for (final vehicle in VehicleType.values)
      if ((
            vehicle == VehicleType.heavy
                ? spot.heavyAllowed
                : spot.scooterAllowed,
            spot.verifiedAt(vehicle),
          )
          case (final open?, final at?))
        '${vehicle.label}${open ? '可停' : '不可停'}：管理員確認，${formatSpotDate(at)}'
            '${currentVerification(spot, vehicle, now: now) == null ? '，已超過 $verificationDays 天' : ''}',
];

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
