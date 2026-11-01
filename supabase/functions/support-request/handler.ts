// support-request: the public support form of the account deletion page
// (#269), for people who cannot sign in (banned, lost the account). It
// stores the request through public.support_request_submit() (migration
// 202611012000_support_requests.sql) and tells the administrators that one
// came in: the notice carries only the request id and the admin page link,
// never the email or the message.
//
// Bots: the page sends a Firebase App Check token (reCAPTCHA Enterprise web
// provider), checked with _shared/app_check.ts like the App's writes, but
// always enforced here. Limits: 5 a Taiwan day per network, 3 per email (in
// the database).
import { cors, readBody, response } from '../_shared/http.ts';
import type { AppCheckResult } from '../_shared/app_check.ts';

export type Submission = {
  kind: 'account_deletion';
  email: string;
  hint: string;
  message: string;
};

/** How administrators hear about a new request; replaceable (T269_Q4_MAILER). */
export interface Notifier {
  /** False when no mail service is configured: nothing was sent. */
  notify(notice: { id: string; adminUrl: string }): Promise<boolean>;
}

/** No mail service yet: requests still show on the admin page. */
export const silentNotifier: Notifier = {
  notify: () => Promise.resolve(false),
};

export type Deps = {
  /** The App Check verdict for the request's token. */
  appCheck(token: string | null): Promise<AppCheckResult | null>;
  /** HMAC of the trusted client IP; null when the IP is unavailable. */
  networkHash(req: Request): Promise<string | null>;
  submit(s: Submission, networkHash: string): Promise<string>;
  notified(id: string): Promise<void>;
  notifier: Notifier;
  /** The admin page of one request, e.g. https://admin.example/support/<id>. */
  adminUrl(id: string): string;
};

const email = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
// Control characters other than tab and newlines are dropped.
// deno-lint-ignore no-control-regex
const control = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;
const clean = (value: unknown) =>
  typeof value === 'string' ? value.replace(control, '').trim() : '';

export function parse(body: Record<string, unknown>): Submission | null {
  const kind = body.kind ?? 'account_deletion';
  const address = clean(body.email).toLowerCase();
  const hint = clean(body.account_hint), message = clean(body.message);
  if (
    kind !== 'account_deletion' || address.length > 254 ||
    !email.test(address) || [...hint].length > 200 ||
    [...message].length > 1000
  ) return null;
  return { kind, email: address, hint, message };
}

const fail = (error: string, status: number) => response({ error }, status);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('request.invalid', 405);

  const verdict = await deps.appCheck(
    req.headers.get('x-firebase-appcheck')?.trim() || null,
  ).catch(() => null);
  if (!verdict) return fail('server.unavailable', 503);
  if (verdict.status !== 'valid') return fail('app_check.required', 401);

  const network = await deps.networkHash(req);
  if (!network) return fail('server.unavailable', 503);

  let body: Record<string, unknown>;
  try {
    body = await readBody(req);
  } catch {
    return fail('request.invalid', 400);
  }
  const submission = parse(body);
  if (!submission) return fail('request.invalid', 400);

  let id: string;
  try {
    id = await deps.submit(submission, network);
  } catch (error) {
    const message = (error as { message?: unknown })?.message;
    if (message === 'support.rate_limited') {
      return fail('support.rate_limited', 429);
    }
    if (message === 'request.invalid') return fail('request.invalid', 400);
    return fail('server.unavailable', 503);
  }
  // The request is stored; a failed notice only leaves it unmarked, and the
  // admin page lists it either way.
  try {
    if (await deps.notifier.notify({ id, adminUrl: deps.adminUrl(id) })) {
      await deps.notified(id);
    }
  } catch {
    console.error(`support-request: notice failed for ${id}`);
  }
  // Nothing about whether an account exists.
  return response({ received: true, id });
}
