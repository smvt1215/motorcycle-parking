/// 隱藏這位車友與檢舉內容不當的文字 (#280, canvas v172 P17a–P17d, P10).
library;

import '../data/hidden_riders.dart';

/// The rider's name in a sentence; 這位車友 when there is no public name.
String riderOrDefault(String name) =>
    name.trim().isEmpty ? '這位車友' : name.trim();

// P17a: the ⋯ menu beside 資料來源.

/// The ⋯ button's spoken label, from the words on screen: a rider's spot
/// is 這筆回報, an admin-added or imported one 這筆資料.
String moreActionsLabel({required bool byRider}) =>
    '${moreActionsTitle(byRider: byRider)}：更多動作';

/// The menu's heading (iOS) and the button's label stem.
String moreActionsTitle({required bool byRider}) => byRider ? '這筆回報' : '這筆資料';

const hideRiderAction = '隱藏這位車友';
const unhideRiderAction = '解除隱藏';
const reportContentAction = '檢舉內容不當';

// P17a ②: the confirmation.
const hideRiderConfirmTitle = '隱藏這位車友？';
String hideRiderConfirmBody(String name) =>
    '${riderOrDefault(name)}新增的停車點和名稱都不會再顯示，你登入的每台裝置都會同步。'
    '可以在「帳號與設定」的「已隱藏的車友」解除。';
const hideRiderConfirm = '隱藏';
const hideRiderCancel = '取消';

// P17a ③, P17c ②: the undo toast.
String hiddenToast(String name) => '已隱藏${riderOrDefault(name)}';
String unhiddenToast(String name) => '已解除隱藏${riderOrDefault(name)}';
const undoAction = '復原';

// P17c: 已隱藏的車友.
const hiddenRidersTitle = '已隱藏的車友';
const hiddenRidersIntro =
    '這些車友新增的停車點和名稱都不會顯示。'
    '名稱是你隱藏當時看到的，對方之後可能已經改名；改名後仍然維持隱藏。';

/// The page's foot when signed in (v174).
const hiddenRidersFootnote = '登入後會同步到你的帳號，你登入的每台裝置都會套用。';

/// P17c ④: signed out, the foot becomes this card with 登入.
const hiddenRidersGuestNote = '目前沒有登入，清單先存在這台裝置。登入後會保存到帳號。';
const hiddenRidersSignIn = '登入';

/// Hiding past the list's limit (500); not drawn on the canvas.
const hiddenRidersFull = '隱藏的車友已達 500 位上限，請先解除部分隱藏。';
const hiddenRidersEmptyTitle = '沒有隱藏的車友';
const hiddenRidersEmptyBody = '在社群停車點詳情的「資料來源」旁點 ⋯，可以隱藏這位車友。';

/// A row without a public name (renamed blank, email-like or cleared).
const unnamedRider = '未公開名稱的車友';

/// The row's title: the name when hidden, else [unnamedRider].
String hiddenRiderTitle(HiddenRider rider) =>
    rider.name.trim().isEmpty ? unnamedRider : rider.name.trim();

/// The row's subtitle: 隱藏時的名稱・在「點位」隱藏・日期.
String hiddenRiderSubtitle(HiddenRider rider) {
  final at = rider.hiddenAt.toLocal();
  final date = '${at.month} 月 ${at.day} 日';
  final where = rider.spotName.trim().isEmpty
      ? '隱藏'
      : '在「${rider.spotName.trim()}」隱藏';
  return rider.name.trim().isEmpty ? '$where・$date' : '隱藏時的名稱・$where・$date';
}

/// 解除隱藏 read with whom it unhides.
String unhideLabel(String name) => '解除隱藏 ${riderOrDefault(name)}';

/// The grey avatar's letter: the name's first character.
String hiddenRiderInitial(String name) {
  final n = name.trim();
  return n.isEmpty ? '' : String.fromCharCodes(n.runes.take(1)).toUpperCase();
}

// P10: the two new rows.
const settingsPrivacyGroup = '隱私';
const settingsHiddenRiders = hiddenRidersTitle;
const settingsHiddenRidersDetail = '登入後會同步到你的帳號';
String settingsHiddenRidersCount(int count) => '$count 位';
const settingsContact = '聯絡我們';
const settingsContactDetail = '問題回報、內容檢舉';
const supportUrl = 'https://motoparking.smvtstudio.com/support';

// P17d: favourites and a spot opened from elsewhere.
String hiddenFavoriteNote(String name) =>
    '已隱藏這位車友（${riderOrDefault(name)}）。地圖上不會顯示這個點。';

/// The banner atop the details of a hidden rider's spot. [fromLink]: the
/// spot came from a shared link (P17d ②); otherwise from 我的收藏 or another
/// list, where the link clause would be untrue.
String hiddenSpotBanner(String name, {bool fromLink = false}) =>
    '你已隱藏這位車友（${riderOrDefault(name)}）。'
    '他新增的停車點在地圖上不會顯示'
    '${fromLink ? '；這個點是從分享連結打開的。' : '。'}';

// P17b ⑪: the contributor's own spot under review.
const contentHeldNote = '部分內容審核中';
