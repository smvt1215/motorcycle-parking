// Copy of the support pages, verbatim from the approved canvas: version 32's
// SupportKinds and PhoneSupportKinds (the kinds and their form) and PhoneCase
// (the case page), version 20's PhoneSupport (the deletion form), PhoneVerify
// (the confirmation link) and PhoneCancel (the deletion notice's 取消刪除
// link). Where the page says something the boards do not, the constant's
// comment says why. These pages name no reply time (user, #295): the boards'
// 「5 個工作天」 sentence is left out.

// ===== The kinds (SupportKinds) =====
export const supportTitle = '聯絡我們';
export const supportIntro = '先選你要詢問的類型。';
export const kindLegend = '要詢問什麼';
export const kindOptions = [
  { value: 'general', label: '一般問題', description: 'App 怎麼用、帳號或其他問題。' },
  { value: 'data_issue', label: '資料錯誤或侵權', description: '停車點資料有誤，或內容侵害你的權利。' },
  { value: 'complaint', label: '檢舉與申訴', description: '檢舉不當內容，或對處理結果提出申訴。' },
  {
    value: 'privacy',
    label: '個資權利請求',
    description: '查閱、更正或取得你的個人資料。要用帳號的登入 email 確認。',
  },
  { value: 'account_deletion', label: '刪除帳號', description: '沒辦法登入時，用登入 email 申請。' },
] as const;

/**
 * What the mails call each kind (kindNames in support-request/resend.ts): the
 * case page's heading and a general receipt. The form's choice says 刪除帳號.
 */
export const kindNames: Record<string, string> = {
  general: '一般問題',
  data_issue: '資料錯誤或侵權',
  complaint: '檢舉與申訴',
  privacy: '個資權利請求',
  account_deletion: '刪除帳號申請',
};

// ===== The other kinds' form (SupportKinds, PhoneSupportKinds) =====
export const caseContactNote = '（必填）';
export const caseContactHelp = '我們會回覆到這裡，信裡也有案件連結。';
export const subjectLabel = '主旨';
export const subjectNote = '（必填，最多 120 字）';
export const subjectMax = 120;
export const contentLabel = '內容';
export const contentNote = '（必填，最多 4,000 字）';
export const contentHelp = '請不要填寫密碼或其他人的個人資料。';
export const contentMax = 4000;
export const caseSubmit = '送出';
export const privacyLoginNote = '（必填）';
export const privacyLoginHelp = '確認信只寄到這裡，資料也只寄到這裡。';
export const privacyRightLegend = '要做什麼';
export const privacyRightOptions = [
  { value: 'access', label: '查閱我的資料' },
  { value: 'correction', label: '更正我的資料' },
  { value: 'copy', label: '取得資料副本' },
] as const;

/** Not on a board, which shows no empty state for these fields. */
export const subjectMissing = '請填寫主旨';
export const contentMissing = '請填寫內容';
export const privacyRightMissing = '請選擇要做什麼';
/** Not on a board: text from another kind, longer than the deletion form takes. */
export const messageTooLong = '最多 1,000 字，請縮短內容';

/** Not on a board: a general kind's receipt, in the mail's words (caseReceiptMail). */
export function caseReceivedTitle(name: string, code: string): string {
  return `已收到你的${name}，案件編號 ${code}`;
}
export const caseReceivedBody = [
  '我們會回覆到你填的聯絡用 email，信裡也有案件連結。',
  '要補充內容，請打開收件回條裡的案件連結（30 天內有效），或直接回覆那封信。沒收到回條？請檢查垃圾郵件。',
] as const;

/** Not on a board: the deletion receipt's words for a privacy request. */
export function privacyReceivedTitle(code: string): string {
  return `已收到請求，編號 ${code}`;
}
export const privacyReceivedBody = [
  '如果這個登入 email 有對應的帳號，確認信會寄到該信箱，寄件人是 support@motoparking.smvtstudio.com。連結 24 小時內有效、只能使用一次；你在連結頁按下確認後，客服才會處理，資料也只會寄到那個信箱。',
  '聯絡用 email 只會收到一封收件回條。沒收到確認信？請檢查垃圾郵件，或確認填的是 App 的登入 email。重新送出後，舊的確認連結會作廢。',
] as const;

// ===== The form (PhoneSupport) =====
export const formTitle = '用登入 email 申請刪除';
export const formIntro = {
  before: '我們只會寄確認信到你在 App 的',
  bold: '登入 email',
  after:
    '（包含 Apple 的「隱藏的電子郵件」）。你打開信裡的連結並按下確認，就會立即申請刪除，之後一樣有 7 天冷靜期。',
};
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
 * The limits of account_deletion and privacy. The board names the network
 * and login email limits; the backend also limits the contact email (3 a
 * day, 10 in 30 days), so this says all of them (support_request_submit in
 * 202611040100_support_cases.sql).
 */
export const rateLimitedBody =
  '每個網路每天最多送出 5 次，同一個登入 email 或聯絡用 email 每天最多 3 次，同一個聯絡用 email 30 天內最多 10 次（以台灣時間計算，重新送出也算一次）。請明天再試；已送出的申請會照常處理。';
/** Not on a board: the kinds with only a contact email have no login email limit. */
export const caseRateLimitedBody =
  '每個網路每天最多送出 5 次，同一個聯絡用 email 每天最多 3 次、30 天內最多 10 次（以台灣時間計算，所有類型合計）。請明天再試；已送出的內容會照常處理。';
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

// ===== A privacy request's confirmation link =====
// Not on a board (user, #295): PhoneVerify's layout and voice, in the words
// of the privacy confirmation mail (privacyConfirmMail). 帳號已經刪除 is the
// board's own state.
export const privacyVerifyTitle = '是你提出個資權利請求的嗎？';
export const privacyAccountLabel = '請求的帳號';
export const privacyRightLabel = '要做什麼';
export const privacySubjectLabel = '主旨';
export const privacyMessageLabel = '內容';
export const privacyVerifyBody = '按下確認後，客服才會處理這筆請求，資料也只會寄到帳號的登入 email。';
export const privacyVerifyConfirm = '是我，確認這筆請求';
export const privacyDenyNote = '選「不是我申請的」會作廢這次請求，帳號不會有任何變動，也不會再寄信。';
export const privacyVerifiedTitle = '已確認個資權利請求';
export const privacyVerifiedBody = '客服會處理這筆請求，資料只會寄到帳號的登入 email。';
export const privacyDeniedTitle = '已作廢這次請求';
export const privacyResolvedTitle = '這次請求已經關閉';
export const privacyResolvedBody = '客服已經處理完這次請求，連結不再有效。需要的話請重新填寫客服表單。';
export const privacyAccountGoneTitle = '帳號已經刪除';
export const privacyAccountGoneBody = '這個帳號已經刪除，沒有其他資料需要處理。';

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

// ===== The case page (PhoneCase) =====
export const caseCodeLabel = '案件編號';
export function caseSubmittedOn(dateLabel: string): string {
  return `${dateLabel}送出`;
}
/**
 * Plain words for the backend's states. Riders see done and rejected alike,
 * as the backend treats them (support_reopenable). The board has 處理中 and
 * 已結案; the rest are not on it.
 */
export const caseStatuses: Record<string, string> = {
  open: '處理中',
  done: '已結案',
  rejected: '已結案',
  voided: '已作廢',
  expired: '已過期',
  exception: '已結束',
};
/** Not on a board: a kind this page does not know. */
export const caseFallbackTitle = '客服案件';
export const threadLabel = '對話紀錄';
export const fromRider = '你';
export const fromSupport = '客服';
export const replyLabel = '回覆';
export const replyNote = '（最多 4,000 字）';
export const replyHelp = '也可以直接回覆客服寄給你的信。';
export const replyMax = 4000;
export const replySubmit = '送出回覆';
/** Not on the board. */
export const replyMissing = '請填寫回覆內容';
export const replySentTitle = '已送出回覆';
export const replySentBody = '我們會回覆到你的 email。';
export const replyReopened = '這個案件已重新開啟。';
export const caseClosedTitle = '這個案件已結案';
export const caseClosedBody = { before: '結案超過 30 天，沒辦法再回覆。有新問題請', after: '。' };
export const caseInvalidTitle = '連結無效';
export const caseInvalidBody = {
  before: '連結可能已過期（30 天）。請使用最新一封信裡的連結，或',
  after: '。',
};
export const caseRefill = '重新填寫表單';
export const replyLimitTitle = '回覆次數已達上限';
export const replyLimitBody = '今天沒辦法再回覆了，請明天再試。';
/** Not on a board: the case is open, but this link's 5 replies are used up. */
export const linkUsedTitle = '這個連結沒辦法再回覆';
export const linkUsedBody = '這個連結的回覆次數已用完。請使用最新一封信裡的連結，或直接回覆客服寄給你的信。';
/** Not on a board: the form's failures, about the reply. */
export const replyNetworkBody = '網路連線有問題，回覆沒有送出。請確認連線後再試一次，填好的內容會保留。';
export const replyUnavailableBody = '發生錯誤，回覆沒有送出。請稍後再試一次，填好的內容會保留。';
