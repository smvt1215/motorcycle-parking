import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import {
  appleConfig,
  handle,
  latestSignIn,
  signClientSecret,
} from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    anon = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !key || !anon) return response({ error: 'not configured' }, 503);
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    async caller(token) {
      // getUser asks the Auth server: the session is live and the account
      // still exists; amr exists only in the token (getClaims verifies it).
      const { data, error } = await admin.auth.getUser(token);
      if (error || !data.user || data.user.is_anonymous) return null;
      const { data: claims, error: claimsError } = await admin.auth.getClaims(
        token,
      );
      if (claimsError || !claims || claims.claims.sub !== data.user.id) {
        return null;
      }
      return {
        id: data.user.id,
        apple: (data.user.identities ?? []).some((i) => i.provider === 'apple'),
        signedInAt: latestSignIn(claims.claims.amr),
      };
    },
    async canSelfDelete(token) {
      const asCaller = createClient(url, anon, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${token}` } },
      });
      const { data, error } = await asCaller.schema('api_v1').rpc(
        'account_deletion_status',
      );
      if (error) throw error;
      return (data as { can_self_delete?: unknown } | null)?.can_self_delete ===
        true;
    },
    config: appleConfig((name) => Deno.env.get(name)),
    clientSecret: signClientSecret,
    fetch: (url, init) => fetch(url, init),
    now: () => new Date(),
  });
});
