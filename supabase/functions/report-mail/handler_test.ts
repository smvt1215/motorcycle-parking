import { batchSize, type Deps, handle, reportNoticeMail } from './handler.ts';

const id = '5f0c2a9e-1b2c-4d3e-8f40-123456789abc';

function deps(over: Partial<Deps> = {}, log: string[] = []): Deps {
  return {
    secret: 's3cret',
    pending: (limit) => {
      log.push(`pending ${limit}`);
      return Promise.resolve([id]);
    },
    send: (x) => {
      log.push(`send ${x}`);
      return Promise.resolve(true);
    },
    sent: (x) => {
      log.push(`sent ${x}`);
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
  eq(log, [`pending ${batchSize}`, `send ${id}`, `sent ${id}`], 'calls');
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
  eq(log.includes(`sent ${id}`), false, 'not marked');
});

Deno.test('a failed send is retried next time, others still go', async () => {
  const other = '00000000-0000-4000-8000-000000000001';
  const log: string[] = [];
  const res = await handle(
    call(),
    deps({
      pending: () => Promise.resolve([id, other]),
      send: (x) =>
        x === id
          ? Promise.reject(new Error('resend 500'))
          : Promise.resolve(true),
      sent: (x) => {
        log.push(`sent ${x}`);
        return Promise.resolve();
      },
    }, log),
  );
  eq(await res.json(), { sent: 1, failed: 1, skipped: 0 }, 'body');
  eq(log, [`sent ${other}`], 'only the sent one is marked');
});

Deno.test('a database failure is a 503', async () => {
  const res = await handle(
    call(),
    deps({ pending: () => Promise.reject(new Error('down')) }),
  );
  eq(res.status, 503, 'status');
});

Deno.test('the mail has only the id and the admin link', () => {
  const mail = reportNoticeMail(id, `https://admin.test/review/${id}`);
  eq(mail.subject.includes(id.slice(0, 8)), true, 'subject names the report');
  eq(mail.text.includes(`https://admin.test/review/${id}`), true, 'link');
  eq(mail.text.split('\n').length, 6, 'nothing else');
});
