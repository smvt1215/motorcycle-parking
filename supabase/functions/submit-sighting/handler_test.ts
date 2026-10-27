import { type Deps, floodBan, floodNote, handle, refusal } from './handler.ts';
import { validate } from './validate.ts';

/** Deep equality by JSON, enough for these plain values. */
function assertEquals(got: unknown, want: unknown) {
  const [a, b] = [JSON.stringify(got), JSON.stringify(want)];
  if (a !== b) throw new Error(`expected ${b}, got ${a}`);
}

const rider = '10000000-0000-4000-8000-000000000001';
const device = '6f1c2b8e-3d4a-4b5c-9d6e-7f8091a2b3c4';
const spot = 'official:00000000-0000-4000-8000-000000000004';
const body = {
  spot_id: spot,
  kind: 'available',
  vehicle: 'scooter',
  device_id: device,
};

function request(
  payload: unknown = body,
  headers: Record<string, string> = {},
) {
  return new Request('https://example.test/functions/v1/submit-sighting', {
    method: 'POST',
    headers: {
      authorization: 'Bearer token',
      'x-real-ip': '203.0.113.9',
      ...headers,
    },
    body: JSON.stringify(payload),
  });
}

function fake(
  result: Awaited<ReturnType<Deps['apply']>> = {
    data: { accepted: true, closure_suggested: false, suspended_until: null },
  },
  user: { id: string; anonymous: boolean } | null = {
    id: rider,
    anonymous: false,
  },
) {
  const calls = {
    applied: [] as unknown[],
    bans: [] as string[],
    records: [] as unknown[],
  };
  const deps: Deps = {
    user: () => Promise.resolve(user),
    hash: (value) => Promise.resolve(`h(${value})`),
    apply: (args) => {
      calls.applied.push(args);
      return Promise.resolve(result);
    },
    ban: (_id, duration) => {
      calls.bans.push(duration);
      return Promise.resolve('2026-11-03T00:00:00Z');
    },
    record: (entry) => {
      calls.records.push(entry);
      return Promise.resolve();
    },
  };
  return { deps, calls };
}

Deno.test('validate: the three kinds, two vehicles, a spot and a device', () => {
  assertEquals(validate(body), body);
  assertEquals(
    validate({ ...body, spot_id: '00000000-0000-4000-8000-000000000004' }),
    { ...body, spot_id: '00000000-0000-4000-8000-000000000004' },
  );
  for (const kind of ['full', 'closed']) {
    assertEquals(validate({ ...body, kind }), { ...body, kind });
  }
  assertEquals(validate({ ...body, kind: 'gone' }), 'invalid kind');
  assertEquals(validate({ ...body, kind: 3 }), 'invalid kind');
  assertEquals(validate({ ...body, vehicle: 'car' }), 'invalid vehicle');
  assertEquals(validate({ ...body, spot_id: 'tdx:123' }), 'invalid spot');
  assertEquals(validate({ ...body, spot_id: `${spot}x` }), 'invalid spot');
  assertEquals(validate({ ...body, device_id: 'phone' }), 'invalid device');
  assertEquals(validate({ ...body, device_id: undefined }), 'invalid device');
});

Deno.test('validate: never where the rider is', () => {
  assertEquals(
    validate({ ...body, lat: 25.04, lng: 121.5 }),
    'unknown field lat',
  );
  assertEquals(validate({ ...body, user_id: rider }), 'unknown field user_id');
});

Deno.test('a sighting goes to apply_sighting with hashed identities', async () => {
  const { deps, calls } = fake();
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { accepted: true, closure_suggested: false });
  assertEquals(calls.applied, [{
    user: rider,
    ip: 'h(ip:203.0.113.9)',
    device: `h(device:${device})`,
    sighting: body,
  }]);
});

Deno.test('the last hop of the trusted header is the network', async () => {
  const { deps, calls } = fake();
  await handle(
    request(body, { 'x-real-ip': '198.51.100.1, 203.0.113.9' }),
    deps,
    'x-real-ip',
  );
  assertEquals((calls.applied[0] as { ip: string }).ip, 'h(ip:203.0.113.9)');
  const res = await handle(
    request(body, { 'x-real-ip': 'not an ip' }),
    fake().deps,
    'x-real-ip',
  );
  assertEquals(res.status, 503);
});

Deno.test('sign-in: Google or Apple, never anonymous', async () => {
  const none = await handle(
    request(body, { authorization: '' }),
    fake().deps,
    'x-real-ip',
  );
  assertEquals(none.status, 401);
  const anonymous = fake(undefined, { id: rider, anonymous: true });
  const res = await handle(request(), anonymous.deps, 'x-real-ip');
  assertEquals(res.status, 401);
  assertEquals(anonymous.calls.applied, []);
  const expired = await handle(
    request(),
    fake(undefined, null).deps,
    'x-real-ip',
  );
  assertEquals(expired.status, 401);
});

Deno.test('an invalid body never reaches the database', async () => {
  const { deps, calls } = fake();
  const res = await handle(
    request({ ...body, kind: 'gone' }),
    deps,
    'x-real-ip',
  );
  assertEquals(res.status, 400);
  assertEquals(await res.json(), { error: 'invalid kind' });
  const broken = new Request('https://example.test/', {
    method: 'POST',
    headers: { authorization: 'Bearer token', 'x-real-ip': '203.0.113.9' },
    body: '{',
  });
  assertEquals((await handle(broken, deps, 'x-real-ip')).status, 400);
  assertEquals(calls.applied, []);
});

Deno.test('not configured: 503', async () => {
  assertEquals((await handle(request(), null, null)).status, 503);
  assertEquals((await handle(request(), fake().deps, null)).status, 503);
});

Deno.test('limits: the daily limit and the 10-minute rule are 429', async () => {
  const daily = await handle(
    request(),
    fake({ error: { code: 'P0001', message: 'daily sighting limit reached' } })
      .deps,
    'x-real-ip',
  );
  assertEquals(daily.status, 429);
  assertEquals(await daily.json(), { error: 'daily sighting limit reached' });
  const soon = await handle(
    request(),
    fake({
      error: { code: 'P0001', message: 'spot sighted within 10 minutes' },
    })
      .deps,
    'x-real-ip',
  );
  assertEquals(soon.status, 429);
  assertEquals(await soon.json(), { error: 'sighting too soon' });
});

Deno.test('refusals keep their meaning', () => {
  assertEquals(refusal({ code: '42501', message: 'sighting suspended' }), [
    'sighting suspended',
    403,
  ]);
  assertEquals(
    refusal({ code: '42501', message: 'Google or Apple sign-in required' }),
    ['report not permitted', 403],
  );
  assertEquals(refusal({ code: '22023', message: 'spot not found' }), [
    'spot not found',
    404,
  ]);
  assertEquals(refusal({ code: '22023', message: 'invalid sighting' }), [
    'invalid sighting',
    400,
  ]);
});

Deno.test('a flood suspension bans the account for 7 days and is audited', async () => {
  const { deps, calls } = fake({
    data: { accepted: true, suspended_until: '2026-11-03T00:00:00Z' },
  });
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 403);
  assertEquals(await res.json(), { error: 'sighting suspended' });
  assertEquals(calls.bans, [floodBan]);
  assertEquals(calls.records, [{
    user: rider,
    after: '2026-11-03T00:00:00Z',
    duration: '7d',
    note: floodNote,
  }]);
});

Deno.test('a failed ban still answers suspended (the database refuses)', async () => {
  const { deps } = fake({
    data: { accepted: true, suspended_until: '2026-11-03T00:00:00Z' },
  });
  deps.ban = () => Promise.reject(new Error('auth down'));
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 403);
});

Deno.test('a closure suggestion is reported back', async () => {
  const res = await handle(
    request({ ...body, kind: 'closed' }),
    fake({ data: { accepted: true, closure_suggested: true } }).deps,
    'x-real-ip',
  );
  assertEquals(await res.json(), { accepted: true, closure_suggested: true });
});
