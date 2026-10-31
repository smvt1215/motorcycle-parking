/// The bay kinds riders pick from (#188, design canvas Ver.143 S4, P1): the
/// seven painted kinds of [BayKind], in its order, plus the lot. The map
/// filter, the new spot form, the suggestion form and the admin spot form
/// share one list. Charge, time limits and the other added conditions are
/// facets of their own, not kinds: a 一般機車格 is stored as a toll or free
/// bay (or a 限時 one), as before. Pure Dart.
library;

import 'parking.dart';
import 'parking_condition.dart';
import 'zone_entries.dart';

enum SpaceKind {
  motorcycle(BayKind.motorcycle),
  scooterHeavy(BayKind.scooterHeavy),
  heavy(BayKind.heavy),
  carMotorcycle(BayKind.carMotorcycle),
  car(BayKind.car),
  disabled(BayKind.disabled),
  ev(BayKind.ev),

  /// 停車場: its zones carry the bays.
  offStreet(null);

  const SpaceKind(this.bay);

  /// The painted kind; null for [offStreet].
  final BayKind? bay;

  String get label => switch (this) {
    motorcycle => '一般機車格',
    scooterHeavy => '普大共用格',
    heavy => '重機專用格',
    carMotorcycle => '汽機車共用格',
    car => '汽車格',
    disabled => '身障格',
    ev => '充電格',
    offStreet => '停車場',
  };

  /// One sentence under the name (P1).
  String get detail => switch (this) {
    motorcycle => '一般白線機車格',
    scooterHeavy => '普通機車與大型重機都能停',
    heavy => '標示大型重機專用',
    carMotorcycle => '依牌面時段汽車與機車輪替',
    car => '一般汽車格',
    disabled => '限身障特製車輛，持識別證',
    ev => '充換電專用',
    offStreet => '路外停車場',
  };

  /// The space type whose condition the kind starts from (§1.3); a
  /// 一般機車格's or 普大共用格's charge comes from the form.
  SpaceType get baseType => switch (this) {
    motorcycle || scooterHeavy => SpaceType.paidMotorcycle,
    heavy => SpaceType.heavyOnly,
    carMotorcycle => SpaceType.flexShared,
    car => SpaceType.car,
    disabled => SpaceType.disabledMotorcycle,
    ev => SpaceType.evMotorcycle,
    offStreet => SpaceType.offStreet,
  };

  /// The ground marking the list shows (decision 63): the plain motorcycle
  /// boxes for 一般機車格 whether toll or free, the app's markings for the
  /// rest; 普大共用格 draws the plain boxes with the heavy-bike helmet.
  SpaceType get markingType => switch (this) {
    motorcycle || scooterHeavy => SpaceType.freeMotorcycle,
    _ => baseType,
  };

  /// Whether a stored bay of this kind is toll or free by its condition
  /// (its legacy space type depends on it), so the form asks which.
  bool get asksCharge => this == motorcycle || this == scooterHeavy;

  /// The kind of [bay].
  static SpaceKind ofBay(BayKind bay) => values.firstWhere((k) => k.bay == bay);

  /// The kind a stored spot reads as: a lot is [offStreet]; a street bay
  /// reads by its condition, or the one its space type stands for.
  static SpaceKind of(SpaceType type, ParkingCondition? condition) {
    if (type == SpaceType.offStreet) return offStreet;
    final bay =
        bayKindOf(condition) ??
        bayKindOf(conditionOf(type)) ??
        BayKind.motorcycle;
    return ofBay(bay);
  }
}
