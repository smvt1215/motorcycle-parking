import {
  accepts,
  authResults,
  payload,
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
  ];
  equal(
    authResults(headers),
    { spf: 'softfail', dkim: 'pass' },
    'the topmost of Cloudflare',
  );
  equal(
    authResults(headers.slice(1)),
    { spf: null, dkim: null },
    'a forged one counts as none',
  );
  equal(authResults([]), { spf: null, dkim: null }, 'none');
  equal(
    authResults([{
      key: 'Authentication-Results',
      value: 'mx.example; spf=pass',
    }], 'mx.example'),
    { spf: 'pass', dkim: null },
    'another authserv-id when configured',
  );
});

Deno.test('the payload carries no raw mail and attachments by name', () => {
  equal(
    payload('Support@MotoParking.smvtstudio.com', 'bounce@example.test', {
      headers: [{
        key: 'authentication-results',
        value: 'mx.cloudflare.net; spf=pass; dkim=pass',
      }],
      from: { address: 'Writer@Example.test' },
      subject: '費用',
      messageId: '<m1@example.test>',
      text: '內容',
      attachments: [{ filename: 'a.pdf' }, { filename: null }],
    }),
    {
      to: 'support@motoparking.smvtstudio.com',
      from: 'writer@example.test',
      subject: '費用',
      text: '內容',
      spf: 'pass',
      dkim: 'pass',
      attachments: ['a.pdf'],
      message_id: '<m1@example.test>',
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
