import { type Deps, handle, refusal } from './handler.ts';
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
  kind: 'level',
  level: 1,
  vehicle: 'scooter',
  device_id: device,
};
/** body as validate() returns it: every key, in its order. */
const parsed = {
  spot_id: spot,
  kind: 'level',
  level: 1,
  zone_id: null,
  segment_id: null,
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
    /** What suspension_status() answers, in order; then not suspended. */
    suspensions: [] as { suspended: boolean; until: string | null }[],
  };
  const deps: Deps = {
    user: () => Promise.resolve(user),
    hash: (value) => Promise.resolve(`h(${value})`),
    apply: (args) => {
      calls.applied.push(args);
      return Promise.resolve(result);
    },
    suspension: () =>
      Promise.resolve(
        calls.suspensions.shift() ?? { suspended: false, until: null },
      ),
  };
  return { deps, calls };
}

Deno.test('validate: four levels or closed, two vehicles, a spot and a device', () => {
  assertEquals(validate(body), parsed);
  assertEquals(
    validate({ ...body, spot_id: '00000000-0000-4000-8000-000000000004' }),
    { ...parsed, spot_id: '00000000-0000-4000-8000-000000000004' },
  );
  assertEquals(
    validate({
      ...body,
      spot_id: spot.toUpperCase().replace('OFFICIAL', 'official'),
    }),
    parsed,
  );
  for (const level of [0, 1, 2, 3]) {
    assertEquals(validate({ ...body, level }), { ...parsed, level });
  }
  assertEquals(validate({ ...body, level: 4 }), 'invalid level');
  assertEquals(validate({ ...body, level: 1.5 }), 'invalid level');
  assertEquals(validate({ ...body, level: '1' }), 'invalid level');
  assertEquals(validate({ ...body, level: undefined }), 'invalid level');
  assertEquals(
    validate({ ...body, kind: 'closed', level: undefined }),
    { ...parsed, kind: 'closed', level: null },
  );
  // Closed is the whole spot: no level, no zone.
  assertEquals(validate({ ...body, kind: 'closed' }), 'invalid level');
  assertEquals(
    validate({ ...body, kind: 'closed', level: null, zone_id: 'b2' }),
    'invalid area',
  );
  assertEquals(validate({ ...body, kind: 'available' }), 'invalid kind');
  assertEquals(validate({ ...body, kind: 3 }), 'invalid kind');
  assertEquals(validate({ ...body, vehicle: 'car' }), 'invalid vehicle');
  assertEquals(validate({ ...body, spot_id: 'tdx:123' }), 'invalid spot');
  assertEquals(validate({ ...body, spot_id: `${spot}x` }), 'invalid spot');
  assertEquals(validate({ ...body, device_id: 'phone' }), 'invalid device');
  assertEquals(validate({ ...body, device_id: undefined }), 'invalid device');
});

Deno.test('validate: a zone or a segment by its id, not both', () => {
  assertEquals(validate({ ...body, zone_id: 'b2' }), {
    ...parsed,
    zone_id: 'b2',
  });
  assertEquals(validate({ ...body, segment_id: 'north-1' }), {
    ...parsed,
    segment_id: 'north-1',
  });
  assertEquals(
    validate({ ...body, zone_id: 'b2', segment_id: 'north-1' }),
    'invalid area',
  );
  assertEquals(validate({ ...body, zone_id: 'B2' }), 'invalid area');
  assertEquals(validate({ ...body, zone_id: 'x'.repeat(33) }), 'invalid area');
  assertEquals(validate({ ...body, segment_id: 7 }), 'invalid area');
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
    sighting: parsed,
    ipCapped: true,
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
    request({ ...body, kind: 'available' }),
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
  assertEquals(refusal({ code: '22023', message: 'area not found' }), [
    'area not found',
    404,
  ]);
  assertEquals(refusal({ code: '22023', message: 'spot not found' }), [
    'spot not found',
    404,
  ]);
  assertEquals(refusal({ code: '22023', message: 'invalid sighting' }), [
    'invalid sighting',
    400,
  ]);
});

Deno.test('a suspended account is refused before the database (#331)', async () => {
  const { deps, calls } = fake();
  calls.suspensions.push({ suspended: true, until: '2026-11-12T00:00:00Z' });
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 403);
  assertEquals(await res.json(), {
    error: 'account.suspended',
    until: '2026-11-12T00:00:00Z',
  });
  assertEquals(calls.applied.length, 0);
});

Deno.test('an indefinite suspension has no end', async () => {
  const { deps, calls } = fake();
  calls.suspensions.push({ suspended: true, until: null });
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(await res.json(), { error: 'account.suspended', until: null });
});

Deno.test('the suspension check failing refuses the sighting', async () => {
  const { deps, calls } = fake();
  deps.suspension = () => Promise.reject(new Error('db down'));
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 503);
  assertEquals(calls.applied.length, 0);
});

Deno.test('the database refusing a suspended account gives the same answer', async () => {
  const { deps } = fake({
    error: {
      code: 'PT403',
      message: 'account.suspended',
      details: '{"until": "2026-11-12T00:00:00+00:00"}',
    },
  });
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 403);
  assertEquals(await res.json(), {
    error: 'account.suspended',
    until: '2026-11-12T00:00:00+00:00',
  });
});

Deno.test('a flood suspension answers with the account suspension', async () => {
  const { deps, calls } = fake({
    data: { accepted: true, suspended_until: '2026-11-03T00:00:00Z' },
  });
  // Not suspended when it starts; the database suspends it in the same
  // transaction, and an admin's longer suspension is kept.
  calls.suspensions.push(
    { suspended: false, until: null },
    { suspended: true, until: '2026-12-01T00:00:00Z' },
  );
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 403);
  assertEquals(await res.json(), {
    error: 'account.suspended',
    until: '2026-12-01T00:00:00Z',
  });
});

Deno.test("a flood suspension falls back to the rule's own end", async () => {
  const { deps } = fake({
    data: { accepted: true, suspended_until: '2026-11-03T00:00:00Z' },
  });
  let n = 0;
  deps.suspension = () =>
    n++ === 0
      ? Promise.resolve({ suspended: false, until: null })
      : Promise.reject(new Error('db down'));
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 403);
  assertEquals(await res.json(), {
    error: 'account.suspended',
    until: '2026-11-03T00:00:00Z',
  });
});

Deno.test('a closure suggestion is reported back', async () => {
  const res = await handle(
    request({ ...body, kind: 'closed', level: null }),
    fake({ data: { accepted: true, closure_suggested: true } }).deps,
    'x-real-ip',
  );
  assertEquals(await res.json(), { accepted: true, closure_suggested: true });
});

Deno.test('App Check: enforce refuses a bad token before the database', async () => {
  const { deps, calls } = fake();
  const seen: (string | null)[] = [];
  deps.appCheckMode = 'enforce';
  deps.appCheck = (token) => {
    seen.push(token);
    return Promise.resolve({ status: 'invalid', reason: 'signature' });
  };
  const log = console.log;
  console.log = () => {};
  try {
    const res = await handle(
      request(body, { 'X-Firebase-AppCheck': 'tok' }),
      deps,
      'x-real-ip',
    );
    assertEquals(res.status, 401);
    assertEquals(await res.json(), { error: 'app check required' });
    assertEquals(seen, ['tok']);
    assertEquals(calls.applied, []);
  } finally {
    console.log = log;
  }
});

Deno.test('App Check: log only records, the sighting goes through', async () => {
  const { deps, calls } = fake();
  deps.appCheckMode = 'log';
  deps.appCheck = () => Promise.resolve({ status: 'missing' });
  const log = console.log;
  const lines: string[] = [];
  console.log = (line: string) => lines.push(line);
  try {
    const res = await handle(request(), deps, 'x-real-ip');
    assertEquals(res.status, 200);
    assertEquals(calls.applied.length, 1);
    assertEquals(JSON.parse(lines[0]).status, 'missing');
    // Only logging: the network's daily cap still applies.
    assertEquals((calls.applied[0] as { ipCapped: boolean }).ipCapped, true);
  } finally {
    console.log = log;
  }
});

Deno.test('App Check: off never asks', async () => {
  const { deps } = fake();
  deps.appCheck = () => {
    throw new Error('asked');
  };
  const res = await handle(request(), deps, 'x-real-ip');
  assertEquals(res.status, 200);
});

Deno.test('App Check enforced: the network cap becomes a risk signal', async () => {
  const { deps, calls } = fake();
  deps.appCheckMode = 'enforce';
  deps.appCheck = () => Promise.resolve({ status: 'valid', appId: 'a' });
  const log = console.log;
  console.log = () => {};
  try {
    const res = await handle(request(), deps, 'x-real-ip');
    assertEquals(res.status, 200);
    assertEquals((calls.applied[0] as { ipCapped: boolean }).ipCapped, false);
  } finally {
    console.log = log;
  }
});
