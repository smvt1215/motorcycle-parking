// availability-ingest: fetches the Taipei parking office's live counts and
// stores them through the service-role functions of migration
// 202610270140_availability_p2.sql. pg_cron calls it every five minutes
// with the shared secret; nobody else can.
import { response } from '../_shared/http.ts';
import {
  type ParkCapacity,
  type ParkCounts,
  parseTaipeiAvailability,
  parseTaipeiCapacities,
} from './taipei.ts';

export const sourceKey = 'taipei_tcmsv';

/** Capacities change rarely: the 2.9 MB description is read a few times a day. */
export const capacityMaxAge = 6 * 3600_000;

/** A source time further ahead than this is in the future. */
export const clockSkew = 60_000;

const maxBytes = 20 * 1024 * 1024;

export type Source = {
  key: string;
  enabled: boolean;
  feed_url: string;
  capacity_url: string | null;
  etag: string | null;
  next_attempt_at: string | null;
  capacity_updated_at: string | null;
};

export type Outcome =
  | 'ok'
  | 'unchanged'
  | 'skipped'
  | 'out_of_order'
  | 'error';

export type Deps = {
  /** AVAILABILITY_INGEST_SECRET; empty when unset. */
  secret: string;
  now(): Date;
  fetch(url: string, init: RequestInit): Promise<Response>;
  sleep(ms: number): Promise<void>;
  source(key: string): Promise<Source | null>;
  storeCapacities(key: string, rows: ParkCapacity[]): Promise<void>;
  ingest(
    key: string,
    updatedAt: Date,
    parks: ParkCounts[],
    etag: string | null,
  ): Promise<{ outcome: Outcome; rows: number }>;
  record(key: string, outcome: Outcome, message: string): Promise<void>;
};

/** Compares in time independent of where the strings differ. */
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

class FetchError extends Error {}

/**
 * One GET with a timeout, retried once after a short pause when the
 * network fails or the server answers 429/5xx. A 304 is returned as is.
 */
export async function fetchRetry(
  deps: Pick<Deps, 'fetch' | 'sleep'>,
  url: string,
  headers: Record<string, string> = {},
): Promise<Response> {
  let last = '';
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) await deps.sleep(2000);
    try {
      const res = await deps.fetch(url, {
        headers,
        signal: AbortSignal.timeout(20_000),
      });
      if (res.status === 429 || res.status >= 500) {
        last = `HTTP ${res.status}`;
        await res.body?.cancel();
        continue;
      }
      return res;
    } catch (error) {
      last = error instanceof Error ? error.name : 'fetch failed';
    }
  }
  throw new FetchError(`${new URL(url).pathname}: ${last}`);
}

async function text(res: Response, url: string): Promise<string> {
  if (!res.ok) {
    await res.body?.cancel();
    throw new FetchError(`${new URL(url).pathname}: HTTP ${res.status}`);
  }
  const length = Number(res.headers.get('content-length') ?? 0);
  if (length > maxBytes) throw new FetchError('response too large');
  const body = new TextDecoder('utf-8').decode(await res.arrayBuffer());
  if (body.length > maxBytes) throw new FetchError('response too large');
  return body;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return response({ error: 'POST only' }, 405);
  if (!deps.secret) return response({ error: 'not configured' }, 503);
  if (!sameSecret(req.headers.get('x-ingest-secret') ?? '', deps.secret)) {
    return response({ error: 'forbidden' }, 403);
  }
  const key = sourceKey;
  const now = deps.now();
  const source = await deps.source(key);
  if (!source || !source.enabled) {
    return response({ outcome: 'skipped', reason: 'disabled' });
  }
  if (source.next_attempt_at && Date.parse(source.next_attempt_at) > +now) {
    await deps.record(key, 'skipped', 'backoff');
    return response({ outcome: 'skipped', reason: 'backoff' });
  }
  const notes: string[] = [];
  try {
    const capacityAge = source.capacity_updated_at
      ? +now - Date.parse(source.capacity_updated_at)
      : Infinity;
    if (source.capacity_url && capacityAge > capacityMaxAge) {
      try {
        const res = await fetchRetry(deps, source.capacity_url);
        const rows = parseTaipeiCapacities(
          await text(res, source.capacity_url),
        );
        if (rows.length === 0) throw new FetchError('no capacities');
        await deps.storeCapacities(key, rows);
      } catch (error) {
        // Old capacities still judge the counts; none at all cannot.
        if (!source.capacity_updated_at) throw error;
        notes.push(`capacities kept: ${message(error)}`);
      }
    }
    const res = await fetchRetry(
      deps,
      source.feed_url,
      source.etag ? { 'If-None-Match': source.etag } : {},
    );
    if (res.status === 304) {
      await res.body?.cancel();
      await deps.record(
        key,
        'unchanged',
        ['not modified', ...notes].join('; '),
      );
      return response({ outcome: 'unchanged' });
    }
    const feed = parseTaipeiAvailability(await text(res, source.feed_url));
    if (!feed.updatedAt) throw new FetchError('no UPDATETIME');
    if (+feed.updatedAt > +now + clockSkew) {
      throw new FetchError(
        `UPDATETIME in the future: ${feed.updatedAt.toISOString()}`,
      );
    }
    if (feed.parks.length === 0) throw new FetchError('no PARK rows');
    const result = await deps.ingest(
      key,
      feed.updatedAt,
      feed.parks,
      res.headers.get('etag'),
    );
    return response({
      ...result,
      source_updated_at: feed.updatedAt.toISOString(),
      ...(notes.length ? { notes } : {}),
    });
  } catch (error) {
    const text = [message(error), ...notes].join('; ');
    try {
      await deps.record(key, 'error', text);
    } catch {
      // The log is best effort; the response still says what failed.
    }
    return response({ outcome: 'error', error: text }, 502);
  }
}

function message(error: unknown): string {
  if (error instanceof FetchError) return error.message;
  if (error instanceof SyntaxError) return 'unreadable response';
  if (error instanceof Error) return error.message.slice(0, 300);
  // A PostgREST error is a plain object with a message.
  const text = (error as { message?: unknown } | null)?.message;
  return typeof text === 'string' ? text.slice(0, 300) : 'failed';
}
