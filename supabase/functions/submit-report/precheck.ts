// Stage 0 precheck (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.8, §9): rules
// that only need the request itself. They run after `validate`, so every
// value here already has the type and range the columns allow. The rule
// codes, actions, messages, placeholder words and personal-data patterns live
// in precheck_rules.json, which lib/domain/precheck.dart mirrors; the cases in
// precheck_cases.json run against both. Rules stay conservative: a missed
// contradiction still meets review, a wrong block loses a report.
import data from './precheck_rules.json' with { type: 'json' };

export type PrecheckAction = 'fix' | 'reject';
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
const lotFacilities = ['multiStorey', 'underground', 'surface'];

/** Contradictions between the fields of one spot or one suggestion. */
function combinationIssues(s: Json): PrecheckIssue[] {
  const out: PrecheckIssue[] = [];
  const zones = Array.isArray(s.parking_zones)
    ? s.parking_zones.filter(object)
    : [];
  if ('space_type' in s) {
    if (s.space_type === 'offStreet' && s.facility_type === 'roadside') {
      out.push(issue('lot_roadside', 'facility_type'));
    }
    if (s.space_type !== 'offStreet') {
      if (lotFacilities.includes(String(s.facility_type))) {
        out.push(issue('street_lot_details', 'facility_type'));
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
  if (object(s.fee)) out.push(...feeIssues(s.fee, 'fee', ''));
  zones.forEach((zone, i) => {
    if (object(zone.fee)) {
      out.push(
        ...feeIssues(zone.fee, `parking_zones.${i}.fee`, `分區 ${i + 1}：`),
      );
    }
  });
  return out;
}

function feeIssues(fee: Json, field: string, where: string): PrecheckIssue[] {
  const out: PrecheckIssue[] = [];
  if (
    object(fee.heavy) && fee.heavy.mode === 'same_as_scooter' && !fee.scooter
  ) {
    out.push(issue('fee_follows_missing_scooter', `${field}.heavy`, { where }));
  }
  for (const key of ['scooter', 'heavy'] as const) {
    const rate = fee[key];
    if (!object(rate) || rate.mode !== 'hourly') continue;
    const params = { where, vehicle: vehicles[key] };
    const amount = Number(rate.amount);
    if (amount === 0) {
      out.push(issue('fee_hourly_zero', `${field}.${key}`, params));
    }
    if (typeof rate.daily_cap === 'number' && rate.daily_cap < amount) {
      out.push(
        issue('fee_cap_below_amount', `${field}.${key}`, {
          ...params,
          cap: rate.daily_cap,
          amount,
        }),
      );
    }
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
  if (object(body.spot)) {
    const s = body.spot;
    add('name', s.name, true);
    for (const key of ['fee_note', 'note', 'entrance_note', 'parking_guide']) {
      add(key, s[key]);
    }
    if (Array.isArray(s.parking_zones)) {
      s.parking_zones.forEach((z, i) => {
        if (!object(z)) return;
        add(`parking_zones.${i}.name`, z.name, true);
        add(`parking_zones.${i}.guide`, z.guide);
      });
    }
  }
  if (object(body.proposed)) {
    const p = body.proposed;
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

/** Every stage 0 rule the request breaks; empty when it may go on. */
export function precheck(body: Json): PrecheckIssue[] {
  const out: PrecheckIssue[] = [];
  const spot = ['create', 'update'].includes(String(body.action)) &&
      object(body.spot)
    ? body.spot
    : undefined;
  const proposed = body.action === 'flag' && object(body.proposed)
    ? body.proposed
    : undefined;
  if (spot) out.push(...combinationIssues(spot));
  if (proposed) {
    out.push(
      ...combinationIssues(proposed).map((i) => ({
        ...i,
        field: `proposed.${i.field}`,
      })),
    );
    if (
      goneFields.includes(String(body.field)) &&
      Object.keys(proposed).some((k) => k !== 'hidden' && k !== 'status')
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

/** The response body for a blocked request; `error` stays a short code
 * like every other refusal, and `message` reads as a full sentence. */
export function precheckResponse(issues: PrecheckIssue[]) {
  const action: PrecheckAction = issues.some((i) => i.action === 'reject')
    ? 'reject'
    : 'fix';
  const first = issues.find((i) => i.action === action) ?? issues[0];
  return {
    error: `precheck ${action}`,
    action,
    message: first.message,
    issues,
  };
}
