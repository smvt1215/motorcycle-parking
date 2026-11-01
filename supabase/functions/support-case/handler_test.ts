import { confirmToken, newSecret } from '../_shared/support_token.ts';
import type { Notice } from '../support-request/handler.ts';
import { type CaseResult, type Deps, handle } from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const id = '20000000-0000-4000-8000-000000000001';
const at = '2026-11-01T10:00:00Z';

function fake(answer: (action: string) => CaseResult, fail = false) {
  const calls: string[] = [];
  const notices: Notice[] = [];
  const deps: Deps = {
    link(x, h, action, body) {
      calls.push(`${x} ${h.length} ${action} ${body}`);
      if (fail) return Promise.reject(new Error('db'));
      return Promise.resolve(answer(action));
    },
    notifier: {
      notify: (n) => {
        notices.push(n);
        return Promise.resolve(true);
      },
    },
    adminUrl: (x) => `https://admin.test/support/${x}`,
  };
  return { deps, calls, notices };
}

const post = (body: unknown) =>
  new Request('http://local/support-case', {
    method: 'POST',
    body: JSON.stringify(body),
  });

async function call(deps: Deps, req: Request) {
  const res = await handle(req, deps);
  return { status: res.status, body: await res.json() };
}

const thread: CaseResult = {
  result: 'ok',
  id,
  kind: 'general',
  status: 'open',
  submitted_at: at,
  can_reply: true,
  messages: [
    { direction: 'in', body: '費用不對', created_at: at },
    { direction: 'out', body: '已更正', created_at: at },
  ],
};

Deno.test('view shows the case with its code and changes nothing', async () => {
  const made = await newSecret();
  const token = confirmToken(id, made.secret);
  const { deps, calls, notices } = fake(() => thread);
  equal(await call(deps, post({ token })), {
    status: 200,
    body: {
      result: 'ok',
      code: 'S-20000000',
      kind: 'general',
      status: 'open',
      submitted_at: at,
      can_reply: true,
      messages: thread.result === 'ok' ? thread.messages : [],
    },
  }, 'shown');
  equal(calls, [`${id} 64 view null`], 'only the hash goes to the database');
  equal(notices, [], 'no notice');
});

Deno.test('a reply goes to the same case and tells ops@ only the id and link', async () => {
  const made = await newSecret();
  const token = confirmToken(id, made.secret);
  const { deps, calls, notices } = fake(() => ({
    result: 'received',
    message_id: 'm1',
    reopened: true,
  }));
  equal(
    await call(
      deps,
      post({ token, action: 'reply', message: '  補充\u0007  ' }),
    ),
    { status: 200, body: { result: 'received', reopened: true } },
    'received',
  );
  equal(calls, [`${id} 64 reply 補充`], 'cleaned text');
  equal(notices, [{
    id,
    adminUrl: `https://admin.test/support/${id}`,
    replyId: 'm1',
  }], 'notice');
});

Deno.test('refusals', async () => {
  const made = await newSecret();
  const token = confirmToken(id, made.secret);
  const cases: [CaseResult['result'], number, string][] = [
    ['invalid', 400, 'support.link_invalid'],
    ['closed', 409, 'support.case_closed'],
    ['rate_limited', 429, 'support.rate_limited'],
  ];
  for (const [result, status, error] of cases) {
    const { deps, notices } = fake(() => ({ result } as CaseResult));
    equal(
      await call(deps, post({ token, action: 'reply', message: 'x' })),
      { status, body: { error } },
      result,
    );
    equal(notices, [], 'no notice');
  }
  const { deps, calls } = fake(() => thread);
  for (
    const body of [
      { token, action: 'delete' },
      { token, action: 'reply' },
      { token, action: 'reply', message: '' },
      { token, action: 'reply', message: '長'.repeat(4001) },
    ]
  ) {
    equal(
      await call(deps, post(body)),
      { status: 400, body: { error: 'request.invalid' } },
      JSON.stringify(body).slice(0, 40),
    );
  }
  equal(
    await call(deps, post({ token: 'nope' })),
    { status: 400, body: { error: 'support.link_invalid' } },
    'malformed token',
  );
  equal(calls, [], 'nothing reached the database');
  equal(
    (await call(fake(() => thread, true).deps, post({ token }))).status,
    503,
    'database down',
  );
  equal(
    (await call(deps, new Request('http://local/', { method: 'GET' }))).status,
    405,
    'POST only',
  );
});
