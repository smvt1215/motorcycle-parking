import contract from '../_shared/parking_contract.json' with { type: 'json' };
import {
  feeWriteComplete,
  freeFeeNoteMaxLength,
  rateWriteComplete,
  subset,
  validFee,
  validFeeNote,
  validProposedFee,
  validSlotTimes,
} from '../_shared/fee.ts';

export { feeWriteComplete, rateWriteComplete, validFee, validSlotTimes };

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
  // A lot's zones or a street spot's segments, by id (#188).
  'zones',
  'segments',
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
const coordinate = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
// Whole yuan or minutes in range; never a string or a fraction.
const whole = (v: unknown, min: number, max: number) =>
  typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;
// Parking conditions (docs/designs/2026-10-26-parking-conditions-and-fees.md
// §1.2, §4): the rules come from _shared/parking_contract.json, which
// lib/models/parking_condition.dart mirrors and tool/gen_contract_sql.py turns
// into valid_condition(). New spots and suggestions carry it (C5).
const cond = contract.condition;
// Eligibility (#201): true, false or not_stated; null is old data's 待確認.
const notStated: string = contract.eligibility.not_stated;
const eligibilityValue = (x: unknown) =>
  typeof x === 'boolean' || x === notStated;
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
type Range = { min: number; max: number };
type LimitSpec = {
  required: string[];
  optional: Record<string, Range>;
  periods?: {
    max_entries: number;
    keys: string[];
    ranges: Record<string, Range>;
  };
  exclusive?: string[];
};
/**
 * A limit's periods (#188 layer 2, `contract_limit_periods()` in SQL): 1 to
 * max_entries slots of the listed keys, all but the optional from/to pair
 * required, days and times as a schedule slot's, each range a whole number.
 */
function validLimitPeriods(
  v: unknown,
  spec: NonNullable<LimitSpec['periods']>,
): boolean {
  return Array.isArray(v) && v.length >= 1 && v.length <= spec.max_entries &&
    v.every((e) =>
      isObject(e) && Object.keys(e).every((k) => spec.keys.includes(k)) &&
      spec.keys.every((k) =>
        has(e, k) || contract.time.optional_pair.includes(k)
      ) &&
      validSlotTimes(e) &&
      Object.entries(spec.ranges).every(([k, r]) => whole(e[k], r.min, r.max))
    );
}
const limitsRequired = cond.write.limits_required as Record<string, string[]>;
/**
 * Whether a valid condition is complete for a new write (#188 layer 2,
 * `condition_write_complete()` in SQL): time_limit carries its periods,
 * not the old shapes.
 */
export function conditionWriteComplete(c: unknown): boolean {
  if (!isObject(c)) return false;
  const limits = Array.isArray(c.limits) ? c.limits : [];
  return limits.every((l) =>
    isObject(l) &&
    (limitsRequired[l.kind as string] ?? []).every((k) => has(l, k))
  );
}
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

  const limitSpecs = cond.limits as unknown as Record<string, LimitSpec>;
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
        if (key === 'kind') continue;
        // Time periods (#188 layer 2): time_limit's and no_parking's.
        if (key === 'periods' && spec.periods) {
          if (!validLimitPeriods(value, spec.periods)) return false;
          continue;
        }
        if (spec.required.includes(key)) continue;
        const range = Object.hasOwn(spec.optional, key)
          ? spec.optional[key]
          : undefined;
        if (!range || !whole(value, range.min, range.max)) return false;
      }
      if (!spec.required.every((k) => has(l, k))) return false;
      if (spec.exclusive?.every((k) => has(l, k))) return false;
      if (has(l, 'vehicle') && !inList(cond.special_vehicles)(l.vehicle)) {
        return false;
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
        cond.allow_keys.includes(k) && eligibilityValue(x)
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
 * The bay kind a condition reads as (#188, `bay_kinds`): the first rule
 * that matches, or null when it is unconfirmed. The same as
 * `condition_bay_kind()` in SQL and `bayKindOf` in Dart.
 */
export function bayKindOf(c: unknown): string | null {
  if (!isObject(c)) return null;
  const limits = Array.isArray(c.limits) ? c.limits : [];
  for (const { when, bay_kind } of contract.bay_kinds.rules) {
    const w = when as Record<string, string | undefined>;
    if (
      (!('limit' in w) ||
        limits.some((l) => isObject(l) && l.kind === w.limit)) &&
      ['share', 'bay'].every((k) => !(k in w) || c[k] === w[k])
    ) return bay_kind;
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
  if (!isObject(zone.condition)) return false;
  // A zone that says not_stated (#201) writes back no access.
  const allow = zone.condition.allow;
  if (isObject(allow) && Object.values(allow).includes(notStated)) {
    return (zone.access === undefined || zone.access === null) &&
      cond.allow_keys.every((k: string) => has(allow, k));
  }
  if (typeof zone.access !== 'string') return false;
  return zone.access === legacyAccess(zone.condition);
}
/**
 * Whether a zone states both vehicles (#201): by its access, or by a
 * condition whose allow names both. `zone_eligibility_stated()` in SQL.
 */
export function zoneStated(zone: Record<string, unknown>): boolean {
  if (typeof zone.access === 'string') return true;
  const c = zone.condition;
  return isObject(c) && isObject(c.allow) &&
    cond.allow_keys.every((k: string) =>
      has(c.allow as Record<string, unknown>, k)
    );
}
const vehicles: string[] = contract.eligibility.vehicles;
/**
 * A write's vehicle keys (#201, `eligibility_values_ok()` in SQL): each
 * vehicle it names is true or false, or not_stated (`x_not_stated: true`
 * with no boolean). It never clears one.
 */
export function eligibilityValuesOk(o: Record<string, unknown>): boolean {
  return vehicles.every((v) => {
    const a = o[`${v}_allowed`], n = o[`${v}_not_stated`];
    if (a !== undefined && a !== null && typeof a !== 'boolean') return false;
    if (n !== undefined && typeof n !== 'boolean') return false;
    if (n === true) return a === undefined || a === null;
    if (n === false) return typeof a === 'boolean';
    return a !== null;
  });
}
/** Whether a spot states both vehicles: true, false or not_stated. */
export function eligibilityStated(o: Record<string, unknown>): boolean {
  return vehicles.every((v) =>
    typeof o[`${v}_allowed`] === 'boolean' || o[`${v}_not_stated`] === true
  );
}
/**
 * Whether each zone a suggestion's patch adds or changes states both
 * vehicles once applied to the stored list (#201): only the zones a rider
 * changes must be filled in. Without the stored list, only new zones are
 * checked; the review checks the rest (`zone_patch_stated()`).
 */
export function zonePatchesStated(
  patch: unknown,
  current: unknown,
  stated: (e: Record<string, unknown>) => boolean = zoneStated,
): boolean {
  if (!Array.isArray(patch)) return true;
  const stored = Array.isArray(current) ? current.filter(isObject) : null;
  return patch.filter(isObject).every((e) => {
    if (e.removed === true) return true;
    if (!has(e, 'id')) return stated(e);
    if (!stored) return true;
    const old = stored.find((z) => z.id === e.id) ?? {};
    const merged: Record<string, unknown> = { ...old };
    for (const [k, x] of Object.entries(e)) {
      if (x === null) delete merged[k];
      else merged[k] = x;
    }
    return stated(merged);
  });
}
/**
 * [zonePatchesStated] for segments (#188 layer 2): each segment a
 * suggestion adds or changes states both vehicles once applied, so a rider
 * who changes a segment fills in who may park there.
 */
export const segmentPatchesStated = (patch: unknown, current: unknown) =>
  zonePatchesStated(patch, current, segmentStated);
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
/** UTF-16 code units, as Dart and JS count. */
const textWithin = (v: unknown, max: number) =>
  typeof v === 'string' && v.trim() !== '' && v.length <= max;
const entryIdPattern = new RegExp(contract.zone.id_pattern);
/**
 * The ids of a zone or segment list (#188): each id that is present is a
 * string of `zone.id_pattern`, and no two entries share one. Entries may
 * leave it out: the tables' trigger gives them one.
 */
function validEntryIds(list: unknown[]): boolean {
  const ids = list.filter(isObject).filter((e) => has(e, 'id')).map((e) =>
    e.id
  );
  return ids.every((id) => typeof id === 'string' && entryIdPattern.test(id)) &&
    new Set(ids).size === ids.length;
}
/**
 * A spot's parking_zones as the contract takes them (`valid_zones()` in
 * SQL, `validZoneList` in Dart): objects with a valid fee and condition
 * (whose access agrees with it), an optional https evidence_url, and ids
 * as validEntryIds takes them. An old writer's `area` (#188 layer 2) is
 * not checked: the tables' trigger drops it.
 */
export function validZoneEntries(v: unknown): boolean {
  if (!Array.isArray(v)) return false;
  return v.every((z) =>
    isObject(z) &&
    (!has(z, 'fee') || validFee(z.fee)) &&
    (!has(z, 'condition') ||
      (validCondition(z.condition, true) && zoneConditionConsistent(z))) &&
    (!has(z, 'evidence_url') || validEvidenceUrl(z.evidence_url))
  ) && validEntryIds(v);
}
const seg = contract.segment;
/** One segment's keys other than its id, as the contract takes them. */
function validSegmentFields(s: Record<string, unknown>): boolean {
  return Object.keys(s).every((k) => seg.keys.includes(k)) &&
    textWithin(s.name, seg.name_max_length) &&
    (!has(s, 'side') || inList(seg.sides)(s.side)) &&
    (!has(s, 'range') || textWithin(s.range, seg.range_max_length)) &&
    (!has(s, 'guide') || textWithin(s.guide, seg.guide_max_length)) &&
    (!has(s, 'total') || whole(s.total, seg.total.min, seg.total.max)) &&
    (!has(s, 'condition') || validCondition(s.condition, true)) &&
    (!has(s, 'fee') || validFee(s.fee)) &&
    (!has(s, 'fee_plan') || typeof s.fee_plan === 'string') &&
    (!has(s, 'evidence_url') || validEvidenceUrl(s.evidence_url));
}
/**
 * A street spot's parking_segments (#188, `valid_segments()` in SQL,
 * `validSegmentList` in Dart): at most max_entries named segments with an
 * optional side, range, guide, number of bays, https evidence_url, a
 * zone-style condition (its allow says who may park, #188 layer 2) and its
 * own fee and fee_plan reference.
 */
export function validSegments(v: unknown): boolean {
  return Array.isArray(v) && v.length <= seg.max_entries &&
    v.every((s) => isObject(s) && validSegmentFields(s)) && validEntryIds(v);
}
/**
 * A rider's zone condition (#188 layer 2): the contract's zone condition
 * without a basis (a notice travels as evidence_url), complete for a new
 * write. Who may park is checked with the zone (zoneStated).
 */
const riderZoneCondition = (c: unknown) =>
  validCondition(c, true) && !has(c as Record<string, unknown>, 'basis') &&
  conditionWriteComplete(c);
/** A fee written whole (a zone's, a segment's): valid and complete. */
const riderEntryFee = (f: unknown) => validFee(f) && feeWriteComplete(f);
/**
 * One rider zone without its id: named, with access, a guide, a fee, a
 * notice link and a condition. An old build's `area` is let through and
 * dropped by the tables' trigger (#188 layer 2, PM_ANS_20261101_49).
 */
function validRiderZone(zone: Record<string, unknown>): boolean {
  return Object.keys(zone).every((k) =>
    ['name', 'access', 'area', 'guide', 'fee', 'evidence_url', 'condition']
      .includes(k)
  ) &&
    text(40, 1)(zone.name) &&
    (!('access' in zone) || oneOf(accessKinds)(zone.access)) &&
    (!('guide' in zone) || text(200)(zone.guide)) &&
    (!('fee' in zone) || riderEntryFee(zone.fee)) &&
    (!('condition' in zone) || riderZoneCondition(zone.condition));
}
/**
 * A lot's zones as riders report them: named, with access and a guide.
 * Every zone of a new spot states both vehicles (#201).
 */
export function validZones(v: unknown): boolean {
  if (!Array.isArray(v) || v.length > 10) return false;
  return v.every((z) => isObject(z) && validRiderZone(z) && zoneStated(z)) &&
    // A new spot's zones get their ids from the table's trigger.
    validZoneEntries(v);
}
/**
 * A rider's segment: the contract's, with no id, no basis and no fee plan
 * (plans are an admin's); its condition and fee complete for a new write.
 */
function validRiderSegment(s: Record<string, unknown>): boolean {
  return !has(s, 'id') && !has(s, 'fee_plan') && validSegmentFields(s) &&
    (!isObject(s.condition) ||
      (!has(s.condition, 'basis') && conditionWriteComplete(s.condition))) &&
    (!has(s, 'fee') || feeWriteComplete(s.fee));
}
/**
 * Whether a segment states both vehicles (#188 layer 2: eligibility goes
 * with the bay): its condition's allow names scooter and heavy.
 */
export function segmentStated(s: Record<string, unknown>): boolean {
  const c = s.condition;
  return isObject(c) && isObject(c.allow) &&
    cond.allow_keys.every((k: string) =>
      has(c.allow as Record<string, unknown>, k)
    );
}
/**
 * A new street spot's segments as riders report them (#188): each states
 * both vehicles (layer 2).
 */
export function validRiderSegments(v: unknown): boolean {
  return validSegments(v) &&
    (v as unknown[]).every((s) =>
      validRiderSegment(s as Record<string, unknown>) &&
      segmentStated(s as Record<string, unknown>)
    );
}
/**
 * A suggestion's zone or segment patches (#188), applied by id in
 * `admin_resolve_report` (entries_patch()): `{id, …changed keys}` where null
 * clears an optional key, `{id, removed: true}`, or a new entry without an
 * id. Each id at most once. [entry] checks a new entry, and a patched one
 * once its nulls are left out (they clear optional keys only).
 */
function validEntryPatches(
  v: unknown,
  entry: (e: Record<string, unknown>) => boolean,
  required: string[],
): boolean {
  if (!Array.isArray(v) || v.length < 1 || v.length > 30) return false;
  const ids = new Set<unknown>();
  for (const e of v) {
    if (!isObject(e)) return false;
    if (!has(e, 'id')) {
      if (has(e, 'removed') || !entry(e)) return false;
      continue;
    }
    if (typeof e.id !== 'string' || !entryIdPattern.test(e.id)) return false;
    if (ids.has(e.id)) return false;
    ids.add(e.id);
    if (has(e, 'removed')) {
      if (e.removed !== true || Object.keys(e).length !== 2) return false;
      continue;
    }
    const { id: _, ...rest } = e;
    if (Object.keys(rest).length === 0) return false;
    if (required.some((k) => has(rest, k) && rest[k] === null)) return false;
    const kept = Object.fromEntries(
      Object.entries(rest).filter(([, x]) => x !== null),
    );
    // A patch need not repeat the name; it is checked when it is sent.
    if (!entry({ name: 'x', ...kept })) return false;
  }
  return true;
}
const validZonePatches = (v: unknown) =>
  validEntryPatches(
    v,
    (z) => validRiderZone(z) && validZoneEntries([z]),
    ['name'],
  ) &&
  // A new zone states both vehicles (#201); a changed one is checked on
  // the stored list (zonePatchesStated).
  (v as unknown[]).every((e) => !isObject(e) || has(e, 'id') || zoneStated(e));
const validSegmentPatches = (v: unknown) =>
  validEntryPatches(v, (s) => validRiderSegment(s), ['name']) &&
  // A new segment states both vehicles (#188 layer 2); a changed one is
  // checked on the stored list (segmentPatchesStated).
  (v as unknown[]).every((e) =>
    !isObject(e) ||
    (has(e, 'id')
      // A condition sent replaces the stored one: it states both itself.
      ? !isObject(e.condition) || segmentStated(e)
      : segmentStated(e))
  );
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
  // Typed here; eligibilityValuesOk() below holds each vehicle to true,
  // false or not_stated (a null flag beside not_stated), never cleared.
  scooter_allowed: (v) => v === null || typeof v === 'boolean',
  heavy_allowed: (v) => v === null || typeof v === 'boolean',
  scooter_not_stated: (v) => typeof v === 'boolean',
  heavy_not_stated: (v) => typeof v === 'boolean',
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
  // Each rate it names complete for a new write (#188 layer 2).
  fee: (v) =>
    validProposedFee(v) &&
    Object.values(v as Record<string, unknown>).every((r) =>
      r === null || rateWriteComplete(r)
    ),
  // Checked with the space type beside it (validProposedCondition).
  condition: (v) => v === null || isObject(v),
  status: (v) => v === 'hidden',
  // Riders ask to take a spot down; restoring one is an admin decision.
  hidden: (v) => v === true,
  // Works or a closure (#116): the cause and the date the notice gives;
  // null says it is over. The start and basis are the reviewer's.
  closure: validProposedClosure,
  // Zones and segments by id (#188).
  parking_zones: validZonePatches,
  parking_segments: validSegmentPatches,
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
    conditionWriteComplete(p.condition) &&
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
    if (!eligibilityValuesOk(p)) return 'invalid proposed';
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
      // Both vehicles (#201): true or false; a lot may also say
      // not_stated (官方與營運業者都沒寫).
      const lot = offStreetSpaceTypes.includes(String(s.space_type)) ||
        offStreetFacilityTypes.includes(String(s.facility_type)) ||
        (Array.isArray(s.facility_types) &&
          s.facility_types.some((t) =>
            offStreetFacilityTypes.includes(String(t))
          ));
      for (const v of vehicles) {
        if (
          !eligibilityValuesOk(s) ||
          !(typeof s[`${v}_allowed`] === 'boolean' ||
            (lot && s[`${v}_not_stated`] === true))
        ) return `invalid ${v}_allowed`;
      }
      // A new spot's fee is complete (#188 layer 2, fee.write).
      if (
        s.fee !== undefined && s.fee !== null &&
        !(validFee(s.fee) && feeWriteComplete(s.fee))
      ) {
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
          !conditionWriteComplete(s.condition) ||
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
          ['parking_segments', validRiderSegments],
        ] as const
      ) {
        if (s[key] !== undefined && !check(s[key])) return `invalid ${key}`;
      }
      // Segments are a street spot's only (#188 layer 2).
      if (
        lot && Array.isArray(s.parking_segments) &&
        s.parking_segments.length > 0
      ) return 'invalid parking_segments';
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

/**
 * The refusal when an admin has deleted the spot (#200, `apply_report`
 * raises P0410): the app shows `message` as it is.
 */
export const spotDeletedResponse = {
  error: 'spot deleted',
  message: '這個點已被刪除',
};
