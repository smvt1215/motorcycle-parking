import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { googleProvider } from './google.ts';
import { handle, LimitReached } from './handler.ts';
import type { Candidate, Provider } from './query.ts';

// Google Geocoding (docs/ADMIN_WEB.md 後端變更 7). Without the secret every
// search answers `not_configured`; the key never leaves this function.
const googleKey = Deno.env.get('GOOGLE_GEOCODING_API_KEY');
const provider: Provider | null = googleKey ? googleProvider(googleKey) : null;

// The payload of a token the Auth server has just accepted.
function claims(token: string): Record<string, unknown> {
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const json = new TextDecoder().decode(
      Uint8Array.from(atob(part), (c) => c.charCodeAt(0)),
    );
    return JSON.parse(json);
  } catch {
    return {};
  }
}

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) {
    return response({ error: 'not_configured' }, 503);
  }
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    provider,
    async caller(token) {
      const { data, error } = await admin.auth.getUser(token);
      if (error || !data.user || data.user.is_anonymous) return null;
      // Same rule as public.is_admin(): the admin role after a second factor.
      const c = claims(token);
      return {
        id: data.user.id,
        admin: data.user.app_metadata?.role === 'admin' && c.aal === 'aal2',
      };
    },
    async begin(caller, cacheKey) {
      const { data, error } = await admin.rpc('geocode_begin', {
        p_user: caller.id,
        p_admin: caller.admin,
        p_key: cacheKey,
      });
      if (error) throw error.code === 'P0001' ? new LimitReached() : error;
      return (data as Candidate[] | null) ?? null;
    },
    async store(cacheKey, candidates) {
      const { error } = await admin.rpc('geocode_store', {
        p_key: cacheKey,
        p_candidates: candidates,
      });
      if (error) throw error;
    },
  });
});
