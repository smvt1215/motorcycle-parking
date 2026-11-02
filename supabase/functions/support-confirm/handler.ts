// support-confirm: the one-time link of a support request's confirmation
// mail (#285, PM_ANS_20261101_132). The site's confirmation page reads the
// token from the link's fragment and posts it here with an action:
//
//   view     opening the link: shows the request (submitted time, masked
//            contact email) and changes nothing, since mail scanners open
//            links on their own
//   confirm  "是我，請申請刪除": asks for the deletion right away (source
//            'support', the App's 7-day cooling-off period, signed out
//            everywhere, name hidden), then the notice goes to the login
//            email (PM_ANS_20261101_133)
//   deny     "不是我申請的": voids the request
//
// The deletion notice's 取消刪除 link (PM_ANS_20261101_138) posts here with
// `link: 'cancel'` and an action:
//
//   view     shows the deletion time and changes nothing
//   cancel   cancels as the App's 取消刪除 does (audited as support_link)
//
// with results pending (with scheduled_at), cancelled, not_pending (already
// cancelled), account_deleting.
//
// A personal data request (#295) uses the same link: confirm records that
// the login email's owner asked (result verified) and the case waits for
// the administrators' answer, which goes only to that login email. Every
// answer carries the request's kind (account_deletion or privacy), so the
// page (https://motoparking.smvtstudio.com/support/verify) words itself.
//
// Results for a good confirmation token: pending (view), deletion_requested (with
// scheduled_at), denied, resolved, account_deletion_pending (with
// scheduled_at), account_deleting, unavailable (an admin account). The
// person holding the token has shown they own the login email, so these
// say nothing to anyone else.
//
// public.support_request_link() (migration
// 202611012200_support_deletion_verify.sql) does the work. Every bad token
// (malformed, unknown, wrong, used, voided, expired) is the same 400, so the
// answer tells nothing about requests or accounts. The token is 32 random
// bytes, only ever in the request body, and never logged.
import { cors, readBody, response } from '../_shared/http.ts';
import { parseConfirmToken } from '../_shared/support_token.ts';

export const actions = ['view', 'confirm', 'deny'] as const;
export type Action = typeof actions[number];

export type LinkResult =
  | { result: 'invalid' }
  | {
    result:
      | 'pending'
      | 'verified'
      | 'deletion_requested'
      | 'denied'
      | 'resolved'
      | 'account_deletion_pending'
      | 'account_deleting'
      | 'unavailable';
    kind: 'account_deletion' | 'privacy';
    /** A privacy request's item, subject and text; null for a deletion. */
    privacy_right?: 'access' | 'correction' | 'copy' | null;
    subject?: string | null;
    message?: string | null;
    submitted_at: string;
    contact_email: string;
    scheduled_at: string | null;
  };

export const cancelActions = ['view', 'cancel'] as const;
export type CancelAction = typeof cancelActions[number];

export type CancelResult =
  | { result: 'invalid' }
  | {
    result: 'pending' | 'cancelled' | 'not_pending' | 'account_deleting';
    scheduled_at: string | null;
  };

export type Deps = {
  link(id: string, tokenHash: string, action: Action): Promise<LinkResult>;
  cancel(
    id: string,
    tokenHash: string,
    action: CancelAction,
  ): Promise<CancelResult>;
};

/** `r***@e***.tw`: enough to recognise one's own address, no more. */
export function maskEmail(address: string): string {
  const at = address.lastIndexOf('@');
  if (at < 1) return '***';
  const local = address.slice(0, at), domain = address.slice(at + 1);
  const dot = domain.lastIndexOf('.');
  const host = dot > 0 ? domain.slice(0, dot) : domain,
    tld = dot > 0 ? domain.slice(dot) : '';
  return `${[...local][0]}***@${[...host][0] ?? ''}***${tld}`;
}

const fail = (error: string, status: number) => response({ error }, status);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('request.invalid', 405);

  let body: Record<string, unknown>;
  try {
    body = await readBody(req);
  } catch {
    return fail('request.invalid', 400);
  }
  const kind = body.link ?? 'confirm';
  const action = body.action ?? 'view';
  if (
    kind === 'cancel'
      ? !cancelActions.includes(action as CancelAction)
      : kind !== 'confirm' || !actions.includes(action as Action)
  ) return fail('request.invalid', 400);
  const token = await parseConfirmToken(body.token);
  if (!token) return fail('support.link_invalid', 400);
  if (kind === 'cancel') {
    let found: CancelResult;
    try {
      found = await deps.cancel(token.id, token.hash, action as CancelAction);
    } catch {
      return fail('server.unavailable', 503);
    }
    if (found.result === 'invalid') return fail('support.link_invalid', 400);
    return response({
      result: found.result,
      scheduled_at: found.scheduled_at ?? null,
    });
  }
  let found: LinkResult;
  try {
    found = await deps.link(token.id, token.hash, action as Action);
  } catch {
    return fail('server.unavailable', 503);
  }
  if (found.result === 'invalid') return fail('support.link_invalid', 400);
  return response({
    result: found.result,
    kind: found.kind,
    // What the owner of the login email is confirming (Codex review, #301).
    privacy_right: found.privacy_right ?? null,
    subject: found.subject ?? null,
    message: found.message ?? null,
    submitted_at: found.submitted_at,
    contact_email: maskEmail(found.contact_email),
    scheduled_at: found.scheduled_at ?? null,
  });
}
