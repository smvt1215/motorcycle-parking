import { type Deps, handle, maxWaitMs, skewMs, waitMs } from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const now = Date.parse('2026-11-09T10:00:00Z');

function fake(options: { secret?: string; run?: () => Promise<unknown> } = {}) {
  const log: string[] = [];
  const deps: Deps = {
    secret: options.secret ?? 's3cret',
    now: () => now,
    sleep: (ms) => {
      log.push(`sleep ${ms}`);
      return Promise.resolve();
    },
    run: options.run ?? (() => {
      log.push('run');
      return Promise.resolve({ claimed: 1, done: 1 });
    }),
  };
  return { deps, log };
}

const post = (body: unknown, secret: string | null = 's3cret') =>
  new Request('https://x.test/case-actions', {
    method: 'POST',
    headers: secret === null ? {} : { 'x-case-actions-secret': secret },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

Deno.test('only a POST with the shared secret gets in', async () => {
  const { deps, log } = fake();
  equal(
    (await handle(new Request('https://x.test/', { method: 'GET' }), deps))
      .status,
    405,
    'GET',
  );
  equal((await handle(post({}, null), deps)).status, 403, 'no secret');
  equal((await handle(post({}, 'wrong'), deps)).status, 403, 'wrong secret');
  equal(log, [], 'nothing ran');
});

Deno.test('an unset secret refuses everyone', async () => {
  const { deps, log } = fake({ secret: '' });
  equal((await handle(post({}, ''), deps)).status, 403, 'empty');
  equal(log, [], 'nothing ran');
});

Deno.test('waits for run_at, then runs and returns the counts', async () => {
  const { deps, log } = fake();
  const res = await handle(
    post({ run_at: new Date(now + 5000).toISOString() }),
    deps,
  );
  equal(res.status, 200, 'status');
  equal(await res.json(), { claimed: 1, done: 1 }, 'counts');
  equal(log, [`sleep ${5000 + skewMs}`, 'run'], 'sleeps before running');
});

Deno.test('never waits more than the limit', async () => {
  const { deps, log } = fake();
  await handle(post({ run_at: new Date(now + 90_000).toISOString() }), deps);
  equal(log, [`sleep ${maxWaitMs}`, 'run'], 'capped; pg_cron does the rest');
});

Deno.test('a due action and an empty body run at once', async () => {
  const past = fake();
  await handle(
    post({ run_at: new Date(now - 60_000).toISOString() }),
    past.deps,
  );
  equal(past.log, ['run'], 'past');
  const empty = fake();
  await handle(post({}), empty.deps);
  equal(empty.log, ['run'], 'no run_at');
});

Deno.test('a bad body is refused without running', async () => {
  for (const body of ['not json', '[]', { run_at: 'soon' }, { run_at: 5 }]) {
    const { deps, log } = fake();
    equal((await handle(post(body), deps)).status, 400, JSON.stringify(body));
    equal(log, [], 'nothing ran');
  }
});

Deno.test('a database failure answers 503', async () => {
  const { deps } = fake({ run: () => Promise.reject(new Error('down')) });
  const res = await handle(post({}), deps);
  equal(res.status, 503, 'status');
  equal(await res.json(), { error: 'server.unavailable' }, 'body');
});

Deno.test('waitMs', () => {
  equal(waitMs(null, now), 0, 'no time');
  equal(waitMs(now - 1000, now), 0, 'past');
  equal(waitMs(now, now), skewMs, 'just due');
  equal(waitMs(now + 1_000_000, now), maxWaitMs, 'far');
});
