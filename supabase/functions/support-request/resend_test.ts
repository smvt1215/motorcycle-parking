import {
  noticeMail,
  resendConfig,
  resendNotifier,
  resendUrl,
} from './resend.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const id = '20000000-0000-4000-8000-000000000001';
const config = {
  apiKey: 're_test',
  from: 'MotoPark <support@x.tw>',
  to: ['ops@x.tw'],
};

Deno.test('resendConfig needs the key, the sender and a recipient', () => {
  const env: Record<string, string> = {
    RESEND_API_KEY: 're_test',
    SUPPORT_MAIL_FROM: 'MotoPark <support@x.tw>',
    SUPPORT_MAIL_TO: 'ops@x.tw, ',
  };
  equal(resendConfig((n) => env[n]), config, 'all set');
  equal(
    resendConfig((n) => (n === 'RESEND_API_KEY' ? '' : env[n])),
    null,
    'no key',
  );
  equal(
    resendConfig((n) => (n === 'SUPPORT_MAIL_TO' ? ' , ' : env[n])),
    null,
    'no recipient',
  );
});

Deno.test('without configuration nothing is sent', async () => {
  let called = false;
  const notifier = resendNotifier(null, () => {
    called = true;
    return Promise.resolve(new Response('{}'));
  });
  equal(await notifier.notify({ id, adminUrl: 'u' }), false, 'not sent');
  equal(called, false, 'no request');
});

Deno.test('sends only the id and the link, once per request', async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const notifier = resendNotifier(config, (url, init) => {
    seen.push({ url: String(url), init: init! });
    return Promise.resolve(Response.json({ id: 'mail' }));
  });
  equal(
    await notifier.notify({ id, adminUrl: 'https://admin.test/s/1' }),
    true,
    'sent',
  );
  equal(seen[0].url, resendUrl, 'Resend');
  const headers = new Headers(seen[0].init.headers);
  equal(headers.get('authorization'), 'Bearer re_test', 'key');
  equal(headers.get('idempotency-key'), `support-request/${id}`, 'idempotent');
  const body = JSON.parse(String(seen[0].init.body));
  equal(body, {
    from: config.from,
    to: config.to,
    ...noticeMail(id, 'https://admin.test/s/1'),
  }, 'body');
  equal(
    /@|帳號被|Google/.test(body.text.replace(/support@x\.tw/, '')),
    false,
    'no personal data',
  );
});

Deno.test('a refused send throws, so the request stays unmarked', async () => {
  const notifier = resendNotifier(
    config,
    () => Promise.resolve(new Response('{}', { status: 422 })),
  );
  let threw = false;
  try {
    await notifier.notify({ id, adminUrl: 'u' });
  } catch {
    threw = true;
  }
  equal(threw, true, 'throws');
});
