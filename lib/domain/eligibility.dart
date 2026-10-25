import '../models/parking.dart';

/// Ordered from most to least parkable; the map ranks search results by it.
/// - [allowed]: law or verified data opens this space to the vehicle.
/// - [conditional]: law opens it with limits (marked bays, how to park),
///   so the posted signs decide.
/// - [unverified]: the data cannot tell (unchecked or stale community
///   reports, unlabelled lots, no rule in force here).
/// - [notAllowed]: law or verified data closes it to the vehicle.
enum EligibilityStatus { allowed, conditional, unverified, notAllowed }

class Eligibility {
  const Eligibility(this.status, this.reason, {this.restriction});
  final EligibilityStatus status;
  final String reason;

  /// The kind of limit behind a [EligibilityStatus.conditional] result.
  final RuleRestriction? restriction;
  String get label => switch (status) {
    EligibilityStatus.allowed => '可停',
    EligibilityStatus.conditional => switch (restriction) {
      final kind? => '有條件・${kind.label}',
      null => '有條件',
    },
    EligibilityStatus.unverified => '待確認',
    EligibilityStatus.notAllowed => '不可停',
  };
}

Eligibility eligibility(
  ParkingSpot spot,
  VehicleType vehicle,
  CityRule? rule, {
  DateTime? now,
}) {
  final result = _judge(spot, vehicle, rule, now: now);
  // A timed bay is a motorcycle bay with a clock: where the bay is open, the
  // posted hours still limit it.
  if (spot.spaceType == SpaceType.timedMotorcycle &&
      result.status == EligibilityStatus.allowed) {
    return const Eligibility(
      EligibilityStatus.conditional,
      '限時停車：請依現場牌面的時段與時限停放，超時須移車',
      restriction: RuleRestriction.timeLimited,
    );
  }
  return result;
}

/// The kind a city rule judges [type] as: rules list the original kinds,
/// and a timed bay follows the paid bay it is painted like.
SpaceType ruleSpaceType(SpaceType type) => switch (type) {
  SpaceType.timedMotorcycle => SpaceType.paidMotorcycle,
  final type => type,
};

Eligibility _judge(
  ParkingSpot spot,
  VehicleType vehicle,
  CityRule? rule, {
  DateTime? now,
}) {
  const noRule = Eligibility(
    EligibilityStatus.unverified,
    '此地區尚無已生效的停車規則資料，請以現場標誌標線為準',
  );
  final explicit = vehicle == VehicleType.heavy
      ? spot.heavyAllowed
      : spot.scooterAllowed;
  // Only trusted data may deny outright; a pending, stale or undated
  // community claim falls through to the rules below, which keep it
  // unverified. Confirming a community spot shows the bay exists, not that
  // its reported vehicle fields are right; an administrator setting them
  // does, for as long as official data would stay fresh.
  final verified = explicit != null && _recentlyVerified(spot, vehicle, now);
  final trusted = spot.isOfficial || verified || _recentlyConfirmed(spot, now);
  if (explicit == false && trusted) {
    return const Eligibility(EligibilityStatus.notAllowed, '此停車點標示不開放目前車種');
  }
  // Bays reserved by law or by vehicle, whatever the city rule says.
  switch (spot.spaceType) {
    case SpaceType.disabledMotorcycle ||
            SpaceType.evMotorcycle ||
            SpaceType.flexShared
        when !trusted:
      return const Eligibility(
        EligibilityStatus.unverified,
        '社群資訊尚未查核或可能過時，請確認現場',
      );
    // Open to permit holders, who may be the rider using the app.
    case SpaceType.disabledMotorcycle:
      return const Eligibility(
        EligibilityStatus.conditional,
        '身心障礙者專用，須持有效停車識別證明才可停放',
      );
    case SpaceType.evMotorcycle:
      return const Eligibility(
        EligibilityStatus.conditional,
        '限電動機車停放或充換電，燃油機車不可停',
        restriction: RuleRestriction.evOnly,
      );
    case SpaceType.flexShared:
      return const Eligibility(
        EligibilityStatus.conditional,
        '汽機車依時段輪替使用，請看現場牌面的機車開放時段',
        restriction: RuleRestriction.timeLimited,
      );
    default:
  }
  final type = ruleSpaceType(spot.spaceType);
  if (spot.spaceType == SpaceType.heavyOnly && vehicle == VehicleType.scooter) {
    return const Eligibility(EligibilityStatus.notAllowed, '大型重機專用格');
  }
  // Car bays are painted for small cars and heavy bikes (標誌標線號誌設置規則
  // §190); an ordinary scooter there is the wrong vehicle class unless a
  // city rule opens them (道路交通安全規則 §112, last paragraph).
  if (spot.spaceType == SpaceType.car &&
      vehicle == VehicleType.scooter &&
      !(rule?.allowedSpaceTypes.contains(SpaceType.car) ?? false) &&
      !(rule?.conditionalSpaceTypes.contains(SpaceType.car) ?? false)) {
    return const Eligibility(
      EligibilityStatus.notAllowed,
      '汽車格為小型車及大型重機停放線，普通機車停放屬車種不依規定',
    );
  }
  // Community claims never override legal rules, and only official or
  // admin-verified data may open a lot: confirmed existence never verifies a
  // community "可停".
  if (spot.spaceType == SpaceType.offStreet) {
    if (explicit == true && spot.isOfficial && !spot.stale) {
      return const Eligibility(EligibilityStatus.allowed, '場站資料標示可停，請確認現場公告');
    }
    if (explicit == true && verified) {
      return const Eligibility(
        EligibilityStatus.allowed,
        '管理員已核驗開放目前車種，請確認現場公告',
      );
    }
    return const Eligibility(
      EligibilityStatus.unverified,
      '場站資料未確認開放目前車種，請以入口公告為準',
    );
  }
  if (rule == null || rule.effectiveDate.isAfter(now ?? DateTime.now())) {
    return noRule;
  }
  if (rule.vehicle != vehicle ||
      (rule.city != '全國' && rule.city != spot.city)) {
    return noRule;
  }
  // Open by whole district: parkable inside, closed outside, unknown when
  // the spot's district is.
  final openIn = rule.districtSpaceTypes[type];
  if (openIn != null) {
    if (spot.district.isEmpty) {
      return Eligibility(
        EligibilityStatus.unverified,
        '僅${openIn.join('、')}開放，無法判斷此停車點所在行政區',
      );
    }
    if (!openIn.contains(spot.district)) {
      return Eligibility(
        EligibilityStatus.notAllowed,
        '僅${openIn.join('、')}開放，${spot.district}不開放',
      );
    }
  }
  final limited = rule.conditionalSpaceTypes.contains(type);
  // A rule not verified yet opens nothing for certain.
  if (limited && rule.restriction == RuleRestriction.unverified) {
    return Eligibility(EligibilityStatus.unverified, rule.exceptions);
  }
  if (!limited && openIn == null && !rule.allowedSpaceTypes.contains(type)) {
    return Eligibility(EligibilityStatus.notAllowed, rule.exceptions);
  }
  if (rule.districts.isNotEmpty && !rule.districts.contains(spot.district)) {
    return const Eligibility(
      EligibilityStatus.unverified,
      '不在規則公告的開放行政區內，請以現場標誌標線為準',
    );
  }
  if (!trusted) {
    return const Eligibility(
      EligibilityStatus.unverified,
      '社群資訊尚未查核或可能過時，請確認現場',
    );
  }
  // Known limits only once the spot itself is trusted.
  if (limited) {
    return Eligibility(
      EligibilityStatus.conditional,
      rule.exceptions,
      restriction: rule.restriction,
    );
  }
  return Eligibility(
    EligibilityStatus.allowed,
    rule.canUseTwoSpaces ? '可斜停兩格，請依公告停放' : '依地方規則開放，請勿超出格線',
  );
}

/// An administrator set [vehicle]'s access on this spot within the last 180
/// days, the same window a ground confirmation stays fresh for.
bool _recentlyVerified(ParkingSpot spot, VehicleType vehicle, DateTime? now) {
  final at = spot.verifiedAt(vehicle);
  return at != null && (now ?? DateTime.now()).difference(at).inDays <= 180;
}

/// A community spot confirmed on the ground within the last 180 days. With
/// no confirmation time its freshness is unknown, never assumed.
bool _recentlyConfirmed(ParkingSpot spot, DateTime? now) {
  final at = spot.lastConfirmedAt;
  return spot.status == TrustStatus.confirmed &&
      at != null &&
      (now ?? DateTime.now()).difference(at).inDays <= 180;
}
