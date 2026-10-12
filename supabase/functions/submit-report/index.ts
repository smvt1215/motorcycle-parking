import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { cors, readBody, response } from '../_shared/http.ts';
import { identityHash, validate } from './validate.ts';
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
  // Configure only a header overwritten/appended by the trusted ingress gateway.
  // Last hop avoids trusting client-prepended X-Forwarded-For values.
  const ip = req.headers.get(header)?.split(',').at(-1)?.trim();
  if (!ip || !/^[0-9a-f:.]+$/i.test(ip)) {
    return response({ error: 'trusted client IP unavailable' }, 503);
  }
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await admin.auth.getUser(authorization.slice(7));
  if (error || !data.user || data.user.is_anonymous) {
    return response({ error: 'Google or Apple sign-in required' }, 401);
  }
  try {
    const body = await readBody(req);
    const invalid = validate(body);
    if (invalid) return response({ error: invalid }, 400);
    const { data: result, error: rpcError } = await admin.rpc('apply_report', {
      p_user: data.user.id,
      p_ip: await identityHash(secret, `ip:${ip}`),
      p_device: await identityHash(secret, `device:${body.device_id}`),
      p_payload: body,
    });
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
