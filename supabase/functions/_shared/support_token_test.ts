import {
  confirmToken,
  newReplyToken,
  newSecret,
  parseConfirmToken,
  parseReplyAddress,
  replyAddress,
  replyTokenHash,
  secretBytes,
} from './support_token.ts';

function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

const id = '20000000-0000-4000-8000-000000000001';

Deno.test('a secret round-trips to the same hash', async () => {
  const made = await newSecret();
  equal(made.secret.length, 43, '32 bytes in base64url');
  equal(/^[0-9a-f]{64}$/.test(made.hash), true, 'hex SHA-256');
  equal(
    await parseConfirmToken(confirmToken(id, made.secret)),
    { id, hash: made.hash },
    'parsed',
  );
});

Deno.test('the hash is the SHA-256 of the secret bytes', async () => {
  const made = await newSecret((b) => b.fill(0));
  equal(made.secret, 'A'.repeat(43), 'zero bytes');
  // SHA-256 of 32 zero bytes.
  equal(
    made.hash,
    '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925',
    'digest',
  );
  equal(secretBytes, 32, 'at least 32 bytes');
});

Deno.test('every new secret differs', async () => {
  const a = await newSecret(), b = await newSecret();
  equal(a.secret === b.secret, false, 'random');
});

Deno.test('malformed tokens are refused', async () => {
  const good = 'A'.repeat(43);
  for (
    const token of [
      undefined,
      42,
      '',
      good,
      `${id}.${good}.x`,
      `not-a-uuid.${good}`,
      `${id}.${good.slice(1)}`,
      `${id}.${good}A`,
      `${id}.${'+'.repeat(43)}`,
      `ABCDEF00-0000-4000-8000-000000000001.${good}`,
    ]
  ) equal(await parseConfirmToken(token), null, String(token));
});

Deno.test('a reply token fits an address and hashes its text', async () => {
  const made = await newReplyToken();
  equal(/^[a-z2-7]{32}$/.test(made.secret), true, '32 base32 characters');
  equal(made.hash, await replyTokenHash(made.secret), 'hash of the text');
  const zero = await newReplyToken((b) => b.fill(0));
  equal(zero.secret, 'a'.repeat(32), 'zero bytes');
  // SHA-256 of 32 ASCII "a".
  equal(
    zero.hash,
    '3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547',
    'the database gets the SHA-256 of the text',
  );
});

Deno.test('only reply+<token>@ our domain is a reply address', () => {
  const token = 'abcdefghijklmnopqrstuvwxyz234567';
  equal(
    parseReplyAddress(replyAddress(token)),
    token,
    'round trip',
  );
  equal(
    parseReplyAddress(
      ` Reply+${token.toUpperCase()}@MotoParking.SmvtStudio.com `,
    ),
    token,
    'any case',
  );
  equal(
    parseReplyAddress('support@motoparking.smvtstudio.com'),
    null,
    'support@',
  );
  equal(parseReplyAddress(`reply+${token}@evil.test`), null, 'another domain');
  equal(
    parseReplyAddress(`reply+${token}x@motoparking.smvtstudio.com`),
    null,
    'too long',
  );
  equal(
    parseReplyAddress(`reply+${token.slice(1)}1@motoparking.smvtstudio.com`),
    null,
    'not base32',
  );
  equal(parseReplyAddress(42), null, 'not a string');
});
