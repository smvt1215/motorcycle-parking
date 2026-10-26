import { cors, readBody, response } from '../_shared/http.ts';
import {
  cacheKey,
  type Candidate,
  type Provider,
  ProviderError,
  readRequest,
  shape,
} from './query.ts';

export interface Caller {
  id: string;
  admin: boolean;
}

// Everything the handler needs from outside, so tests run without Supabase
// or a geocoding provider.
export interface Deps {
  // The signed-in, non-anonymous caller of a valid token; null otherwise.
  caller(token: string): Promise<Caller | null>;
  // Counts the request against the caller's daily limit and returns fresh
  // cached candidates. Throws [LimitReached] when the day's limit is used.
  begin(caller: Caller, key: string): Promise<Candidate[] | null>;
  store(key: string, candidates: Candidate[]): Promise<void>;
  // Null until a provider is configured (docs/ADMIN_WEB.md 後端變更 7).
  provider: Provider | null;
}

export class LimitReached extends Error {}

const fail = (error: string, status: number) => response({ error }, status);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('method_not_allowed', 405);
  const authorization = req.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) {
    return fail('sign_in_required', 401);
  }
  if (!deps.provider) return fail('not_configured', 503);
  let caller: Caller | null;
  try {
    caller = await deps.caller(authorization.slice(7));
  } catch {
    return fail('unavailable', 503);
  }
  if (!caller) return fail('sign_in_required', 401);
  let body: Record<string, unknown>;
  try {
    body = await readBody(req);
  } catch {
    return fail('invalid_query', 400);
  }
  const request = readRequest(body);
  if (typeof request === 'string') return fail(request, 400);
  const key = cacheKey(request.query, request.near);
  let cached: Candidate[] | null;
  try {
    cached = await deps.begin(caller, key);
  } catch (e) {
    if (e instanceof LimitReached) return fail('daily_limit', 429);
    return fail('unavailable', 503);
  }
  const kind = request.query.kind;
  if (cached) return response({ kind, candidates: cached });
  let candidates: Candidate[];
  try {
    candidates = shape(await deps.provider(request.query, request.near));
  } catch (e) {
    // The provider's own daily cap is shared by everyone: say so, rather
    // than blaming this caller's limit.
    if (e instanceof ProviderError && e.reason === 'quota') {
      return fail('service_limit', 503);
    }
    return fail('unavailable', 502);
  }
  // A failed cache write only costs a later provider call.
  await deps.store(key, candidates).catch(() => {});
  return response({ kind, candidates });
}
