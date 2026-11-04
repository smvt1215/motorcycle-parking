import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { confirmToken, newSecret } from '../_shared/support_token.ts';
import {
  deletionNoticeMail,
  resendSender,
  sendMail,
} from '../support-request/resend.ts';
import { handle, type Notice } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    // The site's cancel page, e.g.
    // https://motoparking.smvtstudio.com/account-deletion/cancel; the token
    // goes in the fragment, so it reaches no server log.
    cancelBase = Deno.env.get('SUPPORT_CANCEL_URL')?.trim();
  if (!url || !key) return response({ error: 'server.unavailable' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Resend (T269_Q4_MAILER); without it nothing is sent and the notices
  // wait.
  const sender = resendSender((name) => Deno.env.get(name));
  return handle(req, {
    secret: Deno.env.get('SUPPORT_MAIL_SECRET') ?? '',
    async notices(limit) {
      const { data, error } = await db.rpc('support_deletion_notices', {
        p_limit: limit,
      });
      if (error) throw error;
      return (data ?? []) as Notice[];
    },
    newSecret: () => newSecret(),
    async setCancelToken(id, tokenHash) {
      const { data, error } = await db.rpc('support_cancel_token', {
        p_id: id,
        p_token_hash: tokenHash,
      });
      if (error) throw error;
      return data === true;
    },
    cancelLink: (id, secret) =>
      cancelBase ? `${cancelBase}#token=${confirmToken(id, secret)}` : null,
    async send(notice, link, tokenHash) {
      if (!sender) return false;
      await sendMail(
        sender,
        {
          to: [notice.email],
          ...deletionNoticeMail(
            notice.scheduled_at,
            notice.apple === true,
            link,
          ),
        },
        // Per link: a retry with a new link is a new mail; the earlier
        // try's link no longer works.
        `support-deletion/${notice.id}/${tokenHash.slice(0, 16)}`,
      );
      return true;
    },
    async notified(id) {
      const { error } = await db.rpc('support_deletion_notified', { p_id: id });
      if (error) throw error;
    },
  });
});
