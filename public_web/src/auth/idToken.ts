/**
 * A nonce for one ID-token sign-in. The provider is given `hashed` and puts
 * it in the token's nonce claim; the backend and Supabase Auth are sent
 * `raw` and compare the claim with its hex SHA-256.
 */
export interface Nonce {
  raw: string;
  hashed: string;
}

function base64Url(bytes: Uint8Array): string {
  let binary = '';
  bytes.forEach((byte) => (binary += String.fromCharCode(byte)));
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** A random string for `state` or a nonce. */
export function randomToken(): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function makeNonce(): Promise<Nonce> {
  const raw = randomToken();
  return { raw, hashed: await sha256Hex(raw) };
}

/** The claims the page reads from an ID token (unverified: display and matching only). */
export interface IdTokenClaims {
  sub: string | null;
  email: string | null;
}

/** Reads an ID token's payload without checking it; the backend checks it. */
export function idTokenClaims(token: string): IdTokenClaims {
  try {
    const part = token.split('.')[1] ?? '';
    const padded = part.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (part.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
    const payload = JSON.parse(new TextDecoder().decode(bytes)) as { sub?: unknown; email?: unknown };
    return {
      sub: typeof payload.sub === 'string' ? payload.sub : null,
      email: typeof payload.email === 'string' && payload.email ? payload.email : null,
    };
  } catch {
    return { sub: null, email: null };
  }
}
