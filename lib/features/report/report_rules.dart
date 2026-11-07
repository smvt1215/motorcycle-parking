/// Who a new bay starts with: the markings first, then the city's rule.
library;

import '../../domain/eligibility.dart';
import '../../models/parking.dart';
import '../../models/space_kind.dart';

/// What a bay's markings say about each vehicle before the reporter looks
/// further: motorcycle bays take scooters, heavy-only bays take heavy bikes
/// only, and car bays are not for scooters (道路交通安全規則 §112). Anything
/// the markings cannot settle stays unconfirmed.
({bool? scooter, bool? heavy}) markedEligibility(SpaceType type) =>
    switch (type) {
      SpaceType.paidMotorcycle ||
      SpaceType.freeMotorcycle ||
      SpaceType.timedMotorcycle => (scooter: true, heavy: null),
      SpaceType.heavyOnly => (scooter: false, heavy: true),
      SpaceType.car => (scooter: false, heavy: null),
      _ => (scooter: null, heavy: null),
    };

/// What the city's rule decides for a bay of [type] before anything on the
/// ground: open is 可停, closed is 不可停, and anything conditional or
/// unknown stays unconfirmed.
({bool? scooter, bool? heavy}) ruledEligibility(
  List<CityRule> rules,
  SpaceType type,
  String? city,
) {
  bool? decide(VehicleType vehicle) {
    if (city == null) return null;
    final rule =
        rules
            .where((r) => r.vehicle == vehicle && r.city == city)
            .firstOrNull ??
        rules.where((r) => r.vehicle == vehicle && r.city == '全國').firstOrNull;
    // Judged as data with no claims of its own, so only the law speaks.
    final draft = ParkingSpot(
      id: 'draft',
      name: '',
      lat: 0,
      lng: 0,
      city: city,
      spaceType: type,
      source: 'official',
    );
    return switch (eligibility(draft, vehicle, rule).status) {
      EligibilityStatus.allowed => true,
      EligibilityStatus.notAllowed => false,
      _ => null,
    };
  }

  return (
    scooter: decide(VehicleType.scooter),
    heavy: decide(VehicleType.heavy),
  );
}

/// The vehicles a new report starts with: what the markings say, and the
/// city's rule where the markings cannot tell.
({bool? scooter, bool? heavy}) defaultEligibility(
  List<CityRule> rules,
  SpaceType type,
  String? city,
) {
  final marked = markedEligibility(type);
  final ruled = ruledEligibility(rules, type, city);
  return (
    scooter: marked.scooter ?? ruled.scooter,
    heavy: marked.heavy ?? ruled.heavy,
  );
}

/// What a new bay of [kind] starts with: [defaultEligibility], and a
/// 普大共用格 is marked for heavy bikes too (decision 60).
({bool? scooter, bool? heavy}) bayDefaults(
  List<CityRule> rules,
  SpaceKind kind,
  String? city,
) {
  final d = defaultEligibility(rules, kind.baseType, city);
  return kind == SpaceKind.scooterHeavy ? (scooter: d.scooter, heavy: true) : d;
}
