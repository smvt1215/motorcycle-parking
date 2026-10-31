import {
  appCheckConfig,
  appCheckMode,
  appCheckRefuses,
  appCheckToken,
  type FetchKeys,
  resetAppCheckKeys,
  verifyAppCheck,
} from './app_check.ts';

function assertEquals(got: unknown, want: unknown) {
  const [a, b] = [JSON.stringify(got), JSON.stringify(want)];
  if (a !== b) throw new Error(`expected ${b}, got ${a}`);
}

const config = {
  projectNumber: '123456789',
  appIds: ['1:123456789:android:abc'],
};
const now = Date.UTC(2026, 9, 31, 12, 0, 0);

const pair = await crypto.subtle.generateKey(
  {
    name: 'RSASSA-PKCS1-v1_5',
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: 'SHA-256',
  },
  true,
  ['sign', 'verify'],
) as CryptoKeyPair;
const other = await crypto.subtle.generateKey(
  {
    name: 'RSASSA-PKCS1-v1_5',
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: 'SHA-256',
  },
  true,
  ['sign', 'verify'],
) as CryptoKeyPair;
const jwk = {
  ...(await crypto.subtle.exportKey('jwk', pair.publicKey)),
  kid: 'k1',
};

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-')
    .replace(/\//g, '_').replace(/=+$/, '');
}
const text = (value: unknown) =>
  b64url(new TextEncoder().encode(JSON.stringify(value)));

async function token(
  overrides: { header?: object; payload?: object; key?: CryptoKey } = {},
) {
  const header = { alg: 'RS256', typ: 'JWT', kid: 'k1', ...overrides.header };
  const payload = {
    iss: 'https://firebaseappcheck.googleapis.com/123456789',
    aud: ['projects/123456789', 'projects/demo-project'],
    sub: '1:123456789:android:abc',
    exp: now / 1000 + 3600,
    iat: now / 1000 - 60,
    ...overrides.payload,
  };
  const body = `${text(header)}.${text(payload)}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      overrides.key ?? pair.privateKey,
      new TextEncoder().encode(body),
    ),
  );
  return `${body}.${b64url(signature)}`;
}

let fetches = 0;
const fetchKeys: FetchKeys = () => {
  fetches++;
  return Promise.resolve({ keys: [jwk], maxAgeMs: 24 * 3600 * 1000 });
};
const verify = (t: string | null, at = now) => {
  return verifyAppCheck(t, config, { fetchKeys, now: at });
};

Deno.test('a valid token names its app', async () => {
  resetAppCheckKeys();
  assertEquals(await verify(await token()), {
    status: 'valid',
    appId: '1:123456789:android:abc',
  });
});

Deno.test("each of Firebase's checks refuses", async () => {
  resetAppCheckKeys();
  assertEquals(await verify(null), { status: 'missing' });
  assertEquals(await verify('a.b'), { status: 'invalid', reason: 'malformed' });
  const cases: [Promise<string>, string][] = [
    [token({ header: { alg: 'HS256' } }), 'alg'],
    [token({ header: { typ: 'JOSE' } }), 'typ'],
    [token({ header: { kid: 'gone' } }), 'kid'],
    [token({ key: other.privateKey }), 'signature'],
    [
      token({ payload: { iss: 'https://firebaseappcheck.googleapis.com/9' } }),
      'iss',
    ],
    [token({ payload: { exp: now / 1000 - 1 } }), 'expired'],
    [token({ payload: { aud: ['projects/9'] } }), 'aud'],
    [token({ payload: { aud: 'projects/123456789' } }), 'aud'],
    [token({ payload: { sub: '1:123456789:ios:other' } }), 'sub'],
  ];
  for (const [t, reason] of cases) {
    assertEquals(await verify(await t), { status: 'invalid', reason });
  }
});

Deno.test('keys are cached for at most 6 hours', async () => {
  resetAppCheckKeys();
  fetches = 0;
  const t = await token();
  await verify(t);
  await verify(t, now + 5 * 3600 * 1000);
  assertEquals(fetches, 1);
  await verify(t, now + 6 * 3600 * 1000 + 1);
  assertEquals(fetches, 2);
});

Deno.test('an unreachable key set is an invalid token, not a crash', async () => {
  resetAppCheckKeys();
  const result = await verifyAppCheck(await token(), config, {
    fetchKeys: () => Promise.reject(new Error('down')),
    now,
  });
  assertEquals(result, { status: 'invalid', reason: 'keys unavailable' });
});

Deno.test('configuration, mode and header', () => {
  const env = (values: Record<string, string>) => (name: string) =>
    values[name];
  assertEquals(
    appCheckConfig(env({
      FIREBASE_PROJECT_NUMBER: '123',
      APP_CHECK_APP_IDS: ' a , b ,',
    })),
    { projectNumber: '123', appIds: ['a', 'b'] },
  );
  assertEquals(appCheckConfig(env({ FIREBASE_PROJECT_NUMBER: '123' })), null);
  assertEquals(
    appCheckConfig(
      env({ FIREBASE_PROJECT_NUMBER: 'demo', APP_CHECK_APP_IDS: 'a' }),
    ),
    null,
  );
  assertEquals(appCheckMode(undefined), 'log');
  assertEquals(appCheckMode('enforce'), 'enforce');
  assertEquals(appCheckMode('off'), 'off');
  assertEquals(appCheckMode('strict'), 'log');
  const req = new Request('https://example.test/', {
    headers: { 'X-Firebase-AppCheck': ' t ' },
  });
  assertEquals(appCheckToken(req), 't');
  assertEquals(appCheckToken(new Request('https://example.test/')), null);
});

Deno.test('only enforce refuses, and only a token that is not valid', () => {
  const log = console.log;
  const lines: string[] = [];
  console.log = (line: string) => lines.push(line);
  try {
    const valid = { status: 'valid', appId: 'a' } as const;
    const missing = { status: 'missing' } as const;
    assertEquals(appCheckRefuses('x', 'off', missing), false);
    assertEquals(lines.length, 0);
    assertEquals(appCheckRefuses('x', 'log', missing), false);
    assertEquals(appCheckRefuses('x', 'enforce', valid), false);
    assertEquals(appCheckRefuses('x', 'enforce', missing), true);
    assertEquals(appCheckRefuses('x', 'enforce', null), true);
    assertEquals(JSON.parse(lines[0]), {
      event: 'app_check',
      endpoint: 'x',
      mode: 'log',
      status: 'missing',
    });
    assertEquals(JSON.parse(lines[3]).status, 'unconfigured');
  } finally {
    console.log = log;
  }
});

Deno.test('an unknown kid refetches the keys at most once a minute', async () => {
  resetAppCheckKeys();
  fetches = 0;
  await verify(await token());
  const forged = await token({ header: { kid: 'nope' } });
  for (let i = 0; i < 5; i++) {
    assertEquals(await verify(forged, now + 1000), {
      status: 'invalid',
      reason: 'kid',
    });
  }
  assertEquals(fetches, 1);
  await verify(forged, now + 61 * 1000);
  assertEquals(fetches, 2);
});
