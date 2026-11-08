/// 登入 (P11) 與編輯個人資料 (P12) 的文字.
const signInIntro = '登入後可回報停車資訊與同步收藏。';
const signInNotNeeded = '瀏覽地圖與記錄停車位置不需登入。';

const profileNameHelper = '你新增的停車點會顯示這個名稱。';

/// P12 ②: no saved name yet; the field holds the Google name as a suggestion.
const profileNameUnset = '尚未設定公開名稱';
const profileNameSuggestionHelper =
    '這是 Google 帳號的姓名，按「儲存」後才會公開顯示在你新增的停車點。不想公開可以改成暱稱。';

/// P12 ③: the field was cleared; saving keeps the name private.
const profileNameClearing = '儲存後不公開名稱';
const profileNameClearedHelper = '留空就不公開名稱，你新增的停車點會顯示「由車友回報」。已隱藏你的人仍會維持隱藏。';

/// P10 account card when there is no saved public name.
const settingsNameUnset = '尚未設定名稱';
const settingsSetName = '設定名稱';

/// Read out after 登出 in 帳號與設定, which stays open signed out.
const settingsSignedOut = '已登出';
