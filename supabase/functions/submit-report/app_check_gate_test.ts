import type { AppCheckResult } from '../_shared/app_check.ts';
import { appCheckGate } from './app_check_gate.ts';

/** Deep equality by JSON, enough for these plain values. */
function assertEquals(got: unknown, want: unknown) {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`expected ${b}, got ${a}`);
}

function request(token?: string): Request {
  return new Request('https://example.test/submit-report', {
    method: 'POST',
    headers: token ? { 'x-firebase-appcheck': token } : {},
  });
}

/** A verifier that records the tokens it was asked about. */
function verifier(result: AppCheckResult | null) {
  const seen: (string | null)[] = [];
  return {
    seen,
    verify: (token: string | null) => {
      seen.push(token);
      return Promise.resolve(result);
    },
  };
}

Deno.test('off: no verification, never refused, network capped', async () => {
  const v = verifier({ status: 'invalid', reason: 'bad' });
  assertEquals(await appCheckGate(request('t'), 'off', v.verify), {
    refused: false,
    ipCapped: true,
  });
  assertEquals(v.seen, []);
});

Deno.test('log: verifies the header token but never refuses', async () => {
  for (
    const result of [
      { status: 'missing' } as const,
      { status: 'invalid', reason: 'expired' } as const,
      { status: 'valid', appId: 'a' } as const,
      null,
    ]
  ) {
    const v = verifier(result);
    assertEquals(await appCheckGate(request('tok'), 'log', v.verify), {
      refused: false,
      ipCapped: true,
    });
    assertEquals(v.seen, ['tok']);
  }
});

Deno.test('log: a request without the header is verified as missing', async () => {
  const v = verifier({ status: 'missing' });
  await appCheckGate(request(), 'log', v.verify);
  assertEquals(v.seen, [null]);
});

Deno.test('enforce: refuses anything but valid; network not capped', async () => {
  for (
    const result of [
      { status: 'missing' } as const,
      { status: 'invalid', reason: 'audience' } as const,
      null,
    ]
  ) {
    assertEquals(
      await appCheckGate(request('tok'), 'enforce', verifier(result).verify),
      { refused: true, ipCapped: false },
    );
  }
  assertEquals(
    await appCheckGate(
      request('tok'),
      'enforce',
      verifier({ status: 'valid', appId: 'a' }).verify,
    ),
    { refused: false, ipCapped: false },
  );
});
