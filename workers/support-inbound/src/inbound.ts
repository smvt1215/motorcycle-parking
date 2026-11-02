// The pure part of the support-inbound Email Worker (#295 layer 2): which
// recipients it takes, the SPF and DKIM results it trusts, the JSON it posts
// and the signature on it. No Cloudflare or npm imports, so Deno tests it.

export const domain = 'motoparking.smvtstudio.com';
export const supportInbox = `support@${domain}`;
/** Cloudflare Email Routing's authserv-id (AUTHSERV_ID overrides it). */
export const defaultAuthservId = 'mx.cloudflare.net';
/** Larger mail is refused; attachments are not taken anyway. */
export const maxRawSize = 5 * 1024 * 1024;

const reply = new RegExp(
  `^reply\\+[a-z2-7]{32}@${domain.replaceAll('.', '\\.')}$`,
);

/** support@ or reply+<token>@: the only addresses this Worker takes. */
export function accepts(to: string): boolean {
  const a = to.trim().toLowerCase();
  return a === supportInbox || reply.test(a);
}

export type Header = { key: string; value: string };
export type AuthResults = { spf: string | null; dkim: string | null };

/**
 * SPF and DKIM from the topmost Authentication-Results whose authserv-id is
 * Cloudflare's. A sender can write its own Authentication-Results below it,
 * so any other is ignored; none at all gives nulls (suspicious).
 */
export function authResults(
  headers: Header[],
  authservId = defaultAuthservId,
): AuthResults {
  const header = headers.find((h) =>
    h.key.toLowerCase() === 'authentication-results' &&
    h.value.split(';')[0].trim().split(/\s+/)[0].toLowerCase() ===
      authservId.toLowerCase()
  );
  if (!header) return { spf: null, dkim: null };
  const found: Record<string, string[]> = { spf: [], dkim: [] };
  for (const part of header.value.split(';').slice(1)) {
    const m = /^\s*(spf|dkim)\s*=\s*([a-z]+)/i.exec(part);
    if (m) found[m[1].toLowerCase()].push(m[2].toLowerCase());
  }
  return {
    spf: found.spf[0] ?? null,
    // One passing signature is enough.
    dkim: found.dkim.includes('pass') ? 'pass' : found.dkim[0] ?? null,
  };
}

export type Parsed = {
  headers: Header[];
  from?: { address?: string };
  subject?: string;
  messageId?: string;
  text?: string;
  attachments: { filename: string | null }[];
};

/** The JSON for support-inbound: no raw mail, attachments by name only. */
export function payload(
  to: string,
  envelopeFrom: string,
  parsed: Parsed,
  authservId = defaultAuthservId,
) {
  const { spf, dkim } = authResults(parsed.headers, authservId);
  return {
    to: to.trim().toLowerCase(),
    // The header From is who the case belongs to; DKIM and SPF say how far
    // to trust it.
    from: (parsed.from?.address || envelopeFrom).trim().toLowerCase(),
    subject: (parsed.subject ?? '').slice(0, 200),
    text: (parsed.text ?? '').slice(0, 4000),
    spf,
    dkim,
    attachments: parsed.attachments.slice(0, 20).map((a) =>
      (a.filename ?? '').slice(0, 200)
    ).filter((name) => name !== ''),
    message_id: parsed.messageId ?? null,
  };
}

const encoder = new TextEncoder();

/** hex HMAC-SHA256 of `<timestamp>.<body>`, as support-inbound checks. */
export async function sign(
  secret: string,
  timestamp: string,
  body: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign(
      'HMAC',
      key,
      encoder.encode(`${timestamp}.${body}`),
    ),
  );
  return [...mac].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** The signed POST to support-inbound. */
export async function signedRequest(
  url: string,
  secret: string,
  body: unknown,
  now = Math.floor(Date.now() / 1000),
): Promise<Request> {
  const raw = JSON.stringify(body), timestamp = String(now);
  return new Request(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-support-timestamp': timestamp,
      'x-support-signature': await sign(secret, timestamp, raw),
    },
    body: raw,
  });
}
