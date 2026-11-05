// The App's formatting of the deletion date and the account line
// (lib/domain/account_deletion_display.dart), so both say the same.

/** Taiwan has no daylight saving time: UTC+8 all year. */
const TAIWAN_OFFSET_MS = 8 * 60 * 60 * 1000;

/**
 * The calendar day of `iso` in Taiwan, e.g. 「11 月 8 日」; the deletion runs
 * at the first daily job after it, so the page says 「X 月 X 日後」.
 */
export function deletionDateLabel(iso: string | null | undefined): string {
  const at = iso ? Date.parse(iso) : Number.NaN;
  if (Number.isNaN(at)) return '7 天';
  const taipei = new Date(at + TAIWAN_OFFSET_MS);
  return `${taipei.getUTCMonth() + 1} 月 ${taipei.getUTCDate()} 日`;
}

/** 「a••••@gmail.com」: enough to recognise the account, not to read it out. */
export function maskEmail(email: string): string {
  const at = email.indexOf('@');
  if (at <= 0) return '••••';
  return `${email[0]}••••${email.slice(at)}`;
}

/** Apple's 「隱藏我的電子郵件」 relay address. */
export function isPrivateRelay(email: string | null): boolean {
  return email?.endsWith('privaterelay.appleid.com') ?? false;
}

/** The board's identity line: 「以 Google 登入：r…@gmail.com」. */
export function accountLine(provider: 'google' | 'apple', email: string | null): string {
  const via = provider === 'apple' ? '以 Apple 登入' : '以 Google 登入';
  if (!email) return via;
  if (provider === 'apple' && isPrivateRelay(email)) return `${via}：隱藏的電子郵件（${email}）`;
  return `${via}：${email}`;
}
