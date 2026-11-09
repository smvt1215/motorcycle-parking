import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { handle } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return response({ error: 'server.unavailable' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    secret: Deno.env.get('CASE_ACTIONS_SECRET') ?? '',
    now: () => Date.now(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    async run() {
      const { data, error } = await db.rpc('run_due_case_actions');
      if (error) throw error;
      return data;
    },
  });
});
