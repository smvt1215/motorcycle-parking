// The one-time link of a support request's confirmation mail (#285): the
// link carries `<request id>.<secret>`, the secret being 32 random bytes in
// base64url. Only the SHA-256 of the secret's bytes reaches the database
// (support_request_submit, support_request_confirm), which looks the request
// up by id and compares the hashes in constant time.

export const secretBytes = 32;

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// 32 bytes are 43 base64url characters without padding.
const secretText = /^[A-Za-z0-9_-]{43}$/;

function base64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(
    /=+$/,
    '',
  );
}

function fromBase64url(text: string): Uint8Array {
  const binary = atob(text.replaceAll('-', '+').replaceAll('_', '/') + '=');
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-256', bytes as Uint8Array<ArrayBuffer>),
  );
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export type Secret = { secret: string; hash: string };

/** A new secret and the hash to store; made for every request. */
export async function newSecret(
  random: (bytes: Uint8Array) => Uint8Array = (b) => crypto.getRandomValues(b),
): Promise<Secret> {
  const bytes = random(new Uint8Array(secretBytes));
  return { secret: base64url(bytes), hash: await sha256Hex(bytes) };
}

export const confirmToken = (id: string, secret: string) => `${id}.${secret}`;

/** The request id and the secret's hash; null for anything malformed. */
export async function parseConfirmToken(
  token: unknown,
): Promise<{ id: string; hash: string } | null> {
  if (typeof token !== 'string' || token.length > 100) return null;
  const [id, secret, ...rest] = token.trim().split('.');
  if (
    rest.length > 0 || !uuid.test(id ?? '') || !secretText.test(secret ?? '')
  ) {
    return null;
  }
  const bytes = fromBase64url(secret);
  if (bytes.length !== secretBytes) return null;
  return { id, hash: await sha256Hex(bytes) };
}
