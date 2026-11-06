import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import {
  confirmToken,
  newReplyToken,
  newSecret,
  replyAddress,
} from '../_shared/support_token.ts';
import {
  inboundReceiptMail,
  resendConfig,
  resendNotifier,
  resendSender,
  sendMail,
} from '../support-request/resend.ts';
import { type Filed, handle } from './handler.ts';

declare const EdgeRuntime: { waitUntil(task: Promise<unknown>): void };

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    adminBase = Deno.env.get('ADMIN_SUPPORT_URL'),
    // https://motoparking.smvtstudio.com/support/case (docs/CD_SETUP.md).
    caseBase = Deno.env.get('SUPPORT_CASE_URL')?.trim();
  if (!url || !key || !adminBase) {
    return response({ error: 'server.unavailable' }, 503);
  }
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const env = (name: string) => Deno.env.get(name);
  const sender = resendSender(env);
  return handle(req, {
    secret: Deno.env.get('SUPPORT_INBOUND_SECRET') ?? '',
    now: () => Math.floor(Date.now() / 1000),
    newSecret: () => newSecret(),
    newReplyToken: () => newReplyToken(),
    async file(mail, replyHash, keyHash, linkHash, newReplyHash) {
      const { data, error } = await db.rpc('support_inbound', {
        p_reply_hash: replyHash,
        p_from: mail.from,
        p_subject: mail.subject,
        p_body: mail.text,
        p_spf: mail.spf,
        p_dkim: mail.dkim,
        p_attachments: mail.attachments,
        p_key_hash: keyHash,
        p_link_hash: linkHash,
        p_new_reply_hash: newReplyHash,
        p_dmarc: mail.dmarc,
      });
      if (error) throw error;
      return data as Filed;
    },
    async receipt({ id, email, link, replyTo, identity }) {
      if (!sender) return false;
      await sendMail(
        sender,
        { to: [email], replyTo, ...inboundReceiptMail(id, link, identity) },
        `support-receipt/${id}`,
      );
      return true;
    },
    caseLink: (id, secret) =>
      caseBase ? `${caseBase}#token=${confirmToken(id, secret)}` : null,
    replyAddress: (token) => replyAddress(token),
    notifier: resendNotifier(resendConfig(env)),
    adminUrl: (id) => `${adminBase.replace(/\/$/, '')}/${id}`,
    background: (task) => EdgeRuntime.waitUntil(task),
  });
});
