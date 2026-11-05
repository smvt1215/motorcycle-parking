// deletion-precheck: the account deletion page (#270, #268) asks, before it
// signs anyone in, whether a Google or Apple ID token belongs to an existing
// account (PM_ANS_20261105_185, _187). supabase.auth.signInWithIdToken
// creates an account for an identity it does not know, so the page only
// calls it when this answers has_account: true.
//
// The ID token is verified as Supabase Auth verifies it: the provider's JWKS
// signature, iss, aud (the web client id / Services ID), exp, and the nonce
// claim equal to the hex SHA-256 of the raw nonce the page sends. The token is
// not consumed (no jti is recorded): the page signs in with the same token
// next. Then auth.identities is looked up by provider + sub
// (public.deletion_precheck_has_account), and only a boolean comes back.
//
// Bots: a Firebase App Check token (reCAPTCHA Enterprise web provider, the
// same web app as support-request), always enforced, and 30 attempts an hour
// per network (public.deletion_precheck_attempt; the IP is only kept as an
// HMAC). The token, the sub and the IP are never logged.
import { errors, jwtVerify, type JWTVerifyGetKey } from 'npm:jose@6.2.13';
import { cors, readBody, response } from '../_shared/http.ts';
import type { AppCheckResult } from '../_shared/app_check.ts';

export type Provider = 'google' | 'apple';

export const issuers: Record<Provider, string[]> = {
  // Google signs with either form (Verify the Google ID token, Google
  // Identity Services).
  google: ['https://accounts.google.com', 'accounts.google.com'],
  apple: ['https://appleid.apple.com'],
};
export const jwksUrls: Record<Provider, string> = {
  google: 'https://www.googleapis.com/oauth2/v3/certs',
  apple: 'https://appleid.apple.com/auth/keys',
};

export type PrecheckConfig = {
  /** Accepted aud values per provider. */
  audiences: Record<Provider, string[]>;
};

/**
 * GOOGLE_WEB_CLIENT_ID (the web OAuth client the Supabase Google provider
 * accepts; comma separated if there are several) and APPLE_CLIENT_ID (the
 * Services ID, as apple-revoke); null when either is missing.
 */
export function precheckConfig(
  env: (name: string) => string | undefined,
): PrecheckConfig | null {
  const list = (name: string) =>
    (env(name) ?? '').split(',').map((v) => v.trim()).filter((v) => v !== '');
  const google = list('GOOGLE_WEB_CLIENT_ID'), apple = list('APPLE_CLIENT_ID');
  if (google.length === 0 || apple.length === 0) return null;
  return { audiences: { google, apple } };
}

export class RateLimited extends Error {
  constructor() {
    super('deletion_precheck.rate_limited');
  }
}

export type Deps = {
  config: PrecheckConfig | null;
  /** The App Check verdict for the request's token. */
  appCheck(token: string | null): Promise<AppCheckResult | null>;
  /** HMAC of the trusted client IP; null when the IP is unavailable. */
  networkHash(req: Request): Promise<string | null>;
  /** Records one attempt; throws RateLimited over the per-network limit. */
  attempt(networkHash: string): Promise<void>;
  /** The provider's signing keys (createRemoteJWKSet). */
  keys(provider: Provider): JWTVerifyGetKey;
  hasAccount(provider: Provider, sub: string): Promise<boolean>;
  now(): Date;
};

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  );
  return Array.from(
    new Uint8Array(digest),
    (b) => b.toString(16).padStart(2, '0'),
  )
    .join('');
}

const fail = (error: string, status: number) => response({ error }, status);

/** One line per outcome, without the token, the sub or the network. */
const log = (provider: string | null, outcome: string, reason?: string) =>
  console.log(JSON.stringify({
    event: 'deletion_precheck',
    provider,
    outcome,
    ...(reason ? { reason } : {}),
  }));

/** Why jose refused a token, or null when it could not check it at all. */
function refusal(error: unknown): string | null {
  if (error instanceof errors.JWKSTimeout) return null;
  if (error instanceof errors.JWKSInvalid) return null;
  if (error instanceof errors.JWTExpired) return 'exp';
  if (error instanceof errors.JWTClaimValidationFailed) {
    return error.claim.slice(0, 20);
  }
  // jose's generic error is a key set answer other than 200 OK.
  if (error instanceof errors.JOSEError && error.code !== 'ERR_JOSE_GENERIC') {
    return error.code.slice(0, 40);
  }
  // A failed key fetch (network, HTTP error from the provider).
  return null;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('request.invalid', 405);
  if (!deps.config) return fail('server.unavailable', 503);

  const verdict = await deps.appCheck(
    req.headers.get('x-firebase-appcheck')?.trim() || null,
  ).catch(() => null);
  if (!verdict) return fail('server.unavailable', 503);
  if (verdict.status !== 'valid') return fail('app_check.required', 401);

  const network = await deps.networkHash(req).catch(() => null);
  if (!network) return fail('server.unavailable', 503);

  // Every request that passed App Check counts, whatever its body.
  try {
    await deps.attempt(network);
  } catch (error) {
    if (error instanceof RateLimited) {
      log(null, 'rate_limited');
      return fail('rate_limited', 429);
    }
    return fail('server.unavailable', 503);
  }

  let body: Record<string, unknown>;
  try {
    body = await readBody(req);
  } catch {
    return fail('request.invalid', 400);
  }
  const { provider, id_token: idToken, nonce } = body;
  if (
    (provider !== 'google' && provider !== 'apple') ||
    typeof idToken !== 'string' || idToken.length < 1 ||
    idToken.length > 4096 ||
    typeof nonce !== 'string' || nonce.length < 1 || nonce.length > 256
  ) {
    return fail('request.invalid', 400);
  }

  let sub: string;
  try {
    const { payload } = await jwtVerify(idToken, deps.keys(provider), {
      issuer: issuers[provider],
      audience: deps.config.audiences[provider],
      algorithms: ['RS256'],
      requiredClaims: ['exp', 'sub', 'nonce'],
      currentDate: deps.now(),
    });
    // Supabase Auth compares the claim with the hex SHA-256 of the raw nonce.
    if (payload.nonce !== await sha256Hex(nonce)) {
      log(provider, 'invalid_token', 'nonce');
      return fail('invalid_token', 400);
    }
    if (typeof payload.sub !== 'string' || payload.sub.length > 255) {
      log(provider, 'invalid_token', 'sub');
      return fail('invalid_token', 400);
    }
    sub = payload.sub;
  } catch (error) {
    const reason = refusal(error);
    if (reason === null) {
      log(provider, 'keys_unavailable');
      return fail('server.unavailable', 503);
    }
    log(provider, 'invalid_token', reason);
    return fail('invalid_token', 400);
  }

  let hasAccount: boolean;
  try {
    hasAccount = await deps.hasAccount(provider, sub);
  } catch {
    return fail('server.unavailable', 503);
  }
  log(provider, hasAccount ? 'account' : 'no_account');
  return response({ has_account: hasAccount });
}
