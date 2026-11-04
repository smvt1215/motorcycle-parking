// support-mail: tells the account's login email that its deletion was asked
// for through the confirmation link (#285): the deletion time, that signing
// in to the App and choosing 取消刪除 within the 7 days cancels it, a one-time
// 取消刪除 link valid through the cooling-off period (PM_ANS_20261101_138)
// and, for an Apple account, how to remove Sign in with Apple themselves
// (the token cannot be revoked without the owner signing in). Confirming
// the link (public.support_request_link, migration
// 202611012200_support_deletion_verify.sql) calls public.support_mail_tick(),
// which posts here through pg_net with the shared SUPPORT_MAIL_SECRET;
// pg_cron does the same every 15 minutes for notices that were not sent.
import { response } from '../_shared/http.ts';
import type { Secret } from '../_shared/support_token.ts';
import { sameSecret } from '../account-deletion/handler.ts';

/** Notices sent per call; the rest wait for the next. */
export const batchSize = 50;

export type Notice = {
  id: string;
  /** The account's login email, never the contact email. */
  email: string;
  scheduled_at: string;
  /** The account signs in with Apple: the notice says how to stop that. */
  apple: boolean;
};

export type Deps = {
  /** SUPPORT_MAIL_SECRET; empty when unset. */
  secret: string;
  notices(limit: number): Promise<Notice[]>;
  /** A new one-time secret for the cancel link. */
  newSecret(): Promise<Secret>;
  /** Stores the cancel link's hash; false when the deletion is gone. */
  setCancelToken(id: string, tokenHash: string): Promise<boolean>;
  /** The site's cancel page with the token; null when not configured. */
  cancelLink(id: string, secret: string): string | null;
  /**
   * False when no mail service is configured: nothing was sent. tokenHash
   * tells one try's mail from another's (the idempotency key).
   */
  send(
    notice: Notice,
    cancelLink: string | null,
    tokenHash: string,
  ): Promise<boolean>;
  notified(id: string): Promise<void>;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return response({ error: 'request.invalid' }, 405);
  if (
    !deps.secret ||
    !sameSecret(req.headers.get('x-support-mail-secret') ?? '', deps.secret)
  ) {
    return response({ error: 'auth.forbidden' }, 403);
  }
  let notices: Notice[];
  try {
    notices = await deps.notices(batchSize);
  } catch {
    return response({ error: 'server.unavailable' }, 503);
  }
  let sent = 0, failed = 0, skipped = 0;
  for (const notice of notices) {
    try {
      // A new link for every try: an earlier try's mail was not sent.
      const secret = await deps.newSecret();
      if (!(await deps.setCancelToken(notice.id, secret.hash))) {
        skipped++;
        continue;
      }
      const link = deps.cancelLink(notice.id, secret.secret);
      if (!(await deps.send(notice, link, secret.hash))) {
        skipped++;
        continue;
      }
      await deps.notified(notice.id);
      sent++;
    } catch {
      // Unmarked, so the next call retries; no email or link in the log.
      failed++;
      console.error(`support-mail: notice failed for ${notice.id}`);
    }
  }
  return response({ sent, failed, skipped });
}
