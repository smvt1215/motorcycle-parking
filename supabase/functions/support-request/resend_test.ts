import {
  caseReceiptMail,
  confirmMail,
  deletionNoticeMail,
  inboundReceiptMail,
  noticeMail,
  privacyConfirmMail,
  receiptMail,
  replyMail,
  resendConfig,
  resendNotifier,
  resendSender,
  resendUrl,
  sendMail,
  statusMail,
  supportCode,
  taiwanTime,
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

Deno.test('mail to riders needs only the key and the sender', () => {
  const env: Record<string, string> = {
    RESEND_API_KEY: 're_test',
    SUPPORT_MAIL_FROM: 'MotoPark <support@x.tw>',
  };
  equal(resendSender((n) => env[n]), {
    apiKey: 're_test',
    from: 'MotoPark <support@x.tw>',
  }, 'set');
  equal(
    resendSender((n) => (n === 'SUPPORT_MAIL_FROM' ? ' ' : env[n])),
    null,
    'no sender',
  );
});

Deno.test('sendMail sends to the given address with the idempotency key', async () => {
  const seen: RequestInit[] = [];
  await sendMail(
    config,
    { to: ['rider@x.tw'], subject: 's', text: 't' },
    'support-confirm/1',
    (_url, init) => {
      seen.push(init!);
      return Promise.resolve(Response.json({}));
    },
  );
  equal(
    new Headers(seen[0].headers).get('idempotency-key'),
    'support-confirm/1',
    'key',
  );
  equal(JSON.parse(String(seen[0].body)), {
    from: config.from,
    to: ['rider@x.tw'],
    subject: 's',
    text: 't',
  }, 'body');
});

Deno.test('the confirmation mail: the link, 24 hours, once, 5 working days', () => {
  const { text } = confirmMail('https://site.test/c#token=abc');
  for (
    const part of [
      '不是我申請的',
      'https://site.test/c#token=abc',
      '24 小時',
      '只能使用一次',
      '5 個工作天',
      'support@motoparking.smvtstudio.com',
      'https://motoparking.smvtstudio.com',
    ]
  ) equal(text.includes(part), true, part);
});

Deno.test('the deletion notice: the date in Taiwan time and how to cancel', () => {
  equal(taiwanTime('2026-11-08T07:30:00Z'), '2026/11/08 15:30', 'UTC+8');
  equal(taiwanTime('2026-11-08T17:05:00Z'), '2026/11/09 01:05', 'next day');
  const { text } = deletionNoticeMail('2026-11-08T07:30:00Z', false);
  equal(text.includes('2026/11/08 15:30'), true, 'date');
  equal(text.includes('使用 Apple 登入'), false, 'no Apple steps');
  equal(
    deletionNoticeMail('2026-11-08T07:30:00Z', true).text.includes(
      '「使用 Apple 登入」自行移除',
    ),
    true,
    'Apple steps for an Apple account',
  );
  equal(/登入 App 選「取消刪除」/.test(text), true, 'cancel');
  equal(text.includes('7 天內'), true, 'within 7 days');
});

Deno.test('the receipt carries only the code, the same for any request', () => {
  equal(supportCode(id), 'S-20000000', 'code');
  const a = receiptMail(id),
    b = receiptMail('abcdef12-0000-4000-8000-000000000009');
  equal(a.text.includes('S-20000000'), true, 'code in the text');
  equal(
    a.text.replaceAll('S-20000000', 'X'),
    b.text.replaceAll('S-ABCDEF12', 'X'),
    'nothing else differs',
  );
  equal(a.text.includes('5 個工作天'), true, '5 working days');
  equal(
    /找到帳號/.test(a.text) && !/已找到|沒有找到|找不到/.test(a.text),
    true,
    'never says',
  );
});

Deno.test('the state mail: already asked for, when, and how to cancel', () => {
  const { text } = statusMail('2026-11-08T07:30:00Z');
  equal(text.includes('2026/11/08 15:30'), true, 'date');
  equal(text.includes('不需要再申請'), true, 'no need to ask again');
  equal(/登入 App 選「取消刪除」/.test(text), true, 'cancel');
});

Deno.test('the deletion notice carries the one-time cancel link', () => {
  const link = 'https://site.test/cancel#token=abc';
  equal(
    deletionNoticeMail('2026-11-08T07:30:00Z', false, link).text.includes(link),
    true,
    'link',
  );
  equal(
    deletionNoticeMail('2026-11-08T07:30:00Z', false).text.includes('#token='),
    false,
    'none without the page',
  );
});

Deno.test('sendMail sets the Reply-To and gives back the Resend id', async () => {
  const seen: RequestInit[] = [];
  const got = await sendMail(
    config,
    { to: ['rider@x.tw'], subject: 's', text: 't', replyTo: 'reply+abc@x.tw' },
    'support-reply/1',
    (_url, init) => {
      seen.push(init!);
      return Promise.resolve(Response.json({ id: 're_1' }));
    },
  );
  equal(got, 're_1', 'id');
  equal(
    JSON.parse(String(seen[0].body)).reply_to,
    'reply+abc@x.tw',
    'reply_to',
  );
  equal(
    await sendMail(
      config,
      { to: ['rider@x.tw'], subject: 's', text: 't' },
      'k',
      () => Promise.resolve(new Response('not json')),
    ),
    null,
    'no id',
  );
});

Deno.test('every mail says to reply to it, not to write to support@ (#295)', () => {
  for (
    const { text } of [
      receiptMail(id),
      receiptMail(id, 'privacy'),
      confirmMail('https://site.test/c#token=abc'),
      privacyConfirmMail('https://site.test/c#token=abc'),
      statusMail('2026-11-08T07:30:00Z'),
      deletionNoticeMail('2026-11-08T07:30:00Z', false),
      caseReceiptMail(id, 'general', 'https://site.test/case#token=abc'),
      replyMail(id, '已更正', 'https://site.test/case#token=abc'),
    ]
  ) {
    equal(text.includes('直接回覆這封信'), true, text.slice(0, 20));
    equal(text.includes('寄信到'), false, 'no 寄信到');
  }
});

Deno.test('a case mail: the text, the code and the case link', () => {
  const link = 'https://site.test/case#token=abc';
  const receipt = caseReceiptMail(id, 'data_issue', link);
  equal(receipt.subject.includes('資料錯誤或侵權'), true, 'kind');
  equal(receipt.text.includes(link), true, 'link');
  equal(receipt.text.includes('S-20000000'), true, 'code');
  const reply = replyMail(id, '您好，已更正。', link);
  equal(reply.text.startsWith('您好，已更正。'), true, 'the answer first');
  equal(
    reply.text.includes(link) && reply.text.includes('30 天'),
    true,
    'link',
  );
  equal(reply.subject, '【機車停車指南】客服回覆 S-20000000', 'subject');
  equal(replyMail(id, 'x', null).text.includes('#token='), false, 'no page');
});

Deno.test('the privacy confirmation: the link, 24 hours, only to this inbox', () => {
  const { text } = privacyConfirmMail('https://site.test/v#token=abc');
  for (
    const part of [
      'https://site.test/v#token=abc',
      '24 小時',
      '只會寄到這個信箱',
      '不是我申請的',
    ]
  ) equal(text.includes(part), true, part);
});

Deno.test('the state mail carries the one-time cancel link', () => {
  const link = 'https://site.test/cancel#token=abc';
  equal(
    statusMail('2026-11-08T07:30:00Z', link).text.includes(link),
    true,
    'link',
  );
  equal(
    statusMail('2026-11-08T07:30:00Z').text.includes('#token='),
    false,
    'none',
  );
});

Deno.test('a reply notice says so, with its own idempotency key', async () => {
  const seen: RequestInit[] = [];
  await resendNotifier(config, (_url, init) => {
    seen.push(init!);
    return Promise.resolve(Response.json({ id: 're_2' }));
  }).notify({ id, adminUrl: 'https://admin.test/x', replyId: 'm1' });
  equal(
    new Headers(seen[0].headers).get('idempotency-key'),
    'support-reply/m1',
    'per reply',
  );
  const body = JSON.parse(String(seen[0].body));
  equal(body.subject.includes('新回覆'), true, 'subject');
  equal(
    body.text.split('\n').includes('處理：https://admin.test/x'),
    true,
    'link line',
  );
  equal(noticeMail(id, 'u').text.includes('新的客服案件'), true, 'new case');
});

Deno.test('the receipt of a mail to support@ points identity requests to the form', () => {
  const link = 'https://site.test/case#token=abc';
  const plain = inboundReceiptMail(id, link, false).text;
  equal(
    plain.includes(link) && plain.includes('直接回覆這封信'),
    true,
    'case lines',
  );
  equal(
    plain.includes('/support\n') || plain.endsWith('/support'),
    false,
    'no form link',
  );
  const identity = inboundReceiptMail(id, link, true).text;
  equal(
    identity.includes('https://motoparking.smvtstudio.com/support'),
    true,
    'form',
  );
  equal(identity.includes('登入 email'), true, 'the login email decides');
});
