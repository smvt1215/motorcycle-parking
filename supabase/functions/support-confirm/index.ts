import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { type CancelResult, handle, type LinkResult } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return response({ error: 'server.unavailable' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    async link(id, tokenHash, action) {
      const { data, error } = await db.rpc('support_request_link', {
        p_id: id,
        p_token_hash: tokenHash,
        p_action: action,
      });
      if (error) throw error;
      return data as LinkResult;
    },
    async cancel(id, tokenHash, action) {
      const { data, error } = await db.rpc('support_cancel_link', {
        p_id: id,
        p_token_hash: tokenHash,
        p_action: action,
      });
      if (error) throw error;
      return data as CancelResult;
    },
  });
});
