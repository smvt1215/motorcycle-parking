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

const create = (spot: Record<string, unknown>) =>
  validate({
    device_id: '3f1c2a4e-0000-4000-8000-000000000001',
    action: 'create',
    spot: { name: '測試', lat: 25.05, lng: 121.5, city: '臺北市', ...spot },
  });

Deno.test('a new street spot may carry its condition', () => {
  const ok = [
    {
      space_type: 'paidMotorcycle',
      condition: { bay: 'motorcycle', use: 'usual', charge: 'toll' },
    },
    {
      space_type: 'timedMotorcycle',
      condition: {
        bay: 'motorcycle',
        use: 'usual',
        charge: 'free',
        limits: [{ kind: 'time_limit', max_minutes: 20 }],
      },
    },
    { space_type: 'paidMotorcycle', condition: null },
    { space_type: 'paidMotorcycle' },
  ];
  for (const spot of ok) {
    const got = create(spot);
    if (got !== null) throw new Error(`${JSON.stringify(spot)}: ${got}`);
  }
});

Deno.test('a new spot refuses a condition the tables would refuse', () => {
  const bad = [
    // Not the space type it is sent with.
    {
      space_type: 'freeMotorcycle',
      condition: { bay: 'motorcycle', use: 'usual', charge: 'toll' },
    },
    // A lot's bays live in its zones.
    {
      space_type: 'offStreet',
      condition: { bay: 'motorcycle', use: 'usual', charge: 'toll' },
    },
    {
      space_type: 'paidMotorcycle',
      facility_type: 'underground',
      condition: { bay: 'motorcycle', use: 'usual', charge: 'toll' },
    },
    // Riders attach notices as evidence; only admins write a basis.
    {
      space_type: 'paidMotorcycle',
      condition: {
        bay: 'motorcycle',
        use: 'usual',
        charge: 'toll',
        basis: { source_url: 'https://example.test/n' },
      },
    },
    { space_type: 'paidMotorcycle', condition: { bay: 'motorcycle' } },
    { space_type: 'paidMotorcycle', condition: 'paidMotorcycle' },
  ];
  for (const spot of bad) {
    const got = create(spot);
    if (got !== 'invalid condition') {
      throw new Error(`${JSON.stringify(spot)}: ${got}`);
    }
  }
  if (
    create({ space_type: 'offStreet', zones_complete: false }) !==
      'invalid zones_complete'
  ) {
    throw new Error('riders never send zones_complete');
  }
});

Deno.test('conditions stay outside suggestions until the app sends them', () => {
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
