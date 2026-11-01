/// 刪除帳號（#215，P15a–c）與設定頁（P10）的文字。
library;

// P10 帳號與設定
const settingsDeleteAccount = '刪除帳號';
const settingsDeleteFootnote = '申請後有 7 天冷靜期，期間登入時可以選擇取消。';
const settingsDataLicense = '資料來源與授權';
const settingsDataLicenseDetail = '官方停車資料依「政府資料開放授權條款」使用';
const settingsPrivacyPolicy = '隱私權政策';
const settingsTerms = '服務條款';

// P15a 刪除說明
const deletionIntro = '刪除前，先看看你的資料會怎麼處理。';
const deletionCoolingOffHeading = '7 天冷靜期';
const deletionCoolingOff = [
  ('7 天後才會刪除', '這段期間登入時，可以選擇取消刪除。'),
  ('名稱立刻隱藏', '停車點上不再顯示你的名稱，取消後恢復。'),
  ('所有裝置都會登出', '送出後，這支手機和其他裝置都會登出。'),
];
const deletionDeletedHeading = '會刪除';
const deletionDeleted = [
  '帳號與登入資訊',
  '顯示名稱和頭像',
  '收藏',
  '可信度分數',
  '使用紀錄（地址查詢、次數限制）',
  '這支手機上的停車紀錄',
];
const deletionKeptHeading = '會保留，但改為匿名';
const deletionKept = ['你新增的停車點', '修改建議與回報（審核中的照常審核）', '投票與現場回報'];
const deletionKeptNote = '這些內容不會再連到你，也不顯示你的名稱。';
const deletionHashHeading = '防濫用紀錄';
const deletionHashTitle = '保留匿名的防濫用雜湊';
const deletionHashDetail = '由 IP 和裝置算出的雜湊值，只用來計票和防止洗票，不含你的帳號或名稱；保留 180 天後刪除。';
const deletionButton = '刪除帳號';
const deletionSending = '正在送出…';
const deletionReauthNote = '如果超過 10 分鐘沒登入，送出前會請你再登入一次。';

const deletionConfirmTitle = '要刪除帳號嗎？';
const deletionConfirmBody = '帳號會在 7 天後刪除。這段期間登入時可以選擇取消；之後就無法復原。';
const deletionConfirmCancel = '取消';
const deletionConfirmAction = '刪除帳號';

// P15a ④⑤ 再登入一次
const reauthTitle = '再登入一次';
const reauthBody = '為了確認是你本人，請用目前的帳號再登入一次。';
const reauthBodyApple = '為了確認是你本人，並撤銷「使用 Apple 登入」的授權，請再用 Apple 登入一次。';
const reauthFootnote = '登入後會直接送出刪除申請。';
const reauthCancel = '取消';
String reauthButton({required bool apple}) =>
    apple ? '使用 Apple 登入' : '使用 Google 登入';

// P15c 錯誤
const adminCannotDeleteTitle = '管理員帳號無法自行刪除';
const adminCannotDeleteBody = '請先請其他管理員移除你的管理員權限，再回來刪除帳號。';
const networkFailedTitle = '沒有送出';
const networkFailedBody = '網路連線有問題，帳號沒有刪除。請確認連線後再試一次。';
const networkRetry = '重試';
const reauthIncomplete = '登入沒有完成，帳號沒有刪除。請再試一次。';
String reauthWrongAccount(String? email) =>
    '你剛才登入的是 ${email == null ? '另一個帳號' : maskEmail(email)}，'
    '不是要刪除的帳號。帳號沒有刪除，也沒有切換。';
const genericErrorTitle = '發生錯誤';
const genericErrorBody = '發生錯誤，請稍後再試。';
const dialogOk = '好';

// P15b ① 登出後提示
const requestedTitle = '已申請刪除帳號';
String scheduledLine(String? scheduledAt) =>
    '帳號預計於 ${deletionDateLabel(scheduledAt)}後刪除。';
const requestedRows = ['登入時可以選擇取消刪除', '你的名稱已從停車點上隱藏', '已登出所有裝置'];
const requestedDone = '完成';
const requestedSignIn = '登入以取消刪除';

/// The path follows Apple's own help page (support.apple.com/zh-tw/102571):
/// Settings > your name > Sign in with Apple > the app > Delete.
const appleRevokeFailedTitle = 'Apple 登入授權沒有撤銷';
const appleRevokeFailedBody =
    '帳號仍會照常刪除。你可以到「設定 > 你的姓名 > 使用 Apple 登入」，選取本 App 後點一下「刪除」，停止本 App 使用。';

// P15b ② 冷靜期內登入
const pendingTitle = '帳號正在等待刪除';
const pendingBody = '你在冷靜期內登入了。要繼續使用這個帳號，還是維持刪除申請？';
const pendingCancel = '取消刪除';
const pendingCancelDetail = '帳號和名稱恢復，照常使用。';
const pendingContinue = '繼續刪除';
String pendingContinueDetail(String? scheduledAt) =>
    '維持申請並登出，${deletionDateLabel(scheduledAt)}後刪除。';
const pendingFootnote = '要先選一個，才能繼續使用 App。';

// P15b ③④ 提示
const cancelledBannerTitle = '已取消刪除帳號';
const cancelledBannerBody = '帳號和名稱都恢復了。';
const cancelledSnackbar = '已取消刪除帳號，名稱已恢復';
const continuedTitle = '已維持刪除申請，並已登出';
const bannerDismiss = '知道了';

// P15b ⑤ 409
const inProgressTitle = '帳號正在刪除';
const inProgressBody = '刪除已經開始，無法取消。';

/// Taiwan has no daylight saving time: UTC+8 all year.
const _taiwanOffset = Duration(hours: 8);

/// The calendar day of [iso] in Taiwan, e.g. 「11 月 8 日」; the deletion runs
/// at the first daily job after it, so the UI says 「X 月 X 日後」.
String deletionDateLabel(String? iso) {
  final at = iso == null ? null : DateTime.tryParse(iso);
  if (at == null) return '7 天';
  final taipei = at.toUtc().add(_taiwanOffset);
  return '${taipei.month} 月 ${taipei.day} 日';
}

/// 「a••••@gmail.com」: enough to recognise the account, not to read it out.
String maskEmail(String email) {
  final at = email.indexOf('@');
  if (at <= 0) return '••••';
  return '${email[0]}••••${email.substring(at)}';
}

/// The account line under the name on the re-sign-in panel.
String reauthAccountLine({required String? email, required bool apple}) {
  final provider = apple ? 'Apple' : 'Google';
  if (email == null || email.isEmpty) return '$provider 帳號';
  if (apple && email.endsWith('privaterelay.appleid.com')) {
    return 'Apple ID・隱藏的電子郵件';
  }
  return '${maskEmail(email)}・$provider';
}
