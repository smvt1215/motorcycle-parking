import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  type JWTPayload,
  type JWTVerifyGetKey,
  SignJWT,
} from 'npm:jose@6.2.13';
import {
  type Deps,
  handle,
  precheckConfig,
  type Provider,
  RateLimited,
  sha256Hex,
} from './handler.ts';
import type { AppCheckResult } from '../_shared/app_check.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const now = new Date('2026-11-05T12:00:00Z');
const nowSeconds = Math.floor(now.getTime() / 1000);
const googleClient = 'web-client.apps.googleusercontent.com';
const appleClient = 'tw.motopark.motorcycleParking.web';
const rawNonce = 'raw-nonce-123';

const { publicKey, privateKey } = await generateKeyPair('RS256');
const jwk = { ...await exportJWK(publicKey), kid: 'k1', alg: 'RS256' };
const localKeys = createLocalJWKSet({ keys: [jwk] });
const other = await generateKeyPair('RS256');

const claims = (provider: Provider, patch: JWTPayload = {}) => ({
  iss: provider === 'google'
    ? 'https://accounts.google.com'
    : 'https://appleid.apple.com',
  aud: provider === 'google' ? googleClient : appleClient,
  sub: `${provider}-sub-1`,
  iat: nowSeconds - 60,
  exp: nowSeconds + 600,
  ...patch,
});

async function idToken(
  provider: Provider,
  patch: JWTPayload = {},
  key: CryptoKey = privateKey,
  nonce: string | null = rawNonce,
) {
  const payload = claims(provider, patch);
  return await new SignJWT({
    ...payload,
    ...(nonce === null ? {} : { nonce: await sha256Hex(nonce) }),
  }).setProtectedHeader({ alg: 'RS256', kid: 'k1' }).sign(key);
}

function fake(
  options: {
    appCheck?: AppCheckResult | null;
    network?: string | null;
    limited?: boolean;
    accounts?: string[];
    keys?: JWTVerifyGetKey;
  } = {},
) {
  const looked: string[] = [], attempts: string[] = [];
  const deps: Deps = {
    config: precheckConfig((name) =>
      ({ GOOGLE_WEB_CLIENT_ID: googleClient, APPLE_CLIENT_ID: appleClient })[
        name as 'GOOGLE_WEB_CLIENT_ID'
      ]
    ),
    appCheck: () =>
      Promise.resolve(
        options.appCheck === undefined
          ? { status: 'valid', appId: 'web' }
          : options.appCheck,
      ),
    networkHash: () =>
      Promise.resolve(
        options.network === undefined ? 'a'.repeat(64) : options.network,
      ),
    attempt(network) {
      attempts.push(network);
      return options.limited
        ? Promise.reject(new RateLimited())
        : Promise.resolve();
    },
    keys: () => options.keys ?? localKeys,
    hasAccount(provider, sub) {
      looked.push(`${provider}:${sub}`);
      return Promise.resolve(
        (options.accounts ?? ['apple:apple-sub-1']).includes(
          `${provider}:${sub}`,
        ),
      );
    },
    now: () => now,
  };
  return { deps, looked, attempts };
}

const post = (body: unknown, appCheck: string | null = 'app-check') =>
  new Request('http://local/deletion-precheck', {
    method: 'POST',
    headers: appCheck ? { 'x-firebase-appcheck': appCheck } : {},
    body: JSON.stringify(body),
  });

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

const ask = (provider: Provider, token: string, nonce = rawNonce) =>
  post({ provider, id_token: token, nonce });

Deno.test('an Apple token of an existing account: has_account true', async () => {
  const { deps, looked } = fake();
  equal(
    await call(deps, await ask('apple', await idToken('apple'))),
    { status: 200, body: { has_account: true } },
    'answer',
  );
  equal(looked, ['apple:apple-sub-1'], 'looked up by provider and sub');
});

Deno.test('a Google token without an account: has_account false', async () => {
  const { deps, looked } = fake();
  equal(
    await call(deps, await ask('google', await idToken('google'))),
    { status: 200, body: { has_account: false } },
    'answer',
  );
  equal(looked, ['google:google-sub-1'], 'looked up');
});

Deno.test('a Google token with an account', async () => {
  const { deps } = fake({ accounts: ['google:google-sub-1'] });
  equal(
    await call(deps, await ask('google', await idToken('google'))),
    { status: 200, body: { has_account: true } },
    'answer',
  );
});

Deno.test('Google issuer without the scheme is accepted', async () => {
  const { deps } = fake({ accounts: ['google:google-sub-1'] });
  const token = await idToken('google', { iss: 'accounts.google.com' });
  equal((await call(deps, await ask('google', token))).status, 200, 'status');
});

const invalid = { status: 400, body: { error: 'invalid_token' } };

Deno.test('wrong issuer is refused', async () => {
  const { deps, looked } = fake();
  equal(
    await call(
      deps,
      await ask('apple', await idToken('apple', { iss: 'https://evil.test' })),
    ),
    invalid,
    'apple',
  );
  // A Google token sent as Apple.
  equal(
    await call(
      deps,
      await ask('apple', await idToken('google', { aud: appleClient })),
    ),
    invalid,
    'google token as apple',
  );
  equal(looked, [], 'no lookup');
});

Deno.test('wrong audience is refused', async () => {
  const { deps } = fake();
  equal(
    await call(
      deps,
      await ask('google', await idToken('google', { aud: 'other-client' })),
    ),
    invalid,
    'google',
  );
  equal(
    await call(
      deps,
      await ask('apple', await idToken('apple', { aud: 'tw.motopark.app' })),
    ),
    invalid,
    'apple (the App bundle id is not the web Services ID)',
  );
});

Deno.test('an expired token is refused', async () => {
  const { deps } = fake();
  equal(
    await call(
      deps,
      await ask('apple', await idToken('apple', { exp: nowSeconds - 1 })),
    ),
    invalid,
    'expired',
  );
});

Deno.test('a token without exp is refused', async () => {
  const { deps } = fake();
  const token = await idToken('apple', { exp: undefined });
  equal(await call(deps, await ask('apple', token)), invalid, 'no exp');
});

Deno.test('the nonce must hash to the claim', async () => {
  const { deps, looked } = fake();
  const token = await idToken('apple');
  equal(
    await call(deps, await ask('apple', token, 'another-nonce')),
    invalid,
    'other nonce',
  );
  // The hash itself is not the raw nonce.
  equal(
    await call(deps, await ask('apple', token, await sha256Hex(rawNonce))),
    invalid,
    'hash sent as the nonce',
  );
  equal(
    await call(
      deps,
      await ask('apple', await idToken('apple', {}, privateKey, null)),
    ),
    invalid,
    'token without a nonce',
  );
  equal(looked, [], 'no lookup');
});

Deno.test('a token signed by another key is refused', async () => {
  const { deps } = fake();
  const token = await idToken('apple', {}, other.privateKey);
  equal(await call(deps, await ask('apple', token)), invalid, 'signature');
  equal(
    await call(deps, await ask('apple', 'not.a.jwt')),
    invalid,
    'malformed',
  );
});

Deno.test('unreachable keys are a server error, not a bad token', async () => {
  const { deps } = fake({
    keys: () => Promise.reject(new TypeError('network')),
  });
  equal(
    await call(deps, await ask('apple', await idToken('apple'))),
    { status: 503, body: { error: 'server.unavailable' } },
    'keys',
  );
});

Deno.test('App Check is required', async () => {
  const { deps, attempts } = fake({ appCheck: { status: 'missing' } });
  equal(
    await call(deps, await ask('apple', await idToken('apple'))),
    { status: 401, body: { error: 'app_check.required' } },
    'missing',
  );
  const invalidCheck = fake({
    appCheck: { status: 'invalid', reason: 'signature' },
  });
  equal(
    await call(invalidCheck.deps, await ask('apple', await idToken('apple'))),
    { status: 401, body: { error: 'app_check.required' } },
    'invalid',
  );
  equal(attempts, [], 'not counted');
  const down = fake({ appCheck: null });
  equal(
    (await call(down.deps, await ask('apple', await idToken('apple')))).status,
    503,
    'verifier unavailable',
  );
});

Deno.test('over the per-network limit: 429 rate_limited', async () => {
  const { deps, looked, attempts } = fake({ limited: true });
  equal(
    await call(deps, await ask('apple', await idToken('apple'))),
    { status: 429, body: { error: 'rate_limited' } },
    'limited',
  );
  equal(attempts, ['a'.repeat(64)], 'counted by network hash');
  equal(looked, [], 'no lookup');
});

Deno.test('every App Check-valid request counts, even a bad body', async () => {
  const { deps, attempts } = fake();
  equal(
    await call(deps, post({ provider: 'facebook', id_token: 'x', nonce: 'n' })),
    { status: 400, body: { error: 'request.invalid' } },
    'provider',
  );
  equal(
    await call(deps, post({ provider: 'apple', id_token: 'x' })),
    { status: 400, body: { error: 'request.invalid' } },
    'nonce required',
  );
  equal(attempts.length, 2, 'both counted');
});

Deno.test('no network: 503', async () => {
  const { deps } = fake({ network: null });
  equal(
    (await call(deps, await ask('apple', await idToken('apple')))).status,
    503,
    'status',
  );
});

Deno.test('not configured: 503', async () => {
  const { deps } = fake();
  equal(
    (await call(
      { ...deps, config: null },
      await ask('apple', await idToken('apple')),
    )).status,
    503,
    'status',
  );
  equal(
    precheckConfig((name) => name === 'APPLE_CLIENT_ID' ? 'x' : undefined),
    null,
    'Google client id required',
  );
});

Deno.test('only POST', async () => {
  const { deps } = fake();
  equal(
    (await handle(new Request('http://local/x', { method: 'OPTIONS' }), deps))
      .status,
    200,
    'preflight',
  );
  equal(
    (await call(deps, new Request('http://local/x'))).status,
    405,
    'GET',
  );
});

Deno.test('logs carry neither the token nor the sub', async () => {
  const lines: string[] = [];
  const original = console.log;
  console.log = (line: string) => lines.push(line);
  try {
    const { deps } = fake();
    const token = await idToken('apple');
    await call(deps, await ask('apple', token));
    await call(deps, await ask('apple', token, 'wrong'));
    const text = lines.join('\n');
    equal(text.includes('apple-sub-1'), false, 'no sub');
    equal(text.includes(token.slice(0, 20)), false, 'no token');
    equal(lines.length, 2, 'one line each');
  } finally {
    console.log = original;
  }
});
