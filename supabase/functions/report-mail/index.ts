import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { resendConfig, sendMail } from '../support-request/resend.ts';
import {
  caseLink,
  fuseNoticeMail,
  handle,
  type Notice,
  pendingBase,
  reportNoticeMail,
} from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    // The admin site's 待處理 page, e.g. https://<admin>/pending; the case
    // id is appended (/pending/:caseId).
    base = pendingBase((name) => Deno.env.get(name));
  if (!url || !key) return response({ error: 'server.unavailable' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Resend and SUPPORT_MAIL_TO, as support-request; without them, or
  // without the admin link, nothing is sent and the notices wait.
  const config = resendConfig((name) => Deno.env.get(name));
  return handle(req, {
    secret: Deno.env.get('REPORT_MAIL_SECRET') ?? '',
    async pending(limit) {
      const { data, error } = await db.rpc('report_mail_pending', {
        p_limit: limit,
      });
      if (error) throw error;
      return (data ?? []) as Notice[];
    },
    async send(notice) {
      if (!config || !base) return false;
      const { id, kind } = notice;
      const mail = kind === 'fuse' ? fuseNoticeMail : reportNoticeMail;
      await sendMail(
        config,
        { to: config.to, ...mail(id, caseLink(base, notice)) },
        // A retry of the same notice is not sent twice (kept 24 hours).
        `content-report/${kind}/${id}`,
      );
      return true;
    },
    async sent({ id, kind }) {
      const { error } = await db.rpc('report_mail_sent', {
        p_id: id,
        p_kind: kind,
      });
      if (error) throw error;
    },
  });
});
