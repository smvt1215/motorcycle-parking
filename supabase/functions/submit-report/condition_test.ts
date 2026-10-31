import cases from '../_shared/parking_contract_cases.json' with {
  type: 'json',
};
import {
  bayKindOf,
  legacyAccess,
  legacySpaceType,
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
  // Riders send no zone condition yet: refused as an unknown key, so the
  // consistency check never loosens what the DB refuses.
  const zone = {
    name: 'B1',
    access: 'heavyCar',
    condition: {
      bay: 'car',
      use: 'usual',
      allow: { scooter: false, heavy: true },
    },
  };
  if (validZones([zone])) throw new Error('zone condition accepted');
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
    limits: [{ kind: 'time_limit', max_minutes: 20 }],
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

Deno.test('rider zones may name their area', () => {
  if (
    !validZones([{ name: 'B1', area: 'motorcycle', access: 'scooterOnly' }, {
      name: 'B2',
      area: 'car',
      access: 'heavyCar',
    }])
  ) {
    throw new Error('zone area rejected');
  }
  for (const area of ['bus', '', null, ['car']]) {
    if (validZones([{ name: 'B1', area, access: 'scooterOnly' }])) {
      throw new Error(`area ${JSON.stringify(area)} accepted`);
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
