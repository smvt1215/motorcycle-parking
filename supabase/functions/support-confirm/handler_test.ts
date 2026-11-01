import { confirmToken, newSecret } from '../_shared/support_token.ts';
import { type Action, type Deps, handle, maskEmail } from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const id = '20000000-0000-4000-8000-000000000001';
const at = '2026-11-01T10:00:00Z', later = '2026-11-08T10:05:00Z';

/** A database with one request: view keeps it, confirm or deny ends it. */
function fake(
  hash: string,
  fail = false,
  kind: 'account_deletion' | 'privacy' = 'account_deletion',
) {
  const calls: string[] = [];
  let state: 'pending' | 'used' = 'pending';
  let cancelled = false;
  const deps: Deps = {
    cancel(x, h, action) {
      calls.push(`cancel ${x} ${h} ${action}`);
      if (fail) return Promise.reject(new Error('db'));
      if (cancelled || x !== id || h !== hash) {
        return Promise.resolve({ result: 'invalid' });
      }
      if (action === 'cancel') cancelled = true;
      return Promise.resolve({
        result: action === 'view' ? 'pending' : 'cancelled',
        scheduled_at: action === 'view' ? later : null,
      });
    },
    link(x, h, action: Action) {
      calls.push(`${x} ${h} ${action}`);
      if (fail) return Promise.reject(new Error('db'));
      if (state === 'used' || x !== id || h !== hash) {
        return Promise.resolve({ result: 'invalid' });
      }
      if (action !== 'view') state = 'used';
      return Promise.resolve({
        result: action === 'view'
          ? 'pending'
          : action === 'confirm'
          ? (kind === 'privacy' ? 'verified' : 'deletion_requested')
          : 'denied',
        kind,
        submitted_at: at,
        contact_email: 'rider@example.tw',
        scheduled_at: action === 'confirm' && kind !== 'privacy' ? later : null,
      });
    },
  };
  return { deps, calls };
}

const post = (body: unknown) =>
  new Request('http://local/support-confirm', {
    method: 'POST',
    body: JSON.stringify(body),
  });

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

const invalid = { status: 400, body: { error: 'support.link_invalid' } };
const shown = (
  result: string,
  scheduled: string | null = null,
  kind = 'account_deletion',
) => ({
  status: 200,
  body: {
    result,
    kind,
    submitted_at: at,
    contact_email: 'r***@e***.tw',
    scheduled_at: scheduled,
  },
});

Deno.test('opening shows the request and changes nothing', async () => {
  const made = await newSecret();
  const { deps, calls } = fake(made.hash);
  const token = confirmToken(id, made.secret);
  equal(await call(deps, post({ token })), shown('pending'), 'view by default');
  equal(
    await call(deps, post({ token, action: 'view' })),
    shown('pending'),
    'again',
  );
  equal(
    await call(deps, post({ token, action: 'confirm' })),
    shown('deletion_requested', later),
    'confirm asks for the deletion',
  );
  equal(
    calls[0],
    `${id} ${made.hash} view`,
    'only the hash reaches the database',
  );
  equal(
    await call(deps, post({ token, action: 'confirm' })),
    invalid,
    'once only',
  );
});

Deno.test('"not me" voids the request', async () => {
  const made = await newSecret();
  const { deps } = fake(made.hash);
  const token = confirmToken(id, made.secret);
  equal(
    await call(deps, post({ token, action: 'deny' })),
    shown('denied'),
    'denied',
  );
  equal(await call(deps, post({ token })), invalid, 'link gone');
});

Deno.test('every bad token looks the same', async () => {
  const made = await newSecret(), other = await newSecret();
  const { deps, calls } = fake(made.hash);
  for (
    const token of [
      confirmToken(id, other.secret),
      confirmToken('20000000-0000-4000-8000-000000000002', made.secret),
      'garbage',
      undefined,
    ]
  ) equal(await call(deps, post({ token })), invalid, String(token));
  equal(calls.length, 2, 'malformed tokens never reach the database');
});

Deno.test('requests the page cannot make', async () => {
  const made = await newSecret();
  const { deps, calls } = fake(made.hash);
  equal(
    (await call(
      deps,
      post({ token: confirmToken(id, made.secret), action: 'delete' }),
    )).status,
    400,
    'unknown action',
  );
  equal(calls, [], 'nothing asked');
  equal(
    (await call(deps, new Request('http://local/', { method: 'GET' }))).status,
    405,
    'GET',
  );
  equal(
    (await call(
      deps,
      new Request('http://local/', { method: 'POST', body: '[' }),
    )).status,
    400,
    'bad JSON',
  );
  equal(
    (await handle(new Request('http://local/', { method: 'OPTIONS' }), deps))
      .status,
    200,
    'CORS preflight',
  );
  equal(
    await call(
      fake(made.hash, true).deps,
      post({ token: confirmToken(id, made.secret) }),
    ),
    { status: 503, body: { error: 'server.unavailable' } },
    'database trouble is not a refusal',
  );
});

Deno.test('maskEmail', () => {
  equal(maskEmail('rider@example.tw'), 'r***@e***.tw', 'plain');
  equal(maskEmail('a@b.co.uk'), 'a***@b***.uk', 'subdomains hidden');
  equal(maskEmail('騎士@例子.台灣'), '騎***@例***.台灣', 'unicode');
  equal(maskEmail('nope'), '***', 'not an address');
});

Deno.test('the cancel link: view shows, cancel cancels once', async () => {
  const made = await newSecret();
  const { deps, calls } = fake(made.hash);
  const token = confirmToken(id, made.secret);
  equal(await call(deps, post({ token, link: 'cancel' })), {
    status: 200,
    body: { result: 'pending', scheduled_at: later },
  }, 'view by default');
  equal(await call(deps, post({ token, link: 'cancel', action: 'cancel' })), {
    status: 200,
    body: { result: 'cancelled', scheduled_at: null },
  }, 'cancelled');
  equal(
    await call(deps, post({ token, link: 'cancel', action: 'cancel' })),
    invalid,
    'once only',
  );
  equal(
    calls.every((c) => c.startsWith('cancel ')),
    true,
    'never the confirmation link',
  );
  for (
    const body of [
      { token, link: 'cancel', action: 'confirm' },
      { token, link: 'cancel', action: 'deny' },
      { token, action: 'cancel' },
      { token, link: 'other' },
    ]
  ) {
    equal(
      (await call(deps, post(body))).status,
      400,
      JSON.stringify(body),
    );
  }
});

Deno.test('a privacy request: the page knows the kind; confirm verifies', async () => {
  const made = await newSecret();
  const token = confirmToken(id, made.secret);
  const { deps } = fake(made.hash, false, 'privacy');
  equal(
    await call(deps, post({ token })),
    shown('pending', null, 'privacy'),
    'view',
  );
  equal(
    await call(deps, post({ token, action: 'confirm' })),
    shown('verified', null, 'privacy'),
    'verified',
  );
  equal(await call(deps, post({ token, action: 'confirm' })), invalid, 'once');
});
