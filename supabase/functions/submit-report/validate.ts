const spaceTypes = [
  'paidMotorcycle',
  'freeMotorcycle',
  'heavyOnly',
  'car',
  'offStreet',
  'disabledMotorcycle',
  'timedMotorcycle',
  'flexShared',
  'evMotorcycle',
];
// Suggestion categories the app sends as `field`: stable keys, plus the
// Chinese labels sent before the keys existed. The readable summary stays in
// `reason` for older app versions.
const suggestionFields = [
  'name',
  'space_type',
  'fee_note',
  'eligibility',
  'note',
  'gone',
  '停車點名稱',
  '格位類型',
  '收費資訊',
  '機車停放資格',
  '位置或其他備註',
  '點位已不存在',
];
const text = (max: number, min = 0) => (v: unknown) =>
  typeof v === 'string' && v.trim().length >= min && v.length <= max;
// A real string, not one coerced from an array: ['x'] must not pass as 'x'.
const oneOf = (values: string[]) => (v: unknown) =>
  v === null || (typeof v === 'string' && values.includes(v));
const flag = (v: unknown) => v === null || typeof v === 'boolean';
const coordinate = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
// Whole yuan or minutes in range; never a string or a fraction.
const whole = (v: unknown, min: number, max: number) =>
  typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;
// The keys each fee mode uses (202610250010_spot_fee.sql holds the same).
const rateKeys: Record<string, string[]> = {
  free: [],
  posted: [],
  same_as_scooter: [],
  same_as_car: [],
  hourly: ['amount', 'per_minutes', 'daily_cap'],
  per_visit: ['amount', 'max_minutes'],
  daily: ['amount'],
};
function validRate(v: unknown, heavy: boolean): boolean {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return false;
  const r = v as Record<string, unknown>;
  const mode = r.mode;
  if (typeof mode !== 'string' || !Object.hasOwn(rateKeys, mode)) return false;
  // Only heavy bikes may follow another vehicle's rate.
  if (mode.startsWith('same_as_') && !heavy) return false;
  if (Object.keys(r).some((k) => k !== 'mode' && !rateKeys[mode].includes(k))) {
    return false;
  }
  const optional = (key: string, min: number, max: number) =>
    !(key in r) || whole(r[key], min, max);
  return mode === 'hourly'
    ? whole(r.amount, 0, 10000) && whole(r.per_minutes, 1, 1440) &&
      optional('daily_cap', 0, 10000)
    : mode === 'per_visit'
    ? whole(r.amount, 0, 10000) && optional('max_minutes', 1, 1440)
    : mode === 'daily'
    ? whole(r.amount, 0, 10000)
    : true;
}
const facilityTypes = ['multiStorey', 'underground', 'surface', 'roadside'];
const accessKinds = [
  'scooterOnly',
  'scooterHeavy',
  'heavyCar',
  'noMotorcycle',
  'heavyOnly',
];
/** A lot's zones as riders report them: named, with access and a guide. */
export function validZones(v: unknown): boolean {
  if (!Array.isArray(v) || v.length > 10) return false;
  return v.every((z) => {
    if (!z || typeof z !== 'object' || Array.isArray(z)) return false;
    const zone = z as Record<string, unknown>;
    return Object.keys(zone).every((k) =>
      ['name', 'access', 'guide'].includes(k)
    ) &&
      text(40, 1)(zone.name) &&
      (!('access' in zone) || oneOf(accessKinds)(zone.access)) &&
      (!('guide' in zone) || text(200)(zone.guide));
  });
}
/** A rate per vehicle; a missing vehicle is unconfirmed. */
export function validFee(v: unknown): boolean {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return false;
  const f = v as Record<string, unknown>;
  return Object.keys(f).every((k) => k === 'scooter' || k === 'heavy') &&
    (!('scooter' in f) || validRate(f.scooter, false)) &&
    (!('heavy' in f) || validRate(f.heavy, true));
}
// Mirrors the columns admin_resolve_report may patch, plus how riders ask to
// take a spot down: status for community spots, hidden for official ones.
const proposedChecks: Record<string, (v: unknown) => boolean> = {
  name: text(100, 1),
  lat: coordinate,
  lng: coordinate,
  city: text(30, 1),
  district: text(30),
  space_type: (v) => typeof v === 'string' && spaceTypes.includes(v),
  fee_note: text(200),
  note: text(500),
  scooter_allowed: flag,
  heavy_allowed: flag,
  facility_type: oneOf(facilityTypes),
  parking_access: oneOf(accessKinds),
  address: text(200),
  road_segment: text(200),
  entrance_note: text(500),
  parking_guide: text(500),
  special_rules: text(500),
  fee: validFee,
  status: (v) => v === 'hidden',
  // Riders ask to take a spot down; restoring one is an admin decision.
  hidden: (v) => v === true,
};
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
    body.action === 'flag' && body.field !== undefined &&
    (typeof body.field !== 'string' || !suggestionFields.includes(body.field))
  ) return 'invalid field';
  // A suggested value set: only columns an admin can apply as a patch, each
  // with the type and length its table allows.
  if (body.action === 'flag' && body.proposed !== undefined) {
    const p = body.proposed as Record<string, unknown>;
    if (!p || typeof p !== 'object' || Array.isArray(p)) {
      return 'invalid proposed';
    }
    const entries = Object.entries(p);
    if (entries.length < 1 || entries.length > 20) return 'invalid proposed';
    const official = String(body.source_id).startsWith('official:');
    for (const [key, value] of entries) {
      // Own keys only: `toString` or `__proto__` must not find a prototype member.
      const check = Object.hasOwn(proposedChecks, key)
        ? proposedChecks[key]
        : undefined;
      // Community spots are hidden by status, official spots by a flag.
      if (
        !check || (key === 'status' && official) ||
        (key === 'hidden' && !official) || !check(value)
      ) return 'invalid proposed';
    }
    if (
      ('lat' in p &&
        (typeof p.lat !== 'number' || p.lat < 20 || p.lat > 27)) ||
      ('lng' in p &&
        (typeof p.lng !== 'number' || p.lng < 118 || p.lng > 123))
    ) return 'invalid coordinates';
  }
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
      if (s.fee !== undefined && s.fee !== null && !validFee(s.fee)) {
        return 'invalid fee';
      }
      // Lot details, each optional and checked like the columns they fill.
      for (
        const [key, check] of [
          ['facility_type', oneOf(facilityTypes)],
          ['parking_access', oneOf(accessKinds)],
          ['entrance_note', text(500)],
          ['parking_guide', text(500)],
          ['parking_zones', validZones],
        ] as const
      ) {
        if (s[key] !== undefined && !check(s[key])) return `invalid ${key}`;
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
