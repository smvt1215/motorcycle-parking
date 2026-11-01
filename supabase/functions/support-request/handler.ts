// support-request: the public support form of the account deletion page
// (#269), for people who cannot sign in (banned, lost the account). It
// stores the request through public.support_request_submit() (migrations
// 202611012000_support_requests.sql, 202611012200_support_deletion_verify.sql)
// and tells the administrators that one came in: the notice carries only the
// request id and the admin page link, never an email or the message.
//
// Bots: the page sends a Firebase App Check token (reCAPTCHA Enterprise web
// provider), checked with _shared/app_check.ts like the App's writes, but
// always enforced here. Limits: 5 a Taiwan day per network, 3 per login
// email and 3 per contact email (in the database).
//
// Identity (#285, PM_ANS_20261101_132): the form has two emails. The
// account's login email is only matched against accounts; the contact email
// only ever gets one fixed receipt with the request code, whatever the match.
// When the login email is one account's and that account can be deleted,
// the database keeps the hash of a one-time secret and the confirmation mail
// with the link goes to that login email (PM_ANS_20261101_133: the owner's
// "是我" on that page asks for the deletion). The system's exceptions (no
// account, an admin account, already in the cooling-off period or being
// deleted) are only recorded; when the account is already in the cooling-off
// period its login email gets a mail saying so. The mails go out in the
// background and the answer is the same in every case, so neither the form
// nor the contact inbox tells whether an account exists.
import { cors, readBody, response } from '../_shared/http.ts';
import type { AppCheckResult } from '../_shared/app_check.ts';
import type { Secret } from '../_shared/support_token.ts';

export type Submission = {
  kind: 'account_deletion';
  contactEmail: string;
  loginEmail: string;
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

/** Mail to the person who filled in the form (#285). */
export interface RiderMailer {
  /** The fixed receipt to the contact email. False: nothing was sent. */
  receipt(mail: { id: string; email: string }): Promise<boolean>;
  /** The one-time link to the login email. False: nothing was sent. */
  confirm(mail: { id: string; email: string; link: string }): Promise<boolean>;
  /** The account is already in the cooling-off period: when it goes. */
  status(
    mail: { id: string; email: string; scheduledAt: string },
  ): Promise<boolean>;
}

export const silentRiderMailer: RiderMailer = {
  receipt: () => Promise.resolve(false),
  confirm: () => Promise.resolve(false),
  status: () => Promise.resolve(false),
};

/** What the database stored, and which mail the login email gets. */
export type Submitted = {
  id: string;
  mail: 'confirm' | 'status' | null;
  /** The deletion time, with mail 'status'. */
  scheduledAt: string | null;
};

export type Deps = {
  /** The App Check verdict for the request's token. */
  appCheck(token: string | null): Promise<AppCheckResult | null>;
  /** HMAC of the trusted client IP; null when the IP is unavailable. */
  networkHash(req: Request): Promise<string | null>;
  /** A new one-time secret and its hash, made for every request. */
  secret(): Promise<Secret>;
  submit(
    s: Submission,
    networkHash: string,
    tokenHash: string,
  ): Promise<Submitted>;
  notified(id: string): Promise<void>;
  notifier: Notifier;
  mailer: RiderMailer;
  /** The confirmation page with the token; null when it is not configured. */
  confirmLink(id: string, secret: string): string | null;
  /** Runs a task after the answer (EdgeRuntime.waitUntil). */
  background(task: Promise<unknown>): void;
  /** The admin page of one request, e.g. https://admin.example/support/<id>. */
  adminUrl(id: string): string;
};

const email = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
// Control characters other than tab and newlines are dropped.
// deno-lint-ignore no-control-regex
const control = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;
const clean = (value: unknown) =>
  typeof value === 'string' ? value.replace(control, '').trim() : '';
const address = (value: unknown) => {
  const a = clean(value).toLowerCase();
  return a.length <= 254 && email.test(a) ? a : null;
};

export function parse(body: Record<string, unknown>): Submission | null {
  const kind = body.kind ?? 'account_deletion';
  const contactEmail = address(body.contact_email),
    loginEmail = address(body.login_email);
  const hint = clean(body.account_hint), message = clean(body.message);
  if (
    kind !== 'account_deletion' || !contactEmail || !loginEmail ||
    [...hint].length > 200 || [...message].length > 1000
  ) return null;
  return { kind, contactEmail, loginEmail, hint, message };
}

const fail = (error: string, status: number) => response({ error }, status);

/** Runs one mail; logs only the request id, never an address or a link. */
const mail = (what: string, id: string, send: () => Promise<boolean>) =>
  send().then((sent) => {
    if (!sent) console.error(`support-request: no ${what} for ${id}`);
  }).catch(() => console.error(`support-request: ${what} failed for ${id}`));

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

  // Made whether or not the email matches, so both take the same steps.
  let secret: Secret, submitted: Submitted;
  try {
    secret = await deps.secret();
    submitted = await deps.submit(submission, network, secret.hash);
  } catch (error) {
    const message = (error as { message?: unknown })?.message;
    if (message === 'support.rate_limited') {
      return fail('support.rate_limited', 429);
    }
    if (message === 'request.invalid') return fail('request.invalid', 400);
    return fail('server.unavailable', 503);
  }
  const { id } = submitted;
  // In the background, so a match does not answer later than a miss.
  const mails = [
    mail(
      'receipt',
      id,
      () => deps.mailer.receipt({ id, email: submission.contactEmail }),
    ),
  ];
  if (submitted.mail === 'confirm') {
    const link = deps.confirmLink(id, secret.secret);
    mails.push(
      mail(
        'confirmation',
        id,
        () =>
          link
            ? deps.mailer.confirm({ id, email: submission.loginEmail, link })
            : Promise.resolve(false),
      ),
    );
  } else if (submitted.mail === 'status' && submitted.scheduledAt) {
    const scheduledAt = submitted.scheduledAt;
    mails.push(
      mail(
        'state mail',
        id,
        () =>
          deps.mailer.status({ id, email: submission.loginEmail, scheduledAt }),
      ),
    );
  }
  deps.background(Promise.all(mails));
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
