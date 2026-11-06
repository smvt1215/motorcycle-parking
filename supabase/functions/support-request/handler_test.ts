import type { AppCheckResult } from '../_shared/app_check.ts';
import {
  type Deps,
  handle,
  type Notifier,
  parse,
  type RiderMailer,
} from './handler.ts';

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
    mail?: 'confirm' | 'status' | 'case' | null;
    mailer?: RiderMailer;
    confirmBase?: string | null;
  } = {},
) {
  const log: string[] = [];
  const tasks: Promise<unknown>[] = [];
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
    secret: () =>
      Promise.resolve({ secret: 'S'.repeat(43), hash: 'h'.repeat(64) }),
    replyToken: () =>
      Promise.resolve({ secret: 'r'.repeat(32), hash: 'q'.repeat(64) }),
    submit: (s, network, tokenHash, replyHash) => {
      if (options.submitError) {
        return Promise.reject({ message: options.submitError });
      }
      log.push(
        `submit ${JSON.stringify(s)} ${network.length} ${tokenHash}${
          replyHash ? ` ${replyHash}` : ''
        }`,
      );
      return Promise.resolve({
        id,
        mail: options.mail ?? null,
        scheduledAt: options.mail === 'status' ? '2026-11-08T07:30:00Z' : null,
      });
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
    mailer: options.mailer ?? {
      receipt: (m) => {
        log.push(`receipt ${JSON.stringify(m)}`);
        return Promise.resolve(true);
      },
      caseReceipt: (m) => {
        log.push(`caseReceipt ${JSON.stringify(m)}`);
        return Promise.resolve(true);
      },
      confirm: (m) => {
        log.push(`confirm ${JSON.stringify(m)}`);
        return Promise.resolve(true);
      },
      status: (m) => {
        log.push(`status ${JSON.stringify(m)}`);
        return Promise.resolve(true);
      },
    },
    confirmLink: (x, secret) =>
      options.confirmBase === null
        ? null
        : `${
          options.confirmBase ?? 'https://site.test/confirm'
        }#token=${x}.${secret}`,
    cancelLink: (x, secret) => `https://site.test/cancel#token=${x}.${secret}`,
    caseLink: (x, secret) => `https://site.test/case#token=${x}.${secret}`,
    replyAddress: (token) => `reply+${token}@site.test`,
    background: (task) => {
      log.push('background');
      tasks.push(task);
    },
    adminUrl: (x) => `https://admin.test/support/${x}`,
  };
  return { deps, log, settle: () => Promise.all(tasks) };
}

const post = (body: unknown) =>
  new Request('http://local/support-request', {
    method: 'POST',
    headers: { 'x-firebase-appcheck': 'token' },
    body: JSON.stringify(body),
  });
const form = {
  contact_email: ' Helper@Contact.TEST ',
  login_email: ' Rider@Example.TEST ',
  account_hint: 'Google',
  message: '想刪除\u0007帳號',
};

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

const receipt =
  `receipt {"id":"${id}","email":"helper@contact.test","kind":"account_deletion"}`;
const notice = [
  `notify {"id":"${id}","adminUrl":"https://admin.test/support/${id}"}`,
  `notified ${id}`,
];

Deno.test('stores the request, sends the receipt and notifies with only its id and link', async () => {
  const { deps, log, settle } = fake();
  equal(
    await call(deps, post(form)),
    { status: 200, body: { received: true, id } },
    'received',
  );
  await settle();
  equal(log, [
    `submit {"kind":"account_deletion","contactEmail":"helper@contact.test","loginEmail":"rider@example.test","privacyRight":null,"subject":"","hint":"Google","message":"想刪除帳號"} 64 ${
      'h'.repeat(64)
    }`,
    receipt,
    'background',
    ...notice,
  ], 'steps');
});

Deno.test('a login email gets the one-time link; the contact email only the receipt', async () => {
  const { deps, log, settle } = fake({ mail: 'confirm' });
  const res = await call(deps, post(form));
  equal(res, { status: 200, body: { received: true, id } }, 'same answer');
  await settle();
  // The sends start before the task is handed to the background.
  equal(log.slice(1), [
    receipt,
    `confirm {"id":"${id}","email":"rider@example.test","link":"https://site.test/confirm#token=${id}.${
      'S'.repeat(43)
    }","kind":"account_deletion"}`,
    'background',
    ...notice,
  ], 'confirmation to the login email');
});

Deno.test('a match and a miss answer alike and send the contact email the same', async () => {
  const hit = fake({ mail: 'confirm' }),
    miss = fake({ mail: null }),
    state = fake({ mail: 'status' });
  equal(
    await call(hit.deps, post(form)),
    await call(miss.deps, post(form)),
    'same status and body',
  );
  equal(
    await call(state.deps, post(form)),
    await call(miss.deps, post(form)),
    'same for an account already in the cooling-off period',
  );
  await hit.settle();
  await miss.settle();
  await state.settle();
  // Every mail to the contact email; miss answered twice.
  const toContact = (log: string[]) =>
    log.filter((l) =>
      !l.startsWith('submit') && l.includes('helper@contact.test')
    );
  equal(
    toContact(hit.log),
    toContact(miss.log).slice(0, 1),
    'same mail to the contact email',
  );
  equal(toContact(state.log), toContact(hit.log), 'whatever the state');
  equal(
    state.log.filter((l) => l.startsWith('status')),
    [
      `status {"id":"${id}","email":"rider@example.test","scheduledAt":"2026-11-08T07:30:00Z","cancelLink":"https://site.test/cancel#token=${id}.${
        'S'.repeat(43)
      }"}`,
    ],
    'the owner of an account in the cooling-off period hears its state',
  );
  equal(
    miss.log.some((l) => l.startsWith('confirm')),
    false,
    'no link for a miss',
  );
});

Deno.test('failed or unconfigured mail never logs an address or the link', async () => {
  const errors: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => errors.push(args.join(' '));
  const refuse = () => Promise.reject(new Error('x'));
  try {
    for (
      const options of [
        {
          mailer: {
            receipt: refuse,
            caseReceipt: refuse,
            confirm: refuse,
            status: refuse,
          },
        },
        { confirmBase: null },
        {
          mailer: {
            receipt: () => Promise.resolve(false),
            caseReceipt: () => Promise.resolve(false),
            confirm: () => Promise.resolve(false),
            status: () => Promise.resolve(false),
          },
        },
      ]
    ) {
      const { deps, settle } = fake({ mail: 'confirm', ...options });
      equal((await call(deps, post(form))).status, 200, 'still received');
      await settle();
    }
  } finally {
    console.error = original;
  }
  equal(errors.length, 5, 'each reported');
  equal(
    errors.some((e) => e.includes('S'.repeat(43)) || e.includes('@')),
    false,
    'without the link or an address',
  );
});

Deno.test('without a mail service the request is still stored', async () => {
  const { deps, log } = fake({
    notifier: { notify: () => Promise.resolve(false) },
  });
  equal((await call(deps, post(form))).status, 200, 'ok');
  equal(
    log.some((l) => l.startsWith('notified')),
    false,
    'not marked notified',
  );
});

Deno.test('a failed notice does not lose the request', async () => {
  const { deps, log } = fake({
    notifier: { notify: () => Promise.reject(new Error('smtp')) },
  });
  equal((await call(deps, post(form))).status, 200, 'ok');
  equal(log[0].startsWith('submit'), true, 'stored');
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
    [{}, { ...form, login_email: 'nope' }, 400, 'request.invalid'],
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
  equal(parse({ contact_email: 'a@b.tw', login_email: 'L@B.tw' }), {
    kind: 'account_deletion',
    contactEmail: 'a@b.tw',
    loginEmail: 'l@b.tw',
    privacyRight: null,
    subject: '',
    hint: '',
    message: '',
  }, 'minimal');
  equal(
    parse({
      contact_email: 'a@b.tw',
      login_email: 'a@b.tw',
      account_hint: 'x'.repeat(201),
    }),
    null,
    'hint',
  );
  equal(parse({}), null, 'emails required');
  equal(parse({ contact_email: 'a@b.tw' }), null, 'login email required');
  equal(parse({ login_email: 'a@b.tw' }), null, 'contact email required');
});

const question = {
  kind: 'general',
  contact_email: ' Asker@Contact.TEST ',
  subject: '  費用\n錯誤  ',
  message: '停車點的費用不對',
};

Deno.test('a general case: the receipt carries the case link and the reply address', async () => {
  const { deps, log, settle } = fake({ mail: 'case' });
  equal(
    await call(deps, post(question)),
    { status: 200, body: { received: true, id } },
    'same answer',
  );
  await settle();
  equal(log, [
    `submit {"kind":"general","contactEmail":"asker@contact.test","loginEmail":null,"privacyRight":null,"subject":"費用 錯誤","hint":"","message":"停車點的費用不對"} 64 ${
      'h'.repeat(64)
    } ${'q'.repeat(64)}`,
    `caseReceipt {"id":"${id}","email":"asker@contact.test","kind":"general","link":"https://site.test/case#token=${id}.${
      'S'.repeat(43)
    }","replyTo":"reply+${'r'.repeat(32)}@site.test"}`,
    'background',
    ...notice,
  ], 'the case link and reply token are made and only their hashes stored');
});

Deno.test('a privacy request is confirmed by the login email like a deletion', async () => {
  const { deps, log, settle } = fake({ mail: 'confirm' });
  await call(deps, post({ ...form, kind: 'privacy', privacy_right: 'copy' }));
  await settle();
  equal(
    log.filter((l) => l.startsWith('confirm') || l.startsWith('receipt')),
    [
      `receipt {"id":"${id}","email":"helper@contact.test","kind":"privacy"}`,
      `confirm {"id":"${id}","email":"rider@example.test","link":"https://site.test/confirm#token=${id}.${
        'S'.repeat(43)
      }","kind":"privacy"}`,
    ],
    'the fixed receipt and the link to the login email',
  );
  equal(log[0].includes(' q'), false, 'no reply token');
});

Deno.test('parse the case kinds', () => {
  equal(parse(question)?.loginEmail, null, 'a question has no login email');
  equal(
    parse({ ...question, login_email: 'x@y.tw' }),
    null,
    'and may not send one',
  );
  equal(parse({ ...question, message: '' }), null, 'a question needs its text');
  equal(
    parse({ ...question, message: '長'.repeat(4000) })?.message.length,
    4000,
    '4000 characters',
  );
  equal(parse({ ...question, message: '長'.repeat(4001) }), null, 'not more');
  equal(parse({ ...question, subject: 'x'.repeat(121) }), null, 'subject');
  equal(
    parse({ ...question, privacy_right: 'copy' }),
    null,
    'only a privacy request names a right',
  );
  equal(
    parse({ ...form, kind: 'privacy' }),
    null,
    'a privacy request names the right',
  );
  equal(
    parse({ ...form, kind: 'privacy', privacy_right: 'delete' }),
    null,
    'one of access, correction, copy',
  );
  equal(
    parse({ ...form, kind: 'privacy', privacy_right: 'access' })?.privacyRight,
    'access',
    'access',
  );
  equal(
    parse({
      ...form,
      kind: 'privacy',
      privacy_right: 'access',
      login_email: '',
    }),
    null,
    'a privacy request needs the login email',
  );
  for (const kind of ['data_issue', 'complaint']) {
    equal(parse({ ...question, kind })?.kind, kind, kind);
  }
});

Deno.test('the longest allowed form fits the request size limit', async () => {
  const { deps } = fake({ mail: 'case' });
  const body = {
    ...question,
    contact_email: 'rider@example.test',
    subject: '長'.repeat(120),
    account_hint: '長'.repeat(200),
    message: '🏍'.repeat(4000),
  };
  equal(JSON.stringify(body).length > 8192, true, 'over the default');
  equal((await call(deps, post(body))).status, 200, 'accepted');
});
