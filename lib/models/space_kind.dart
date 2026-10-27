/// The bay kinds riders pick from (C6 canvas AppPatterns, pattern 1;
/// decision 57): the legacy space types plus 普大共用機車格, a motorcycle
/// bay posted for both classes, grouped by use. The map filter, the new
/// spot form and the suggestion form share one list. Pure Dart.
library;

import 'parking.dart';
import 'parking_condition.dart';

/// The four groups the list folds into.
enum SpaceKindGroup {
  motorcycle('一般機車格', '收費、免費、普大共用'),
  reserved('專用格', '重機、電動、身障'),
  timedOrShared('限時或共用', '限時、汽機共用'),
  carOrLot('汽車格與停車場', '汽車格、停車場');

  const SpaceKindGroup(this.label, this.hint);
  final String label;

  /// What the group holds, beside its name while it is folded.
  final String hint;

  List<SpaceKind> get kinds => [
    for (final k in SpaceKind.values)
      if (k.group == this) k,
  ];
}

enum SpaceKind {
  paidMotorcycle(SpaceKindGroup.motorcycle, SpaceType.paidMotorcycle),
  freeMotorcycle(SpaceKindGroup.motorcycle, SpaceType.freeMotorcycle),

  /// 普大共用機車格: not time limited, posted for 普通 and 大型重機 alike
  /// (condition `share: scooter_heavy`); stored as a toll or free bay.
  sharedMotorcycle(SpaceKindGroup.motorcycle, null),
  heavyOnly(SpaceKindGroup.reserved, SpaceType.heavyOnly),
  evMotorcycle(SpaceKindGroup.reserved, SpaceType.evMotorcycle),
  disabledMotorcycle(SpaceKindGroup.reserved, SpaceType.disabledMotorcycle),
  timedMotorcycle(SpaceKindGroup.timedOrShared, SpaceType.timedMotorcycle),
  flexShared(SpaceKindGroup.timedOrShared, SpaceType.flexShared),
  car(SpaceKindGroup.carOrLot, SpaceType.car),
  offStreet(SpaceKindGroup.carOrLot, SpaceType.offStreet);

  const SpaceKind(this.group, this.type);
  final SpaceKindGroup group;

  /// The legacy space type this kind is; null for [sharedMotorcycle], whose
  /// charge decides it.
  final SpaceType? type;

  String get label => type?.label ?? '普大共用機車格';

  /// One sentence under the name, as the ground and its signs show it.
  String get detail => switch (this) {
    paidMotorcycle => '路邊白線機車格，依公告時段收費',
    freeMotorcycle => '不收費的路邊或巷弄機車格',
    sharedMotorcycle => '非限時，標示普通機車與大型重機都能停',
    heavyOnly => '標示大型重機專用的格位',
    evMotorcycle => '限電動機車停放或充換電',
    disabledMotorcycle => '限經監理站檢驗合格的身障特製機車，並持識別證或專用牌照',
    timedMotorcycle => '黃色內框機車格，依牌面時段限時停放',
    flexShared => '汽車與機車依時段輪替使用的格位',
    car => '依規定可停放機車的汽車格',
    offStreet => '停車場內的機車或重機區',
  };

  /// The kind a stored spot reads as: its space type, except a toll or free
  /// motorcycle bay posted for both classes, which is [sharedMotorcycle].
  static SpaceKind of(SpaceType type, ParkingCondition? condition) {
    final c = condition ?? conditionOf(type);
    if ((type == SpaceType.paidMotorcycle ||
            type == SpaceType.freeMotorcycle) &&
        c?.share == ShareKind.scooterHeavy) {
      return sharedMotorcycle;
    }
    return values.firstWhere((k) => k.type == type);
  }
}
