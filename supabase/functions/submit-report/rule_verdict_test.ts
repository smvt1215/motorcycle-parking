import vectors from '../_shared/rule_verdict_cases.json' with { type: 'json' };
import { type CityRuleRow, ruleVerdict } from '../_shared/rule_verdict.ts';

const rules = vectors.rules as unknown as Record<string, CityRuleRow>;

// The vectors lib/domain/parking_decision.dart and rule_verdict() in SQL run.
Deno.test('shared vectors: ruleVerdict agrees with Dart and SQL', () => {
  if (vectors.cases.length === 0) throw new Error('no cases');
  for (const c of vectors.cases) {
    const got = ruleVerdict(
      c.rules.map((id) => rules[id]),
      c.kind,
      c.district,
      new Date(c.now),
    );
    if (got.verdict !== c.verdict || got.restriction !== c.restriction) {
      throw new Error(
        `${c.name}: got ${got.verdict}(${got.restriction}), ` +
          `expected ${c.verdict}(${c.restriction})`,
      );
    }
  }
});
