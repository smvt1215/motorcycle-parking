import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { appCheckConfig, verifyAppCheck } from '../_shared/app_check.ts';
import { trustedIp } from '../_shared/client_ip.ts';
import { response } from '../_shared/http.ts';
import { identityHash } from '../submit-report/validate.ts';
import { confirmToken, newSecret } from '../_shared/support_token.ts';
import { handle, type RiderMailer, silentRiderMailer } from './handler.ts';
import {
  confirmMail,
  receiptMail,
  resendConfig,
  resendNotifier,
  resendSender,
  sendMail,
  statusMail,
} from './resend.ts';

declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    secret = Deno.env.get('REPORT_HASH_SECRET'),
    header = Deno.env.get('TRUSTED_IP_HEADER'),
    adminBase = Deno.env.get('ADMIN_SUPPORT_URL'),
    // The site's confirmation page (#285), e.g.
    // https://motoparking.smvtstudio.com/account-deletion/confirm; the token
    // goes in the fragment, so it reaches no server log.
    confirmBase = Deno.env.get('SUPPORT_CONFIRM_URL')?.trim();
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
  const env = (name: string) => Deno.env.get(name);
  const sender = resendSender(env);
  const mailer: RiderMailer = sender
    ? {
      async receipt({ id, email }) {
        await sendMail(
          sender,
          { to: [email], ...receiptMail(id) },
          `support-receipt/${id}`,
        );
        return true;
      },
      async confirm({ id, email, link }) {
        await sendMail(
          sender,
          { to: [email], ...confirmMail(link) },
          `support-confirm/${id}`,
        );
        return true;
      },
      async status({ id, email, scheduledAt }) {
        await sendMail(
          sender,
          { to: [email], ...statusMail(scheduledAt) },
          `support-status/${id}`,
        );
        return true;
      },
    }
    : silentRiderMailer;
  return handle(req, {
    appCheck: (token) => verifyAppCheck(token, appCheck),
    async networkHash(req) {
      // TRUSTED_IP_HEADER is cf-connecting-ip on Supabase, as submit-report.
      const ip = trustedIp(req, header);
      return ip ? await identityHash(secret, `ip:${ip}`) : null;
    },
    secret: () => newSecret(),
    async submit(s, network, tokenHash) {
      const { data, error } = await db.rpc('support_request_submit', {
        p_kind: s.kind,
        p_contact_email: s.contactEmail,
        p_login_email: s.loginEmail,
        p_hint: s.hint,
        p_message: s.message,
        p_ip_hash: network,
        p_token_hash: tokenHash,
      });
      if (error) throw error;
      const row = data as {
        id: string;
        mail: string | null;
        scheduled_at: string | null;
      };
      return {
        id: String(row.id),
        mail: row.mail === 'confirm' || row.mail === 'status' ? row.mail : null,
        scheduledAt: row.scheduled_at ?? null,
      };
    },
    async notified(id) {
      const { error } = await db.rpc('support_request_notified', { p_id: id });
      if (error) throw error;
    },
    // Resend (T269_Q4_MAILER); without its settings nothing is sent and
    // the admin page is where new requests show.
    notifier: resendNotifier(resendConfig(env)),
    mailer,
    confirmLink: (id, secret) =>
      confirmBase ? `${confirmBase}#token=${confirmToken(id, secret)}` : null,
    background: (task) => EdgeRuntime.waitUntil(task),
    adminUrl: (id) => `${adminBase.replace(/\/$/, '')}/${id}`,
  });
});
