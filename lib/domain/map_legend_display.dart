/// What the map's markers, corner badges and pills mean, in the words of
/// the design canvas (Ver.154 A0 地圖圖標, P3 地圖怎麼看). Pure Dart: the
/// widgets draw the shapes, this file holds every label they show.
library;

import '../models/parking.dart';
import '../models/zone_entries.dart';
import 'eligibility.dart';

/// A spot's corner badge: the bay kind beyond whether it is parkable.
/// Dedicated bays wear a white circle, shared bays a square (A0). One per
/// bay kind but the plain 一般機車格, which wears none.
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
  ev;

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
  };

  /// How the badge looks, under its name in the legend.
  String get look => switch (this) {
    heavyOnly => '白圓・重機',
    shared => '白黃雙色方・重機',
    car => '白圓・汽車',
    carMotorcycle => '白淺藍雙色方・汽車',
    disabled => '白圓・身障',
    ev => '白圓・充電',
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

const legendBadgesHeading = '格位徽章：圖示＝格位類別，白圓＝專用，方形＝共用';
const legendBadgesNote = '一般機車格不掛徽章。';

const legendCapsulesHeading = '空位膠囊（一律墨色）';
const legendCapsulesNote = '無即時資料或不能停時不掛。';

/// The pills, by what the legend calls them: name and meaning.
const capsuleLegendLive = ('即時', '官方即時剩餘格數');
const capsuleLegendFull = ('已滿', '官方資料目前沒有空位');
const capsuleLegendDelayed = ('延遲', '更新延遲，數字可能已變');
const capsuleLegendSuspended = ('暫停營運', '場站暫停營運');
const capsuleLegendCar = ('重機可停的汽車格', '汽車格的剩餘格數');

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
