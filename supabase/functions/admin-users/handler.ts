import { cors, readBody, response } from '../_shared/http.ts';

/** Who called, from a token the Auth server accepted. */
export interface Caller {
  id: string;
  /** `app_metadata.role` of the account now and in the token. */
  admin: boolean;
  aal: string;
}

export interface Target {
  id: string;
  admin: boolean;
}

/** One suspension change, written with its audit entry in one call. */
export interface SuspensionChange {
  actor: string;
  user: string;
  action: 'ban' | 'unban';
  /** 7d, 30d or indefinite; null to lift it. */
  duration: string | null;
  note: string;
}

export interface Deps {
  caller(token: string): Promise<Caller | null>;
  target(id: string): Promise<Target | null>;
  /**
   * public.admin_set_user_suspension() (#331): an App-level suspension in
   * private.user_suspensions, not an Auth ban, so the account can still sign
   * in and delete itself. Returns the new `banned_until` (null when lifted;
   * 9999-12-31 when indefinite).
   */
  suspend(change: SuspensionChange): Promise<string | null>;
}

/** The choices the admin page offers. */
export const durations = ['7d', '30d', 'indefinite'];

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface BanRequest {
  action: 'ban' | 'unban';
  userId: string;
  duration: string | null;
  reason: string;
}

export function parse(body: Record<string, unknown>): BanRequest | string {
  const { action, user_id: userId, duration, reason } = body;
  if (action !== 'ban' && action !== 'unban') return 'unknown action';
  if (typeof userId !== 'string' || !uuid.test(userId)) {
    return 'invalid user id';
  }
  const note = typeof reason === 'string' ? reason.trim() : '';
  if (note.length < 1 || [...note].length > 500) {
    return 'a reason of 1–500 characters is required';
  }
  if (action === 'ban') {
    if (typeof duration !== 'string' || !durations.includes(duration)) {
      return 'invalid duration';
    }
    return { action, userId, duration, reason: note };
  }
  return { action, userId, duration: null, reason: note };
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  try {
    return await serve(req, deps);
  } catch {
    return response({ error: 'user service unavailable' }, 503);
  }
}

async function serve(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') {
    return response({ error: 'method not allowed' }, 405);
  }
  const authorization = req.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) {
    return response({ error: 'sign-in required' }, 401);
  }
  const caller = await deps.caller(authorization.slice(7));
  if (!caller) return response({ error: 'sign-in required' }, 401);
  // Same rule as is_admin(): the admin role and a second factor.
  if (!caller.admin || caller.aal !== 'aal2') {
    return response({ error: 'admin with a second factor required' }, 403);
  }
  let request: BanRequest | string;
  try {
    request = parse(await readBody(req));
  } catch {
    request = 'invalid request';
  }
  if (typeof request === 'string') return response({ error: request }, 400);
  if (request.userId.toLowerCase() === caller.id.toLowerCase()) {
    return response({ error: 'you cannot ban your own account' }, 400);
  }
  const target = await deps.target(request.userId);
  if (!target) return response({ error: 'user not found' }, 404);
  if (target.admin) {
    return response({ error: 'administrators cannot be banned here' }, 403);
  }
  let after: string | null;
  try {
    after = await deps.suspend({
      actor: caller.id,
      user: target.id,
      action: request.action,
      duration: request.duration,
      note: request.reason,
    });
  } catch {
    return response({ error: 'the ban could not be changed' }, 502);
  }
  return response({ user_id: target.id, banned_until: after });
}
