import {
  type AppCheckMode,
  appCheckRefuses,
  type AppCheckResult,
  appCheckToken,
} from '../_shared/app_check.ts';
import { trustedIp } from '../_shared/client_ip.ts';
import { cors, readBody, response } from '../_shared/http.ts';
import {
  suspendedRefusal,
  suspendedResponse,
  type Suspension,
} from '../_shared/suspension.ts';
import { type Sighting, validate } from './validate.ts';

/** An error the database raised, as supabase-js reports it. */
export interface RpcError {
  code?: string;
  message?: string;
  details?: string | null;
}

export interface Deps {
  /** The account behind a token the Auth server accepts. */
  user(token: string): Promise<{ id: string; anonymous: boolean } | null>;
  /** Keyed hash of a network or device, as submit-report stores them. */
  hash(value: string): Promise<string>;
  /** apply_sighting() with the service role. */
  apply(args: {
    user: string;
    ip: string;
    device: string;
    sighting: Sighting;
    /**
     * Whether the network's daily cap applies: while App Check only logs.
     * Once it is enforced the network count is a risk signal instead (#203).
     */
    ipCapped: boolean;
  }): Promise<
    { data?: Record<string, unknown> | null; error?: RpcError | null }
  >;
  /** public.suspension_status() with the service role (#331). */
  suspension(user: string): Promise<Suspension>;
  /**
   * The App Check verdict on the request's token (#203); null when App Check
   * is not configured.
   */
  appCheck?(token: string | null): Promise<AppCheckResult | null>;
  /** APP_CHECK_MODE: off, log (the default) or enforce. */
  appCheckMode?: AppCheckMode;
}

/** What the app reads from a refusal of the database. */
export function refusal(error: RpcError): [string, number] {
  const message = error.message ?? '';
  if (error.code === 'P0001') {
    return message.includes('10 minutes')
      ? ['sighting too soon', 429]
      : ['daily sighting limit reached', 429];
  }
  if (error.code === '42501') {
    return message.includes('suspended')
      ? ['sighting suspended', 403]
      : ['report not permitted', 403];
  }
  if (message.includes('spot not found')) return ['spot not found', 404];
  if (message.includes('area not found')) return ['area not found', 404];
  return ['invalid sighting', 400];
}

export async function handle(
  req: Request,
  deps: Deps | null,
  ipHeader: string | null,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') {
    return response({ error: 'method not allowed' }, 405);
  }
  const authorization = req.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) {
    return response({ error: 'sign-in required' }, 401);
  }
  if (!deps || !ipHeader) {
    return response({ error: 'sighting service not configured' }, 503);
  }
  const ip = trustedIp(req, ipHeader);
  if (!ip) return response({ error: 'trusted client IP unavailable' }, 503);
  try {
    const user = await deps.user(authorization.slice(7));
    if (!user || user.anonymous) {
      return response({ error: 'Google or Apple sign-in required' }, 401);
    }
    const mode = deps.appCheckMode ?? 'off';
    if (mode !== 'off') {
      const verdict = deps.appCheck
        ? await deps.appCheck(appCheckToken(req))
        : null;
      if (appCheckRefuses('submit-sighting', mode, verdict)) {
        return response({ error: 'app check required' }, 401);
      }
    }
    // A suspended account still signs in and manages itself; only App
    // writes are refused (#331).
    const status = await deps.suspension(user.id);
    if (status.suspended) return suspendedResponse(status.until);
    let sighting: Sighting | string;
    try {
      sighting = validate(await readBody(req));
    } catch {
      sighting = 'invalid sighting';
    }
    if (typeof sighting === 'string') {
      return response({ error: sighting }, 400);
    }
    const { data, error } = await deps.apply({
      user: user.id,
      ip: await deps.hash(`ip:${ip}`),
      device: await deps.hash(`device:${sighting.device_id}`),
      sighting,
      ipCapped: mode !== 'enforce',
    });
    if (error) {
      const suspended = suspendedRefusal(error);
      if (suspended) return suspendedResponse(suspended.until);
      const [message, code] = refusal(error);
      return response({ error: message }, code);
    }
    if (typeof data?.suspended_until === 'string') {
      // The flood rule suspended the account for 7 days in the same
      // transaction (#331); a longer suspension an admin set is kept.
      let until: string | null = data.suspended_until;
      try {
        until = (await deps.suspension(user.id)).until;
      } catch {
        // The suspension holds; the rule's own end is close enough.
      }
      return suspendedResponse(until);
    }
    return response({
      accepted: true,
      closure_suggested: data?.closure_suggested === true,
    });
  } catch {
    return response({ error: 'sighting service unavailable' }, 503);
  }
}
