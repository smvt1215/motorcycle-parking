// report-mail: tells the support inbox (SUPPORT_MAIL_TO, ops@) about each
// new inappropriate-content report (#280). The mail carries only the report
// id and the link to its case on the admin site's 待處理 page (#449): no
// content, spot, reporter or contributor.
// pg_cron and the insert itself call it through pg_net with the shared
// REPORT_MAIL_SECRET (public.report_mail_tick(), migration
// 202611021100_content_reports.sql); a notice not sent waits for the next.
import { response } from '../_shared/http.ts';
import { sameSecret } from '../account-deletion/handler.ts';
import { ResendError } from '../support-request/resend.ts';

/** Notices sent per call; the rest wait for the next. */
export const batchSize = 50;

/**
 * new: a new report; fuse: the site-wide limit on immediate hides tripped
 * (#280 layer 3), later reports only wait for review.
 */
export type NoticeKind = 'new' | 'fuse';
/**
 * id: the report (queue) id. case_id: the 待處理 case it is in now, the
 * earliest open report on the same spot and target (migration
 * 202611121000_report_mail_case_link.sql); null once it is resolved, and
 * missing before that migration.
 */
export type Notice = { id: string; kind: NoticeKind; case_id?: string | null };

export type Deps = {
  /** REPORT_MAIL_SECRET; empty when unset. */
  secret: string;
  /** The notices not yet sent, oldest first. */
  pending(limit: number): Promise<Notice[]>;
  /** False when no mail service or admin link is configured: not sent. */
  send(notice: Notice): Promise<boolean>;
  sent(notice: Notice): Promise<void>;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return response({ error: 'request.invalid' }, 405);
  if (
    !deps.secret ||
    !sameSecret(req.headers.get('x-report-mail-secret') ?? '', deps.secret)
  ) {
    return response({ error: 'auth.forbidden' }, 403);
  }
  let notices: Notice[];
  try {
    notices = await deps.pending(batchSize);
  } catch {
    return response({ error: 'server.unavailable' }, 503);
  }
  let sent = 0, failed = 0, skipped = 0;
  for (const notice of notices) {
    try {
      if (!(await deps.send(notice))) {
        skipped++;
        continue;
      }
      await deps.sent(notice);
      sent++;
    } catch {
      // Unmarked, so the next call retries.
      failed++;
      console.error(
        `report-mail: ${notice.kind} notice failed for ${notice.id}`,
      );
    }
  }
  return response({ sent, failed, skipped });
}

/**
 * Where 待處理 lives: ADMIN_PENDING_URL (https://<admin>/pending), or, so a
 * project still set up with ADMIN_REVIEW_URL (https://<admin>/review) keeps
 * sending, the same site's /pending. Hosting serves 待處理 at /pending on
 * the admin origin (firebase.json, admin_web/react/vite.config.ts). Null when
 * the one in use is not an http(s) URL, or ADMIN_PENDING_URL has a query or
 * a fragment (the case id could not follow it): nothing is sent and the
 * notices wait, as with no link set.
 */
export function pendingBase(
  env: (name: string) => string | undefined,
): string | null {
  const pending = env('ADMIN_PENDING_URL')?.trim();
  if (pending) {
    const url = webUrl(pending);
    if (!url || pending.includes('?') || pending.includes('#')) return null;
    return `${url.origin}${url.pathname.replace(/\/+$/, '')}`;
  }
  const review = env('ADMIN_REVIEW_URL')?.trim();
  const url = review ? webUrl(review) : null;
  return url ? `${url.origin}/pending` : null;
}

function webUrl(value: string): URL | null {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url : null;
  } catch {
    return null;
  }
}

/**
 * Resend already took a mail under this notice's key within 24 hours, with
 * other text: the link follows the case at send time, so a retry after an
 * unmarked send can differ (the case was resolved, or a deploy changed the
 * link). The notice went out, so it is marked sent rather than failing every
 * run and going out again once the key expires. A concurrent send under the
 * same key (concurrent_idempotent_requests) is still a failure, retried.
 */
export function alreadySent(error: unknown): boolean {
  return error instanceof ResendError && error.status === 409 &&
    error.code === 'invalid_idempotent_request';
}

/** The case's page; the list when the report is no longer in an open case. */
export function caseLink(base: string, notice: Notice): string {
  return notice.case_id
    ? `${base}/${encodeURIComponent(notice.case_id)}`
    : base;
}

/** The notice: the report id and the admin page link, nothing else. */
export function reportNoticeMail(id: string, adminUrl: string) {
  return {
    subject: `【機車停車指南】新的內容不當檢舉 ${id.slice(0, 8)}`,
    text: [
      '有一筆新的內容不當檢舉，請在 5 個工作天內確認並處理。',
      '',
      `檢舉編號：${id}`,
      `處理：${adminUrl}`,
      '',
      '檢舉內容只在管理站顯示，本信不含點位、內容或任何人的資料。',
    ].join('\n'),
  };
}

/** The site-wide limit tripped: later reports wait for review, unhidden. */
export function fuseNoticeMail(id: string, adminUrl: string) {
  return {
    subject: '【機車停車指南】內容不當檢舉：立即暫時隱藏已達每日上限',
    text: [
      '過去 24 小時內，因檢舉而立即暫時隱藏的內容已達 20 次。之後的檢舉不會立即隱藏，只進審核，請盡快確認是否有人集體檢舉。',
      '',
      `觸發的檢舉編號：${id}`,
      `處理：${adminUrl}`,
      '',
      '本信不含點位、內容或任何人的資料。',
    ].join('\n'),
  };
}
