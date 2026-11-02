import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import {
  appCheckConfig,
  appCheckMode,
  verifyAppCheck,
} from '../_shared/app_check.ts';
import { trustedIp } from '../_shared/client_ip.ts';
import { cors, readBody, response } from '../_shared/http.ts';
import { appCheckGate } from './app_check_gate.ts';
import { currentSpot } from './current_spot.ts';
import { blocking, precheck, precheckResponse, riskFlags } from './precheck.ts';
import {
  identityHash,
  proposedConditionComplete,
  segmentPatchesStated,
  spotDeletedResponse,
  validate,
  zonePatchesStated,
} from './validate.ts';
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') {
    return response({ error: 'method not allowed' }, 405);
  }
  const authorization = req.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) {
    return response({ error: 'sign-in required' }, 401);
  }
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const secret = Deno.env.get('REPORT_HASH_SECRET'),
    header = Deno.env.get('TRUSTED_IP_HEADER');
  if (!url || !key || !secret || !header) {
    return response({ error: 'report service not configured' }, 503);
  }
  // TRUSTED_IP_HEADER is cf-connecting-ip on Supabase (docs/CD_SETUP.md).
  const ip = trustedIp(req, header);
  if (!ip) {
    return response({ error: 'trusted client IP unavailable' }, 503);
  }
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user || data.user.is_anonymous) {
    return response({ error: 'Google or Apple sign-in required' }, 401);
  }
  // App Check (#203): APP_CHECK_MODE log (the default) only records the
  // verdict; enforce refuses a request without a valid token.
  const appCheck = appCheckConfig((name) => Deno.env.get(name));
  const gate = await appCheckGate(
    req,
    appCheckMode(Deno.env.get('APP_CHECK_MODE')),
    (token) =>
      appCheck ? verifyAppCheck(token, appCheck) : Promise.resolve(null),
  );
  if (gate.refused) return response({ error: 'app check required' }, 401);
  try {
    const body = await readBody(req);
    const invalid = validate(body);
    if (invalid) return response({ error: invalid }, 400);
    // Contradictions and personal data come back with what to change; the
    // client's own precheck is only a hint and is never trusted.
    const current = await currentSpot(admin, body);
    // A zone or segment the suggestion changes states both vehicles once
    // applied (#201; segments since #188 layer 2).
    const proposed = body.proposed as Record<string, unknown> | undefined;
    if (
      proposed &&
      (!proposedConditionComplete(proposed, current) ||
        !zonePatchesStated(proposed.parking_zones, current?.parking_zones) ||
        !segmentPatchesStated(
          proposed.parking_segments,
          current?.parking_segments,
        ))
    ) return response({ error: 'invalid proposed' }, 400);
    const issues = precheck(body, current);
    const refused = blocking(issues);
    if (refused.length) return response(precheckResponse(refused), 400);
    const { data: result, error: rpcError } = await admin.rpc('apply_report', {
      p_user: data.user.id,
      p_ip: await identityHash(secret, `ip:${ip}`),
      p_device: await identityHash(secret, `device:${body.device_id}`),
      // A hold goes through flagged for stricter review (§4.3); the flags
      // are always the server's own, never a client's.
      p_payload: { ...body, risk_flags: riskFlags(issues) },
      // The network's daily cap holds until App Check is enforced (#203).
      p_ip_capped: gate.ipCapped,
    });
    if (rpcError?.code === 'P0410') {
      // An admin deleted the spot (#200): nothing a rider sends reaches it.
      return response(spotDeletedResponse, 410);
    }
    if (rpcError?.code === 'P0409') {
      // One open inappropriate-content report per rider and spot (#280).
      return response({ error: 'duplicate report' }, 409);
    }
    if (rpcError) {
      return response(
        {
          error: rpcError.code === 'P0001'
            ? 'daily report limit reached'
            : rpcError.code === '42501'
            ? 'report not permitted'
            : 'invalid report',
        },
        rpcError.code === 'P0001' ? 429 : rpcError.code === '42501' ? 403 : 400,
      );
    }
    return response(result);
  } catch {
    return response({ error: 'invalid report' }, 400);
  }
});
