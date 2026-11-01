import cases from '../_shared/parking_contract_cases.json' with {
  type: 'json',
};
import {
  bayKindOf,
  legacyAccess,
  legacySpaceType,
  proposedConditionComplete,
  validate,
  validCondition,
  validSegments,
  validZoneEntries,
  validZones,
  zoneConditionConsistent,
} from './validate.ts';

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

Deno.test('shared cases: legacy access of zone conditions', () => {
  for (const { name, condition, access } of cases.zones) {
    const got = legacyAccess(condition as Record<string, unknown>);
    if (got !== access) throw new Error(`${name}: got ${got}`);
  }
});

Deno.test('shared cases: zone access agrees with its condition', () => {
  if (cases.zone_rows.length === 0) throw new Error('no cases');
  for (const { name, zone, consistent } of cases.zone_rows) {
    if (zoneConditionConsistent(zone) !== consistent) {
      throw new Error(`${name}: expected ${consistent}`);
    }
  }
});

Deno.test('rider zones keep their keys and stay consistent', () => {
  if (
    !validZones([{ name: 'B1', access: 'scooterOnly' }, {
      name: 'B2',
      condition: { allow: { scooter: 'not_stated', heavy: true } },
    }])
  ) {
    throw new Error('a zone stated by access or by allow is accepted');
  }
  // Every zone of a new spot states both vehicles (#201).
  if (validZones([{ name: 'B2' }])) throw new Error('unstated zone accepted');
  if (
    validZones([{ name: 'B2', condition: { allow: { scooter: true } } }])
  ) throw new Error('a zone stating one vehicle accepted');
  // Riders may send a zone condition (#188 layer 2: S5 copies limits to
  // the zones), consistent with its access and without a basis.
  const zone = {
    name: 'B1',
    access: 'heavyCar',
    condition: {
      bay: 'car',
      use: 'usual',
      allow: { scooter: false, heavy: true },
      limits: [{
        kind: 'time_limit',
        periods: [{ days: 'all', max_minutes: 120, extensions: 1 }],
      }],
    },
  };
  if (!validZones([zone])) throw new Error('zone condition refused');
  if (validZones([{ ...zone, access: 'scooterOnly' }])) {
    throw new Error('an inconsistent zone condition accepted');
  }
  if (
    validZones([{
      ...zone,
      condition: { ...zone.condition, basis: { source_url: 'https://a.tw' } },
    }])
  ) throw new Error('a rider zone basis accepted');
  if (
    validZones([{
      ...zone,
      condition: { ...zone.condition, limits: [{ kind: 'time_limit' }] },
    }])
  ) throw new Error('an old time limit shape accepted on a new write');
});

const create = (spot: Record<string, unknown>) =>
  validate({
    device_id: '3f1c2a4e-0000-4000-8000-000000000001',
    action: 'create',
    spot: {
      name: '測試',
      lat: 25.05,
      lng: 121.5,
      city: '臺北市',
      scooter_allowed: true,
      heavy_allowed: false,
      ...spot,
    },
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
        limits: [{
          kind: 'time_limit',
          periods: [{ days: 'all', max_minutes: 20, extensions: 0 }],
        }],
      },
    },
    {
      space_type: 'paidMotorcycle',
      condition: {
        bay: 'motorcycle',
        use: 'usual',
        charge: 'toll',
        limits: [{
          kind: 'no_parking',
          periods: [{ days: ['mon'], from: '06:00', to: '08:00' }],
        }],
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
    // Any lot type among several places it off the street (decision 58).
    {
      space_type: 'paidMotorcycle',
      facility_types: ['roadside', 'surface'],
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

Deno.test('suggestions carry a condition with the space type it is stored under', () => {
  const flag = (proposed: Record<string, unknown>) =>
    validate({
      device_id: '3f1c2a4e-0000-4000-8000-000000000001',
      action: 'flag',
      source_id: 'community:x',
      reason: '格位類型',
      proposed,
    });
  const timed = {
    bay: 'motorcycle',
    use: 'usual',
    charge: 'toll',
    limits: [{
      kind: 'time_limit',
      periods: [{ days: 'weekday', max_minutes: 20, extensions: 1 }],
    }],
  };
  const ok = [
    { space_type: 'timedMotorcycle', condition: timed },
    { space_type: 'paidMotorcycle', condition: null },
    // A street bay becoming a lot drops its condition.
    { space_type: 'offStreet', condition: null },
  ];
  for (const proposed of ok) {
    const error = flag(proposed);
    if (error) throw new Error(`${JSON.stringify(proposed)}: ${error}`);
  }
  const bad = [
    // Without its space type, or under another one, it would split state.
    { condition: timed },
    { space_type: 'paidMotorcycle', condition: timed },
    // A lot's conditions live in its zones.
    { space_type: 'offStreet', condition: timed },
    // Riders attach a notice as evidence; admins write the basis (§1.4).
    {
      space_type: 'timedMotorcycle',
      condition: { ...timed, basis: { source_url: 'https://a.tw/x' } },
    },
    { space_type: 'timedMotorcycle', condition: { ...timed, bay: 'bus' } },
    { space_type: 'timedMotorcycle', condition: 'timed' },
  ];
  for (const proposed of bad) {
    if (flag(proposed) !== 'invalid proposed') {
      throw new Error(`accepted ${JSON.stringify(proposed)}`);
    }
  }
});

Deno.test("an old build's zone area is let through for the DB to drop", () => {
  // #188 layer 2 (PM_ANS_20261101_49): area is gone from the contract; old
  // builds still send it, and the tables' trigger drops it.
  for (const area of ['motorcycle', 'bus', null]) {
    if (!validZones([{ name: 'B1', area, access: 'scooterOnly' }])) {
      throw new Error(`area ${JSON.stringify(area)} refused`);
    }
  }
});

Deno.test('reports may attach a notice link as evidence', () => {
  const ids = {
    device_id: '3f1c2a4e-0000-4000-8000-000000000001',
  };
  const flag = { ...ids, action: 'flag', source_id: 'x', reason: '收費' };
  if (validate({ ...flag, evidence_url: 'https://pma.gov.taipei/n?a=1' })) {
    throw new Error('https link rejected');
  }
  if (create({ space_type: 'paidMotorcycle' })) throw new Error('base');
  for (
    const url of [
      'http://pma.gov.taipei',
      'https://a b',
      'javascript:alert(1)',
      `https://a.tw/${'x'.repeat(2048)}`,
      42,
    ]
  ) {
    if (validate({ ...flag, evidence_url: url }) !== 'invalid evidence_url') {
      throw new Error(`accepted ${url}`);
    }
  }
  // Only reports that open a case or a spot keep one.
  if (
    validate({
      ...ids,
      action: 'vote',
      spot_id: '3f1c2a4e-0000-4000-8000-000000000002',
      vote: 'still_there',
      evidence_url: 'https://a.tw',
    }) !== 'invalid evidence_url'
  ) throw new Error('vote kept evidence');
});

// #188: zone and segment lists and the seven bay kinds, the cases Dart and
// the generated SQL run too.
Deno.test('shared cases: zone lists', () => {
  if (cases.zone_lists.length === 0) throw new Error('no cases');
  for (const { name, zones, valid } of cases.zone_lists) {
    if (validZoneEntries(zones) !== valid) {
      throw new Error(`${name}: expected ${valid}`);
    }
  }
});

Deno.test('shared cases: segment lists', () => {
  if (cases.segment_lists.length === 0) throw new Error('no cases');
  for (const { name, segments, valid } of cases.segment_lists) {
    if (validSegments(segments) !== valid) {
      throw new Error(`${name}: expected ${valid}`);
    }
  }
});

Deno.test('shared cases: bay kinds', () => {
  if (cases.bay_kinds.length === 0) throw new Error('no cases');
  for (const { name, condition, bay_kind } of cases.bay_kinds) {
    const got = bayKindOf(condition);
    if (got !== bay_kind) throw new Error(`${name}: got ${got}`);
  }
});

Deno.test('a suggestion gives a time limit its periods, unless it keeps the stored one (#188 layer 2)', () => {
  const old = {
    bay: 'motorcycle',
    use: 'usual',
    charge: 'toll',
    limits: [{ kind: 'time_limit', max_minutes: 30 }],
  };
  const proposed = { space_type: 'timedMotorcycle', condition: old };
  if (proposedConditionComplete(proposed, { condition: { charge: 'free' } })) {
    throw new Error('an old time limit shape accepted as new');
  }
  if (
    !proposedConditionComplete(proposed, {
      condition: { ...old, charge: 'free' },
    })
  ) throw new Error('the stored time limit, untouched, refused');
  if (!proposedConditionComplete({ space_type: 'paidMotorcycle' }, undefined)) {
    throw new Error('a suggestion without a condition refused');
  }
});
