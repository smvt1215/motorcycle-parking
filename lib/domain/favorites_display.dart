import '../models/parking.dart';

/// 個人中心收藏區 (P4) 與我的收藏 (P6) 的文字.
const favoritesTitle = '我的收藏';

/// P6's count line; 「依距離排序」 only when the list is sorted that way,
/// i.e. once the device is located.
String favoritesCount(int count, {required bool byDistance}) =>
    byDistance ? '$count 個停車點，依距離排序' : '$count 個停車點';

const favoritesEmptyTitle = '還沒有收藏';
const favoritesEmptyBody = '在地圖點選停車點，再按「收藏」。';
const favoritesExplore = '去探索';

/// P4's link to every favourite.
String showAllFavorites(int count) => '查看全部 $count 個收藏';

/// The bookmark button of one P6 card.
String unfavoriteLabel(String name) => '取消收藏「$name」';

/// The avatar beside P4's title opens the account sheet.
const accountSettingsLabel = '帳號與設定';

/// The city the rules page opens on (its picker's default).
const rulesDefaultCity = '臺北市';

/// P4's 停車規則 row: the city and vehicle the rules page shows first.
String rulesLinkSubtitle(VehicleType vehicle) =>
    '$rulesDefaultCity・${vehicle.label}';
