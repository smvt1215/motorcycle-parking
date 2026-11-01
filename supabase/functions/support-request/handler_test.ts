import type { AppCheckResult } from '../_shared/app_check.ts';
import { type Deps, handle, type Notifier, parse } from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const id = '20000000-0000-4000-8000-000000000001';

function fake(
  options: {
    appCheck?: AppCheckResult | null;
    network?: string | null;
    submitError?: string;
    notifier?: Notifier;
  } = {},
) {
  const log: string[] = [];
  const deps: Deps = {
    appCheck: () =>
      Promise.resolve(
        options.appCheck === undefined
          ? { status: 'valid', appId: 'web' }
          : options.appCheck,
      ),
    networkHash: () =>
      Promise.resolve(
        options.network === undefined ? 'n'.repeat(64) : options.network,
      ),
    submit: (s, network) => {
      if (options.submitError) {
        return Promise.reject({ message: options.submitError });
      }
      log.push(`submit ${JSON.stringify(s)} ${network.length}`);
      return Promise.resolve(id);
    },
    notified: (x) => {
      log.push(`notified ${x}`);
      return Promise.resolve();
    },
    notifier: options.notifier ?? {
      notify: (n) => {
        log.push(`notify ${JSON.stringify(n)}`);
        return Promise.resolve(true);
      },
    },
    adminUrl: (x) => `https://admin.test/support/${x}`,
  };
  return { deps, log };
}

const post = (body: unknown) =>
  new Request('http://local/support-request', {
    method: 'POST',
    headers: { 'x-firebase-appcheck': 'token' },
    body: JSON.stringify(body),
  });
const form = {
  email: ' Rider@Example.TEST ',
  account_hint: 'Google',
  message: '想刪除\u0007帳號',
};

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

Deno.test('stores the request and notifies with only its id and link', async () => {
  const { deps, log } = fake();
  equal(
    await call(deps, post(form)),
    { status: 200, body: { received: true, id } },
    'received',
  );
  equal(log, [
    'submit {"kind":"account_deletion","email":"rider@example.test","hint":"Google","message":"想刪除帳號"} 64',
    `notify {"id":"${id}","adminUrl":"https://admin.test/support/${id}"}`,
    `notified ${id}`,
  ], 'steps');
});

Deno.test('without a mail service the request is still stored', async () => {
  const { deps, log } = fake({
    notifier: { notify: () => Promise.resolve(false) },
  });
  equal((await call(deps, post(form))).status, 200, 'ok');
  equal(log.length, 1, 'stored, not marked notified');
});

Deno.test('a failed notice does not lose the request', async () => {
  const { deps, log } = fake({
    notifier: { notify: () => Promise.reject(new Error('smtp')) },
  });
  equal((await call(deps, post(form))).status, 200, 'ok');
  equal(log.length, 1, 'stored');
});

Deno.test('App Check is always required', async () => {
  for (
    const appCheck of [
      { status: 'missing' },
      { status: 'invalid', reason: 'expired' },
    ] as AppCheckResult[]
  ) {
    const { deps, log } = fake({ appCheck });
    equal(
      await call(deps, post(form)),
      { status: 401, body: { error: 'app_check.required' } },
      appCheck.status,
    );
    equal(log, [], 'nothing stored');
  }
  equal(
    (await call(fake({ appCheck: null }).deps, post(form))).status,
    503,
    'verification unavailable',
  );
});

Deno.test('refusals', async () => {
  const cases: [Parameters<typeof fake>[0], unknown, number, string][] = [
    [{ network: null }, form, 503, 'server.unavailable'],
    [{}, { ...form, email: 'nope' }, 400, 'request.invalid'],
    [{}, { ...form, kind: 'other' }, 400, 'request.invalid'],
    [{}, { ...form, message: '長'.repeat(1001) }, 400, 'request.invalid'],
    [
      { submitError: 'support.rate_limited' },
      form,
      429,
      'support.rate_limited',
    ],
    [{ submitError: 'request.invalid' }, form, 400, 'request.invalid'],
    [{ submitError: 'boom' }, form, 503, 'server.unavailable'],
  ];
  for (const [options, body, status, error] of cases) {
    equal(
      await call(fake(options).deps, post(body)),
      { status, body: { error } },
      error,
    );
  }
  equal(
    (await call(
      fake().deps,
      new Request('http://local/', { method: 'GET' }),
    )).status,
    405,
    'POST only',
  );
});

Deno.test('parse', () => {
  equal(parse({ email: 'a@b.tw' }), {
    kind: 'account_deletion',
    email: 'a@b.tw',
    hint: '',
    message: '',
  }, 'minimal');
  equal(
    parse({ email: 'a@b.tw', account_hint: 'x'.repeat(201) }),
    null,
    'hint',
  );
  equal(parse({}), null, 'email required');
});
