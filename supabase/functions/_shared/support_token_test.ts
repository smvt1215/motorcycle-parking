import {
  confirmToken,
  newSecret,
  parseConfirmToken,
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
