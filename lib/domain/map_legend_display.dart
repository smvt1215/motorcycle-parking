/// What the map's markers, corner badges and pills mean, in the words of
/// the design canvas (Ver.154 A0 地圖圖標, P3 地圖怎麼看). Pure Dart: the
/// widgets draw the shapes, this file holds every label they show.
library;

import '../models/parking.dart';
import '../models/zone_entries.dart';
import 'eligibility.dart';

/// A spot's corner badge: the bay kind beyond whether it is parkable.
/// Dedicated bays wear a white circle, shared bays a square (A0). One per
/// bay kind but the plain 一般機車格, which wears none ([bayKinds]), and
/// one for a rule rather than a kind of bay ([generalHeavy]). The pills
/// carry the same badge before a count of those bays (#492).
enum SpaceBadge {
  /// 重機專用格: white circle, heavy bike.
  heavyOnly,

  /// 普大共用格: white and yellow square, heavy bike.
  shared,

  /// 汽車格: white circle, car.
  car,

  /// 汽機車共用格: white and light blue square, car.
  carMotorcycle,

  /// 身障格: white circle, wheelchair.
  disabled,

  /// 充電格: white circle, charging station.
  ev,

  /// 一般機車格可停 (#493, G1): plain motorcycle bays of a lot that state
  /// heavy bikes may park. An ink disc, white ring, white scooter: the one
  /// dark badge. A rule, not a bay painted on the ground, so it shows for
  /// heavy bikes only; a scooter rider sees plain 一般機車格.
  generalHeavy;

  /// The six bay kinds' badges, the same for every vehicle.
  static const bayKinds = [heavyOnly, shared, car, carMotorcycle, disabled, ev];

  /// The badge of [kind]; null for the plain 一般機車格.
  static SpaceBadge? ofBay(BayKind kind) => switch (kind) {
    BayKind.motorcycle => null,
    BayKind.scooterHeavy => shared,
    BayKind.heavy => heavyOnly,
    BayKind.carMotorcycle => carMotorcycle,
    BayKind.car => car,
    BayKind.disabled => disabled,
    BayKind.ev => ev,
  };

  /// A square: the bay is shared between vehicle classes.
  bool get square => this == shared || this == carMotorcycle;

  /// The bay kind's name (the seven kinds' official names).
  String get label => switch (this) {
    heavyOnly => '重機專用格',
    shared => '普大共用格',
    car => '汽車格',
    carMotorcycle => '汽機車共用格',
    disabled => '身障格',
    ev => '充電格',
    generalHeavy => '一般機車格可停',
  };

  /// How the badge looks, under its name in the legend.
  String get look => switch (this) {
    heavyOnly => '白圓・重機',
    shared => '白黃雙色方・重機',
    car => '白圓・汽車',
    carMotorcycle => '白淺藍雙色方・汽車',
    disabled => '白圓・身障',
    ev => '白圓・充電',
    generalHeavy => '深色圓・機車',
  };
}

const legendTitle = '地圖怎麼看';

String legendIntro(VehicleType vehicle) =>
    '標記依目前車種「${vehicle.label}」判斷，切換車種會即時更新。';

const legendMarkersHeading = '停車點標記';

/// The four marker shapes: title and what the shape says.
String markerTitle(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => '可停',
  EligibilityStatus.conditional => '有條件',
  EligibilityStatus.unverified => '待確認、不確定',
  EligibilityStatus.notAllowed => '不能停',
};

String markerDetail(EligibilityStatus status, VehicleType vehicle) =>
    switch (status) {
      EligibilityStatus.allowed => '綠色圓形：法規或已查核資料確認${vehicle.label}可停放',
      EligibilityStatus.conditional => '琥珀圓角方形：法規開放但另有限制，詳見停車點',
      EligibilityStatus.unverified =>
        '灰色圓角方形：社群回報未查核或過時、尚無生效規則；'
            '官方與營運業者都沒寫時，詳情寫「不確定／官方未標示」',
      EligibilityStatus.notAllowed => '紅色方形：法規或已查核資料不開放${vehicle.label}停放',
    };

const legendConditionsHeading = '有條件的圖示';

/// The conditional marker's icons, by the limit behind it; null is any
/// other limit.
String conditionLabel(RuleRestriction? restriction) => switch (restriction) {
  RuleRestriction.timeLimited => '限時段',
  RuleRestriction.signage => '依現場標示',
  RuleRestriction.evOnly => '電動車限定',
  _ => '其他條件',
};

const legendConditionOrder = <RuleRestriction?>[
  RuleRestriction.timeLimited,
  RuleRestriction.signage,
  RuleRestriction.evOnly,
  null,
];

const legendBadgesHeading = '標記右下角的小圖示';

/// Under the badges (design #492 v3): the ink circle is listed and
/// explained for heavy bikes only.
String legendBadgesNote(VehicleType vehicle) => vehicle == VehicleType.heavy
    ? '說的是這裡是什麼格位；能不能停看標記本身。白底圓形＝只給一種車，雙色方形＝幾種車共用，'
          '深色圓形＝一般機車格、重機也能停。深色圓形只在大型重機模式出現，其他小圖示切換車種不會變。'
    : '說的是這裡是什麼格位，切換車種不會變；能不能停看標記本身。白底圓形＝只給一種車，'
          '雙色方形＝幾種車共用。一般機車格不掛小圖示。';

/// The ink circle's own row under the six bay kinds, heavy bikes only.
const legendGeneralHeavyBadge = ('一般機車格可停', '這裡的一般機車格明確開放大型重機停。其他一般機車格不掛小圖示');

const legendCapsulesHeading = '標記上方的數字';

/// Under the pills: what the badge before a number means, or, for
/// scooters, that heavy bikes may see one.
String legendCapsulesNote(VehicleType vehicle) => vehicle == VehicleType.heavy
    ? '數字前的小圖示，和標記右下角的是同一枚：表示數字算的是那種格位。沒有小圖示，就是重機自己的格位。'
    : '切到大型重機時，數字前可能多一枚小圖示，說明數字算的是哪種格位。';

/// The pills, by what the legend calls them: name and meaning.
(String, String) capsuleLegendLive(VehicleType vehicle) =>
    vehicle == VehicleType.heavy
    ? ('重機格位的剩餘', '官方即時數字，算的是重機能停的機車格')
    : ('普通機車格的剩餘', '官方即時數字');
const capsuleLegendShared = ('普大共用格的剩餘', '普通機車也停這些格，位子可能先被機車停走');
const capsuleLegendGeneralHeavy = (
  '一般機車格可停',
  '算的是一般機車格的剩餘。這裡的一般機車格也開放重機停，普通機車同樣停這些格，位子可能先被停走',
);
const capsuleLegendCar = ('汽車格的剩餘', '這裡重機現在可以停汽車格');
(String, String) capsuleLegendDelayed(VehicleType vehicle) => (
  '有時鐘：資料晚到',
  vehicle == VehicleType.heavy ? '數字可能已經變了；時鐘會和小圖示一起出現' : '數字可能已經變了',
);
const capsuleLegendFull = ('已滿', '官方資料目前沒有空位');
const capsuleLegendSuspended = ('暫停營運', '停車場暫時不開');
(String, String) capsuleLegendNone(VehicleType vehicle) => (
  '沒有數字：不知道有沒有位',
  vehicle == VehicleType.heavy
      ? '不是沒位。官方沒給、資料太舊，或這裡的機車數字也算到只給普通機車停的格位，不能當成重機的空位'
      : '不是沒位。官方沒給，或資料太舊',
);

const legendRiderHeading = '車友回報角標（15 分鐘內，淺灰底量表）';
const legendRiderNote =
    '放在空位膠囊的位置；有官方即時或延遲膠囊時不掛（官方優先，不被車友回報蓋過）。'
    '地圖角標只看 15 分鐘內、目前車種的回報；停車點詳情的車友回報列出 30 分鐘內的，'
    '30 分鐘後消失。';

const legendOthersHeading = '其他狀態';

/// The other map states: name and, where the legend explains it, how.
const otherSelected = ('選取', '');
const otherCluster = ('群聚', '5 點以上；放大地圖即可展開');
const otherExcluded = ('被篩掉', '不符合目前篩選條件');
const otherGone = ('回報已不存在', '車友回報已不存在，待確認');
const otherLongPress = ('長按地圖', '在該位置新增停車點');

const legendFootnote = '社群資訊可能有延遲，停車前請確認現場標示。';

/// The iOS back button's title, naming the page the legend came from.
String legendBackTitle({required bool fromMap}) => fromMap ? '探索' : '個人中心';
