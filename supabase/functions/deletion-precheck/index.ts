import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { createRemoteJWKSet } from 'npm:jose@6.2.13';
import { appCheckConfig, verifyAppCheck } from '../_shared/app_check.ts';
import { trustedIp } from '../_shared/client_ip.ts';
import { response } from '../_shared/http.ts';
import { identityHash } from '../submit-report/validate.ts';
import {
  handle,
  jwksUrls,
  precheckConfig,
  type Provider,
  RateLimited,
} from './handler.ts';

// Kept across requests in one isolate, so the keys are cached (jose: 10
// minutes, a missing kid refetched at most every 30 seconds).
const keySets = {
  google: createRemoteJWKSet(new URL(jwksUrls.google)),
  apple: createRemoteJWKSet(new URL(jwksUrls.apple)),
};

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    secret = Deno.env.get('REPORT_HASH_SECRET'),
    header = Deno.env.get('TRUSTED_IP_HEADER');
  // The same web app as the support form (PM_NOTICE_20261105_190): the
  // deletion page's App Check app ids are SUPPORT_APP_CHECK_APP_IDS.
  const appCheck = appCheckConfig((name) =>
    Deno.env.get(
      name === 'APP_CHECK_APP_IDS' ? 'SUPPORT_APP_CHECK_APP_IDS' : name,
    )
  );
  if (!url || !key || !secret || !header || !appCheck) {
    return response({ error: 'server.unavailable' }, 503);
  }
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    config: precheckConfig((name) => Deno.env.get(name)),
    appCheck: (token) => verifyAppCheck(token, appCheck),
    async networkHash(req) {
      // TRUSTED_IP_HEADER is cf-connecting-ip on Supabase, as submit-report.
      const ip = trustedIp(req, header);
      return ip ? await identityHash(secret, `ip:${ip}`) : null;
    },
    async attempt(network) {
      const { error } = await db.rpc('deletion_precheck_attempt', {
        p_ip_hash: network,
      });
      if (error?.message === 'deletion_precheck.rate_limited') {
        throw new RateLimited();
      }
      if (error) throw error;
    },
    keys: (provider: Provider) => keySets[provider],
    async hasAccount(provider, sub) {
      const { data, error } = await db.rpc('deletion_precheck_has_account', {
        p_provider: provider,
        p_sub: sub,
      });
      if (error) throw error;
      return data === true;
    },
    now: () => new Date(),
  });
});
