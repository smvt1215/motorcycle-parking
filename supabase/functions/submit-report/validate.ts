const spaceTypes = [
  'paidMotorcycle',
  'freeMotorcycle',
  'heavyOnly',
  'car',
  'offStreet',
];
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function validate(body: Record<string, unknown>): string | null {
  if (typeof body.device_id !== 'string' || !uuid.test(body.device_id)) {
    return 'invalid device id';
  }
  if (
    !['create', 'vote', 'flag', 'update', 'delete'].includes(
      String(body.action),
    )
  ) return 'invalid action';
  if (
    ['vote', 'update', 'delete'].includes(String(body.action)) &&
    (typeof body.spot_id !== 'string' || !uuid.test(body.spot_id))
  ) return 'invalid spot id';
  if (
    body.action === 'vote' &&
    !['still_there', 'gone'].includes(String(body.vote))
  ) return 'invalid vote';
  if (
    body.action === 'flag' &&
    (typeof body.source_id !== 'string' || body.source_id.length < 1 ||
      body.source_id.length > 160)
  ) return 'invalid source id';
  if (
    body.action === 'flag' &&
    (typeof body.reason !== 'string' || body.reason.trim().length < 1 ||
      body.reason.length > 500)
  ) return 'invalid reason';
  if (
    body.note !== undefined &&
    (typeof body.note !== 'string' || body.note.length > 500)
  ) return 'invalid note';
  if (body.action === 'create' || body.action === 'update') {
    const s = body.spot as Record<string, unknown> | undefined;
    if (!s || typeof s !== 'object' || Array.isArray(s)) return 'invalid spot';
    if (
      typeof s.name !== 'string' || s.name.trim().length < 1 ||
      s.name.length > 100
    ) return 'invalid name';
    for (
      const [key, max] of [['fee_note', 200], ['note', 500], [
        'district',
        30,
      ]] as const
    ) {
      if (
        s[key] !== undefined &&
        (typeof s[key] !== 'string' || s[key].length > max)
      ) return `invalid ${key}`;
    }
    if (body.action === 'create') {
      if (
        typeof s.lat !== 'number' || !Number.isFinite(s.lat) || s.lat < 20 ||
        s.lat > 27 || typeof s.lng !== 'number' || !Number.isFinite(s.lng) ||
        s.lng < 118 || s.lng > 123
      ) return 'invalid coordinates';
      if (
        typeof s.city !== 'string' || s.city.length < 1 || s.city.length > 30
      ) return 'invalid city';
      if (!spaceTypes.includes(String(s.space_type))) {
        return 'invalid space type';
      }
      for (const key of ['heavy_allowed', 'scooter_allowed']) {
        if (
          s[key] !== undefined && s[key] !== null && typeof s[key] !== 'boolean'
        ) return `invalid ${key}`;
      }
    }
  }
  return null;
}
export async function identityHash(
  secret: string,
  value: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const digest = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(value),
  );
  return Array.from(
    new Uint8Array(digest),
    (x) => x.toString(16).padStart(2, '0'),
  ).join('');
}
