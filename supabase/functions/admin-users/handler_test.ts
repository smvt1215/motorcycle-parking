import {
  type BanRecord,
  type Caller,
  type Deps,
  handle,
  restoreDuration,
} from './handler.ts';

const adminId = '10000000-0000-4000-8000-000000000005';
const riderId = '10000000-0000-4000-8000-000000000001';
const now = new Date('2026-10-25T00:00:00Z');

function fake(caller: Caller | null, options: { recordFails?: boolean } = {}) {
  const bans: string[] = [];
  const records: BanRecord[] = [];
  const deps: Deps = {
    caller: () => Promise.resolve(caller),
    target: (id) =>
      Promise.resolve(
        id === riderId
          ? { id, admin: false, bannedUntil: null }
          : id === adminId || id === '10000000-0000-4000-8000-000000000009'
          ? { id, admin: true, bannedUntil: null }
          : null,
      ),
    setBan: (_id, duration) => {
      bans.push(duration);
      return Promise.resolve(
        duration === 'none' ? null : '2026-11-01T00:00:00Z',
      );
    },
    record: (entry) => {
      if (options.recordFails) return Promise.reject(new Error('db down'));
      records.push(entry);
      return Promise.resolve();
    },
    now: () => now,
  };
  return { deps, bans, records };
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
  const { deps, bans, records } = fake({
    id: riderId,
    admin: false,
    aal: 'aal2',
  });
  const res = await handle(post(ban), deps);
  assert(res.status === 403, `status ${res.status}`);
  assert(bans.length === 0 && records.length === 0, 'rider changed a ban');
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
  const { deps, bans, records } = fake(admin);
  const res = await handle(post({ ...ban, reason: '  洗版回報  ' }), deps);
  assert(res.status === 200, `status ${res.status}`);
  const body = await res.json();
  assert(body.banned_until === '2026-11-01T00:00:00Z', 'banned_until');
  assert(bans.join() === '168h', `durations ${bans}`);
  const [entry] = records;
  assert(
    records.length === 1 && entry.actor === adminId && entry.user === riderId &&
      entry.action === 'ban_user' && entry.note === '洗版回報' &&
      entry.duration === '168h' && entry.before === null,
    JSON.stringify(records),
  );
});

Deno.test('lifting a ban is audited too', async () => {
  const { deps, bans, records } = fake(admin);
  const res = await handle(
    post({ action: 'unban', user_id: riderId, reason: '申訴成立' }),
    deps,
  );
  assert(res.status === 200, `status ${res.status}`);
  assert(bans.join() === 'none', `durations ${bans}`);
  assert(
    records[0]?.action === 'unban_user' && records[0].after === null,
    'record',
  );
});

Deno.test('a ban the audit cannot record is undone', async () => {
  const { deps, bans, records } = fake(admin, { recordFails: true });
  const res = await handle(post(ban), deps);
  assert(res.status === 500, `status ${res.status}`);
  assert(bans.join() === '168h,none', `durations ${bans}`);
  assert(records.length === 0, 'recorded');
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

Deno.test('restoring a previous ban keeps at least its remaining time', () => {
  assert(restoreDuration(null, now) === 'none', 'none');
  assert(restoreDuration('2026-10-24T00:00:00Z', now) === 'none', 'past');
  assert(restoreDuration('2026-10-25T01:30:00Z', now) === '2h', 'rounded up');
});
