import contract from '../_shared/parking_contract.json' with { type: 'json' };
import {
  freeFeeNoteMaxLength,
  subset,
  validFee,
  validFeeNote,
  validProposedFee,
  validSlotTimes,
} from '../_shared/fee.ts';

export { validFee, validSlotTimes };

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
  'guide',
  'location',
  'gone',
  // A rider at a lapsed closure: 已經可以停 (#116).
  'reopened',
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
// Parking conditions (docs/designs/2026-10-26-parking-conditions-and-fees.md
// §1.2, §4): the rules come from _shared/parking_contract.json, which
// lib/models/parking_condition.dart mirrors and tool/gen_contract_sql.py turns
// into valid_condition(). New spots and suggestions carry it (C5).
const cond = contract.condition;
const isObject = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === 'object' && !Array.isArray(v);
const has = (o: Record<string, unknown>, k: string) => Object.hasOwn(o, k);
const realDate = (v: unknown) => {
  if (typeof v !== 'string' || !new RegExp(contract.date.pattern).test(v)) {
    return false;
  }
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().startsWith(v);
};
const inList = (list: string[]) => (v: unknown) =>
  typeof v === 'string' && list.includes(v);
/**
 * A condition the contract accepts. A zone may carry `allow` and leave its
 * bay unconfirmed; a street condition names its bay and, on a motorcycle
 * bay, toll or free unless a limit decides the legacy space type.
 */
export function validCondition(v: unknown, zone = false): boolean {
  if (!isObject(v) || Object.keys(v).length === 0) return false;
  if (
    !Object.keys(v).every((k) =>
      cond.keys.includes(k) || (zone && cond.zone_keys.includes(k))
    )
  ) return false;
  const shares = cond.share as Record<string, string>;
  for (
    const [key, ok] of [
      ['bay', inList(cond.bay)],
      ['use', inList(cond.use)],
      ['share', inList(Object.keys(shares))],
      ['charge', inList(cond.charge)],
    ] as const
  ) {
    if (has(v, key) && !ok(v[key])) return false;
  }
  if (!zone && !has(v, 'bay')) return false;
  if (has(v, 'share') !== (v.use === 'share')) return false;
  if (has(v, 'share') && v.bay !== shares[v.share as string]) return false;

  const limitSpecs = cond.limits as Record<
    string,
    {
      required: string[];
      optional: Record<string, { min: number; max: number }>;
    }
  >;
  const kinds = new Set<string>();
  if (has(v, 'limits')) {
    const limits = v.limits;
    if (
      !Array.isArray(limits) || limits.length === 0 ||
      limits.length > Object.keys(limitSpecs).length
    ) return false;
    for (const l of limits) {
      if (!isObject(l) || typeof l.kind !== 'string') return false;
      const spec = Object.hasOwn(limitSpecs, l.kind)
        ? limitSpecs[l.kind]
        : undefined;
      if (!spec || kinds.has(l.kind)) return false;
      kinds.add(l.kind);
      for (const [key, value] of Object.entries(l)) {
        if (key === 'kind' || spec.required.includes(key)) continue;
        const range = Object.hasOwn(spec.optional, key)
          ? spec.optional[key]
          : undefined;
        if (!range || !whole(value, range.min, range.max)) return false;
      }
      if (!spec.required.every((k) => has(l, k))) return false;
      if (has(l, 'vehicle') && !inList(cond.special_vehicles)(l.vehicle)) {
        return false;
      }
      // A limit's periods (時段性禁停, decision 62): like schedule slots,
      // without vehicles.
      if (has(l, 'periods')) {
        const periods = l.periods;
        if (
          !Array.isArray(periods) || periods.length === 0 ||
          periods.length > cond.limit_periods.max_entries ||
          !periods.every((p) =>
            isObject(p) &&
            Object.keys(p).every((k) => cond.limit_periods.keys.includes(k)) &&
            validSlotTimes(p)
          )
        ) return false;
      }
    }
  }
  if (
    !zone && v.bay === 'motorcycle' && !has(v, 'charge') &&
    !cond.street_charge_optional_with.some((k) => kinds.has(k))
  ) return false;

  if (has(v, 'allow')) {
    const allow = v.allow;
    if (
      !isObject(allow) || Object.keys(allow).length === 0 ||
      !Object.entries(allow).every(([k, x]) =>
        cond.allow_keys.includes(k) && typeof x === 'boolean'
      )
    ) return false;
    if (allow.scooter === true && v.bay === 'heavy') return false;
  }

  if (has(v, 'schedule')) {
    const schedule = v.schedule;
    if (
      !Array.isArray(schedule) || schedule.length === 0 ||
      schedule.length > cond.schedule.max_entries
    ) return false;
    for (const s of schedule) {
      if (
        !isObject(s) ||
        !Object.keys(s).every((k) => cond.schedule.keys.includes(k)) ||
        !validSlotTimes(s) ||
        !subset(s.vehicles, cond.schedule.vehicles)
      ) return false;
    }
  }

  if (has(v, 'basis')) {
    const basis = v.basis;
    if (
      !isObject(basis) ||
      !Object.keys(basis).every((k) => cond.basis.keys.includes(k))
    ) return false;
    // Reserved until photo evidence ships (verification plan P2).
    if (cond.basis.reserved.some((k) => basis[k] != null)) return false;
    if (!cond.basis.required_one_of.some((k) => basis[k] != null)) {
      return false;
    }
    const url = basis.source_url;
    if (
      has(basis, 'source_url') &&
      (typeof url !== 'string' ||
        url.length > cond.basis.source_url.max_length ||
        !new RegExp(cond.basis.source_url.pattern).test(url))
    ) return false;
    for (const key of ['effective_date', 'expires_on']) {
      if (basis[key] != null && !realDate(basis[key])) return false;
    }
    const from = basis.effective_date, to = basis.expires_on;
    if (typeof from === 'string' && typeof to === 'string' && to <= from) {
      return false;
    }
  }
  return true;
}
/**
 * The legacy `space_type` a condition is stored under (§1.3): the first
 * `to_space_type` rule that matches, or null.
 */
export function legacySpaceType(
  c: Record<string, unknown>,
  offStreet: boolean,
): string | null {
  const limits = Array.isArray(c.limits) ? c.limits : [];
  for (const { when, space_type } of contract.conversion.to_space_type) {
    const w = when as Record<string, string | undefined>;
    if (
      (!('placement' in w) || (w.placement === 'off_street') === offStreet) &&
      (!('limit' in w) ||
        limits.some((l) => isObject(l) && l.kind === w.limit)) &&
      ['share', 'bay', 'charge'].every((k) => !(k in w) || c[k] === w[k])
    ) return space_type;
  }
  return null;
}
/**
 * The legacy `access` a zone condition is written back as (§1.3,
 * `to_access`): the `from_access` entry with the same `allow` and, when the
 * entry names a bay, the same bay; null when none matches.
 */
export function legacyAccess(c: Record<string, unknown>): string | null {
  if (!isObject(c.allow)) return null;
  const allow = c.allow;
  for (
    const [access, entry] of Object.entries(contract.conversion.from_access)
  ) {
    const e = entry as { bay?: string; allow: Record<string, boolean> };
    if (
      cond.allow_keys.every((k: string) => allow[k] === e.allow[k]) &&
      (e.bay === undefined || c.bay === e.bay)
    ) return access;
  }
  return null;
}
/**
 * Whether a zone's access agrees with its condition (decision 32, §1.3): a
 * zone without a condition is unchecked; one with a condition carries an
 * `allow` naming both vehicles and the access it writes back. The same rule
 * as `zone_condition_consistent()` in SQL.
 */
export function zoneConditionConsistent(
  zone: Record<string, unknown>,
): boolean {
  if (zone.condition === undefined || zone.condition === null) return true;
  if (!isObject(zone.condition) || typeof zone.access !== 'string') {
    return false;
  }
  return zone.access === legacyAccess(zone.condition);
}
const facilityTypes: string[] = contract.placement.facility_types;
/**
 * The facility types of one spot (decision 58): one or more distinct types
 * of the contract; the table stores them in the contract's order.
 */
export function validFacilityTypes(v: unknown): boolean {
  return Array.isArray(v) && v.length >= 1 &&
    v.length <= facilityTypes.length &&
    v.every((t) => typeof t === 'string' && facilityTypes.includes(t)) &&
    new Set(v).size === v.length;
}
const offStreetSpaceTypes: string[] = contract.placement.off_street_space_types;
const offStreetFacilityTypes: string[] =
  contract.placement.off_street_facility_types;
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
      ['name', 'access', 'area', 'guide', 'fee'].includes(k)
    ) &&
      text(40, 1)(zone.name) &&
      (!('access' in zone) || oneOf(accessKinds)(zone.access)) &&
      (!('area' in zone) || inList(contract.zone.area)(zone.area)) &&
      (!('guide' in zone) || text(200)(zone.guide)) &&
      (!('fee' in zone) || validFee(zone.fee)) &&
      // Riders send no zone condition yet; the check keeps the DB rule in
      // step if they ever do (202610270020).
      zoneConditionConsistent(zone);
  });
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
  // Free text up to 200, or the proposed fee's own text (checked below).
  fee_note: (v) => typeof v === 'string',
  note: text(500),
  scooter_allowed: flag,
  heavy_allowed: flag,
  facility_type: oneOf(facilityTypes),
  // null clears them, as it clears facility_type.
  facility_types: (v) => v === null || validFacilityTypes(v),
  parking_access: oneOf(accessKinds),
  address: text(200),
  road_segment: text(200),
  entrance_note: text(500),
  parking_guide: text(500),
  special_rules: text(500),
  // Merged per vehicle: null clears a vehicle, one left out keeps its rate.
  fee: validProposedFee,
  // Checked with the space type beside it (validProposedCondition).
  condition: (v) => v === null || isObject(v),
  status: (v) => v === 'hidden',
  // Riders ask to take a spot down; restoring one is an admin decision.
  hidden: (v) => v === true,
  // Works or a closure (#116): the cause and the date the notice gives;
  // null says it is over. The start and basis are the reviewer's.
  closure: validProposedClosure,
};
const locationKeys = ['lat', 'lng', 'city', 'district'];
/** A suggested closure: `{reason: works|closed, until?: YYYY-MM-DD}` or null. */
function validProposedClosure(v: unknown): boolean {
  if (v === null) return true;
  if (!isObject(v)) return false;
  const c = v as Record<string, unknown>;
  if (Object.keys(c).some((k) => k !== 'reason' && k !== 'until')) {
    return false;
  }
  if (c.reason !== 'works' && c.reason !== 'closed') return false;
  if (!('until' in c)) return true;
  if (typeof c.until !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(c.until)) {
    return false;
  }
  const d = new Date(`${c.until}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) &&
    d.toISOString().slice(0, 10) === c.until;
}
/**
 * The notice a rider attaches as evidence (§1.4, §4.2): an https link kept
 * with the case, never written to the spot. Same limits as a basis link.
 */
export const validEvidenceUrl = (v: unknown) =>
  typeof v === 'string' && v.length <= cond.basis.source_url.max_length &&
  new RegExp(cond.basis.source_url.pattern).test(v);
/**
 * A suggested street condition (decision 33): the contract's, without a
 * basis (a notice travels as `evidence_url`), with the space type it is
 * stored under beside it; null drops the condition (also when the bay
 * becomes a lot, whose conditions live in its zones).
 */
function validProposedCondition(p: Record<string, unknown>): boolean {
  if (!('condition' in p)) return true;
  const type = p.space_type;
  if (typeof type !== 'string') return false;
  // A lot drops a stored street condition; it never carries one.
  if (p.condition === null) return true;
  if (offStreetSpaceTypes.includes(type)) return false;
  return validCondition(p.condition) &&
    !Object.hasOwn(p.condition as object, 'basis') &&
    legacySpaceType(p.condition as Record<string, unknown>, false) === type;
}
const withoutCleared = (fee: unknown) =>
  fee && typeof fee === 'object' && !Array.isArray(fee)
    ? Object.fromEntries(Object.entries(fee).filter(([, v]) => v !== null))
    : fee;
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
    // A long note is the sentence of the rates the suggestion names; a
    // vehicle it clears (null) is not one of them.
    if ('fee_note' in p && !validFeeNote(p.fee_note, withoutCleared(p.fee))) {
      return 'invalid proposed';
    }
    if (!validProposedCondition(p)) return 'invalid proposed';
    if (
      ('lat' in p &&
        (typeof p.lat !== 'number' || p.lat < 20 || p.lat > 27)) ||
      ('lng' in p &&
        (typeof p.lng !== 'number' || p.lng < 118 || p.lng > 123))
    ) return 'invalid coordinates';
    // The county and district only travel with the position they describe.
    if (('city' in p || 'district' in p) && !('lat' in p && 'lng' in p)) {
      return 'invalid proposed';
    }
    // A location suggestion is a position: both coordinates, plus the county
    // and district the app looked up, and nothing else.
    if (
      body.field === 'location' &&
      (!('lat' in p) || !('lng' in p) ||
        Object.keys(p).some((k) => !locationKeys.includes(k)))
    ) return 'invalid proposed';
  }
  if (
    body.note !== undefined &&
    (typeof body.note !== 'string' || body.note.length > 500)
  ) return 'invalid note';
  if (
    body.evidence_url !== undefined &&
    (!['create', 'flag'].includes(String(body.action)) ||
      !validEvidenceUrl(body.evidence_url))
  ) return 'invalid evidence_url';
  if (body.action === 'create' || body.action === 'update') {
    const s = body.spot as Record<string, unknown> | undefined;
    if (!s || typeof s !== 'object' || Array.isArray(s)) return 'invalid spot';
    if (
      typeof s.name !== 'string' || s.name.trim().length < 1 ||
      s.name.length > 100
    ) return 'invalid name';
    // A fee note longer than free text must be the new spot's fee's text.
    if (
      s.fee_note !== undefined &&
      !(body.action === 'create'
        ? validFeeNote(s.fee_note, s.fee)
        : typeof s.fee_note === 'string' &&
          s.fee_note.length <= freeFeeNoteMaxLength)
    ) return 'invalid fee_note';
    for (
      const [key, max] of [['note', 500], ['district', 30]] as const
    ) {
      if (
        s[key] !== undefined &&
        (typeof s[key] !== 'string' || s[key].length > max)
      ) return `invalid ${key}`;
    }
    // The source link is an admin's (imports, official spots), never a
    // rider's; the table takes only https (202610270040), and the app opens
    // nothing else. apply_report would drop it anyway: refuse it outright.
    if ('source_url' in s) return 'invalid source_url';
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
      // The bay's condition (docs/designs/2026-10-26-parking-conditions-and-fees.md
      // §4.2): a street spot's only, stored under the space type it decides.
      // Riders never write its basis or zones_complete: a notice travels with
      // a report as evidence, and admins decide (§1.4).
      if ('zones_complete' in s) return 'invalid zones_complete';
      if (s.condition !== undefined && s.condition !== null) {
        // Any lot type among the facility types places it off the street.
        const offStreet = offStreetSpaceTypes.includes(String(s.space_type)) ||
          offStreetFacilityTypes.includes(String(s.facility_type)) ||
          (Array.isArray(s.facility_types) &&
            s.facility_types.some((t) =>
              offStreetFacilityTypes.includes(String(t))
            ));
        if (
          offStreet || !validCondition(s.condition) ||
          Object.hasOwn(s.condition as object, 'basis') ||
          legacySpaceType(s.condition as Record<string, unknown>, false) !==
            s.space_type
        ) return 'invalid condition';
      }
      // Lot details, each optional and checked like the columns they fill.
      for (
        const [key, check] of [
          ['facility_type', oneOf(facilityTypes)],
          ['facility_types', validFacilityTypes],
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
