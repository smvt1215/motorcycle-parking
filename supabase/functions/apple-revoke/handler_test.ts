import {
  type AppleConfig,
  appleConfig,
  type Caller,
  type Deps,
  handle,
  latestSignIn,
  revokeUrl,
  signClientSecret,
} from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}
function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

const now = new Date('2026-11-01T12:00:00Z');
const nowSeconds = now.getTime() / 1000;
const config: AppleConfig = {
  teamId: 'TEAM123456',
  keyId: 'KEY1234567',
  privateKey: 'pem',
  clientId: 'tw.motopark.signin',
};
const rider: Caller = {
  id: '10000000-0000-4000-8000-000000000001',
  apple: true,
  signedInAt: nowSeconds - 60,
};

type Sent = { url: string; body: URLSearchParams };

function fake(
  options: {
    caller?: Caller | null;
    allowed?: boolean;
    config?: AppleConfig | null;
    apple?: Response;
    statusFails?: boolean;
  } = {},
) {
  const sent: Sent[] = [];
  const deps: Deps = {
    caller: () =>
      Promise.resolve(options.caller === undefined ? rider : options.caller),
    canSelfDelete: () =>
      options.statusFails
        ? Promise.reject(new Error('db'))
        : Promise.resolve(options.allowed ?? true),
    config: options.config === undefined ? config : options.config,
    clientSecret: () => Promise.resolve('signed'),
    fetch: (url, init) => {
      sent.push({ url, body: init.body as URLSearchParams });
      return Promise.resolve(
        options.apple ?? new Response('', { status: 200 }),
      );
    },
    now: () => now,
  };
  return { deps, sent };
}

const post = (body: unknown, token: string | null = 'jwt') =>
  new Request('http://local/apple-revoke', {
    method: 'POST',
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(body),
  });

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

Deno.test('revokes the Apple token of a rider about to request deletion', async () => {
  const { deps, sent } = fake();
  equal(
    await call(deps, post({ token: 'apple-refresh' })),
    { status: 200, body: { revoked: true } },
    'revoked',
  );
  equal(sent.length, 1, 'one call to Apple');
  equal(sent[0].url, revokeUrl, 'Apple revoke endpoint');
  equal(
    Object.fromEntries(sent[0].body),
    {
      client_id: 'tw.motopark.signin',
      client_secret: 'signed',
      token: 'apple-refresh',
      token_type_hint: 'refresh_token',
    },
    'form body',
  );
});

Deno.test('an access token can be revoked too', async () => {
  const { deps, sent } = fake();
  await call(deps, post({ token: 'a', token_type_hint: 'access_token' }));
  equal(sent[0].body.get('token_type_hint'), 'access_token', 'hint');
});

Deno.test('the same conditions as the deletion request', async () => {
  const cases: [Parameters<typeof fake>[0], Request, number, string][] = [
    [{}, post({ token: 't' }, null), 401, 'auth.sign_in_required'],
    [{ caller: null }, post({ token: 't' }), 401, 'auth.sign_in_required'],
    [
      { caller: { ...rider, signedInAt: nowSeconds - 601 } },
      post({ token: 't' }),
      401,
      'auth.recent_sign_in_required',
    ],
    [
      { caller: { ...rider, apple: false } },
      post({ token: 't' }),
      400,
      'account.not_apple_sign_in',
    ],
    [
      { allowed: false },
      post({ token: 't' }),
      403,
      'account.admin_cannot_self_delete',
    ],
    [{ statusFails: true }, post({ token: 't' }), 503, 'server.unavailable'],
    [{ config: null }, post({ token: 't' }), 503, 'apple.not_configured'],
    [{}, post({}), 400, 'request.invalid'],
    [
      {},
      post({ token: 't', token_type_hint: 'id_token' }),
      400,
      'request.invalid',
    ],
    [{}, post({ token: 'x'.repeat(4097) }), 400, 'request.invalid'],
  ];
  for (const [options, req, status, error] of cases) {
    const { deps, sent } = fake(options);
    const res = await call(deps, req);
    equal([res.status, res.body.error], [status, error], error);
    equal(sent.length, 0, `${error}: Apple not called`);
  }
});

Deno.test('Apple refusing is reported with its error code only', async () => {
  const { deps } = fake({
    apple: Response.json({ error: 'invalid_client' }, { status: 400 }),
  });
  equal(
    await call(deps, post({ token: 't' })),
    {
      status: 502,
      body: { error: 'apple.revoke_failed', apple_error: 'invalid_client' },
    },
    'refused',
  );
});

Deno.test('a network failure is reported', async () => {
  const { deps } = fake();
  deps.fetch = () => Promise.reject(new TypeError('offline'));
  equal(
    (await call(deps, post({ token: 't' }))).body.error,
    'apple.revoke_failed',
    'failed',
  );
});

Deno.test('latestSignIn reads the newest non-anonymous amr entry', () => {
  equal(
    latestSignIn([
      { method: 'totp', timestamp: 20 },
      { method: 'oauth', timestamp: 10 },
    ]),
    20,
    'newest',
  );
  equal(latestSignIn([{ method: 'anonymous', timestamp: 30 }]), 0, 'anonymous');
  equal(latestSignIn(undefined), 0, 'missing');
  equal(latestSignIn([{ method: 'oauth', timestamp: '9' }]), 0, 'not a number');
});

Deno.test('appleConfig needs all four values', () => {
  const env = {
    APPLE_TEAM_ID: 'T',
    APPLE_KEY_ID: 'K',
    APPLE_PRIVATE_KEY: 'P',
    APPLE_CLIENT_ID: 'C',
  } as Record<string, string>;
  equal(
    appleConfig((n) => env[n]),
    { teamId: 'T', keyId: 'K', privateKey: 'P', clientId: 'C' },
    'all set',
  );
  equal(
    appleConfig((n) => (n === 'APPLE_KEY_ID' ? undefined : env[n])),
    null,
    'one missing',
  );
});

Deno.test('the client secret is an ES256 JWT Apple can verify', async () => {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  );
  const der = new Uint8Array(
    await crypto.subtle.exportKey('pkcs8', pair.privateKey),
  );
  const b64 = btoa(String.fromCharCode(...der));
  // As stored in an environment variable, with escaped newlines.
  const pem = `-----BEGIN PRIVATE KEY-----\\n${
    b64.match(/.{1,64}/g)!.join('\\n')
  }\\n-----END PRIVATE KEY-----`;
  const jwt = await signClientSecret({ ...config, privateKey: pem }, now);
  const [header, payload, signature] = jwt.split('.');
  const decode = (part: string) =>
    JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/')));
  equal(decode(header), { alg: 'ES256', kid: 'KEY1234567' }, 'header');
  equal(decode(payload), {
    iss: 'TEAM123456',
    iat: nowSeconds,
    exp: nowSeconds + 300,
    aud: 'https://appleid.apple.com',
    sub: 'tw.motopark.signin',
  }, 'claims');
  const raw = Uint8Array.from(
    atob(
      signature.replace(/-/g, '+').replace(/_/g, '/') +
        '='.repeat((4 - signature.length % 4) % 4),
    ),
    (c) => c.charCodeAt(0),
  );
  equal(raw.length, 64, 'r || s');
  assert(
    await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      pair.publicKey,
      raw,
      new TextEncoder().encode(`${header}.${payload}`),
    ),
    'signature verifies',
  );
});
