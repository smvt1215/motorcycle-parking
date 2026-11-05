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

export type Deps = {
  /** REPORT_MAIL_SECRET; empty when unset. */
  secret: string;
  /** The ids of reports not yet notified, oldest first. */
  pending(limit: number): Promise<string[]>;
  /** False when no mail service or admin link is configured: not sent. */
  send(id: string): Promise<boolean>;
  sent(id: string): Promise<void>;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return response({ error: 'request.invalid' }, 405);
  if (
    !deps.secret ||
    !sameSecret(req.headers.get('x-report-mail-secret') ?? '', deps.secret)
  ) {
    return response({ error: 'auth.forbidden' }, 403);
  }
  let ids: string[];
  try {
    ids = await deps.pending(batchSize);
  } catch {
    return response({ error: 'server.unavailable' }, 503);
  }
  let sent = 0, failed = 0, skipped = 0;
  for (const id of ids) {
    try {
      if (!(await deps.send(id))) {
        skipped++;
        continue;
      }
      await deps.sent(id);
      sent++;
    } catch {
      // Unmarked, so the next call retries.
      failed++;
      console.error(`report-mail: notice failed for ${id}`);
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
