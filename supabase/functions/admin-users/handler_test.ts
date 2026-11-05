import {
  type Caller,
  type Deps,
  handle,
  type SuspensionChange,
} from './handler.ts';

const adminId = '10000000-0000-4000-8000-000000000005';
const riderId = '10000000-0000-4000-8000-000000000001';

function fake(caller: Caller | null, options: { suspendFails?: boolean } = {}) {
  /** What admin_set_user_suspension() was asked to do. */
  const bans: SuspensionChange[] = [];
  const deps: Deps = {
    caller: () => Promise.resolve(caller),
    target: (id) =>
      Promise.resolve(
        id === riderId
          ? { id, admin: false }
          : id === adminId || id === '10000000-0000-4000-8000-000000000009'
          ? { id, admin: true }
          : null,
      ),
    suspend: (change) => {
      if (options.suspendFails) return Promise.reject(new Error('db down'));
      bans.push(change);
      return Promise.resolve(
        change.action === 'ban' ? '2026-11-01T00:00:00+00:00' : null,
      );
    },
  };
  return { deps, bans };
}

const post = (body: unknown, token = 'token') =>
  new Request('http://local/admin-users', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
const ban = {
  action: 'ban',
  user_id: riderId,
  duration: '7d',
  reason: '洗版回報',
};
const admin: Caller = { id: adminId, admin: true, aal: 'aal2' };

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test('a rider is refused and nothing is banned', async () => {
  const { deps, bans } = fake({
    id: riderId,
    admin: false,
    aal: 'aal2',
  });
  const res = await handle(post(ban), deps);
  assert(res.status === 403, `status ${res.status}`);
  assert(bans.length === 0, 'rider changed a ban');
});

Deno.test('an admin without a second factor is refused', async () => {
  const { deps, bans } = fake({ id: adminId, admin: true, aal: 'aal1' });
  const res = await handle(post(ban), deps);
  assert(res.status === 403, `status ${res.status}`);
  assert(bans.length === 0, 'aal1 admin changed a ban');
});

Deno.test('a missing or rejected token is refused', async () => {
  const unsigned = await handle(
    new Request('http://local', { method: 'POST', body: '{}' }),
    fake(admin).deps,
  );
  assert(unsigned.status === 401, `status ${unsigned.status}`);
  const rejected = await handle(post(ban), fake(null).deps);
  assert(rejected.status === 401, `status ${rejected.status}`);
});

Deno.test('a ban is applied and audited with the admin and reason', async () => {
  const { deps, bans } = fake(admin);
  const res = await handle(post({ ...ban, reason: '  洗版回報  ' }), deps);
  assert(res.status === 200, `status ${res.status}`);
  const body = await res.json();
  assert(
    body.user_id === riderId &&
      body.banned_until === '2026-11-01T00:00:00+00:00',
    JSON.stringify(body),
  );
  const [entry] = bans;
  assert(
    bans.length === 1 && entry.actor === adminId && entry.user === riderId &&
      entry.action === 'ban' && entry.note === '洗版回報' &&
      entry.duration === '7d',
    JSON.stringify(bans),
  );
});

Deno.test('every duration the admin page offers', async () => {
  for (const duration of ['7d', '30d', 'indefinite']) {
    const { deps, bans } = fake(admin);
    const res = await handle(post({ ...ban, duration }), deps);
    assert(res.status === 200, `${duration}: ${res.status}`);
    assert(bans[0]?.duration === duration, JSON.stringify(bans));
  }
});

Deno.test('lifting a ban answers no end', async () => {
  const { deps, bans } = fake(admin);
  const res = await handle(
    post({ action: 'unban', user_id: riderId, reason: '申訴成立' }),
    deps,
  );
  assert(res.status === 200, `status ${res.status}`);
  assert((await res.json()).banned_until === null, 'banned_until');
  assert(
    bans[0]?.action === 'unban' && bans[0].duration === null,
    JSON.stringify(bans),
  );
});

Deno.test('a suspension the database refuses changes nothing', async () => {
  const { deps } = fake(admin, { suspendFails: true });
  const res = await handle(post(ban), deps);
  assert(res.status === 502, `status ${res.status}`);
});

Deno.test('invalid requests are refused before any change', async () => {
  for (
    const body of [
      { ...ban, reason: '   ' },
      { ...ban, reason: '車'.repeat(501) },
      { ...ban, duration: '1h' },
      { ...ban, duration: 'constructor' },
      { ...ban, action: 'delete' },
      { ...ban, user_id: 'not-a-uuid' },
    ]
  ) {
    const { deps, bans } = fake(admin);
    const res = await handle(post(body), deps);
    assert(res.status === 400, `${JSON.stringify(body)}: ${res.status}`);
    assert(bans.length === 0, 'changed a ban');
  }
});

Deno.test('admins, yourself and unknown accounts cannot be banned', async () => {
  const cases: [string, number][] = [
    [adminId, 400],
    ['10000000-0000-4000-8000-000000000009', 403],
    ['10000000-0000-4000-8000-0000000000ff', 404],
  ];
  for (const [id, status] of cases) {
    const { deps, bans } = fake(admin);
    const res = await handle(post({ ...ban, user_id: id }), deps);
    assert(res.status === status, `${id}: ${res.status}`);
    assert(bans.length === 0, 'changed a ban');
  }
});

Deno.test('an unexpected failure answers with CORS headers', async () => {
  const { deps } = fake(admin);
  deps.target = () => Promise.reject(new Error('network'));
  const res = await handle(post(ban), deps);
  assert(res.status === 503, `status ${res.status}`);
  assert(res.headers.get('access-control-allow-origin') === '*', 'cors');
});
