import { type Deps, handle, type Notice } from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const notice = (n: number): Notice => ({
  id: `20000000-0000-4000-8000-00000000000${n}`,
  email: `r${n}@x.tw`,
  scheduled_at: '2026-11-08T07:30:00Z',
  apple: false,
});

function fake(
  options: {
    secret?: string;
    send?: (n: Notice) => Promise<boolean>;
    stored?: boolean;
    cancelBase?: string | null;
  } = {},
) {
  const log: string[] = [];
  let made = 0;
  const deps: Deps = {
    secret: options.secret ?? 's3cret',
    notices: (limit) => {
      log.push(`notices ${limit}`);
      return Promise.resolve([notice(1), notice(2)]);
    },
    newSecret: () => {
      made++;
      return Promise.resolve({
        secret: String(made).repeat(43),
        hash: String(made).repeat(64),
      });
    },
    setCancelToken: (id, hash) => {
      log.push(`token ${id} ${hash.slice(0, 3)}`);
      return Promise.resolve(options.stored ?? true);
    },
    cancelLink: (id, secret) =>
      options.cancelBase === null
        ? null
        : `${
          options.cancelBase ?? 'https://site.test/cancel'
        }#token=${id}.${secret}`,
    send: options.send ? (n) => options.send!(n) : (n, link, hash) => {
      log.push(`send ${n.email} ${link} ${hash.slice(0, 3)}`);
      return Promise.resolve(true);
    },
    notified: (id) => {
      log.push(`notified ${id}`);
      return Promise.resolve();
    },
  };
  return { deps, log };
}

const post = (secret?: string) =>
  new Request('http://local/support-mail', {
    method: 'POST',
    headers: secret ? { 'x-support-mail-secret': secret } : {},
  });

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

Deno.test('stores a cancel link, sends each notice with it and marks it', async () => {
  const { deps, log } = fake();
  equal(await call(deps, post('s3cret')), {
    status: 200,
    body: { sent: 2, failed: 0, skipped: 0 },
  }, 'sent');
  const [a, b] = [notice(1).id, notice(2).id];
  equal(log, [
    'notices 50',
    `token ${a} 111`,
    `send r1@x.tw https://site.test/cancel#token=${a}.${'1'.repeat(43)} 111`,
    `notified ${a}`,
    `token ${b} 222`,
    `send r2@x.tw https://site.test/cancel#token=${b}.${'2'.repeat(43)} 222`,
    `notified ${b}`,
  ], 'steps');
});

Deno.test('without the cancel page the notice still goes', async () => {
  const { deps, log } = fake({ cancelBase: null });
  equal((await call(deps, post('s3cret'))).body.sent, 2, 'sent');
  equal(log[2], 'send r1@x.tw null 111', 'no link');
});

Deno.test('a deletion that is gone is skipped', async () => {
  const { deps, log } = fake({ stored: false });
  equal((await call(deps, post('s3cret'))).body, {
    sent: 0,
    failed: 0,
    skipped: 2,
  }, 'skipped');
  equal(log.some((l) => l.startsWith('send')), false, 'nothing sent');
});

Deno.test('a failed send stays for the next call, without the email in the log', async () => {
  const errors: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => errors.push(args.join(' '));
  try {
    const { deps, log } = fake({
      send: (n) =>
        n.email === 'r1@x.tw'
          ? Promise.reject(new Error('smtp'))
          : Promise.resolve(true),
    });
    equal((await call(deps, post('s3cret'))).body, {
      sent: 1,
      failed: 1,
      skipped: 0,
    }, 'counts');
    equal(log.includes(`notified ${notice(1).id}`), false, 'not marked');
  } finally {
    console.error = original;
  }
  equal(
    errors.some((e) => e.includes('@') || e.includes('#token')),
    false,
    'no email or link logged',
  );
});

Deno.test('without a mail service nothing is marked', async () => {
  const { deps, log } = fake({ send: () => Promise.resolve(false) });
  equal((await call(deps, post('s3cret'))).body, {
    sent: 0,
    failed: 0,
    skipped: 2,
  }, 'skipped');
  equal(log.some((l) => l.startsWith('notified')), false, 'not marked');
});

Deno.test('only with the shared secret', async () => {
  for (const req of [post(), post('wrong')]) {
    const { deps, log } = fake();
    equal((await call(deps, req)).status, 403, 'forbidden');
    equal(log, [], 'nothing read');
  }
  equal((await call(fake({ secret: '' }).deps, post(''))).status, 403, 'unset');
  equal(
    (await call(
      fake().deps,
      new Request('http://local/', { method: 'GET' }),
    )).status,
    405,
    'POST only',
  );
});
