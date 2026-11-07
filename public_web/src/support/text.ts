// Copy of the support pages, verbatim from the approved canvas (version 20):
// PhoneSupport (the form), PhoneVerify (the confirmation link) and
// PhoneCancel (the deletion notice's 取消刪除 link). Where the page says
// something the boards do not, the constant's comment says why.

// ===== The form (PhoneSupport) =====
export const formTitle = '用登入 email 申請刪除';
export const formIntro = {
  before: '我們只會寄確認信到你在 App 的',
  bold: '登入 email',
  after:
    '（包含 Apple 的「隱藏的電子郵件」）。你打開信裡的連結並按下確認，就會立即申請刪除，之後一樣有 7 天冷靜期。',
};
/** Until #295's kinds join the form (user, 2026-11-08): text, never a mail link. */
export const otherQuestions = '其他問題（不是刪除帳號）請寫信到 ops@motoparking.smvtstudio.com。';
export const formWarning = '那個信箱已經收不到信的話，我們無法確認是你，也就無法用這個方式刪除。';

export const loginLabel = '帳號的登入 email';
export const loginRequired = '（必填）';
export const loginHelp =
  '確認信只寄到這裡。用 Apple 登入並選了「隱藏的電子郵件」的話，地址在 iPhone 的「設定 > 你的姓名 > 使用 Apple 登入」裡。';
export const providerLegend = '你在 App 用哪種方式登入？';
export const providerOptions = [
  { value: 'google', label: 'Google' },
  { value: 'apple', label: 'Apple' },
  { value: 'unknown', label: '不記得' },
] as const;
export const contactLabel = '聯絡用 email';
export const contactRequired = '（必填，只寄收件回條）';
export const contactHelp =
  '這個信箱只會收到一封「已收到編號 S-XXXX」的回條，不會收到確認連結或處理結果。可以和登入 email 相同。';
export const messageLabel = '為什麼沒辦法登入';
export const messageOptional = '（選填）';
/** The backend keeps at most 1000 characters (support-request's parse). */
export const messageMax = 1000;
export const submit = '寄確認信';

export const emailIncomplete = 'email 格式不完整，例如 name@example.com';
export const contactMissing = '請填寫聯絡用 email';
/** Not on the board, which shows only the contact field's empty error: the same words for the login field. */
export const loginMissing = '請填寫帳號的登入 email';

export const recaptcha = {
  before: '這個表單以 Google reCAPTCHA Enterprise 防止濫用，送出即表示同意其',
  privacy: '隱私權政策',
  and: '與',
  terms: '服務條款',
  after: '。我們如何處理這些資料，見本站的',
  sitePrivacy: '隱私權政策',
  end: '。',
};

/**
 * Not on the board: the build has no App Check settings (a local preview),
 * so the form cannot be sent. No mail link instead (#295).
 */
export const formUnavailable = '客服表單暫時無法使用，請稍後再試。';

export function receivedTitle(code: string): string {
  return `已收到申請，編號 ${code}`;
}
export const receivedBody = [
  '如果這個登入 email 有對應的帳號，確認信會寄到該信箱，寄件人是 support@motoparking.smvtstudio.com。連結 24 小時內有效、只能使用一次；你在連結頁按下確認後，就會立即申請刪除。',
  '聯絡用 email 只會收到一封收件回條。沒收到確認信？請檢查垃圾郵件，或確認填的是 App 的登入 email。重新送出後，舊的確認連結會作廢。',
] as const;

export const appCheckTitle = '沒辦法確認是真人送出';
export const appCheckBody =
  '重新整理頁面後再送出一次。仍然失敗的話，請改用其他瀏覽器，或關閉阻擋腳本的擴充功能。';
export const rateLimitedTitle = '送出太多次了';
/**
 * The board names the network and login email limits; the backend also
 * limits the contact email (3 a day, 10 in 30 days), so this says all of
 * them (202611012200_support_deletion_verify.sql).
 */
export const rateLimitedBody =
  '每個網路每天最多送出 5 次，同一個登入 email 或聯絡用 email 每天最多 3 次，同一個聯絡用 email 30 天內最多 10 次（以台灣時間計算，重新送出也算一次）。請明天再試；已送出的申請會照常處理。';
export const networkTitle = '沒有送出';
export const networkBody = '網路連線有問題，申請沒有送出。請確認連線後再試一次，填好的內容會保留。';
/** Not on the board: the backend could not take the request (503, or a refused body). */
export const unavailableTitle = '沒有送出';
export const unavailableBody = '發生錯誤，申請沒有送出。請稍後再試一次，填好的內容會保留。';

// ===== Shared by both links =====
export const codeLabel = '申請編號';
/** Not on a board: the page is asking the backend about the link. */
export const loading = '正在確認連結…';
/** Not on a board: no answer from the backend; the action was not sent or its result is unknown. */
export const linkNetworkTitle = '沒有送出';
export const linkNetworkBody = '網路連線有問題，請確認連線後再試一次。';
/** Not on a board: the backend failed (503 or anything unexpected). */
export const linkErrorTitle = '發生錯誤';
export const linkErrorBody = '發生錯誤，請稍後再試。';
export const retry = '重試';
export const refillForm = '重新填寫客服表單';

// ===== The confirmation link (PhoneVerify) =====
export const verifyTitle = '是你申請刪除帳號的嗎？';
export const submittedAtLabel = '送出時間';
export const contactEmailLabel = '聯絡 email';
export const accountLabel = '要刪除的帳號';
export const accountValue = '登入 email 是這個信箱的帳號';
export const verifyBody =
  '按下確認後，會立即申請刪除帳號。之後有 7 天冷靜期；通知信裡附有「取消刪除」連結，7 天內打開並確認就能取消。';
export const verifyConfirm = '是我，申請刪除帳號';
export const verifyDeny = '不是我申請的';
export const verifyDenyNote = '選「不是我申請的」會作廢這次申請，帳號照常使用，也不會再寄信。';

export const requestedTitle = '已申請刪除帳號';
export function requestedBody(dateLabel: string): string {
  return `帳號預計於 ${dateLabel}後刪除。你的名稱已從停車點上隱藏，所有裝置都已登出；通知也寄到了帳號的登入信箱。`;
}
export const requestedCancel =
  '改變主意的話，打開通知信裡的「取消刪除」連結即可（7 天內有效、只能使用一次）；能登入 App 的話，也可以在 App 裡取消。';
/**
 * The board shows this for Apple accounts only; the backend does not say
 * which provider the account uses, so the page always shows it (it names
 * Apple accounts in its first words).
 */
export const requestedApple =
  '用 Apple 登入的帳號：我們無法替你撤銷「使用 Apple 登入」的授權，請到 iPhone 的「設定 > 你的姓名 > 使用 Apple 登入」，選取本 App 後點一下「刪除」。';

export const deniedTitle = '已作廢這次申請';
export const deniedBody = '帳號沒有任何變動。如果不是你填的表單，可能有人輸入了你的 email；不必另外處理。';

/**
 * The backend answers every bad token alike (malformed, used, voided,
 * expired), so the board's three states (確認連結已過期, 這個連結已經用過了,
 * 連結無效) are one here: the 連結無效 heading with the board's words for
 * each cause.
 */
export const verifyInvalidTitle = '連結無效';
export const verifyInvalidBody =
  '連結只在寄出後 24 小時內有效、只能使用一次，也可能已經被新的申請取代。請使用最新一封確認信裡的連結；需要的話請重新填寫客服表單。';

export const resolvedTitle = '這次申請已經關閉';
export const resolvedBody = '客服已經處理完這次申請，連結不再有效。需要的話請重新填寫客服表單。';
export const alreadyPendingTitle = '帳號已經在等待刪除';
export function alreadyPendingBody(dateLabel: string): string {
  return `這個帳號已經申請過刪除，預計於 ${dateLabel}後刪除，不需要再申請。`;
}
/** The backend says account_deleting for an account being deleted and one already deleted: the board's first. */
export const deletingTitle = '帳號正在刪除';
export const deletingBody = '刪除已經開始，無法取消。';
export const adminTitle = '管理員帳號無法用這個方式刪除';
export const adminBody = '請先請其他管理員移除你的管理員權限，再重新填寫客服表單。';

// ===== The cancel link (PhoneCancel) =====
export const cancelTitle = '要取消刪除帳號嗎？';
export const scheduledLabel = '預計刪除';
export function scheduledValue(dateLabel: string): string {
  return `${dateLabel}後`;
}
export const cancelBody = '取消後，帳號和名稱都會恢復，可以照常登入使用。';
export const cancelButton = '取消刪除';
export const cancelKeepNote = '不想取消的話，關閉這個頁面即可，帳號會照原訂時間刪除。';
export const cancelledTitle = '已取消刪除帳號';
export const cancelledBody = '帳號和名稱都恢復了。';
/**
 * not_pending: the deletion was cancelled already (e.g. in the App). The
 * board's used-link state, without its mail link (#295).
 */
export const notPendingTitle = '這個連結已經用過了';
export const notPendingBody = '每個取消連結只能使用一次，刪除已經取消，不需要再點。';
/**
 * Every bad cancel token is one answer too (used, expired, malformed): the
 * board's 取消連結已過期 cannot be told apart, so a neutral heading with the
 * board's and the mail's words.
 */
export const cancelInvalidTitle = '連結無效';
export const cancelInvalidBody =
  '每個取消連結只能使用一次，冷靜期結束後也會失效。冷靜期內能登入 App 的話，也可以在 App 裡取消。';
