/**
 * Firebase App Check tokens on the write endpoints (#203): the app sends the
 * token in the X-Firebase-AppCheck header, never in the URL. This module only
 * says whether the token is valid; each endpoint decides from APP_CHECK_MODE
 * whether a failure is logged (log, the default while closed-beta builds come
 * from App Distribution and Play Integrity may fail) or refused (enforce).
 *
 * Verification follows Firebase's custom-backend steps: the App Check JWKS
 * (cached up to 6 hours), an RS256 signature, header typ JWT, issuer
 * https://firebaseappcheck.googleapis.com/<project number>, not expired,
 * audience projects/<project number>, and the subject (the app id) on the
 * allow list. Debug tokens from test devices and CI are exchanged by Firebase
 * for ordinary App Check tokens, so they pass the same checks.
 */

export const appCheckHeader = 'x-firebase-appcheck';
export const jwksUrl = 'https://firebaseappcheck.googleapis.com/v1/jwks';
/** Firebase asks backends to cache the keys for at most 6 hours. */
const maxKeyAgeMs = 6 * 60 * 60 * 1000;

export type AppCheckMode = 'off' | 'log' | 'enforce';

export interface AppCheckConfig {
  /** The Firebase project number (the issuer and audience use it). */
  projectNumber: string;
  /** App ids allowed as the token's subject (Android and iOS apps). */
  appIds: string[];
}

export type AppCheckResult =
  | { status: 'valid'; appId: string }
  | { status: 'missing' }
  | { status: 'invalid'; reason: string };

/** The mode from APP_CHECK_MODE; anything unknown is log. */
export function appCheckMode(value: string | undefined): AppCheckMode {
  return value === 'off' || value === 'enforce' ? value : 'log';
}

/**
 * The configuration from FIREBASE_PROJECT_NUMBER and APP_CHECK_APP_IDS
 * (comma separated), or null when either is missing.
 */
export function appCheckConfig(
  env: (name: string) => string | undefined,
): AppCheckConfig | null {
  const projectNumber = env('FIREBASE_PROJECT_NUMBER')?.trim();
  const appIds = (env('APP_CHECK_APP_IDS') ?? '').split(',')
    .map((id) => id.trim()).filter((id) => id !== '');
  if (!projectNumber || !/^\d+$/.test(projectNumber) || appIds.length === 0) {
    return null;
  }
  return { projectNumber, appIds };
}

/** The token a request carries, if any. */
export function appCheckToken(req: Request): string | null {
  const token = req.headers.get(appCheckHeader)?.trim();
  return token ? token : null;
}

interface Jwk extends JsonWebKey {
  kid?: string;
}

/** Where the keys come from; tests pass their own. */
export type FetchKeys = () => Promise<{ keys: Jwk[]; maxAgeMs: number }>;

/** The App Check JWKS and how long it may be cached (≤ 6 hours). */
export const fetchFirebaseKeys: FetchKeys = async () => {
  const res = await fetch(jwksUrl);
  if (!res.ok) throw new Error(`jwks ${res.status}`);
  const body = await res.json() as { keys?: Jwk[] };
  const age = /max-age=(\d+)/.exec(res.headers.get('cache-control') ?? '');
  const maxAgeMs = age ? Number(age[1]) * 1000 : maxKeyAgeMs;
  return { keys: body.keys ?? [], maxAgeMs };
};

/**
 * An unknown kid may be a rotated key, but anyone can send one: fetch again
 * for it at most once a minute while the cached keys are still fresh.
 */
const unknownKidRefetchMs = 60 * 1000;

let cache:
  | { keys: Map<string, CryptoKey>; until: number; fetched: number }
  | null = null;

/** Forget the cached keys (tests). */
export function resetAppCheckKeys() {
  cache = null;
}

async function keyFor(
  kid: string,
  fetchKeys: FetchKeys,
  now: number,
): Promise<CryptoKey | null> {
  const stale = !cache || cache.until <= now;
  const rotated = !!cache && !cache.keys.has(kid) &&
    now - cache.fetched >= unknownKidRefetchMs;
  if (stale || rotated) {
    const { keys, maxAgeMs } = await fetchKeys();
    const imported = new Map<string, CryptoKey>();
    for (const jwk of keys) {
      if (!jwk.kid || jwk.kty !== 'RSA') continue;
      imported.set(
        jwk.kid,
        await crypto.subtle.importKey(
          'jwk',
          { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
          { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
          false,
          ['verify'],
        ),
      );
    }
    cache = {
      keys: imported,
      until: now + Math.min(Math.max(maxAgeMs, 0), maxKeyAgeMs),
      fetched: now,
    };
  }
  return cache?.keys.get(kid) ?? null;
}

function base64url(part: string): Uint8Array<ArrayBuffer> {
  const b64 = part.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(b64 + '='.repeat((4 - b64.length % 4) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function json(part: string): Record<string, unknown> {
  const value = JSON.parse(new TextDecoder().decode(base64url(part)));
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('not an object');
  }
  return value;
}

/** Whether token is a valid App Check token for config. */
export async function verifyAppCheck(
  token: string | null,
  config: AppCheckConfig,
  options: { fetchKeys?: FetchKeys; now?: number } = {},
): Promise<AppCheckResult> {
  if (!token) return { status: 'missing' };
  const now = options.now ?? Date.now();
  const parts = token.split('.');
  if (parts.length !== 3) return { status: 'invalid', reason: 'malformed' };
  let header: Record<string, unknown>, payload: Record<string, unknown>;
  try {
    header = json(parts[0]);
    payload = json(parts[1]);
  } catch {
    return { status: 'invalid', reason: 'malformed' };
  }
  if (header.alg !== 'RS256') return { status: 'invalid', reason: 'alg' };
  if (header.typ !== 'JWT') return { status: 'invalid', reason: 'typ' };
  if (typeof header.kid !== 'string') {
    return { status: 'invalid', reason: 'kid' };
  }
  let key: CryptoKey | null;
  try {
    key = await keyFor(header.kid, options.fetchKeys ?? fetchFirebaseKeys, now);
  } catch {
    return { status: 'invalid', reason: 'keys unavailable' };
  }
  if (!key) return { status: 'invalid', reason: 'kid' };
  let signed: boolean;
  try {
    signed = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      key,
      base64url(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
  } catch {
    signed = false;
  }
  if (!signed) return { status: 'invalid', reason: 'signature' };
  const project = config.projectNumber;
  if (payload.iss !== `https://firebaseappcheck.googleapis.com/${project}`) {
    return { status: 'invalid', reason: 'iss' };
  }
  if (typeof payload.exp !== 'number' || payload.exp * 1000 <= now) {
    return { status: 'invalid', reason: 'expired' };
  }
  const aud = payload.aud;
  if (!Array.isArray(aud) || !aud.includes(`projects/${project}`)) {
    return { status: 'invalid', reason: 'aud' };
  }
  if (typeof payload.sub !== 'string' || !config.appIds.includes(payload.sub)) {
    return { status: 'invalid', reason: 'sub' };
  }
  return { status: 'valid', appId: payload.sub };
}

/**
 * Whether the endpoint should refuse the request: only in enforce mode, and
 * only when the token is not valid. Every outcome except off is logged as one
 * line without the token, the user or the network.
 */
export function appCheckRefuses(
  endpoint: string,
  mode: AppCheckMode,
  result: AppCheckResult | null,
): boolean {
  if (mode === 'off') return false;
  const status = result?.status ?? 'unconfigured';
  console.log(JSON.stringify({
    event: 'app_check',
    endpoint,
    mode,
    status,
    ...(result?.status === 'invalid' ? { reason: result.reason } : {}),
    ...(result?.status === 'valid' ? { app_id: result.appId } : {}),
  }));
  return mode === 'enforce' && status !== 'valid';
}
