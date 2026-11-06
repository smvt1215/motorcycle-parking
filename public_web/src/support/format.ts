/** Taiwan has no daylight saving time: UTC+8 all year. */
const TAIWAN_OFFSET_MS = 8 * 60 * 60 * 1000;

/**
 * The short code riders see, e.g. S-1A2B3C4D: the same as the mails'
 * (supportCode in supabase/functions/support-request/resend.ts).
 */
export function supportCode(id: string): string {
  return `S-${id.slice(0, 8).toUpperCase()}`;
}

/** The board's 「[M 月 D 日 HH:mm]」 in Taiwan time; null for a missing or bad time. */
export function submittedLabel(iso: string | null): string | null {
  const at = iso ? Date.parse(iso) : Number.NaN;
  if (Number.isNaN(at)) return null;
  const t = new Date(at + TAIWAN_OFFSET_MS);
  const two = (n: number) => String(n).padStart(2, '0');
  return `${t.getUTCMonth() + 1} 月 ${t.getUTCDate()} 日 ${two(t.getUTCHours())}:${two(t.getUTCMinutes())}`;
}

/** The email shape the backend accepts (support-request's parse). */
const emailShape = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
export function isEmail(value: string): boolean {
  const v = value.trim();
  return v.length <= 254 && emailShape.test(v);
}

// `<request id>.<secret>`: a UUID and 32 bytes in base64url (support_token.ts).
const tokenShape = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.[A-Za-z0-9_-]{43}$/;

/**
 * The one-time token of a link's fragment (`#token=…`), with the request id
 * it starts with; null when there is none or it is malformed, so nothing
 * is sent for it.
 */
export function linkToken(hash: string): { token: string; id: string } | null {
  const token = new URLSearchParams(hash.replace(/^#/, '')).get('token')?.trim() ?? '';
  const match = tokenShape.exec(token);
  return match ? { token, id: match[1]! } : null;
}
