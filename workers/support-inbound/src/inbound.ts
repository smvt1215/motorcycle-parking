// The pure part of the support-inbound Email Worker (#295 layer 2): which
// recipients it takes, the SPF and DKIM results it trusts, the JSON it posts
// and the signature on it. No Cloudflare or npm imports, so Deno tests it.

export const domain = 'motoparking.smvtstudio.com';
export const supportInbox = `support@${domain}`;
/** Cloudflare Email Routing's authserv-id (AUTHSERV_ID overrides it). */
export const defaultAuthservId = 'mx.cloudflare.net';
/** Larger mail is refused; attachments are not taken anyway. */
export const maxRawSize = 5 * 1024 * 1024;

const replyLocal = /^reply\+[a-z2-7]{32}$/;

/** support@ or reply+<token>@: the only addresses this Worker takes. */
export function accepts(to: string): boolean {
  const a = to.trim().toLowerCase();
  if (a === supportInbox) return true;
  const at = a.lastIndexOf('@');
  // The domain is compared as a whole string, never as a pattern.
  return at > 0 && a.slice(at + 1) === domain &&
    replyLocal.test(a.slice(0, at));
}

export type Header = { key: string; value: string };
export type AuthResults = {
  spf: string | null;
  dkim: string | null;
  dmarc: string | null;
};

/**
 * [value] without comments (which nest, RFC 5322) and with each quoted string
 * emptied to `""`; a backslash escapes the next character in both. Null when
 * a comment or string is not closed or a `)` has no `(`. Removing only the
 * innermost parentheses with a regex left the rest of a nested comment
 * behind as if it were a result (#393).
 */
function stripQuotedAndComments(value: string): string | null {
  let out = '', depth = 0, quoted = false;
  for (let i = 0; i < value.length; i++) {
    const c = value[i];
    if (c === '\\') {
      i++;
      if (i >= value.length) return null;
      if (depth === 0 && !quoted) out += c + value[i];
    } else if (quoted) {
      if (c === '"') quoted = false;
    } else if (depth > 0) {
      if (c === '(') depth++;
      else if (c === ')') depth--;
    } else if (c === '(') depth++;
    else if (c === ')') return null;
    else if (c === '"') {
      quoted = true;
      out += '""';
    } else out += c;
  }
  return depth === 0 && !quoted ? out : null;
}

/**
 * SPF, DKIM and DMARC from the topmost Authentication-Results whose
 * authserv-id is Cloudflare's. A sender can write its own
 * Authentication-Results below it, so any other is ignored; none at all
 * gives nulls (suspicious). SPF and DKIM can pass for the sender's own
 * domain while the From header names someone else; only DMARC checks that
 * the authenticated domain matches From (Codex review, PR #306).
 *
 * Cloudflare gives SPF twice, for the HELO name and for the envelope sender,
 * and the envelope sender's is the one DMARC and receipts are about: a Gmail
 * server's HELO name has no SPF record, so spf=none came first on mail that
 * passed. Only a smtp.mailfrom right after its result counts, so text in a
 * comment or after another property cannot claim it. Results that disagree
 * do not pass; with no smtp.mailfrom at all, the first SPF result stands.
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
  if (!header) return { spf: null, dkim: null, dmarc: null };
  const found: Record<string, string[]> = { spf: [], dkim: [], dmarc: [] };
  // Quoted strings and comments carry sender-chosen text (smtp.mailfrom can
  // be "x;dkim=pass"@evil.test): dropped before splitting (cross review,
  // PR #306).
  const value = stripQuotedAndComments(header.value);
  // Malformed (unbalanced) text cannot be trusted to say what is a result.
  if (value === null) return { spf: null, dkim: null, dmarc: null };
  const mailfrom: string[] = [];
  for (const part of value.split(';').slice(1)) {
    const m = /^\s*(spf|dkim|dmarc)\s*=\s*([a-z]+)/i.exec(part);
    if (!m) continue;
    const method = m[1].toLowerCase(), result = m[2].toLowerCase();
    found[method].push(result);
    if (
      method === 'spf' &&
      /^(?:\s+reason\s*=\s*\S+)?\s+smtp\.mailfrom\s*=/i.test(
        part.slice(m[0].length),
      )
    ) mailfrom.push(result);
  }
  return {
    spf: mailfrom.find((r) => r !== 'pass') ?? mailfrom[0] ?? found.spf[0] ??
      null,
    // One passing signature is enough.
    dkim: found.dkim.includes('pass') ? 'pass' : found.dkim[0] ?? null,
    dmarc: found.dmarc[0] ?? null,
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
/** [text] cut to [max] code points: slicing UTF-16 units could split an
 * emoji's surrogate pair, and the lone half then fails the RPC's JSON on
 * every retry (Codex review, PR #306). */
export function clip(text: string, max: number): string {
  return text.length <= max ? text : [...text].slice(0, max).join('');
}

export function payload(
  to: string,
  envelopeFrom: string,
  parsed: Parsed,
  authservId = defaultAuthservId,
  rawSha256: string | null = null,
) {
  const { spf, dkim, dmarc } = authResults(parsed.headers, authservId);
  return {
    to: to.trim().toLowerCase(),
    // The header From is who the case belongs to; DKIM and SPF say how far
    // to trust it.
    from: (parsed.from?.address || envelopeFrom).trim().toLowerCase(),
    subject: clip(parsed.subject ?? '', 200),
    text: clip(parsed.text ?? '', 4000),
    spf,
    dkim,
    dmarc,
    attachments: parsed.attachments.slice(0, 20).map((a) =>
      clip(a.filename ?? '', 200)
    ).filter((name) => name !== ''),
    message_id: parsed.messageId ?? null,
    // The same mail delivered again has the same digest, so a mail without
    // a Message-ID is still filed once (Codex review, PR #306).
    raw_sha256: rawSha256,
  };
}

/** The hex SHA-256 of the raw mail. */
export async function rawDigest(raw: ArrayBuffer): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', raw));
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
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
