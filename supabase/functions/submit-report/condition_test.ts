import cases from '../_shared/parking_contract_cases.json' with {
  type: 'json',
};
import { legacySpaceType, validate, validCondition } from './validate.ts';

// The same cases lib/models/parking_condition.dart and the generated SQL run.
Deno.test('shared cases: validCondition accepts exactly the valid ones', () => {
  if (cases.conditions.length === 0) throw new Error('no cases');
  for (const { name, zone, condition, valid } of cases.conditions) {
    if (validCondition(condition, zone) !== valid) {
      throw new Error(`${name}: expected ${valid}`);
    }
  }
});

Deno.test('shared cases: legacy space types', () => {
  for (const { name, off_street, condition, space_type } of cases.legacy) {
    const got = legacySpaceType(
      condition as Record<string, unknown>,
      off_street,
    );
    if (got !== space_type) throw new Error(`${name}: got ${got}`);
  }
});

Deno.test('conditions are not accepted by any action yet', () => {
  const body = {
    device_id: '3f1c2a4e-0000-4000-8000-000000000001',
    action: 'flag',
    source_id: 'community:x',
    reason: '格位改成限時',
    proposed: {
      condition: { bay: 'motorcycle', use: 'usual', charge: 'toll' },
    },
  };
  if (validate(body) !== 'invalid proposed') {
    throw new Error('condition must stay outside the proposed allow-list');
  }
});
