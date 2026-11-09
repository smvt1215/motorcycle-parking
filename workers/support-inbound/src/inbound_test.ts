import {
  accepts,
  authResults,
  clip,
  payload,
  rawDigest,
  sign,
  signedRequest,
} from './inbound.ts';
import {
  type Deps,
  handle,
  type Inbound,
  sign as checked,
} from '../../../supabase/functions/support-inbound/handler.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const token = 'abcdefghijklmnopqrstuvwxyz234567';

Deno.test('takes only support@ and reply+<token>@', () => {
  equal(accepts('support@motoparking.smvtstudio.com'), true, 'support@');
  equal(
    accepts(` Reply+${token.toUpperCase()}@MotoParking.smvtstudio.com`),
    true,
    'reply+ any case',
  );
  equal(
    accepts('ops@motoparking.smvtstudio.com'),
    false,
    'ops@ is a plain forward',
  );
  equal(accepts(`reply+${token}@evil.test`), false, 'another domain');
  equal(
    accepts('reply+short@motoparking.smvtstudio.com'),
    false,
    'not a token',
  );
  equal(accepts('reply@motoparking.smvtstudio.com'), false, 'no token');
});

Deno.test("trusts only Cloudflare's Authentication-Results", () => {
  const headers = [
    {
      key: 'authentication-results',
      value:
        'mx.cloudflare.net; dkim=fail header.d=x; dkim=pass header.d=example.test; dmarc=pass; spf=softfail smtp.mailfrom=example.test',
    },
    { key: 'authentication-results', value: 'evil.test; spf=pass; dkim=pass' },
    {
      key: 'authentication-results',
      value:
        'mx.cloudflare.net; dkim=none; dmarc=fail; spf=fail smtp.mailfrom="x;dkim=pass"@evil.test (comment; dkim=pass)',
    },
  ];
  equal(
    authResults(headers),
    { spf: 'softfail', dkim: 'pass', dmarc: 'pass' },
    'the topmost of Cloudflare',
  );
  equal(
    authResults(headers.slice(2)),
    { spf: 'fail', dkim: 'none', dmarc: 'fail' },
    'text inside quotes or comments is not a result',
  );
  equal(
    authResults(headers.slice(1, 2)),
    { spf: null, dkim: null, dmarc: null },
    'a forged one counts as none',
  );
  equal(authResults([]), { spf: null, dkim: null, dmarc: null }, 'none');
  equal(
    authResults([{
      key: 'Authentication-Results',
      value: 'mx.example; spf=pass',
    }], 'mx.example'),
    { spf: 'pass', dkim: null, dmarc: null },
    'another authserv-id when configured',
  );
});

Deno.test('the payload carries no raw mail and attachments by name', () => {
  equal(
    payload(
      'Support@MotoParking.smvtstudio.com',
      'bounce@example.test',
      {
        headers: [{
          key: 'authentication-results',
          value: 'mx.cloudflare.net; spf=pass; dkim=pass; dmarc=fail',
        }],
        from: { address: 'Writer@Example.test' },
        subject: '費用',
        messageId: '<m1@example.test>',
        text: '內容',
        attachments: [{ filename: 'a.pdf' }, { filename: null }],
      },
      undefined,
      'd'.repeat(64),
    ),
    {
      to: 'support@motoparking.smvtstudio.com',
      from: 'writer@example.test',
      subject: '費用',
      text: '內容',
      spf: 'pass',
      dkim: 'pass',
      dmarc: 'fail',
      attachments: ['a.pdf'],
      message_id: '<m1@example.test>',
      raw_sha256: 'd'.repeat(64),
    },
    'payload',
  );
  equal(
    payload('support@motoparking.smvtstudio.com', 'Env@Example.test', {
      headers: [],
      attachments: [],
    }).from,
    'env@example.test',
    'the envelope sender without a From',
  );
});

Deno.test('the signature is the one support-inbound checks', async () => {
  const req = await signedRequest(
    'https://x.test/f',
    's3cret',
    { a: 1 },
    1_800_000_000,
  );
  const body = await req.text();
  equal(req.headers.get('x-support-timestamp'), '1800000000', 'timestamp');
  equal(
    req.headers.get('x-support-signature'),
    await checked('s3cret', '1800000000', body),
    'same HMAC',
  );
  equal(
    await sign('s3cret', '1', 'x') === await sign('other', '1', 'x'),
    false,
    'keyed',
  );
});

Deno.test('the same raw mail always has the same digest', async () => {
  const raw = new TextEncoder().encode('Subject: x\r\n\r\nbody').buffer;
  equal(await rawDigest(raw), await rawDigest(raw.slice(0)), 'stable');
  equal((await rawDigest(raw)).length, 64, 'hex SHA-256');
});

Deno.test('cuts long fields at code points, never inside an emoji', () => {
  const body = 'a'.repeat(3999) + '😀' + 'b';
  const out = payload('support@motoparking.smvtstudio.com', 'x@example.test', {
    headers: [],
    subject: 's'.repeat(199) + '😀😀',
    text: body,
    attachments: [{ filename: 'f'.repeat(199) + '😀.pdf' }],
  });
  equal([...out.text].length, 4000, 'text length in code points');
  equal(out.text.endsWith('😀'), true, 'the emoji is kept whole');
  equal(out.subject, 's'.repeat(199) + '😀', 'subject');
  equal(out.attachments, ['f'.repeat(199) + '😀'], 'attachment name');
  equal(
    /[\ud800-\udbff](?![\udc00-\udfff])/.test(out.text),
    false,
    'no lone high surrogate',
  );
  equal(
    JSON.parse(JSON.stringify(out)).text,
    out.text,
    'round-trips through JSON',
  );
  equal(clip('短', 200), '短', 'short text is unchanged');
});

const spf = (value: string, authservId?: string) =>
  authResults(
    [{ key: 'Authentication-Results', value }],
    authservId,
  ).spf;

Deno.test('SPF is the envelope sender’s, not the HELO name’s', () => {
  const helo = (r: string) =>
    `spf=${r} (mx.cloudflare.net: no record) smtp.helo=mail.a.test`;
  const from = (r: string) =>
    `spf=${r} (mx.cloudflare.net: domain of a sender) smtp.mailfrom=w@a.test`;
  const header = (...parts: string[]) =>
    `mx.cloudflare.net;\n ${parts.join(';\n ')}`;
  equal(
    authResults([{
      key: 'authentication-results',
      value: header(
        'dkim=pass header.d=a.test header.s=s header.b=b',
        'dmarc=pass header.from=a.test policy.dmarc=none',
        helo('none'),
        from('pass'),
        'arc=pass smtp.remote-ip=192.0.2.1',
      ),
    }]),
    { spf: 'pass', dkim: 'pass', dmarc: 'pass' },
    'what Cloudflare writes for Gmail',
  );
  equal(spf(header(helo('none'), from('pass'))), 'pass', 'HELO none first');
  equal(spf(header(from('pass'), helo('none'))), 'pass', 'HELO none last');
  equal(spf(header(helo('none'))), 'none', 'only HELO');
  equal(spf(header(helo('pass'))), 'pass', 'only HELO, passing');
  equal(spf(header('spf=fail')), 'fail', 'no property');
  equal(spf(header('spf=pass', 'spf=fail')), 'pass', 'the first without one');
  equal(spf(header(helo('pass'), from('fail'))), 'fail', 'HELO cannot pass it');
  equal(spf(header(from('fail'), helo('pass'))), 'fail', 'in either order');
  equal(
    spf(header('spf=pass reason="ok" smtp.mailfrom=w@a.test')),
    'pass',
    'a reason before the property',
  );
  equal(
    spf(header('SPF=Pass SMTP.MailFrom=w@a.test')),
    'pass',
    'any case',
  );
  equal(
    spf(header(from('pass'), from('softfail'))),
    'softfail',
    'results that disagree do not pass',
  );
  equal(
    spf(header(from('fail'), from('pass'))),
    'fail',
    'in either order, the first that is not a pass',
  );
  equal(
    spf(`other.test; ${from('pass')}`),
    null,
    'another authserv-id',
  );
  equal(
    spf(`other.test; ${helo('none')}; ${from('pass')}`, 'other.test'),
    'pass',
    'a configured authserv-id',
  );
});

Deno.test('support-inbound files what this Worker posts, unlogged', async () => {
  const now = 1_800_000_000, filed: Inbound[] = [];
  const deps: Deps = {
    secret: 's3cret',
    now: () => now,
    newSecret: () => Promise.resolve({ secret: 's', hash: 'h' }),
    newReplyToken: () => Promise.resolve({ secret: 'r', hash: 'q' }),
    file: (mail) => {
      filed.push(mail);
      return Promise.resolve({ result: 'duplicate' });
    },
    notified: () => Promise.resolve(),
    receipt: () => Promise.resolve(true),
    caseLink: () => null,
    replyAddress: () => '',
    notifier: { notify: () => Promise.resolve(true) },
    adminUrl: () => '',
    background: () => {},
  };
  const body = payload(
    'support@motoparking.smvtstudio.com',
    'w@example.test',
    {
      headers: [{
        key: 'authentication-results',
        value: 'mx.cloudflare.net; dkim=pass header.d=example.test; ' +
          'dmarc=pass header.from=example.test; ' +
          'spf=none smtp.helo=m.example.test; ' +
          'spf=pass smtp.mailfrom=w@example.test',
      }],
      from: { address: 'w@example.test' },
      messageId: '<m@example.test>',
      attachments: [],
    },
  );
  equal('auth_trace' in body, false, 'no trace is sent');
  const logged: unknown[] = [], log = console.log;
  console.log = (...args: unknown[]) => logged.push(args);
  try {
    const res = await handle(
      await signedRequest('https://x.test/f', 's3cret', body, now),
      deps,
    );
    equal(res.status, 200, 'accepted');
  } finally {
    console.log = log;
  }
  equal(filed.length, 1, 'filed');
  equal(filed[0].spf, 'pass', 'the envelope sender passed');
  equal(logged, [], 'nothing logged');
});

Deno.test('text a sender writes cannot claim smtp.mailfrom', () => {
  const mx = 'mx.cloudflare.net;';
  equal(
    spf(`${mx} spf=none (smtp.mailfrom=x) smtp.helo=m.a.test`),
    'none',
    'in a comment',
  );
  equal(
    spf(`${mx} spf=none (a (b) smtp.mailfrom=x) smtp.helo=m.a.test`),
    'none',
    'in a nested comment',
  );
  equal(
    spf(`${mx} spf=fail smtp.helo="x smtp.mailfrom=y" ; spf=none`),
    'fail',
    'in quotes',
  );
  equal(
    spf(`${mx} spf=none smtp.helo=m.a.test smtp.mailfrom=x`),
    'none',
    'after another property',
  );
  equal(
    spf(`${mx} spf=fail smtp.mailfrom="x; spf=pass smtp.mailfrom=y"@a.test`),
    'fail',
    'a result inside quotes',
  );
  equal(
    spf(`${mx} spf=fail smtp.mailfrom=x (a (b); spf=pass smtp.mailfrom=y)`),
    'fail',
    'a result inside a nested comment cannot outvote a failure',
  );
  equal(
    spf(`${mx} spf=none smtp.helo=m.a.test; spf=fail reason="x" smtp.helo=y`),
    'none',
    'a reason does not make it the envelope sender',
  );
});
