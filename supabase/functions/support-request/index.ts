import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { appCheckConfig, verifyAppCheck } from '../_shared/app_check.ts';
import { trustedIp } from '../_shared/client_ip.ts';
import { response } from '../_shared/http.ts';
import { identityHash } from '../submit-report/validate.ts';
import { handle, silentNotifier } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    secret = Deno.env.get('REPORT_HASH_SECRET'),
    header = Deno.env.get('TRUSTED_IP_HEADER'),
    adminBase = Deno.env.get('ADMIN_SUPPORT_URL');
  // The web page's App Check app ids, apart from the App's
  // (APP_CHECK_APP_IDS): only the deletion page may use this form.
  const appCheck = appCheckConfig((name) =>
    Deno.env.get(
      name === 'APP_CHECK_APP_IDS' ? 'SUPPORT_APP_CHECK_APP_IDS' : name,
    )
  );
  if (!url || !key || !secret || !header || !adminBase || !appCheck) {
    return response({ error: 'server.unavailable' }, 503);
  }
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    appCheck: (token) => verifyAppCheck(token, appCheck),
    async networkHash(req) {
      // TRUSTED_IP_HEADER is cf-connecting-ip on Supabase, as submit-report.
      const ip = trustedIp(req, header);
      return ip ? await identityHash(secret, `ip:${ip}`) : null;
    },
    async submit(s, network) {
      const { data, error } = await db.rpc('support_request_submit', {
        p_kind: s.kind,
        p_email: s.email,
        p_hint: s.hint,
        p_message: s.message,
        p_ip_hash: network,
      });
      if (error) throw error;
      return String(data);
    },
    async notified(id) {
      const { error } = await db.rpc('support_request_notified', { p_id: id });
      if (error) throw error;
    },
    // The mail service is still to be chosen (T269_Q4_MAILER); until then
    // the admin page is where new requests show.
    notifier: silentNotifier,
    adminUrl: (id) => `${adminBase.replace(/\/$/, '')}/${id}`,
  });
});
