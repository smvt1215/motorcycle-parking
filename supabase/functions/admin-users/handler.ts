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
  /** ISO time; null or past when not banned. */
  bannedUntil: string | null;
}

export interface BanRecord {
  actor: string;
  user: string;
  action: 'ban_user' | 'unban_user';
  before: string | null;
  after: string | null;
  duration: string;
  note: string;
}

export interface Deps {
  caller(token: string): Promise<Caller | null>;
  target(id: string): Promise<Target | null>;
  /** Auth Admin API `ban_duration`; returns the new `banned_until`. */
  setBan(id: string, duration: string): Promise<string | null>;
  record(entry: BanRecord): Promise<void>;
  now(): Date;
}

/** The choices the admin page offers; Go durations for `ban_duration`. */
export const durations: Record<string, string> = {
  '7d': '168h',
  '30d': '720h',
  // About 100 years: until an admin lifts it.
  'indefinite': '876000h',
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface BanRequest {
  action: 'ban' | 'unban';
  userId: string;
  duration: string;
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
    if (typeof duration !== 'string' || !Object.hasOwn(durations, duration)) {
      return 'invalid duration';
    }
    return { action, userId, duration: durations[duration], reason: note };
  }
  return { action, userId, duration: 'none', reason: note };
}

/** What restores [before] if the audit entry cannot be written. */
export function restoreDuration(before: string | null, now: Date): string {
  if (!before) return 'none';
  const ms = Date.parse(before) - now.getTime();
  return ms > 0 ? `${Math.ceil(ms / 3_600_000)}h` : 'none';
}

/** The same ban end, whatever the timestamp's notation. */
export const sameBan = (a: string | null, b: string | null) =>
  a === null || b === null ? a === b : Date.parse(a) === Date.parse(b);

const active = (until: string | null, now: Date) =>
  until !== null && Date.parse(until) > now.getTime();

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
  const now = deps.now();
  const before = active(target.bannedUntil, now) ? target.bannedUntil : null;
  let after: string | null;
  try {
    after = await deps.setBan(target.id, request.duration);
  } catch {
    return response({ error: 'the ban could not be changed' }, 502);
  }
  if (!active(after, now)) after = null;
  try {
    await deps.record({
      actor: caller.id,
      user: target.id,
      action: request.action === 'ban' ? 'ban_user' : 'unban_user',
      before,
      after,
      duration: request.duration,
      note: request.reason,
    });
  } catch {
    // Every ban change is audited: undo one that cannot be, unless another
    // request changed the ban since; its newer value is kept.
    try {
      const latest = await deps.target(target.id);
      const current = latest && active(latest.bannedUntil, now)
        ? latest.bannedUntil
        : null;
      if (!sameBan(current, after)) {
        return response(
          { error: 'audit failed; a newer change was kept' },
          500,
        );
      }
      await deps.setBan(target.id, restoreDuration(before, now));
    } catch {
      return response(
        { error: 'audit failed and the change could not be undone' },
        500,
      );
    }
    return response({ error: 'audit failed; the change was undone' }, 500);
  }
  return response({ user_id: target.id, banned_until: after });
}
