import type { Notice } from '../support-request/handler.ts';
import { replyTokenHash } from '../_shared/support_token.ts';
import {
  type Deps,
  type Filed,
  handle,
  identityRequest,
  type Inbound,
  parse,
  sign,
} from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const id = '20000000-0000-4000-8000-000000000001';
const secret = 'inbound-secret';
const now = 1_800_000_000;
const token = 'abcdefghijklmnopqrstuvwxyz234567';

function fake(filed: Filed, options: { secret?: string } = {}) {
  const calls: string[] = [];
  const receipts: unknown[] = [];
  const notices: Notice[] = [];
  const tasks: Promise<unknown>[] = [];
  const deps: Deps = {
    secret: options.secret ?? secret,
    now: () => now,
    newSecret: () =>
      Promise.resolve({ secret: 'S'.repeat(43), hash: 'l'.repeat(64) }),
    newReplyToken: () =>
      Promise.resolve({ secret: 'r'.repeat(32), hash: 'q'.repeat(64) }),
    file: (mail: Inbound, replyHash, keyHash, linkHash, newReplyHash) => {
      calls.push(
        `${JSON.stringify(mail)} ${replyHash} ${keyHash.length} ${
          linkHash[0]
        } ${newReplyHash[0]}`,
      );
      return Promise.resolve(filed);
    },
    receipt: (m) => {
      receipts.push(m);
      return Promise.resolve(true);
    },
    caseLink: (x, s) => `https://site.test/case#token=${x}.${s}`,
    replyAddress: (t) => `reply+${t}@site.test`,
    notifier: {
      notify: (n) => {
        notices.push(n);
        return Promise.resolve(true);
      },
    },
    adminUrl: (x) => `https://admin.test/support/${x}`,
    background: (task) => tasks.push(task),
  };
  return { deps, calls, receipts, notices, settle: () => Promise.all(tasks) };
}

const mail = {
  to: 'support@motoparking.smvtstudio.com',
  from: 'Writer@Example.TEST',
  subject: '停車點 資訊',
  text: '費用不對',
  spf: 'pass',
  dkim: 'pass',
  attachments: ['a.pdf'],
  message_id: '<m1@example.test>',
};

async function post(
  body: unknown,
  options: { ts?: number; sig?: string } = {},
) {
  const raw = JSON.stringify(body);
  const ts = String(options.ts ?? now);
  return new Request('http://local/support-inbound', {
    method: 'POST',
    headers: {
      'x-support-timestamp': ts,
      'x-support-signature': options.sig ?? await sign(secret, ts, raw),
    },
    body: raw,
  });
}

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

const created: Filed = {
  result: 'created',
  id,
  related_to: null,
  suspicious: false,
};

Deno.test('support@ opens a case; the sender gets a receipt, ops@ only the id and link', async () => {
  const { deps, calls, receipts, notices, settle } = fake(created);
  equal(await call(deps, await post(mail)), {
    status: 200,
    body: { result: 'created' },
  }, 'filed');
  await settle();
  equal(calls.length, 1, 'filed once');
  equal(
    calls[0].includes('"from":"writer@example.test"'),
    true,
    'lower-cased sender',
  );
  equal(
    calls[0].endsWith(' null 64 l q'),
    true,
    'no reply token; the hashes only',
  );
  equal(receipts, [{
    id,
    email: 'writer@example.test',
    link: `https://site.test/case#token=${id}.${'S'.repeat(43)}`,
    replyTo: `reply+${'r'.repeat(32)}@site.test`,
    identity: false,
  }], 'receipt');
  equal(
    notices,
    [{ id, adminUrl: `https://admin.test/support/${id}` }],
    'notice',
  );
});

Deno.test('reply+<token>@ is looked up by the token hash', async () => {
  const { deps, calls, receipts, notices, settle } = fake({
    result: 'appended',
    id,
    message_id: 'm9',
    reopened: false,
    suspicious: false,
  });
  await call(
    deps,
    await post({ ...mail, to: `Reply+${token}@motoparking.smvtstudio.com` }),
  );
  await settle();
  equal(
    calls[0].includes(` ${await replyTokenHash(token)} `),
    true,
    'hash of the token',
  );
  equal(receipts, [], 'no receipt for a reply');
  equal(notices[0].replyId, 'm9', 'ops@ hears of the reply');
});

Deno.test('a forged-looking sender gets no mail', async () => {
  const { deps, receipts, notices, settle } = fake({
    ...created,
    suspicious: true,
  });
  await call(deps, await post({ ...mail, spf: 'fail' }));
  await settle();
  equal(receipts, [], 'no receipt');
  equal(notices.length, 1, 'ops@ still hears');
});

Deno.test('a deletion or data request by mail is pointed to the form', async () => {
  const { deps, receipts, settle } = fake(created);
  await call(deps, await post({ ...mail, subject: '請刪除帳號' }));
  await settle();
  equal((receipts[0] as { identity: boolean }).identity, true, 'identity');
  equal(identityRequest('', 'I want to delete my account'), true, 'english');
  equal(identityRequest('個人資料複本', ''), true, 'data');
  equal(identityRequest('費用', '不對'), false, 'a question');
});

Deno.test('duplicates and limits are dropped quietly', async () => {
  for (const result of ['duplicate', 'rate_limited'] as const) {
    const { deps, receipts, notices, settle } = fake({ result });
    equal(
      await call(deps, await post(mail)),
      { status: 200, body: { result } },
      result,
    );
    await settle();
    equal(receipts.length + notices.length, 0, 'no mail');
  }
});

Deno.test('only signed, fresh posts', async () => {
  const { deps, calls } = fake(created);
  for (
    const req of [
      await post(mail, { sig: 'f'.repeat(64) }),
      await post(mail, { ts: now - 301 }),
      await post(mail, { ts: now + 301 }),
      new Request('http://local/', {
        method: 'POST',
        body: JSON.stringify(mail),
      }),
    ]
  ) equal((await call(deps, req)).status, 403, 'forbidden');
  equal(calls, [], 'nothing filed');
  equal(
    (await call(fake(created, { secret: '' }).deps, await post(mail))).status,
    503,
    'unset secret',
  );
  equal(
    (await call(
      deps,
      await post({ ...mail, to: 'info@motoparking.smvtstudio.com' }),
    )).body,
    {
      error: 'support.unknown_recipient',
    },
    'another address',
  );
  equal(
    (await call(deps, await post({ ...mail, from: 'nope' }))).status,
    400,
    'bad sender',
  );
  equal(
    (await call(deps, new Request('http://local/', { method: 'GET' }))).status,
    405,
    'POST only',
  );
});

Deno.test('parse keeps only what the case needs', () => {
  const got = parse({
    ...mail,
    text: '長'.repeat(5000),
    spf: 'bogus',
    attachments: [' a.pdf ', '', 42, ...Array(30).fill('x')],
  });
  equal(got?.text.length, 4000, '4000 characters');
  equal(got?.spf, null, 'unknown result');
  equal(
    got?.attachments.length,
    18,
    'names only, the first 20, blanks dropped',
  );
  equal(got?.attachments[0], 'a.pdf', 'trimmed');
  equal(parse(null), null, 'not an object');
});
