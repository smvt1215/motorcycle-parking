import {
  batchSize,
  caseLink,
  type Deps,
  fuseNoticeMail,
  handle,
  pendingBase,
  reportNoticeMail,
} from './handler.ts';

const id = '5f0c2a9e-1b2c-4d3e-8f40-123456789abc';

function deps(over: Partial<Deps> = {}, log: string[] = []): Deps {
  return {
    secret: 's3cret',
    pending: (limit) => {
      log.push(`pending ${limit}`);
      return Promise.resolve([{ id, kind: 'new' }]);
    },
    send: (x) => {
      log.push(`send ${x.kind} ${x.id}`);
      return Promise.resolve(true);
    },
    sent: (x) => {
      log.push(`sent ${x.kind} ${x.id}`);
      return Promise.resolve();
    },
    ...over,
  };
}

const call = (secret = 's3cret', method = 'POST') =>
  new Request('https://x.test/report-mail', {
    method,
    headers: { 'x-report-mail-secret': secret },
  });

function eq(a: unknown, b: unknown, what: string) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${what}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
  }
}

Deno.test('sends each pending notice once and marks it', async () => {
  const log: string[] = [];
  const res = await handle(call(), deps({}, log));
  eq(res.status, 200, 'status');
  eq(await res.json(), { sent: 1, failed: 0, skipped: 0 }, 'body');
  eq(
    log,
    [`pending ${batchSize}`, `send new ${id}`, `sent new ${id}`],
    'calls',
  );
});

Deno.test('the shared secret is required', async () => {
  const log: string[] = [];
  eq((await handle(call('nope'), deps({}, log))).status, 403, 'wrong secret');
  eq((await handle(call(''), deps({ secret: '' }, log))).status, 403, 'unset');
  eq((await handle(call('s3cret', 'GET'), deps({}, log))).status, 405, 'GET');
  eq(log, [], 'nothing read');
});

Deno.test('an unconfigured mailer leaves the notice for later', async () => {
  const log: string[] = [];
  const res = await handle(
    call(),
    deps({ send: () => Promise.resolve(false) }, log),
  );
  eq(await res.json(), { sent: 0, failed: 0, skipped: 1 }, 'body');
  eq(log.includes(`sent new ${id}`), false, 'not marked');
});

Deno.test('a failed send is retried next time, others still go', async () => {
  const other = '00000000-0000-4000-8000-000000000001';
  const log: string[] = [];
  const res = await handle(
    call(),
    deps({
      pending: () =>
        Promise.resolve([{ id, kind: 'new' }, { id: other, kind: 'fuse' }]),
      send: (x) =>
        x.id === id
          ? Promise.reject(new Error('resend 500'))
          : Promise.resolve(true),
      sent: (x) => {
        log.push(`sent ${x.kind} ${x.id}`);
        return Promise.resolve();
      },
    }, log),
  );
  eq(await res.json(), { sent: 1, failed: 1, skipped: 0 }, 'body');
  eq(log, [`sent fuse ${other}`], 'only the sent one is marked');
});

Deno.test('a database failure is a 503', async () => {
  const res = await handle(
    call(),
    deps({ pending: () => Promise.reject(new Error('down')) }),
  );
  eq(res.status, 503, 'status');
});

Deno.test('the mail has only the id and the admin link', () => {
  const mail = reportNoticeMail(id, `https://admin.test/pending/${id}`);
  eq(mail.subject.includes(id.slice(0, 8)), true, 'subject names the report');
  eq(mail.text.includes(`https://admin.test/pending/${id}`), true, 'link');
  eq(mail.text.split('\n').length, 6, 'nothing else');
  // Same deadline the app states (#316 contentReportIntro).
  eq(
    mail.text.split('\n')[0],
    '有一筆新的內容不當檢舉，請在 5 個工作天內確認並處理。',
    'deadline',
  );
});

Deno.test('the fuse mail says later reports wait, with no personal data', () => {
  const mail = fuseNoticeMail(id, `https://admin.test/pending/${id}`);
  eq(mail.text.includes(`https://admin.test/pending/${id}`), true, 'link');
  eq(mail.text.includes('只進審核'), true, 'what changed');
});

Deno.test('the link opens the case on 待處理, not the report id', () => {
  const caseId = '00000000-0000-4000-8000-0000000000c1';
  eq(
    caseLink('https://admin.test/pending', {
      id,
      kind: 'new',
      case_id: caseId,
    }),
    `https://admin.test/pending/${caseId}`,
    'a later report on the same spot opens the case it joined',
  );
  eq(
    caseLink('https://admin.test/pending', { id, kind: 'fuse', case_id: id }),
    `https://admin.test/pending/${id}`,
    'the first report is its own case',
  );
  eq(
    caseLink('https://admin.test/pending', { id, kind: 'new', case_id: null }),
    'https://admin.test/pending',
    'already resolved: the list',
  );
  eq(
    caseLink('https://admin.test/pending', { id, kind: 'new' }),
    'https://admin.test/pending',
    'before the migration: the list',
  );
});

Deno.test("ADMIN_PENDING_URL, else the review site's /pending", () => {
  const env = (vars: Record<string, string>) => (name: string) => vars[name];
  eq(
    pendingBase(env({ ADMIN_PENDING_URL: ' https://admin.test/pending/ ' })),
    'https://admin.test/pending',
    'set',
  );
  eq(
    pendingBase(env({
      ADMIN_PENDING_URL: 'https://admin.test/pending',
      ADMIN_REVIEW_URL: 'https://old.test/review',
    })),
    'https://admin.test/pending',
    'the new name wins',
  );
  eq(
    pendingBase(env({ ADMIN_REVIEW_URL: 'https://admin.test/review/' })),
    'https://admin.test/pending',
    'only the old secret: no secret change needed',
  );
  eq(pendingBase(env({})), null, 'unset: nothing is sent');
  eq(pendingBase(env({ ADMIN_REVIEW_URL: 'admin/review' })), null, 'not a URL');
  eq(
    pendingBase(env({ ADMIN_REVIEW_URL: 'javascript:alert(1)' })),
    null,
    'not a web link',
  );
});
