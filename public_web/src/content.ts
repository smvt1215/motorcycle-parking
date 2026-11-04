// Words of the public pages (approved design: canvas 5YXW7ZGBPs5qof2d1BEKAB,
// version 20). The lists shared with the App come from
// lib/domain/account_deletion_display.dart (#284); src/content.test.ts fails
// when the two drift apart.

export const developer = '小哲資訊工作室（H.C. CHEN）';
export const appName = '機車停車指南';
/** The sender of our mail; the pages offer the support form, not a mail link (#295). */
export const supportEmail = 'support@motoparking.smvtstudio.com';

export const intro =
  '刪除前，先看看你的資料會怎麼處理。申請後有 7 天冷靜期，這段期間登入時，可以選擇取消刪除。';

export const coolingOffHeading = '7 天冷靜期';
/** The cooling-off as it runs; a sequence, so the page draws it in order. */
export const coolingOffSteps = [
  { when: '送出當下', what: '名稱立刻隱藏，停車點上不再顯示；這支手機和其他裝置都會登出' },
  { when: '7 天內', what: '登入 App 或這個網頁時，可以選擇取消刪除；取消後名稱恢復' },
  { when: '7 天後', what: '刪除，之後就無法復原' },
] as const;

export const deletedHeading = '會刪除';
/**
 * App's deletionDeleted; the parking log lives on the phone, so the web
 * says when it goes.
 */
export const deleted = [
  '帳號與登入資訊',
  '顯示名稱和頭像',
  '收藏',
  '可信度分數',
  '使用紀錄（地址查詢、次數限制）',
  '這支手機上的停車紀錄（在 App 裡刪除帳號時）',
] as const;

export const keptHeading = '會保留，但改為匿名';
export const kept = ['你新增的停車點', '修改建議與回報（審核中的照常審核）', '投票與現場回報'] as const;
export const keptNote = '這些內容不會再連到你，也不顯示你的名稱。';

export const hashHeading = '防濫用紀錄';
export const hashBody =
  '保留匿名的防濫用雜湊：由 IP 和裝置算出的雜湊值，只用來計票和防止洗票，不含你的帳號或名稱；保留 180 天後刪除。';

export const retentionHeading = '保存期限';
export const retention = [
  '帳號資料：7 天後刪除；備份會在 7 天內一併清除。',
  '匿名內容：繼續公開，供其他騎士使用。',
  '客服申請與處理紀錄：結案、作廢、自動結束、例外或已申請刪除之後，保留 180 天。',
] as const;

export const signInHeading = '先登入，確認是你';
export const signInBody =
  '用你在 App 裡登入的同一個方式。登入後會再確認一次，才會送出申請。在這裡登入不會建立新帳號。';

export const cannotSignInHeading = '沒辦法登入？';
export const cannotSignInBody =
  '例如換了手機、忘記當初用哪個帳號登入。填寫客服表單後，我們會寄確認信到帳號的登入 email，你在信裡的連結按下確認，就會立即申請刪除。那個信箱收不到信的話，就無法用這個方式刪除。';
export const supportFormLink = '填寫客服表單';

export const footerNote = '只想改收藏或登出？在 App 的「帳號與設定」裡就能處理，不必刪除帳號。';
