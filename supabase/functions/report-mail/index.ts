import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { resendConfig, sendMail } from '../support-request/resend.ts';
import { handle, reportNoticeMail } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    // The admin site's review page, e.g. https://<admin>/review; the
    // report id is appended.
    reviewBase = Deno.env.get('ADMIN_REVIEW_URL')?.trim().replace(/\/$/, '');
  if (!url || !key) return response({ error: 'server.unavailable' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Resend and SUPPORT_MAIL_TO, as support-request; without them, or
  // without the review link, nothing is sent and the notices wait.
  const config = resendConfig((name) => Deno.env.get(name));
  return handle(req, {
    secret: Deno.env.get('REPORT_MAIL_SECRET') ?? '',
    async pending(limit) {
      const { data, error } = await db.rpc('report_mail_pending', {
        p_limit: limit,
      });
      if (error) throw error;
      return ((data ?? []) as { id: string }[]).map((r) => r.id);
    },
    async send(id) {
      if (!config || !reviewBase) return false;
      await sendMail(
        config,
        { to: config.to, ...reportNoticeMail(id, `${reviewBase}/${id}`) },
        // A retry of the same notice is not sent twice (kept 24 hours).
        `content-report/${id}`,
      );
      return true;
    },
    async sent(id) {
      const { error } = await db.rpc('report_mail_sent', { p_id: id });
      if (error) throw error;
    },
  });
});
