import '../models/parking.dart';

enum EligibilityStatus { allowed, conditional, notAllowed }

class Eligibility {
  const Eligibility(this.status, this.reason);
  final EligibilityStatus status;
  final String reason;
  String get label => switch (status) {
    EligibilityStatus.allowed => '可停',
    EligibilityStatus.conditional => '有條件',
    EligibilityStatus.notAllowed => '不可停',
  };
}

Eligibility eligibility(
  ParkingSpot spot,
  VehicleType vehicle,
  CityRule? rule, {
  DateTime? now,
}) {
  const conditional = Eligibility(
    EligibilityStatus.conditional,
    '請以現場標誌標線及場站規定為準',
  );
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  if (explicit == false) {
    return const Eligibility(EligibilityStatus.notAllowed, '此點位標示不開放目前車種');
  }
  if (spot.spaceType == SpaceType.heavyOnly && vehicle == VehicleType.scooter) {
    return const Eligibility(EligibilityStatus.notAllowed, '大型重機專用格');
  }
  if (spot.spaceType == SpaceType.car && vehicle == VehicleType.scooter) {
    return conditional;
  }
  // Community claims never override legal rules; pending/stale claims remain conditional.
  if (spot.spaceType == SpaceType.offStreet) {
    if (explicit == true &&
        (spot.source == 'tdx' || spot.status == TrustStatus.confirmed) &&
        !spot.stale) {
      return const Eligibility(EligibilityStatus.allowed, '場站資料標示可停，請確認現場公告');
    }
    return conditional;
  }
  if (rule == null || rule.effectiveDate.isAfter(now ?? DateTime.now())) {
    return conditional;
  }
  if (rule.vehicle != vehicle ||
      (rule.city != '全國' && rule.city != spot.city)) {
    return conditional;
  }
  if (rule.conditionalSpaceTypes.contains(spot.spaceType)) {
    return Eligibility(EligibilityStatus.conditional, rule.exceptions);
  }
  if (!rule.allowedSpaceTypes.contains(spot.spaceType)) {
    return Eligibility(EligibilityStatus.notAllowed, rule.exceptions);
  }
  if (rule.districts.isNotEmpty && !rule.districts.contains(spot.district)) {
    return conditional;
  }
  if (spot.source != 'tdx' &&
      spot.source != 'official' &&
      (spot.status != TrustStatus.confirmed || spot.stale)) {
    return const Eligibility(
      EligibilityStatus.conditional,
      '社群資訊待確認或可能過時，請確認現場',
    );
  }
  return Eligibility(
    EligibilityStatus.allowed,
    rule.canUseTwoSpaces ? '可斜停兩格，請依公告停放' : '依地方規則開放，請勿超出格線',
  );
}
