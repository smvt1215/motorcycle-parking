// support-inbound: mail sent to support@ or reply+<token>@ becomes a case
// (#295 layer 2; PM_ANS_20261101_147). Cloudflare Email Routing hands the
// mail to the Email Worker (workers/support-inbound), which posts it here as
// JSON signed with HMAC-SHA256 under SUPPORT_INBOUND_SECRET:
//
//   x-support-timestamp  unix seconds; refused when more than 5 minutes off
//   x-support-signature  hex HMAC-SHA256 of `<timestamp>.<body>`
//
// The raw mail never reaches us: only the addresses, the subject, the plain
// text, the SPF, DKIM and DMARC results of Cloudflare's Authentication-Results and
// the attachments' file names. public.support_inbound() (migration
// 202611020200_support_inbound.sql) files it:
//
//   support@         a new general case from email
//   reply+<token>@   the case of the token when the sender is its email (a
//                    case closed within 30 days opens again); otherwise a new
//                    case (one closed longer ago is linked as related_to)
//
// A new case's sender gets a receipt with the case link and a Reply-To of
// its own, unless SPF, DKIM or DMARC did not pass (no mail for a forged
// sender).
// When the mail reads like an account deletion or a personal data request,
// the receipt says mail cannot prove who owns an account and points to the
// form, whose one-time link goes only to the login email (#285). ops@
// (SUPPORT_MAIL_TO) hears of new cases and replies: the case id and the
// admin page link, nothing else.
import { response } from '../_shared/http.ts';
import {
  parseReplyAddress,
  replyTokenHash,
  type Secret,
} from '../_shared/support_token.ts';
import type { Notifier } from '../support-request/handler.ts';

export const supportInbox = 'support@motoparking.smvtstudio.com';
/** How far the Worker's clock may be from ours. */
export const maxSkewSeconds = 300;
export const authResults = [
  'pass',
  'fail',
  'softfail',
  'neutral',
  'none',
  'temperror',
  'permerror',
  'policy',
] as const;

export type Inbound = {
  /** The envelope recipient: support@ or reply+<token>@. */
  to: string;
  /** The header From address. */
  from: string;
  subject: string;
  text: string;
  spf: string | null;
  dkim: string | null;
  /** DMARC: the authenticated domain matches From (Codex review, PR #306). */
  dmarc: string | null;
  attachments: string[];
  /** The Message-ID header, for filing a mail once. */
  message_id: string | null;
  /** The raw mail's SHA-256, the same on every delivery of it. */
  raw_sha256: string | null;
};

export type Filed =
  | {
    result: 'created';
    id: string;
    related_to: string | null;
    suspicious: boolean;
  }
  | {
    result: 'appended';
    id: string;
    message_id: string;
    reopened: boolean;
    suspicious: boolean;
  }
  | { result: 'duplicate' | 'rate_limited' };

export type Deps = {
  /** SUPPORT_INBOUND_SECRET; empty when unset. */
  secret: string;
  /** Now, in unix seconds. */
  now(): number;
  newSecret(): Promise<Secret>;
  newReplyToken(): Promise<Secret>;
  file(
    mail: Inbound,
    replyHash: string | null,
    keyHash: string,
    linkHash: string,
    newReplyHash: string,
  ): Promise<Filed>;
  /** The receipt to a new case's sender. False: nothing was sent. */
  receipt(
    mail: {
      id: string;
      email: string;
      link: string | null;
      replyTo: string;
      identity: boolean;
    },
  ): Promise<boolean>;
  caseLink(id: string, secret: string): string | null;
  replyAddress(token: string): string;
  notifier: Notifier;
  adminUrl(id: string): string;
  /** Runs a task after the answer (EdgeRuntime.waitUntil). */
  background(task: Promise<unknown>): void;
};

const encoder = new TextEncoder();

async function hmacHex(secret: string, text: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign('HMAC', key, encoder.encode(text)),
  );
  return [...mac].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** The signature the Worker sends: hex HMAC-SHA256 of `<ts>.<body>`. */
export const sign = (secret: string, timestamp: string, body: string) =>
  hmacHex(secret, `${timestamp}.${body}`);

/** Compares two strings in time that depends only on their length. */
function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-256', encoder.encode(text)),
  );
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Words of an account deletion or a personal data request.
const identityWords =
  /刪除帳號|刪帳號|註銷帳號|移除帳號|刪除我的帳號|個資|個人資料|delete (my )?account|account deletion|personal data|data (access|export)|gdpr/i;

/** The mail reads like a request only the login email's owner may make. */
export const identityRequest = (subject: string, text: string) =>
  identityWords.test(subject) || identityWords.test(text);

const email = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
// deno-lint-ignore no-control-regex
const control = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;
const str = (v: unknown, max: number) =>
  typeof v === 'string'
    ? [...v.replace(control, '')].slice(0, max).join('')
    : '';
const result = (v: unknown) =>
  authResults.includes(v as typeof authResults[number]) ? v as string : null;

export function parse(body: unknown): Inbound | null {
  if (typeof body !== 'object' || body === null) return null;
  const b = body as Record<string, unknown>;
  const to = str(b.to, 254).trim().toLowerCase(),
    from = str(b.from, 254).trim().toLowerCase();
  if (!email.test(to) || !email.test(from)) return null;
  return {
    to,
    from,
    subject: str(b.subject, 200).replace(/\s+/g, ' ').trim(),
    // The database keeps 4000 characters.
    text: str(b.text, 4000),
    spf: result(b.spf),
    dkim: result(b.dkim),
    dmarc: result(b.dmarc),
    attachments: Array.isArray(b.attachments)
      ? b.attachments.slice(0, 20).map((a) => str(a, 200).trim()).filter((a) =>
        a !== ''
      )
      : [],
    message_id: str(b.message_id, 998).trim() || null,
    raw_sha256: typeof b.raw_sha256 === 'string' &&
        /^[0-9a-f]{64}$/.test(b.raw_sha256)
      ? b.raw_sha256
      : null,
  };
}

const fail = (error: string, status: number) => response({ error }, status);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return fail('request.invalid', 405);
  if (!deps.secret) return fail('server.unavailable', 503);
  const timestamp = req.headers.get('x-support-timestamp') ?? '';
  const signature = req.headers.get('x-support-signature') ?? '';
  const raw = await req.text().catch(() => null);
  if (raw === null || raw.length > 64_000) return fail('request.invalid', 400);
  if (
    !/^\d{1,12}$/.test(timestamp) ||
    Math.abs(deps.now() - Number(timestamp)) > maxSkewSeconds ||
    !sameText(signature, await sign(deps.secret, timestamp, raw))
  ) return fail('auth.forbidden', 403);

  let mail: Inbound | null;
  try {
    mail = parse(JSON.parse(raw));
  } catch {
    mail = null;
  }
  if (!mail) return fail('request.invalid', 400);
  let replyHash: string | null = null;
  if (mail.to !== supportInbox) {
    const token = parseReplyAddress(mail.to);
    if (!token) return fail('support.unknown_recipient', 400);
    replyHash = await replyTokenHash(token);
  }
  // The same mail is filed once: by its Message-ID, or else by the digest of
  // the raw mail, which a redelivery repeats (a signature does not).
  const keyHash = await sha256Hex(
    mail.message_id
      ? `id:${mail.message_id}`
      : mail.raw_sha256
      ? `raw:${mail.raw_sha256}`
      : `sig:${signature}`,
  );

  let link: Secret, reply: Secret, filed: Filed;
  try {
    link = await deps.newSecret();
    reply = await deps.newReplyToken();
    filed = await deps.file(mail, replyHash, keyHash, link.hash, reply.hash);
  } catch (error) {
    const message = (error as { message?: unknown })?.message;
    if (message === 'request.invalid') return fail('request.invalid', 400);
    return fail('server.unavailable', 503);
  }

  if (filed.result === 'created' || filed.result === 'appended') {
    const { id } = filed;
    const tasks: Promise<unknown>[] = [];
    if (filed.result === 'created' && !filed.suspicious) {
      const sender = mail.from,
        identity = identityRequest(mail.subject, mail.text);
      tasks.push(
        deps.receipt({
          id,
          email: sender,
          link: deps.caseLink(id, link.secret),
          replyTo: deps.replyAddress(reply.secret),
          identity,
        }).then((sent) => {
          if (!sent) console.error(`support-inbound: no receipt for ${id}`);
        }).catch(() =>
          console.error(`support-inbound: receipt failed for ${id}`)
        ),
      );
    }
    tasks.push(
      deps.notifier.notify({
        id,
        adminUrl: deps.adminUrl(id),
        ...(filed.result === 'appended' ? { replyId: filed.message_id } : {}),
      }).catch(() => console.error(`support-inbound: notice failed for ${id}`)),
    );
    deps.background(Promise.all(tasks));
    return response({ result: filed.result });
  }
  // Duplicates and mail over the limits are dropped quietly: no bounce.
  return response({ result: filed.result });
}
