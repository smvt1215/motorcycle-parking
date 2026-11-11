import { cors, readBody, response } from '../_shared/http.ts';
import {
  type Candidate,
  type LatLng,
  type Provider,
  ProviderError,
  readRequest,
  readReverse,
  type ReverseProvider,
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
  // Counts the request against the caller's daily limit for [quota]: a
  // search and a reverse lookup each have their own (#434). Throws
  // [LimitReached] when that day's limit is used. Nothing is cached: Google
  // allows address text in a cache only for the rider who asked, and never
  // in place of another call (Service Specific Terms 6.3.2, #411).
  count(caller: Caller, quota: Quota): Promise<void>;
  // Null until a provider is configured (docs/ADMIN_WEB.md 後端變更 7).
  provider: Provider | null;
  // Same key as [provider]; null until it is configured.
  reverse: ReverseProvider | null;
}

// Which daily limit a request counts against (public.geocode_count).
export type Quota = 'search' | 'reverse';

// Either limit answers `daily_limit`: each endpoint only reports its own.
export class LimitReached extends Error {}

const fail = (error: string, status: number) => response({ error }, status);

async function reverse(
  at: LatLng,
  caller: Caller,
  deps: Deps,
): Promise<Response> {
  if (!deps.reverse) return fail('not_configured', 503);
  try {
    await deps.count(caller, 'reverse');
  } catch (e) {
    if (e instanceof LimitReached) return fail('daily_limit', 429);
    return fail('unavailable', 503);
  }
  try {
    return response(await deps.reverse(at));
  } catch (e) {
    if (e instanceof ProviderError && e.reason === 'quota') {
      return fail('service_limit', 503);
    }
    return fail('unavailable', 502);
  }
}

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
  const at = readReverse(body);
  if (typeof at === 'string') return fail(at, 400);
  if (at) return reverse(at, caller, deps);
  const request = readRequest(body);
  if (typeof request === 'string') return fail(request, 400);
  try {
    await deps.count(caller, 'search');
  } catch (e) {
    if (e instanceof LimitReached) return fail('daily_limit', 429);
    return fail('unavailable', 503);
  }
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
  return response({ kind: request.query.kind, candidates });
}
