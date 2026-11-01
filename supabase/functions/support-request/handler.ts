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
//
// Cases (#295): the form also takes a general question (general), a data
// error or infringement (data_issue), a report or appeal (complaint) and a
// personal data request (privacy: access, correction or copy). A general
// kind has only the contact email: its receipt carries the case link (the
// one-time secret, 30 days) and a Reply-To reply+<token>@ (only the hashes
// are stored), so the rider can add to the same case. A privacy request
// works as the deletion does: only the login email's owner, through the
// one-time link, makes it answerable, and the answers go only there; the
// contact email gets the fixed receipt.
import { cors, readBody, response } from '../_shared/http.ts';
import type { AppCheckResult } from '../_shared/app_check.ts';
import type { Secret } from '../_shared/support_token.ts';

export const kinds = [
  'general',
  'data_issue',
  'complaint',
  'privacy',
  'account_deletion',
] as const;
export type Kind = typeof kinds[number];
export const privacyRights = ['access', 'correction', 'copy'] as const;
export type PrivacyRight = typeof privacyRights[number];
/** The kinds whose identity the login email's owner confirms (#285). */
export const verified = (kind: Kind) =>
  kind === 'account_deletion' || kind === 'privacy';

export type Submission = {
  kind: Kind;
  contactEmail: string;
  /** Only for account_deletion and privacy. */
  loginEmail: string | null;
  /** Only for privacy. */
  privacyRight: PrivacyRight | null;
  subject: string;
  hint: string;
  message: string;
};

/**
 * How administrators hear about a new case or a rider's reply (#295);
 * replaceable (T269_Q4_MAILER). Only the case id and the admin page link.
 */
export type Notice = {
  id: string;
  adminUrl: string;
  /** A rider's reply (its message id); a new case without. */
  replyId?: string;
};
export interface Notifier {
  /** False when no mail service is configured: nothing was sent. */
  notify(notice: Notice): Promise<boolean>;
}

/** No mail service yet: requests still show on the admin page. */
export const silentNotifier: Notifier = {
  notify: () => Promise.resolve(false),
};

/** Mail to the person who filled in the form (#285, #295). */
export interface RiderMailer {
  /** The fixed receipt to the contact email. False: nothing was sent. */
  receipt(mail: { id: string; email: string; kind: Kind }): Promise<boolean>;
  /** A general case's receipt: the case link and the reply address. */
  caseReceipt(
    mail: {
      id: string;
      email: string;
      kind: Kind;
      link: string | null;
      replyTo: string;
    },
  ): Promise<boolean>;
  /** The one-time link to the login email. False: nothing was sent. */
  confirm(
    mail: { id: string; email: string; link: string; kind: Kind },
  ): Promise<boolean>;
  /**
   * The account is already in the cooling-off period: when it goes, and a
   * one-time 取消刪除 link (null when the cancel page is not configured).
   */
  status(
    mail: {
      id: string;
      email: string;
      scheduledAt: string;
      cancelLink: string | null;
    },
  ): Promise<boolean>;
}

export const silentRiderMailer: RiderMailer = {
  receipt: () => Promise.resolve(false),
  caseReceipt: () => Promise.resolve(false),
  confirm: () => Promise.resolve(false),
  status: () => Promise.resolve(false),
};

/** What the database stored, and which mail the login email gets. */
export type Submitted = {
  id: string;
  mail: 'confirm' | 'status' | 'case' | null;
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
  /** A new reply token (#295), for a general case. */
  replyToken(): Promise<Secret>;
  submit(
    s: Submission,
    networkHash: string,
    tokenHash: string,
    replyHash: string | null,
  ): Promise<Submitted>;
  notified(id: string): Promise<void>;
  notifier: Notifier;
  mailer: RiderMailer;
  /** The confirmation page with the token; null when it is not configured. */
  confirmLink(id: string, secret: string): string | null;
  /** The 取消刪除 page with the token; null when it is not configured. */
  cancelLink(id: string, secret: string): string | null;
  /** The case page with the token; null when it is not configured. */
  caseLink(id: string, secret: string): string | null;
  /** reply+<token>@ the reply domain. */
  replyAddress(token: string): string;
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
  const kind = (body.kind ?? 'account_deletion') as Kind;
  if (!kinds.includes(kind)) return null;
  const contactEmail = address(body.contact_email);
  const loginEmail = verified(kind) ? address(body.login_email) : null;
  const privacyRight = kind === 'privacy'
    ? (privacyRights.includes(body.privacy_right as PrivacyRight)
      ? body.privacy_right as PrivacyRight
      : null)
    : null;
  const hint = clean(body.account_hint),
    message = clean(body.message),
    subject = clean(body.subject).replace(/\s+/g, ' ');
  if (
    !contactEmail || (verified(kind) && !loginEmail) ||
    // Only the kinds that use them may send them.
    (!verified(kind) && body.login_email !== undefined &&
      body.login_email !== null && body.login_email !== '') ||
    (kind === 'privacy') !== (privacyRight !== null) ||
    (kind !== 'privacy' && body.privacy_right !== undefined &&
      body.privacy_right !== null) ||
    [...hint].length > 200 || [...subject].length > 120 ||
    [...message].length > (kind === 'account_deletion' ? 1000 : 4000) ||
    // A question needs its text.
    (!verified(kind) && message === '')
  ) return null;
  return {
    kind,
    contactEmail,
    loginEmail,
    privacyRight,
    subject,
    hint,
    message,
  };
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
  let secret: Secret, reply: Secret | null = null, submitted: Submitted;
  try {
    secret = await deps.secret();
    if (!verified(submission.kind)) reply = await deps.replyToken();
    submitted = await deps.submit(
      submission,
      network,
      secret.hash,
      reply?.hash ?? null,
    );
  } catch (error) {
    const message = (error as { message?: unknown })?.message;
    if (message === 'support.rate_limited') {
      return fail('support.rate_limited', 429);
    }
    if (message === 'request.invalid') return fail('request.invalid', 400);
    return fail('server.unavailable', 503);
  }
  const { id } = submitted;
  const { kind } = submission;
  const loginEmail = submission.loginEmail ?? '';
  // In the background, so a match does not answer later than a miss.
  const mails = [
    submitted.mail === 'case' && reply
      ? mail('receipt', id, () =>
        deps.mailer.caseReceipt({
          id,
          email: submission.contactEmail,
          kind,
          link: deps.caseLink(id, secret.secret),
          replyTo: deps.replyAddress(reply.secret),
        }))
      : mail(
        'receipt',
        id,
        () => deps.mailer.receipt({ id, email: submission.contactEmail, kind }),
      ),
  ];
  if (submitted.mail === 'confirm' && loginEmail) {
    const link = deps.confirmLink(id, secret.secret);
    mails.push(
      mail(
        'confirmation',
        id,
        () =>
          link
            ? deps.mailer.confirm({ id, email: loginEmail, link, kind })
            : Promise.resolve(false),
      ),
    );
  } else if (
    submitted.mail === 'status' && submitted.scheduledAt && loginEmail
  ) {
    const scheduledAt = submitted.scheduledAt;
    // The stored secret is the cancel link's (#295).
    const cancelLink = deps.cancelLink(id, secret.secret);
    mails.push(
      mail(
        'state mail',
        id,
        () =>
          deps.mailer.status({
            id,
            email: loginEmail,
            scheduledAt,
            cancelLink,
          }),
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
