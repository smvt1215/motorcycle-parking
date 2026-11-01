import { trustedIp } from './client_ip.ts';

function assertEquals(got: unknown, want: unknown) {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`expected ${b}, got ${a}`);
}

/** A request as it reaches the function behind Cloudflare. */
function arriving(headers: Record<string, string>): Request {
  return new Request('https://example.test/functions/v1/submit-report', {
    method: 'POST',
    headers,
  });
}

Deno.test('cf-connecting-ip: each client keeps its own network behind the same proxies', () => {
  // Two riders whose requests pass the same inner hops after Cloudflare:
  // X-Forwarded-For ends in the same proxy, cf-connecting-ip does not.
  const a = arriving({
    'cf-connecting-ip': '203.0.113.7',
    'x-forwarded-for': '203.0.113.7, 10.0.0.2',
  });
  const b = arriving({
    'cf-connecting-ip': '198.51.100.23',
    'x-forwarded-for': '198.51.100.23, 10.0.0.2',
  });
  assertEquals(trustedIp(a, 'cf-connecting-ip'), '203.0.113.7');
  assertEquals(trustedIp(b, 'cf-connecting-ip'), '198.51.100.23');
  // The reason X-Forwarded-For is not the configured header: its last hop
  // merges both riders into the proxy.
  assertEquals(trustedIp(a, 'x-forwarded-for'), '10.0.0.2');
  assertEquals(trustedIp(b, 'x-forwarded-for'), '10.0.0.2');
});

Deno.test('a forged X-Forwarded-For prefix is never the network', () => {
  // The client writes X-Forwarded-For itself; Cloudflare appends to it but
  // overwrites cf-connecting-ip with the address that connected.
  const req = arriving({
    'cf-connecting-ip': '203.0.113.7',
    'x-forwarded-for': '192.0.2.1, 203.0.113.7',
  });
  assertEquals(trustedIp(req, 'cf-connecting-ip'), '203.0.113.7');
  // Even a list in the trusted header yields its last hop, not the prefix.
  assertEquals(
    trustedIp(
      arriving({ 'cf-connecting-ip': '192.0.2.1, 203.0.113.7' }),
      'cf-connecting-ip',
    ),
    '203.0.113.7',
  );
});

Deno.test('IPv6 is accepted; a missing or malformed header is refused', () => {
  assertEquals(
    trustedIp(
      arriving({ 'cf-connecting-ip': '2001:db8::1' }),
      'cf-connecting-ip',
    ),
    '2001:db8::1',
  );
  assertEquals(trustedIp(arriving({}), 'cf-connecting-ip'), null);
  assertEquals(
    trustedIp(arriving({ 'cf-connecting-ip': 'unknown' }), 'cf-connecting-ip'),
    null,
  );
  assertEquals(
    trustedIp(arriving({ 'cf-connecting-ip': '' }), 'cf-connecting-ip'),
    null,
  );
});
