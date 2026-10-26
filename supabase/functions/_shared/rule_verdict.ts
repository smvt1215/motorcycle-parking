// What city rules say about one kind of street bay: step 2 of the parking
// decision (docs/designs/2026-10-26-parking-conditions-and-fees.md §3.2), the
// pure rule function of the rule prescreen engine
// (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.7). The same as ruleVerdict()
// in lib/domain/parking_decision.dart and rule_verdict() in SQL
// (202610270030_parking_decision.sql); all three run
// _shared/rule_verdict_cases.json.

export type Verdict =
  | 'open'
  | 'conditional'
  | 'closed'
  | 'noRule'
  | 'unknownDistrict'
  | 'expired'
  | 'conflict';

export interface RuleVerdict {
  verdict: Verdict;
  restriction: string | null;
}

/** A `city_rules` row as JSON; only the keys the verdict reads. */
export interface CityRuleRow {
  allowed_space_types: string[];
  conditional_space_types?: string[];
  districts?: string[];
  district_space_types?: Record<string, string[]>;
  restriction?: string | null;
  effective_date: string;
  expires_on?: string | null;
}

/** Restrictions the app knows; others (the old pilot_area) read as none. */
const restrictions = ['signage', 'unverified', 'time_limited', 'ev_only'];

/** `YYYY-MM-DD` of [time] in Taiwan, as `(now() at time zone 'Asia/Taipei')::date`. */
export function taipeiDay(time: Date): string {
  return new Date(time.getTime() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

function single(
  rule: CityRuleRow,
  kind: string,
  district: string,
): RuleVerdict {
  const verdict = (v: Verdict, restriction: string | null = null) => ({
    verdict: v,
    restriction,
  });
  const openIn = rule.district_space_types?.[kind];
  if (openIn) {
    if (district === '') return verdict('unknownDistrict');
    if (!openIn.includes(district)) return verdict('closed');
  }
  const limited = (rule.conditional_space_types ?? []).includes(kind);
  const restriction = rule.restriction ?? null;
  if (limited && restriction === 'unverified') {
    return verdict('conditional', 'unverified');
  }
  if (!limited && !openIn && !rule.allowed_space_types.includes(kind)) {
    return verdict('closed');
  }
  const districts = rule.districts ?? [];
  if (districts.length > 0 && !districts.includes(district)) {
    return verdict('unknownDistrict');
  }
  if (limited) {
    return verdict(
      'conditional',
      restriction !== null && restrictions.includes(restriction)
        ? restriction
        : null,
    );
  }
  return verdict('open');
}

/**
 * What [rules] — one city's and vehicle's, already matched — say about the
 * street bay [kind] in [district] at [now]. Dates are Taiwan's. Rules not
 * yet in force are ignored; expired ones answer only when none is in force,
 * and then the answer is `expired`; rules in force that disagree are a
 * `conflict`.
 */
export function ruleVerdict(
  rules: CityRuleRow[],
  kind: string,
  district: string,
  now: Date,
): RuleVerdict {
  const day = taipeiDay(now);
  const started = rules.filter((r) => r.effective_date <= day);
  if (started.length === 0) return { verdict: 'noRule', restriction: null };
  const current = started.filter((r) => !r.expires_on || day < r.expires_on);
  if (current.length === 0) return { verdict: 'expired', restriction: null };
  const [first, ...rest] = current.map((r) => single(r, kind, district));
  return rest.every((v) =>
      v.verdict === first.verdict && v.restriction === first.restriction
    )
    ? first
    : { verdict: 'conflict', restriction: null };
}
