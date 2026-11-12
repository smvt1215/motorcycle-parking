// Words of the signed-in deletion flow (canvas boards PhoneConfirm,
// PhoneRequested, PhonePending, PhoneStates and DesktopFlow). They are the
// App's own (lib/domain/account_deletion_display.dart, P15a–c); text.test.ts
// fails when one drifts. Where the web has to say something else, the
// constant says so.

export const confirmTitle = '要刪除帳號嗎？';
export const confirmBody =
  '帳號和所有已連結的登入方式會在 7 天後一起刪除。這段期間登入時可以選擇取消；之後就無法復原。';
/** The board's three points, in its order. */
export const confirmPoints = [
  '名稱立刻隱藏，停車點上不再顯示你的名稱。',
  '送出後，所有裝置都會登出。',
  '你新增的停車點、修改建議與回報、投票與現場回報會保留，但改為匿名。',
] as const;
export const confirmCheck = '我了解 7 天後帳號就無法復原';
export const confirmCheckHint = '先勾選上面的確認，才能刪除帳號。';
export const confirmAction = '刪除帳號';
export const confirmCancel = '取消';
export const sending = '正在送出…';
export const reauthNote = '如果超過 10 分鐘沒登入，送出前會請你再登入一次。';
/**
 * Apple riders: the revoke needs the authorization code of an Apple sign-in
 * on this page, used once and only for about 4.5 minutes, so the App's
 * 「送出前會請你再用 Apple 登入一次」 holds unless they just signed in here.
 */
export const reauthNoteApple =
  '如果剛才不是在這個頁面登入，送出前會請你再用 Apple 登入一次，以便撤銷「使用 Apple 登入」的授權。';
export const signOut = '登出';
/** Web only: while the page reads the account's deletion status. */
export const checking = '正在確認帳號…';
/** Web only: under it while a sign-in is being checked (canvas SignInLoading). */
export const checkingHint = '請稍候，不要關閉這個頁面。';

export const reauthTitle = '再登入一次';
export const reauthBody = '為了確認是你本人，請用目前的帳號再登入一次。';
/** Apple riders: the sign-in also gives the code that revokes Apple's grant. */
export const reauthBodyApple = '為了確認是你本人，並撤銷「使用 Apple 登入」的授權，請再用 Apple 登入一次。';
export const reauthFootnote = '登入後會直接送出刪除申請。';
export const reauthCancel = '取消';
export function signInButton(provider: 'google' | 'apple'): string {
  return provider === 'apple' ? '使用 Apple 登入' : '使用 Google 登入';
}

export const adminCannotDeleteTitle = '管理員帳號無法自行刪除';
export const adminCannotDeleteBody = '請先請其他管理員移除你的管理員權限，再回來刪除帳號。';
export const networkFailedTitle = '沒有送出';
export const networkFailedBody = '網路連線有問題，帳號沒有刪除。請確認連線後再試一次。';
export const networkRetry = '重試';
export const signInIncompleteTitle = '沒有完成登入';
export const signInIncompleteBody = '登入沒有完成，帳號沒有刪除。請再試一次。';
export const signInRetry = '再試一次';
export const wrongAccountTitle = '登入的不是要刪除的帳號';
export function wrongAccountBody(maskedEmail: string | null): string {
  return `你剛才登入的是 ${maskedEmail ?? '另一個帳號'}，不是要刪除的帳號。帳號沒有刪除，也沒有切換。`;
}
export const genericErrorTitle = '發生錯誤';
export const genericErrorBody = '發生錯誤，請稍後再試。';
export const ok = '好';
// Web only: the sign-in check allows 30 attempts an hour per network.
export const rateLimitedTitle = '暫時無法登入';
export const rateLimitedBody = '嘗試登入的次數太多，請稍後再試。';

export const requestedTitle = '已申請刪除帳號';
export function scheduledLine(dateLabel: string): string {
  return `帳號預計於 ${dateLabel}後刪除。`;
}
export const requestedRows = [
  '登入時可以選擇取消刪除',
  '你的名稱已從停車點上隱藏',
  '已登出所有裝置',
] as const;
export const requestedDone = '完成';
export const requestedSignIn = '登入以取消刪除';
/** Apple's grant was not revoked; the request went ahead anyway (P15c ⑤). */
export const appleRevokeFailedTitle = 'Apple 登入授權沒有撤銷';
export const appleRevokeFailedBody =
  '帳號仍會照常刪除。你可以到「設定 > 你的姓名 > 使用 Apple 登入」，選取本 App 後點一下「刪除」，停止本 App 使用。';

export const pendingTitle = '帳號正在等待刪除';
export const pendingBody = '你在冷靜期內登入了。要繼續使用這個帳號，還是維持刪除申請？';
export const pendingCancel = '取消刪除';
export const pendingCancelDetail = '帳號和名稱恢復，照常使用。';
export const pendingContinue = '繼續刪除';
export function pendingContinueDetail(dateLabel: string): string {
  return `維持申請並登出，${dateLabel}後刪除。`;
}
/** The App's says 「才能繼續使用 App」; on the web there is no App to go on to. */
export const pendingFootnote = '要先選一個，才能繼續。';

export const cancelledTitle = '已取消刪除帳號';
export const cancelledBody = '帳號和名稱都恢復了。';
export const continuedTitle = '已維持刪除申請，並已登出';
export const dismiss = '知道了';

export const inProgressTitle = '帳號正在刪除';
export const inProgressBody = '刪除已經開始，無法取消。';

// Signing in with an identity the App has never seen (PhoneStates): web
// only, the App always has an account by then.
export const noAccountTitle = '這個帳號沒有用過 App';
export function noAccountBody(email: string | null): string {
  return `${email ?? '這個帳號'} 在機車停車指南沒有帳號，所以沒有資料要刪除。為刪除而登入不會建立帳號，也不需要年齡確認。`;
}
export function noAccountHint(provider: 'google' | 'apple'): string {
  return provider === 'apple'
    ? '可能是用了另一個 Apple ID，或當初是用 Google 登入。'
    : '可能是用了另一個 Google 帳號，或當初是用 Apple 登入。';
}
export const noAccountRetry = '換一個帳號登入';
export const noAccountSupport = '想不起來用哪個帳號？填寫客服表單';
