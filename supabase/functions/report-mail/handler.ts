// report-mail: tells the support inbox (SUPPORT_MAIL_TO, ops@) about each
// new inappropriate-content report (#280). The mail carries only the report
// id and the admin review link: no content, spot, reporter or contributor.
// pg_cron and the insert itself call it through pg_net with the shared
// REPORT_MAIL_SECRET (public.report_mail_tick(), migration
// 202611021100_content_reports.sql); a notice not sent waits for the next.
import { response } from '../_shared/http.ts';
import { sameSecret } from '../account-deletion/handler.ts';

/** Notices sent per call; the rest wait for the next. */
export const batchSize = 50;

/**
 * new: a new report; fuse: the site-wide limit on immediate hides tripped
 * (#280 layer 3), later reports only wait for review.
 */
export type NoticeKind = 'new' | 'fuse';
export type Notice = { id: string; kind: NoticeKind };

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

/** The notice: the report id and the admin page link, nothing else. */
export function reportNoticeMail(id: string, adminUrl: string) {
  return {
    subject: `【機車停車指南】新的內容不當檢舉 ${id.slice(0, 8)}`,
    text: [
      '有一筆新的內容不當檢舉，請在 24 小時內確認並處理。',
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
