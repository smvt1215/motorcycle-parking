import {
  type AppCheckMode,
  appCheckRefuses,
  type AppCheckResult,
  appCheckToken,
} from '../_shared/app_check.ts';
import { cors, readBody, response } from '../_shared/http.ts';
import { type Sighting, validate } from './validate.ts';

/** An error the database raised, as supabase-js reports it. */
export interface RpcError {
  code?: string;
  message?: string;
}

export interface Deps {
  /** The account behind a token the Auth server accepts (live, not banned). */
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
  /** Auth Admin API ban, as the admin-users function sets it. */
  ban(user: string, duration: string): Promise<string | null>;
  /**
   * The App Check verdict on the request's token (#203); null when App Check
   * is not configured.
   */
  appCheck?(token: string | null): Promise<AppCheckResult | null>;
  /** APP_CHECK_MODE: off, log (the default) or enforce. */
  appCheckMode?: AppCheckMode;
  /** admin_record_user_ban(): every ban change is audited. */
  record(entry: {
    user: string;
    after: string | null;
    duration: string;
    note: string;
  }): Promise<void>;
}

/** The flood rule's suspension: 7 days (decision 50). */
export const floodBan = '168h';
export const floodNote = '騎士回報洗版，自動停權 7 天（規則評分，決定 50）';

/** The client's network from the configured trusted header's last hop. */
export function trustedIp(req: Request, header: string): string | null {
  const ip = req.headers.get(header)?.split(',').at(-1)?.trim();
  return ip && /^[0-9a-f:.]+$/i.test(ip) ? ip : null;
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
      const [message, status] = refusal(error);
      return response({ error: message }, status);
    }
    if (typeof data?.suspended_until === 'string') {
      // The database already refuses this rider's sightings for 7 days; the
      // ban extends that to the whole account, as an admin's would.
      try {
        const after = await deps.ban(user.id, floodBan);
        await deps.record({
          user: user.id,
          after,
          duration: '7d',
          note: floodNote,
        });
      } catch {
        // The sighting refusal holds without it.
      }
      return response({ error: 'sighting suspended' }, 403);
    }
    return response({
      accepted: true,
      closure_suggested: data?.closure_suggested === true,
    });
  } catch {
    return response({ error: 'sighting service unavailable' }, 503);
  }
}
