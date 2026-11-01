// apple-revoke: revokes the rider's Sign in with Apple token when they ask
// for their account to be deleted (#268; App Store guideline 5.1.1(v):
// apps offering Sign in with Apple revoke its tokens on deletion).
//
// The App calls it right before api_v1.request_account_deletion(), with the
// Apple token from the fresh sign-in that request needs (the session's
// provider_refresh_token, or provider_token): a successful request signs the
// account out everywhere (#215), so a session-checked call cannot follow it.
// The same sign-in conditions apply as for the request: the caller is signed
// in with Apple and signed in within 10 minutes, and an admin, who may not
// delete the account, is refused. The token goes to Apple's
// /auth/revoke and is never stored or logged. If the rider later cancels,
// signing in with Apple again asks them to share their Apple ID again and
// keeps the same account.
//
// Secrets, from the environment only (listed in #262): APPLE_TEAM_ID,
// APPLE_KEY_ID, APPLE_PRIVATE_KEY (the .p8 PEM) and APPLE_CLIENT_ID (the
// Services ID the Supabase Apple provider signs in with).
import { cors, readBody, response } from '../_shared/http.ts';

export const revokeUrl = 'https://appleid.apple.com/auth/revoke';
export const appleAudience = 'https://appleid.apple.com';
/** As api_v1.request_account_deletion(): the sign-in must be this recent. */
export const reauthWindowSeconds = 600;

export type Caller = {
  id: string;
  /** The account has an Apple identity. */
  apple: boolean;
  /** Unix seconds of the latest authentication in the token's amr. */
  signedInAt: number;
};

export type AppleConfig = {
  teamId: string;
  keyId: string;
  privateKey: string;
  clientId: string;
};

export type Deps = {
  caller(token: string): Promise<Caller | null>;
  /** api_v1.account_deletion_status() as the caller: can_self_delete. */
  canSelfDelete(token: string): Promise<boolean>;
  config: AppleConfig | null;
  /** Signs the ES256 client secret. */
  clientSecret(config: AppleConfig, now: Date): Promise<string>;
  fetch(url: string, init: RequestInit): Promise<Response>;
  now(): Date;
};

export function appleConfig(
  env: (name: string) => string | undefined,
): AppleConfig | null {
  const teamId = env('APPLE_TEAM_ID')?.trim(),
    keyId = env('APPLE_KEY_ID')?.trim(),
    privateKey = env('APPLE_PRIVATE_KEY')?.trim(),
    clientId = env('APPLE_CLIENT_ID')?.trim();
  if (!teamId || !keyId || !privateKey || !clientId) return null;
  return { teamId, keyId, privateKey, clientId };
}

/** The latest `timestamp` in a JWT amr claim; 0 when there is none. */
export function latestSignIn(amr: unknown): number {
  if (!Array.isArray(amr)) return 0;
  let latest = 0;
  for (const entry of amr) {
    if (!entry || typeof entry !== 'object') continue;
    const { method, timestamp } = entry as Record<string, unknown>;
    if (method === 'anonymous' || typeof timestamp !== 'number') continue;
    latest = Math.max(latest, timestamp);
  }
  return latest;
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_')
    .replace(/=+$/, '');
const encodeJson = (value: unknown) =>
  base64url(new TextEncoder().encode(JSON.stringify(value)));

/**
 * The client secret Apple asks for: a JWT signed with the .p8 key (ES256),
 * kid = key id, iss = team id, sub = client id, aud = appleid.apple.com.
 * It lives 5 minutes; Apple allows up to 6 months.
 */
export async function signClientSecret(
  config: AppleConfig,
  now: Date,
): Promise<string> {
  const pem = config.privateKey.replace(/\\n/g, '\n')
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const iat = Math.floor(now.getTime() / 1000);
  const input = `${encodeJson({ alg: 'ES256', kid: config.keyId })}.${
    encodeJson({
      iss: config.teamId,
      iat,
      exp: iat + 300,
      aud: appleAudience,
      sub: config.clientId,
    })
  }`;
  // WebCrypto's ECDSA signature is r || s, the form JWS uses.
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      new TextEncoder().encode(input),
    ),
  );
  return `${input}.${base64url(signature)}`;
}

const fail = (error: string, status: number, extra: object = {}) =>
  response({ error, ...extra }, status);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('request.invalid', 405);
  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get('authorization') ?? '')
    ?.[1]?.trim();
  if (!token) return fail('auth.sign_in_required', 401);

  let body: Record<string, unknown>;
  try {
    body = await readBody(req);
  } catch {
    return fail('request.invalid', 400);
  }
  const appleToken = body.token, hint = body.token_type_hint ?? 'refresh_token';
  if (
    typeof appleToken !== 'string' || appleToken.length < 1 ||
    appleToken.length > 4096 ||
    (hint !== 'refresh_token' && hint !== 'access_token')
  ) {
    return fail('request.invalid', 400);
  }

  const caller = await deps.caller(token).catch(() => null);
  if (!caller) return fail('auth.sign_in_required', 401);
  if (
    deps.now().getTime() / 1000 - caller.signedInAt > reauthWindowSeconds
  ) {
    return fail('auth.recent_sign_in_required', 401, {
      max_age_seconds: reauthWindowSeconds,
    });
  }
  if (!caller.apple) return fail('account.not_apple_sign_in', 400);
  let allowed: boolean;
  try {
    allowed = await deps.canSelfDelete(token);
  } catch {
    return fail('server.unavailable', 503);
  }
  // The deletion request would be refused, so the Apple link stays.
  if (!allowed) return fail('account.admin_cannot_self_delete', 403);
  if (!deps.config) return fail('apple.not_configured', 503);

  let res: Response;
  try {
    const secret = await deps.clientSecret(deps.config, deps.now());
    res = await deps.fetch(revokeUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: deps.config.clientId,
        client_secret: secret,
        token: appleToken,
        token_type_hint: hint,
      }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    return fail('apple.revoke_failed', 502);
  }
  if (!res.ok) {
    // Apple answers {"error": "invalid_client" | "invalid_grant" | ...}.
    const apple = await res.json().catch(() => null) as
      | { error?: unknown }
      | null;
    const code = typeof apple?.error === 'string'
      ? apple.error.slice(0, 40)
      : `http_${res.status}`;
    console.error(`apple-revoke: Apple refused (${code})`);
    return fail('apple.revoke_failed', 502, { apple_error: code });
  }
  await res.body?.cancel();
  return response({ revoked: true });
}
