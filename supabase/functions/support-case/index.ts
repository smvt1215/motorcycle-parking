import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { resendConfig, resendNotifier } from '../support-request/resend.ts';
import { type CaseResult, handle } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    adminBase = Deno.env.get('ADMIN_SUPPORT_URL');
  if (!url || !key || !adminBase) {
    return response({ error: 'server.unavailable' }, 503);
  }
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    async link(id, tokenHash, action, body) {
      const { data, error } = await db.rpc('support_case_link', {
        p_id: id,
        p_token_hash: tokenHash,
        p_action: action,
        p_body: body,
      });
      if (error) throw error;
      return data as CaseResult;
    },
    // Resend; without it nothing is sent and the admin page shows the reply.
    notifier: resendNotifier(resendConfig((name) => Deno.env.get(name))),
    adminUrl: (id) => `${adminBase.replace(/\/$/, '')}/${id}`,
  });
});
