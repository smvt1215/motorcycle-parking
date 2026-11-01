// Structured fees v2 (docs/designs/2026-10-26-parking-conditions-and-fees.md
// §2): the shape check validFee and the fee_note sentence feeNoteOf. The
// rules come from parking_contract.json, which tool/gen_contract_sql.py also
// turns into valid_fee() and fee_note_of(); lib/models/fee.dart mirrors both.
// parking_contract_cases.json pins the shapes (`fees`) and the sentences
// (`fee_notes`) for all of them; tool/fee_text.py writes the same sentences
// and works out the longest one, kept in fee_note_limit.json.
import contract from './parking_contract.json' with { type: 'json' };
import limit from './fee_note_limit.json' with { type: 'json' };

type Json = Record<string, unknown>;
const isObject = (v: unknown): v is Json =>
  !!v && typeof v === 'object' && !Array.isArray(v);
const has = (o: Json, k: string) => Object.hasOwn(o, k);
const whole = (v: unknown, min: number, max: number) =>
  typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;

/** A non-empty list of distinct strings drawn from `values`. */
export const subset = (v: unknown, values: string[]) =>
  Array.isArray(v) && v.length > 0 &&
  v.every((x) => typeof x === 'string' && values.includes(x)) &&
  new Set(v).size === v.length;

/**
 * `days`, `from` and `to` of a schedule slot or a fee period; leaving out
 * both `from` and `to` means all day.
 */
export function validSlotTimes(slot: Json): boolean {
  const time = new RegExp(contract.time.pattern);
  const days = slot.days;
  const validDays = typeof days === 'string'
    ? contract.time.days.includes(days)
    : subset(days, contract.time.weekdays);
  if (!contract.time.optional_pair.some((k) => has(slot, k))) return validDays;
  return validDays &&
    typeof slot.from === 'string' && typeof slot.to === 'string' &&
    time.test(slot.from) && time.test(slot.to) && slot.from !== slot.to;
}

type Range = { min: number; max: number | string };
type Spec = {
  required: Record<string, unknown>;
  optional: Record<string, unknown>;
};
const feeContract = contract.fee as unknown as {
  max_bytes: number;
  vehicles: string[];
  follow: {
    vehicles: string[];
    modes: string[];
    optional: Record<string, Range>;
  };
  modes: Record<string, Spec>;
  enums: Record<string, string[]>;
  periods: { max_entries: number; keys: string[]; nested_modes: string[] };
  write: {
    required_vehicles: string[];
    required: Record<string, string[]>;
    required_with: Record<string, Record<string, string>>;
    cross_period_when: { nested_mode: string; min_periods: number };
  };
};

/** The keys of `r` besides `mode` against a {required, optional} spec. */
function validFields(r: Json, spec: Spec, vehicle: string): boolean {
  for (const [key, value] of Object.entries(r)) {
    if (key === 'mode') continue;
    const field = has(spec.required, key)
      ? spec.required[key]
      : has(spec.optional, key)
      ? spec.optional[key]
      : undefined;
    if (field === undefined) return false;
    if (isObject(field)) {
      const range = field as Range;
      const max = typeof range.max === 'string' ? r[range.max] : range.max;
      if (typeof max !== 'number' || !whole(max, 0, 1e9)) return false;
      if (!whole(value, range.min, max)) return false;
    } else if (has(feeContract.enums, field as string)) {
      const list = feeContract.enums[field as string];
      if (typeof value !== 'string' || !list.includes(value)) return false;
    } else if (field === 'periods') {
      const p = feeContract.periods;
      if (
        !Array.isArray(value) || value.length === 0 ||
        value.length > p.max_entries ||
        !value.every((e) =>
          isObject(e) && Object.keys(e).every((k) => p.keys.includes(k)) &&
          p.keys.every((k) =>
            has(e, k) || contract.time.optional_pair.includes(k)
          ) &&
          validSlotTimes(e) && validRate(e.rate, vehicle, true)
        )
      ) return false;
    } else return false;
  }
  return Object.keys(spec.required).every((k) => has(r, k));
}

/** One vehicle's rate; a period's rate may not follow or nest by_time. */
function validRate(v: unknown, vehicle: string, nested: boolean): boolean {
  if (!isObject(v) || typeof v.mode !== 'string') return false;
  const mode = v.mode;
  if (feeContract.follow.modes.includes(mode)) {
    return !nested && feeContract.follow.vehicles.includes(vehicle) &&
      validFields(
        v,
        { required: {}, optional: feeContract.follow.optional },
        vehicle,
      );
  }
  if (!has(feeContract.modes, mode)) return false;
  if (nested && !feeContract.periods.nested_modes.includes(mode)) return false;
  return validFields(v, feeContract.modes[mode], vehicle);
}

/**
 * A fee v2 (§2.2): a rate per vehicle; a missing vehicle is unconfirmed.
 * The size bound reads the JSON as UTF-8 text, close to the column's.
 */
export function validFee(v: unknown): boolean {
  if (!isObject(v)) return false;
  if (
    new TextEncoder().encode(JSON.stringify(v)).length > feeContract.max_bytes
  ) {
    return false;
  }
  return Object.entries(v).every(([k, rate]) =>
    feeContract.vehicles.includes(k) && validRate(rate, k, false)
  );
}

// ---- fee_note sentences (§2.5, §7 items 11, 14, 15, 34; #140) ----

const weekdays: string[] = contract.time.weekdays;
const dayNames = '一二三四五六日';
const dayMasks: Record<string, number> = { all: 127, weekday: 31, holiday: 96 };
const resets: Record<string, string> = {
  calendar_day: '零時重算',
  rolling_24h: '停滿 24 小時重算',
  per_entry: '每次進場重算',
};
const int = (v: unknown) => Math.trunc(Number(v));

/** Whole yuan at `pct` percent, with at most two decimals: 22.5, 41.25. */
function money(amount: unknown, pct: number): string {
  const v = int(amount) * pct, whole = Math.floor(v / 100), rem = v % 100;
  if (rem === 0) return String(whole);
  if (rem % 10 === 0) return `${whole}.${rem / 10}`;
  return `${whole}.${String(rem).padStart(2, '0')}`;
}
const every = (v: unknown) => {
  const m = int(v);
  return m === 60
    ? '每小時'
    : m % 60 === 0
    ? `每 ${m / 60} 小時`
    : `每 ${m} 分鐘`;
};
const dayMask = (days: unknown) =>
  typeof days === 'string'
    ? dayMasks[days]
    : (days as string[]).reduce((m, d) => m | (1 << weekdays.indexOf(d)), 0);
const dayLabel = (mask: number) =>
  mask === 127 ? '每天' : mask === 31 ? '平日' : mask === 96 ? '假日' : [
    ...Array(7).keys(),
  ].filter((i) => mask & (1 << i)).map((i) => `週${dayNames[i]}`).join('、');

/**
 * One rate's words at `pct` percent, or null when it reads as unconfirmed
 * or does not apply (not_applicable, which feeNoteOf leaves out).
 */
function rateText(r: unknown, pct: number): string | null {
  if (!isObject(r)) return null;
  switch (r.mode) {
    case 'free':
      return '免費';
    case 'hourly': {
      let t = `${every(r.per_minutes)} ${money(r.amount, pct)} 元`;
      if (has(r, 'daily_cap')) {
        t += `，當日上限 ${money(r.daily_cap, pct)} 元`;
        const reset = resets[r.cap_reset as string];
        if (reset) t += `（${reset}）`;
      }
      return t;
    }
    case 'per_visit': {
      let t = `每次 ${money(r.amount, pct)} 元`;
      if (r.renew === 'midnight') t += '，隔日另計';
      if (r.renew === 'none') t += '，停多久都只收一次';
      if (has(r, 'extension_amount')) {
        t += `，延長每次 ${money(r.extension_amount, pct)} 元`;
      }
      return t;
    }
    case 'by_time': {
      // Periods grouped by the days they cover, in order of first appearance.
      const groups: { mask: number; items: string[] }[] = [];
      for (const p of r.periods as Json[]) {
        const text = rateText(p.rate, pct);
        if (text === null) continue;
        const time = !has(p, 'from')
          ? '全天'
          : `${p.from}–${
            (p.from as string) < (p.to as string) ? '' : '隔日 '
          }${p.to}`;
        const mask = dayMask(p.days);
        const group = groups.find((g) => g.mask === mask);
        if (group) group.items.push(`${time} ${text}`);
        else groups.push({ mask, items: [`${time} ${text}`] });
      }
      if (!groups.length) return null;
      let t = groups.map((g) => `${dayLabel(g.mask)}：${g.items.join('；')}`)
        .join('；');
      if (has(r, 'cross_period')) {
        t += r.cross_period === 'each_period'
          ? '；跨時段分別計費'
          : '；依進場時段計費';
      }
      return t;
    }
  }
  return null; // not_applicable, or a follow out of place
}

/**
 * The fee_note text of a valid fee: the known vehicles as 機車…；大型重機…；
 * 汽車…, then 大型重機費率未提供 when the heavy rate is unknown
 * (PM_ANS_20261101_55; old rates missing renew, cap_reset or cross_period
 * say nothing of them); a vehicle
 * that is not_applicable (#188) is left out. A heavy rate following another
 * vehicle shows that vehicle's amounts (#140, no factor since #188), or
 * 大型重機費率未提供 when that vehicle is unconfirmed or not applicable.
 */
export function feeNoteOf(fee: unknown): string {
  const f = isObject(fee) ? fee : {};
  const s = rateText(f.scooter, 100), c = rateText(f.car, 100);
  const heavy = f.heavy;
  let h: string | null, unprovided = false;
  if (
    isObject(heavy) &&
    (heavy.mode === 'same_as_scooter' || heavy.mode === 'same_as_car')
  ) {
    h = rateText(heavy.mode === 'same_as_scooter' ? f.scooter : f.car, 100);
    unprovided = h === null;
  } else h = rateText(heavy, 100);
  if (s === null && h === null && c === null && !unprovided) {
    return '請依現場公告';
  }
  const parts: string[] = [];
  if (s !== null) parts.push(`機車${s}`);
  if (h !== null || unprovided) parts.push(`大型重機${h ?? '費率未提供'}`);
  if (c !== null) parts.push(`汽車${c}`);
  const notApplicable = isObject(heavy) && heavy.mode === 'not_applicable';
  if (h === null && !unprovided && !notApplicable) {
    parts.push('大型重機費率未提供');
  }
  return parts.join('；');
}

// ---- New writes (#188 layer 2, fee.write) ----

/**
 * Whether one valid rate is complete for a new write: a per-visit rate
 * names renew, an hourly cap its cap_reset, and a by_time rate with at
 * least min_periods periods, one of them per visit, its cross_period; its
 * periods' rates follow the same rules. `fee_rate_write_complete()` in SQL.
 */
export function rateWriteComplete(r: unknown): boolean {
  if (!isObject(r) || typeof r.mode !== 'string') return false;
  const w = feeContract.write;
  const mode = r.mode;
  if ((w.required[mode] ?? []).some((k) => !has(r, k))) return false;
  for (const [key, when] of Object.entries(w.required_with[mode] ?? {})) {
    if (has(r, when) && !has(r, key)) return false;
  }
  if (mode === 'by_time') {
    const periods = r.periods as Json[];
    if (!periods.every((p) => rateWriteComplete(p.rate))) return false;
    const when = w.cross_period_when;
    if (
      !has(r, 'cross_period') && periods.length >= when.min_periods &&
      periods.some((p) => (p.rate as Json).mode === when.nested_mode)
    ) return false;
  }
  return true;
}

/**
 * Whether a valid fee is complete for a new write: every required vehicle
 * has a rate and each rate is complete. `fee_write_complete()` in SQL.
 */
export function feeWriteComplete(fee: unknown): boolean {
  return isObject(fee) &&
    feeContract.write.required_vehicles.every((v) => has(fee, v)) &&
    Object.values(fee).every(rateWriteComplete);
}

/** The longest fee_note_of() the contract allows (§2.5). */
export const feeNoteMaxLength: number = limit.max_length;

/** The bound of free fee_note text, as before structured fees. */
export const freeFeeNoteMaxLength = 200;

/**
 * Whether `note` fits as a spot's fee_note beside `fee`: free text up to
 * 200, or exactly the fee's own text, which may be longer.
 */
export function validFeeNote(note: unknown, fee: unknown): boolean {
  if (typeof note !== 'string') return false;
  if (note.length <= freeFeeNoteMaxLength) return true;
  return note.length <= feeNoteMaxLength && validFee(fee) &&
    note === feeNoteOf(fee);
}

// ---- Fee plans (§2.6) ----

const planContract = contract.fee_plans;
const utf16Length = (s: string) => s.length;

/**
 * A spot's fee plans, its own plan reference and its zones' and segments'
 * (§2.6, #188 layer 2), as valid_fee_plans() and valid_segment_fee_plans()
 * check them: at most 12 plans of {id, name, fee}, ids
 * unique, names 1–20 UTF-16 code units, each fee valid and not empty. A
 * reference names an existing plan, and the spot or zone carries that
 * plan's fee as its own copy.
 */
export function validFeePlans(
  plans: unknown,
  feePlan: unknown,
  fee: unknown,
  zones: unknown,
  segments: unknown = [],
): boolean {
  const byId = new Map<string, unknown>();
  if (plans !== null && plans !== undefined) {
    if (
      !Array.isArray(plans) || plans.length === 0 ||
      plans.length > planContract.max_entries
    ) return false;
    for (const p of plans) {
      if (
        !isObject(p) ||
        !Object.keys(p).every((k) => planContract.keys.includes(k)) ||
        !planContract.keys.every((k) => has(p, k)) ||
        typeof p.id !== 'string' ||
        !new RegExp(planContract.id_pattern).test(p.id) || byId.has(p.id) ||
        typeof p.name !== 'string' || p.name.trim() === '' ||
        utf16Length(p.name) > planContract.name_max_length ||
        !validFee(p.fee) || Object.keys(p.fee as Json).length === 0
      ) return false;
      byId.set(p.id, p.fee);
    }
  }
  const copies = (id: unknown, copy: unknown) =>
    typeof id === 'string' && byId.has(id) && sameJson(copy, byId.get(id));
  if (feePlan !== null && feePlan !== undefined && !copies(feePlan, fee)) {
    return false;
  }
  // Segments refer to plans as zones do (#188 layer 2,
  // valid_segment_fee_plans() in SQL).
  const entriesCopy = (list: unknown) =>
    !Array.isArray(list) ||
    list.every((z) =>
      !isObject(z) || !has(z, 'fee_plan') || copies(z.fee_plan, z.fee)
    );
  return entriesCopy(zones) && entriesCopy(segments);
}

/** jsonb equality: the same values, object keys in any order. */
function sameJson(a: unknown, b: unknown): boolean {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length &&
      a.every((x, i) => sameJson(x, b[i]));
  }
  if (isObject(a) || isObject(b)) {
    if (!isObject(a) || !isObject(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length &&
      keys.every((k) => has(b, k) && sameJson(a[k], b[k]));
  }
  return a === b;
}

/**
 * A plan's fee with a heavy follow worked out (§2.6 precheck, step 1): the
 * followed vehicle's rate (no factor since #188), or no heavy rate when that
 * vehicle is unconfirmed or not applicable. Other vehicles stay as they are.
 */
export function resolveFee(fee: Json): Json {
  const out: Json = { ...fee };
  const heavy = fee.heavy;
  if (
    isObject(heavy) &&
    (heavy.mode === 'same_as_scooter' || heavy.mode === 'same_as_car')
  ) {
    const target = heavy.mode === 'same_as_scooter' ? fee.scooter : fee.car;
    if (isObject(target) && target.mode !== 'not_applicable') {
      out.heavy = { ...target };
    } else delete out.heavy;
  }
  return out;
}

/**
 * The vehicles a zone's rate counts for (§2.6 precheck, step 2): a heavy
 * bay only heavy bikes; otherwise the motorcycles its allow lets park (read
 * from its access when it has no condition) and cars as they are.
 */
export function zoneFeeVehicles(zone: Json): string[] {
  const fromAccess = contract.conversion.from_access as Record<string, Json>;
  const condition = isObject(zone.condition)
    ? zone.condition
    : typeof zone.access === 'string' && has(fromAccess, zone.access)
    ? fromAccess[zone.access]
    : {};
  if (condition.bay === 'heavy') return ['heavy'];
  const allow = isObject(condition.allow) ? condition.allow : {};
  return [
    ...(allow.scooter === true ? ['scooter'] : []),
    ...(allow.heavy === true ? ['heavy'] : []),
    'car',
  ];
}

/** A plan's fee as one zone's rates: resolved, then projected. */
export function projectZoneFee(fee: Json, zone: Json): Json {
  const resolved = resolveFee(fee);
  const vehicles = zoneFeeVehicles(zone);
  return Object.fromEntries(
    Object.entries(resolved).filter(([k]) => vehicles.includes(k)),
  );
}

// ---- Fee suggestions merged per vehicle (§5.4, §7 item 3) ----

/**
 * A suggested fee (`proposed.fee`): a rate per vehicle it changes, or null
 * for a vehicle it clears. Vehicles it leaves out keep their rates, so an
 * older build that cannot read a vehicle never clears it by omission.
 */
export function validProposedFee(v: unknown): boolean {
  if (!isObject(v)) return false;
  const rates = Object.fromEntries(
    Object.entries(v).filter(([, rate]) => rate !== null),
  );
  return Object.keys(v).every((k) => feeContract.vehicles.includes(k)) &&
    validFee(rates);
}

/**
 * The fee a suggestion leaves: [current] with each vehicle [proposed]
 * names replaced, or removed where it is null.
 */
export function mergeFee(current: unknown, proposed: unknown): Json {
  const out: Json = isObject(current) ? { ...current } : {};
  if (!isObject(proposed)) return out;
  for (const [k, rate] of Object.entries(proposed)) {
    if (rate === null) delete out[k];
    else out[k] = rate;
  }
  return out;
}
