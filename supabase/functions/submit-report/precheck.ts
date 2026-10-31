// Stage 0 precheck (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.8, §9): rules
// that only need the request itself. They run after `validate`, so every
// value here already has the type and range the columns allow. The rule
// codes, actions, messages, placeholder words and personal-data patterns live
// in precheck_rules.json, which lib/domain/precheck.dart mirrors; the cases in
// precheck_cases.json run against both. Rules stay conservative: a missed
// contradiction still meets review, a wrong block loses a report.
import data from './precheck_rules.json' with { type: 'json' };
import { mergeFee } from '../_shared/fee.ts';

/** `hold` lets the request through, flagged for stricter review (design
 * §4.3; feasibility §5.8): the Edge Function never refuses it. */
export type PrecheckAction = 'fix' | 'hold' | 'reject';
export interface PrecheckIssue {
  rule: string;
  action: PrecheckAction;
  /** The payload path the rider corrects, e.g. `scooter_allowed`. */
  field: string;
  message: string;
}

type Rule = {
  action: PrecheckAction;
  message: string;
  patterns?: { source: string; flags: string }[];
};
const rules = data.rules as Record<string, Rule>;
const placeholders = new Set(data.placeholders);
/**
 * Rules between a bay's condition and its fee. In a suggestion that names
 * only one of the two, the other is the spot's stored value: the rider can
 * fix only one side at a time, so these flag the case (hold) instead of
 * refusing it, and the reviewer applies both.
 */
const storedPairHold = new Set(data.stored_pair_hold);
const patterns = Object.entries(rules).flatMap(([code, rule]) =>
  (rule.patterns ?? []).map((p) => ({
    code,
    regex: new RegExp(p.source, `${p.flags}gu`),
  }))
);

function issue(
  rule: string,
  field: string,
  params: Record<string, string | number> = {},
): PrecheckIssue {
  const { action, message } = rules[rule];
  return {
    rule,
    action,
    field,
    message: message.replace(
      /\{(\w+)\}/g,
      (_, key: string) => String(params[key] ?? ''),
    ),
  };
}

/** Full-width letters, digits and signs as ASCII, so ０９１２ reads as 0912. */
export function halfWidth(text: string): string {
  return text.replace(
    /[！-～]/g,
    (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0),
  ).replace(/　/g, ' ');
}

// Letter values of the national ID and resident certificate checksum.
const idLetters = 'ABCDEFGHJKLMNPQRSTUVXYWZIO';
function validNationalId(id: string): boolean {
  const upper = id.toUpperCase();
  const n = idLetters.indexOf(upper[0]) + 10;
  let sum = Math.floor(n / 10) + (n % 10) * 9;
  for (let i = 1; i < 9; i++) sum += Number(upper[i]) * (9 - i);
  return (sum + Number(upper[9])) % 10 === 0;
}

/** The personal-data or advertising rules [text] breaks, one per rule. */
export function textRules(text: string): string[] {
  const value = halfWidth(text);
  const hits: string[] = [];
  for (const { code, regex } of patterns) {
    if (hits.includes(code)) continue;
    const found = [...value.matchAll(regex)].some((m) =>
      code !== 'pii_national_id' || validNationalId(m[0])
    );
    if (found) hits.push(code);
  }
  return hits;
}

/** Whether [text] is a stand-in such as 測試 or asdf rather than content. */
export function isPlaceholder(text: string): boolean {
  const trimmed = text.trim();
  if (!trimmed) return false;
  const bare = halfWidth(trimmed).toLowerCase().replace(/[\s\p{P}\p{S}]/gu, '');
  return bare === '' || placeholders.has(bare);
}

type Json = Record<string, unknown>;
const object = (v: unknown): v is Json =>
  !!v && typeof v === 'object' && !Array.isArray(v);
const vehicles = { scooter: '普通機車', heavy: '大型重機' } as const;
const feeVehicles = { ...vehicles, car: '汽車' } as const;
type FeeVehicle = keyof typeof feeVehicles;
const lotFacilities = ['multiStorey', 'underground', 'surface'];

/** Contradictions between the fields of one spot or one suggestion. */
function combinationIssues(s: Json): PrecheckIssue[] {
  const out: PrecheckIssue[] = [];
  const zones = Array.isArray(s.parking_zones)
    ? s.parking_zones.filter(object)
    : [];
  if ('space_type' in s) {
    // The set a new build sends (decision 58), else the one type: any of
    // them that does not fit the space type counts.
    const types = Array.isArray(s.facility_types)
      ? s.facility_types.map(String)
      : s.facility_type == null
      ? []
      : [String(s.facility_type)];
    const field = 'facility_types' in s ? 'facility_types' : 'facility_type';
    if (s.space_type === 'offStreet' && types.includes('roadside')) {
      out.push(issue('lot_roadside', field));
    }
    if (s.space_type !== 'offStreet') {
      if (types.some((t) => lotFacilities.includes(t))) {
        out.push(issue('street_lot_details', field));
      }
      if (zones.length > 0) {
        out.push(issue('street_lot_details', 'parking_zones'));
      }
    }
    if (s.space_type === 'heavyOnly' && s.scooter_allowed === true) {
      out.push(issue('heavy_only_scooter', 'scooter_allowed'));
    }
  }
  for (const key of ['scooter', 'heavy'] as const) {
    const field = `${key}_allowed`;
    if (s[field] !== true) continue;
    const vehicle = vehicles[key];
    if (s.parking_access === 'noMotorcycle') {
      out.push(issue('access_no_motorcycle', field, { vehicle }));
    }
    if (key === 'scooter' && s.parking_access === 'heavyOnly') {
      out.push(issue('access_heavy_only_scooter', field));
    }
    if (key === 'heavy' && s.parking_access === 'scooterOnly') {
      out.push(issue('access_scooter_only_heavy', field));
    }
    if (
      zones.length > 0 && zones.every((z) => z.access === 'noMotorcycle')
    ) out.push(issue('zones_no_motorcycle', field, { vehicle }));
  }
  // A lot's condition lives in its zones (§1.2); riders send zone areas.
  const condition = object(s.condition) && s.space_type !== 'offStreet'
    ? s.condition
    : undefined;
  if (object(s.fee)) {
    out.push(...feeIssues(s.fee, 'fee', '', { condition }));
  }
  zones.forEach((zone, i) => {
    if (object(zone.fee)) {
      out.push(
        ...feeIssues(zone.fee, `parking_zones.${i}.fee`, `分區 ${i + 1}：`, {
          condition: object(zone.condition) ? zone.condition : undefined,
          area: typeof zone.area === 'string' ? zone.area : undefined,
        }),
      );
    }
  });
  return out;
}

/** A free 普大共用 bay the request itself writes: rare, so it waits for a
 * notice (§4.3, §1.4); a spot already stored that way is not re-flagged. */
function shareFree(condition: unknown, field: string): PrecheckIssue[] {
  return object(condition) && condition.share === 'scooter_heavy' &&
      condition.charge === 'free'
    ? [issue('share_free_needs_basis', field)]
    : [];
}

/** The rates one vehicle pays: its own, or the periods of a by_time rate. */
function ratesOf(rate: Json): Json[] {
  if (rate.mode !== 'by_time' || !Array.isArray(rate.periods)) return [rate];
  return rate.periods.flatMap((p) =>
    object(p) && object(p.rate) ? [p.rate] : []
  );
}

/** A heavy follow's mode as the vehicle it follows; others as they are. */
function modeOf(fee: Json, key: FeeVehicle): unknown {
  const rate = fee[key];
  if (!object(rate)) return undefined;
  if (key === 'heavy' && rate.mode === 'same_as_scooter') {
    return object(fee.scooter) ? fee.scooter.mode : undefined;
  }
  if (key === 'heavy' && rate.mode === 'same_as_car') {
    return object(fee.car) ? fee.car.mode : undefined;
  }
  return rate.mode;
}

/**
 * The structural contradictions in one fee, and those between it and the
 * bay it is for (§4.3): the bay's [condition], or a zone's [area].
 */
function feeIssues(
  fee: Json,
  field: string,
  where: string,
  bay: { condition?: Json; area?: string } = {},
): PrecheckIssue[] {
  const out: PrecheckIssue[] = [];
  const { condition, area } = bay;
  if (
    object(fee.heavy) && fee.heavy.mode === 'same_as_scooter' && !fee.scooter
  ) {
    out.push(issue('fee_follows_missing_scooter', `${field}.heavy`, { where }));
  }
  if (object(fee.heavy) && fee.heavy.mode === 'same_as_car' && !fee.car) {
    out.push(issue('fee_follows_missing_car', `${field}.heavy`, { where }));
  }
  const limit = Array.isArray(condition?.limits)
    ? condition.limits.find((l) => object(l) && l.kind === 'time_limit')
    : undefined;
  for (const key of Object.keys(feeVehicles) as FeeVehicle[]) {
    const rate = fee[key];
    if (!object(rate)) continue;
    const at = `${field}.${key}`;
    const params = { where, vehicle: feeVehicles[key] };
    for (const r of ratesOf(rate)) {
      const amount = Number(r.amount);
      if (r.mode === 'hourly' && amount === 0 && r.free_minutes === undefined) {
        out.push(issue('fee_hourly_zero', at, params));
      }
      if (
        r.mode === 'hourly' && typeof r.daily_cap === 'number' &&
        r.daily_cap < amount
      ) {
        out.push(
          issue('fee_cap_below_amount', at, {
            ...params,
            cap: r.daily_cap,
            amount,
          }),
        );
      }
      // 首段 0 元 is a per-visit 0 with a valid time (§2.3), never free.
      if (
        (r.mode === 'per_visit' && amount === 0 &&
          r.max_minutes === undefined) ||
        (r.mode === 'daily' && amount === 0)
      ) {
        out.push(
          issue('fee_zero_visit', at, {
            ...params,
            mode: r.mode === 'daily' ? '每日' : '計次',
          }),
        );
      }
      if (
        limit && typeof limit.max_minutes === 'number' &&
        r.mode === 'per_visit' && typeof r.max_minutes === 'number' &&
        r.max_minutes !== limit.max_minutes
      ) {
        out.push(
          issue('time_limit_mismatch', at, {
            ...params,
            limit: limit.max_minutes,
            minutes: r.max_minutes,
          }),
        );
      }
    }
    if (
      rate.mode === 'by_time' && rate.cross_period !== undefined &&
      ratesOf(rate).filter((r) => r.mode === 'per_visit').length < 2
    ) out.push(issue('cross_period_single', at, params));
    const mode = modeOf(fee, key);
    if (condition?.charge === 'free') {
      if (mode !== undefined && mode !== 'free') {
        out.push(issue('charge_free_rate', at, params));
      }
      if (ratesOf(rate).some((r) => r.renew !== undefined)) {
        out.push(issue('free_with_renew', at, params));
      }
      if (ratesOf(rate).some((r) => r.extension !== undefined)) {
        out.push(issue('free_with_extension', at, params));
      }
    }
    if (condition?.charge === 'toll' && mode === 'free') {
      out.push(issue('charge_toll_free_rate', at, params));
    }
  }
  if (condition?.bay === 'heavy' && fee.scooter !== undefined) {
    out.push(issue('heavy_bay_scooter_fee', `${field}.scooter`, { where }));
  }
  if (
    (condition?.bay === 'motorcycle' || area === 'motorcycle') &&
    fee.car !== undefined
  ) out.push(issue('motorcycle_bay_car_fee', `${field}.car`, { where }));
  if (area === 'car' && fee.scooter !== undefined) {
    out.push(issue('car_area_scooter_fee', `${field}.scooter`, { where }));
  }
  return out;
}

/** The free text a request carries: its path and whether it names a spot. */
function texts(body: Json): { field: string; value: string; name: boolean }[] {
  const out: { field: string; value: string; name: boolean }[] = [];
  const add = (field: string, value: unknown, name = false) => {
    if (typeof value === 'string' && value.trim()) {
      out.push({ field, value, name });
    }
  };
  // The free text of zones and segments (#188): names, guides and ranges.
  const entryTexts = (field: string, list: unknown) => {
    if (!Array.isArray(list)) return;
    list.forEach((e, i) => {
      if (!object(e)) return;
      add(`${field}.${i}.name`, e.name, true);
      add(`${field}.${i}.guide`, e.guide);
      add(`${field}.${i}.range`, e.range);
    });
  };
  if (object(body.spot)) {
    const s = body.spot;
    add('name', s.name, true);
    for (const key of ['fee_note', 'note', 'entrance_note', 'parking_guide']) {
      add(key, s[key]);
    }
    entryTexts('parking_zones', s.parking_zones);
    entryTexts('parking_segments', s.parking_segments);
  }
  if (object(body.proposed)) {
    const p = body.proposed;
    // Zone and segment patches (#188): the same free text, by position.
    entryTexts('proposed.parking_zones', p.parking_zones);
    entryTexts('proposed.parking_segments', p.parking_segments);
    add('proposed.name', p.name, true);
    for (
      const key of [
        'fee_note',
        'note',
        'address',
        'road_segment',
        'entrance_note',
        'parking_guide',
        'special_rules',
      ]
    ) add(`proposed.${key}`, p[key]);
  }
  add('note', body.note);
  if (body.action === 'flag') add('reason', body.reason);
  return out;
}

const goneFields = ['gone', '點位已不存在'];

/**
 * Every stage 0 rule the request breaks; empty when it may go on. A fee
 * suggestion changes only the vehicles it names (§5.4), so its rules run on
 * the fee it leaves: [current] (the spot's stored values, when known) merged
 * with it. Without [current] the suggestion stands alone.
 */
export function precheck(body: Json, current?: Json): PrecheckIssue[] {
  const out: PrecheckIssue[] = [];
  const spot = ['create', 'update'].includes(String(body.action)) &&
      object(body.spot)
    ? body.spot
    : undefined;
  const proposed = body.action === 'flag' && object(body.proposed)
    ? body.proposed
    : undefined;
  // The fee a suggestion leaves, judged with the condition it leaves: its
  // own, or the spot's (§4.3, merged results).
  const merged =
    proposed && (object(proposed.fee) || object(proposed.condition))
      ? {
        ...proposed,
        // A new condition is judged with the stored fee it would sit beside.
        ...(object(proposed.fee) || object(current?.fee)
          ? { fee: mergeFee(current?.fee, proposed.fee) }
          : {}),
        ...(!('condition' in proposed) && object(current?.condition)
          ? { condition: current.condition }
          : {}),
      }
      : proposed;
  // Whether a suggestion's condition or fee is the spot's stored one.
  const storedPair = !!proposed &&
    (!object(proposed.fee) || !('condition' in proposed));
  if (spot) {
    out.push(...combinationIssues(spot));
    if (spot.space_type !== 'offStreet') {
      out.push(...shareFree(spot.condition, 'condition.charge'));
    }
  }
  if (proposed) {
    out.push(
      ...combinationIssues(merged!).map((i) => ({
        ...i,
        action: storedPair && storedPairHold.has(i.rule)
          ? 'hold' as const
          : i.action,
        field: `proposed.${i.field}`,
      })),
      ...shareFree(proposed.condition, 'proposed.condition.charge'),
    );
    if (
      goneFields.includes(String(body.field)) &&
      // A closure (#116) is what works or a closure suggest instead.
      Object.keys(proposed).some((k) =>
        k !== 'hidden' && k !== 'status' && k !== 'closure'
      )
    ) out.push(issue('gone_with_changes', 'proposed'));
  }
  for (const { field, value, name } of texts(body)) {
    for (const code of textRules(value)) out.push(issue(code, field));
    // A flag's note is the suggestion itself only when nothing structured
    // comes with it; beside a structured value, or on a closure report, it
    // is optional context and 無 there just means nothing to add.
    const solo = field === 'note' && body.action === 'flag' && !proposed &&
      !goneFields.includes(String(body.field));
    if ((name || solo) && isPlaceholder(value)) {
      out.push(
        issue(name ? 'placeholder_name' : 'placeholder_text', field, {
          value: value.trim(),
        }),
      );
    }
  }
  return out;
}

/** The issues that refuse the request; a `hold` only flags it. */
export const blocking = (issues: PrecheckIssue[]) =>
  issues.filter((i) => i.action !== 'hold');

/** The rules a held request broke, once each, for apply_report. */
export function riskFlags(issues: PrecheckIssue[]) {
  return [
    ...new Set(issues.filter((i) => i.action === 'hold').map((i) => i.rule)),
  ];
}

/** The response body for a blocked request; `error` stays a short code
 * like every other refusal, and `message` reads as a full sentence. */
export function precheckResponse(issues: PrecheckIssue[]) {
  const action: PrecheckAction = issues.some((i) => i.action === 'reject')
    ? 'reject'
    : issues.some((i) => i.action === 'fix')
    ? 'fix'
    : 'hold';
  const first = issues.find((i) => i.action === action) ?? issues[0];
  return {
    error: `precheck ${action}`,
    action,
    message: first.message,
    issues,
  };
}
