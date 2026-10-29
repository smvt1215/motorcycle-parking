/// The bay kinds riders pick from (decision 62, C6 canvas SpaceTaxonomy):
/// six painted kinds and the lot. Each painted kind then asks 收費嗎 and the
/// added conditions (限時, 時段性禁停); 共用格 also asks who shares it. 限時
/// is an added condition, no longer a kind: a 一般機車格 with a time limit is
/// still stored as `timedMotorcycle` (§1.3). The map filter, the new spot
/// form, the suggestion form and the admin forms share one list. Pure Dart.
library;

import 'parking.dart';
import 'parking_condition.dart';

/// The added conditions every painted kind may carry (decision 62, C6
/// canvas SpaceTaxonomy 「加註條件（可複選）」).
const addedLimits = {LimitKind.timeLimit, LimitKind.noParking};

enum SpaceKind {
  /// 一般機車格: a white motorcycle bay, toll or free.
  motorcycle,
  heavyOnly,

  /// 充電格 (was 電動機車格).
  evMotorcycle,
  disabledMotorcycle,

  /// 共用格: 普通＆大型重機 (`share: scooter_heavy`) or 汽車＆機車
  /// (`share: car_motorcycle`), see [ShareKind].
  shared,
  car,
  offStreet;

  String get label => switch (this) {
    motorcycle => '一般機車格',
    heavyOnly => '大型重機專用格',
    evMotorcycle => '充電格',
    disabledMotorcycle => '身障格',
    shared => '共用格',
    car => '一般汽車格',
    offStreet => '停車場',
  };

  /// One sentence under the name, as the ground and its signs show it.
  String get detail => switch (this) {
    motorcycle => '白線機車格，收費或免費',
    heavyOnly => '標示大型重機專用的格位',
    evMotorcycle => '限電動機車停放或充換電',
    disabledMotorcycle => '限經監理站檢驗合格的身障特製機車，並持識別證或專用牌照',
    shared => '普通與大型重機共用，或汽機車依時段共用',
    car => '依規定可停放機車的汽車格',
    offStreet => '立體、平面或地下停車場，逐區填格位',
  };

  /// The painted kinds; [offStreet] is the lot.
  static const painted = [
    motorcycle,
    heavyOnly,
    evMotorcycle,
    disabledMotorcycle,
    shared,
    car,
  ];

  /// The space type the kind's base condition comes from (§1.3): its
  /// limits and bay. A 一般機車格's charge, and 共用格's share, come from the
  /// form.
  SpaceType get baseType => switch (this) {
    motorcycle => SpaceType.paidMotorcycle,
    heavyOnly => SpaceType.heavyOnly,
    evMotorcycle => SpaceType.evMotorcycle,
    disabledMotorcycle => SpaceType.disabledMotorcycle,
    shared => SpaceType.flexShared,
    car => SpaceType.car,
    offStreet => SpaceType.offStreet,
  };

  /// The ground marking the kind shows (decision 63): the app's markings,
  /// the plain motorcycle boxes for 一般機車格 whether toll or free, and
  /// 汽機共用's for 共用格 unless the form says 普大共用.
  SpaceType get markingType => switch (this) {
    motorcycle => SpaceType.freeMotorcycle,
    _ => baseType,
  };

  /// The kind a stored spot reads as: by its condition (or the one its
  /// space type stands for). A reserved bay (身障, 充電) stays that kind
  /// whatever else it says; a shared one is 共用格.
  static SpaceKind of(SpaceType type, ParkingCondition? condition) {
    if (type == SpaceType.offStreet) return offStreet;
    final c = condition ?? conditionOf(type);
    if (c == null) return motorcycle;
    if (c.hasLimit(LimitKind.specialVehicle)) return disabledMotorcycle;
    if (c.hasLimit(LimitKind.evOnly)) return evMotorcycle;
    if (c.share != null) return shared;
    return switch (c.bay) {
      Bay.heavy => heavyOnly,
      Bay.car => car,
      _ => motorcycle,
    };
  }

  /// Which 共用格 a stored spot is; null when it is not one.
  static ShareKind? shareOf(SpaceType type, ParkingCondition? condition) =>
      type == SpaceType.offStreet
      ? null
      : (condition ?? conditionOf(type))?.share;
}

/// [kind] as a change list or a summary names it: 共用格 with who shares
/// it, e.g. 共用格（普通＆大型重機）.
String kindText(SpaceKind kind, ShareKind? share) =>
    kind == SpaceKind.shared && share != null
    ? '${kind.label}（${share.label}）'
    : kind.label;

/// What 共用格 asks next: 誰共用？
extension ShareKindLabel on ShareKind {
  String get label => switch (this) {
    ShareKind.scooterHeavy => '普通＆大型重機',
    ShareKind.carMotorcycle => '汽車＆機車',
  };
}
