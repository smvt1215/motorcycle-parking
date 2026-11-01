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
//
// It also sends the administrators' answers to cases (#295):
// admin_v1.reply_support_request queues one and calls support_mail_tick().
// Each try gets a new case link (30 days) and a new Reply-To
// reply+<token>@ token, whose hashes are stored before the mail goes; the
// result (Resend's id, or why it failed) is kept on the message, and a failed
// one is retried up to 5 times.
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

/** A queued answer to a case (#295). */
export type Outbound = {
  id: string;
  request_id: string;
  /** The case email: the contact email, or a privacy request's login email. */
  to_email: string;
  body: string;
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
  /** Claims queued answers (#295). */
  outbound(limit: number): Promise<Outbound[]>;
  /** A new reply token for the Reply-To. */
  newReplyToken(): Promise<Secret>;
  /** Stores the link's and the reply token's hashes; false when unclaimed. */
  setCaseTokens(
    id: string,
    linkHash: string,
    replyHash: string,
  ): Promise<boolean>;
  /** The case page with the token; null when not configured. */
  caseLink(requestId: string, secret: string): string | null;
  /** reply+<token>@ the reply domain. */
  replyAddress(token: string): string;
  /**
   * Sends one answer: Resend's id (null when it gives none), or false when
   * no mail service is configured.
   */
  sendAnswer(
    answer: Outbound,
    caseLink: string | null,
    replyTo: string,
    tokenHash: string,
  ): Promise<string | null | false>;
  /** Records the result; error is a short reason, never an address. */
  answered(
    id: string,
    sent: boolean,
    resendId: string | null,
    error: string | null,
  ): Promise<void>;
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
  const answers = await sendAnswers(deps).catch(() => null);
  if (!answers) return response({ error: 'server.unavailable' }, 503);
  return response({ sent, failed, skipped, answers });
}

/** A short reason for the record: never an address or the text. */
const reason = (error: unknown) => {
  const message = (error as { message?: unknown })?.message;
  return typeof message === 'string' && /^resend \d{3}$/.test(message)
    ? message
    : 'send failed';
};

async function sendAnswers(deps: Deps) {
  const answers = await deps.outbound(batchSize);
  let sent = 0, failed = 0, skipped = 0;
  for (const answer of answers) {
    try {
      const link = await deps.newSecret(), reply = await deps.newReplyToken();
      if (!(await deps.setCaseTokens(answer.id, link.hash, reply.hash))) {
        skipped++;
        continue;
      }
      let resendId: string | null | false;
      try {
        resendId = await deps.sendAnswer(
          answer,
          deps.caseLink(answer.request_id, link.secret),
          deps.replyAddress(reply.secret),
          link.hash,
        );
      } catch (error) {
        failed++;
        console.error(`support-mail: answer failed for ${answer.id}`);
        await deps.answered(answer.id, false, null, reason(error));
        continue;
      }
      if (resendId === false) {
        // No mail service: left claimed, retried after 15 minutes.
        skipped++;
        continue;
      }
      await deps.answered(answer.id, true, resendId, null);
      sent++;
    } catch {
      failed++;
      console.error(`support-mail: answer failed for ${answer.id}`);
    }
  }
  return { sent, failed, skipped };
}
