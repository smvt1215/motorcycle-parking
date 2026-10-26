import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { handle } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) {
    return response({ error: 'user service not configured' }, 503);
  }
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    async caller(token) {
      // getUser asks the Auth server: the session is live and not banned,
      // and the role is the account's current one, not a stale token's.
      const { data, error } = await admin.auth.getUser(token);
      if (error || !data.user) return null;
      // aal exists only in the token; getClaims verifies its signature.
      const { data: claims, error: claimsError } = await admin.auth.getClaims(
        token,
      );
      if (claimsError || !claims || claims.claims.sub !== data.user.id) {
        return null;
      }
      return {
        id: data.user.id,
        admin: data.user.app_metadata?.role === 'admin' &&
          claims.claims.app_metadata?.role === 'admin',
        aal: String(claims.claims.aal ?? ''),
      };
    },
    async target(id) {
      const { data, error } = await admin.auth.admin.getUserById(id);
      if (error || !data.user) return null;
      return {
        id: data.user.id,
        admin: data.user.app_metadata?.role === 'admin',
        bannedUntil: data.user.banned_until ?? null,
      };
    },
    async setBan(id, duration) {
      const { data, error } = await admin.auth.admin.updateUserById(id, {
        ban_duration: duration,
      });
      if (error || !data.user) throw error ?? new Error('no user');
      return data.user.banned_until ?? null;
    },
    async record(entry) {
      const { error } = await admin.rpc('admin_record_user_ban', {
        p_actor: entry.actor,
        p_user: entry.user,
        p_action: entry.action,
        p_before: entry.before,
        p_after: entry.after,
        p_duration: entry.duration,
        p_note: entry.note,
      });
      if (error) throw error;
    },
    now: () => new Date(),
  });
});
