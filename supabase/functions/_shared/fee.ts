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
  extension: Spec;
  periods: { max_entries: number; keys: string[]; nested_modes: string[] };
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
    } else if (field === 'extension') {
      if (
        !isObject(value) || has(value, 'mode') ||
        !validFields(value, feeContract.extension, vehicle)
      ) return false;
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
const span = (v: unknown) => {
  const m = int(v);
  return m % 60 === 0 ? `${m / 60} 小時` : `${m} 分鐘`;
};
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

/** One rate's words at `pct` percent, or null when it reads as unconfirmed. */
function rateText(r: unknown, pct: number): string | null {
  if (!isObject(r)) return null;
  switch (r.mode) {
    case 'free':
      return '免費';
    case 'hourly': {
      let t = `${every(r.per_minutes)} ${money(r.amount, pct)} 元`;
      if (has(r, 'free_minutes')) {
        t = `首 ${span(r.free_minutes)} 0 元，之後${t}`;
      }
      if (has(r, 'unit_minutes')) t += `（以 ${span(r.unit_minutes)}計）`;
      if (has(r, 'daily_cap')) {
        const reset = resets[r.cap_reset as string] ?? '上限計算方式未確認';
        t += `，當日上限 ${money(r.daily_cap, pct)} 元（${reset}）`;
      }
      return t;
    }
    case 'per_visit': {
      let t: string;
      if (int(r.amount) === 0 && has(r, 'max_minutes')) {
        t = `首 ${span(r.max_minutes)} 0 元`;
      } else {
        const notes: string[] = [];
        if (has(r, 'max_minutes')) notes.push(`${span(r.max_minutes)}內`);
        if (!has(r, 'renew')) notes.push('隔日是否另計未確認');
        t = `每次 ${money(r.amount, pct)} 元`;
        if (notes.length) t += `（${notes.join('，')}）`;
        if (r.renew === 'midnight') t += '，隔日另計';
        if (r.renew === 'none') {
          t += has(r, 'max_minutes')
            ? '，有效時間內只收一次'
            : '，停多久都只收一次';
        }
      }
      const ext = r.extension;
      if (isObject(ext)) {
        t += `，可付 ${money(ext.amount, pct)} 元延長 ${int(ext.max_times)} 次`;
        t += has(ext, 'minutes')
          ? `（每次 ${span(ext.minutes)}）`
          : '（延長時間未確認）';
      }
      return t;
    }
    case 'daily': {
      const reset = resets[r.cap_reset as string];
      return `每日 ${money(r.amount, pct)} 元${reset ? `（${reset}）` : ''}`;
    }
    case 'by_time': {
      // Periods grouped by the days they cover, in order of first appearance.
      const groups: { mask: number; items: string[] }[] = [];
      let visits = 0;
      for (const p of r.periods as Json[]) {
        const text = rateText(p.rate, pct);
        if (text === null) continue;
        if ((p.rate as Json).mode === 'per_visit') visits++;
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
      } else if (visits >= 2) t += '；跨時段計費方式未確認';
      return t;
    }
  }
  return null; // posted, or a follow out of place
}

/**
 * The fee_note text of a valid fee: the known vehicles as 機車…；大型重機…；
 * 汽車…, then 大型重機費率未確認 when the heavy rate is unknown. A heavy rate
 * following another vehicle shows the amounts worked out (#140), or
 * 大型重機費率未提供 when that vehicle is unconfirmed.
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
    const target = heavy.mode === 'same_as_scooter' ? f.scooter : f.car;
    h = rateText(
      target,
      has(heavy, 'factor_pct') ? int(heavy.factor_pct) : 100,
    );
    unprovided = h === null;
  } else h = rateText(heavy, 100);
  if (s === null && h === null && c === null && !unprovided) {
    return '請依現場公告';
  }
  const parts: string[] = [];
  if (s !== null) parts.push(`機車${s}`);
  if (h !== null || unprovided) parts.push(`大型重機${h ?? '費率未提供'}`);
  if (c !== null) parts.push(`汽車${c}`);
  if (h === null && !unprovided) parts.push('大型重機費率未確認');
  return parts.join('；');
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
