import {
  accepts,
  authResults,
  payload,
  rawDigest,
  sign,
  signedRequest,
} from './inbound.ts';
import { sign as checked } from '../../../supabase/functions/support-inbound/handler.ts';

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
