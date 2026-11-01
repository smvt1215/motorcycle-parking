import {
  identityHash,
  segmentPatchesStated,
  spotDeletedResponse,
  validate,
  validFee,
  validZones,
  zonePatchesStated,
} from './validate.ts';

Deno.test('zones carry the same structured fee contract, car prices included', () => {
  const zone = {
    name: 'B2',
    access: 'scooterHeavy',
    fee: {
      scooter: { mode: 'free' },
      heavy: {
        mode: 'hourly',
        amount: 20,
        per_minutes: 30,
        daily_cap: 100,
        cap_reset: 'calendar_day',
      },
      car: { mode: 'not_applicable' },
    },
  };
  if (!validZones([zone])) throw new Error('valid zone fee rejected');
  for (
    const fee of [
      null,
      20,
      { bus: { mode: 'free' } },
      { scooter: { mode: 'same_as_car' } },
      { heavy: { mode: 'hourly', amount: 20 } },
      { heavy: { mode: 'daily', amount: -1 } },
      { heavy: { mode: 'daily', amount: 2.5 } },
      // New writes name all three vehicles and each rate whole (#188
      // layer 2, fee.write).
      { scooter: { mode: 'free' }, heavy: { mode: 'free' } },
      {
        scooter: { mode: 'free' },
        heavy: { mode: 'per_visit', amount: 30 },
        car: { mode: 'free' },
      },
    ]
  ) {
    if (validZones([{ ...zone, fee }])) {
      throw new Error('invalid zone fee accepted');
    }
  }
  if (
    !validZones([{
      ...zone,
      fee: {
        scooter: { mode: 'not_applicable' },
        heavy: { mode: 'not_applicable' },
        car: { mode: 'free' },
      },
    }])
  ) {
    throw new Error('zone car fee rejected');
  }
  // A new spot's zone states both vehicles (#201).
  if (validZones([{ name: '舊分區' }])) {
    throw new Error('a zone without eligibility accepted');
  }
});
const base = {
  device_id: '10000000-0000-4000-8000-000000000001',
  action: 'create',
  spot: {
    name: '機車格',
    lat: 25,
    lng: 121,
    city: '臺北市',
    space_type: 'paidMotorcycle',
    scooter_allowed: true,
    heavy_allowed: false,
  },
};
Deno.test('valid reports pass, wrong coordinates and oversized notes fail', () => {
  if (validate(base) !== null) throw new Error('valid report rejected');
  for (
    const body of [
      { ...base, spot: { ...base.spot, lat: 0 } },
      { ...base, spot: { ...base.spot, note: 'a'.repeat(501) } },
      { ...base, spot: { ...base.spot, heavy_allowed: 'true' } },
      { ...base, device_id: 'fake' },
    ]
  ) {
    if (validate(body) === null) throw new Error('invalid report accepted');
  }
});
Deno.test('arbitrary actions, malformed votes and removed annotations fail', () => {
  for (
    const body of [{ ...base, action: 'admin' }, {
      ...base,
      action: 'vote',
      spot_id: 'bad',
      vote: 'gone',
    }, {
      ...base,
      action: 'annotation',
      source_id: 'tdx:Taipei:1',
      heavy_access: 'allowed',
    }]
  ) if (validate(body) === null) throw new Error('invalid action accepted');
});
Deno.test('flags may carry a structured suggestion', () => {
  const flag = {
    device_id: base.device_id,
    action: 'flag',
    source_id: 'official:10000000-0000-4000-8000-000000000001',
    reason: '格位類型：建議「重機專用格」',
  };
  const community = {
    ...flag,
    source_id: '10000000-0000-4000-8000-000000000002',
  };
  // What the app sends for each suggestion form.
  for (
    const body of [
      flag,
      { ...flag, field: '停車點名稱', proposed: { name: '市府轉運站' } },
      { ...flag, field: '格位類型', proposed: { space_type: 'heavyOnly' } },
      { ...flag, field: '收費資訊', proposed: { fee_note: '每小時 20 元' } },
      {
        ...flag,
        field: '機車停放資格',
        proposed: { heavy_allowed: true, scooter_allowed: false },
      },
      {
        ...flag,
        field: 'eligibility',
        proposed: { heavy_not_stated: true },
      },
      { ...flag, field: '位置或其他備註', note: '入口在後巷' },
      {
        ...flag,
        field: '位置或其他備註',
        proposed: { lat: 25.01, lng: 121.46 },
      },
      { ...flag, field: '點位已不存在', proposed: { hidden: true } },
      { ...community, field: '點位已不存在', proposed: { status: 'hidden' } },
      { ...flag, proposed: { facility_type: 'underground', address: '' } },
      // Several types (decision 58), or null to clear them.
      { ...flag, proposed: { facility_types: ['underground', 'surface'] } },
      { ...flag, proposed: { facility_types: null } },
      // Stable keys, which replace the Chinese labels above.
      { ...flag, field: 'name', proposed: { name: '市府轉運站' } },
      { ...flag, field: 'space_type', proposed: { space_type: 'car' } },
      { ...flag, field: 'fee_note', proposed: { fee_note: '免費' } },
      { ...flag, field: 'eligibility', proposed: { heavy_allowed: false } },
      { ...flag, field: 'note', note: '入口在後巷' },
      {
        ...flag,
        field: 'guide',
        proposed: { entrance_note: '松仁路側', parking_guide: 'B2 靠電梯' },
      },
      { ...community, field: 'gone', proposed: { status: 'hidden' } },
    ]
  ) {
    if (validate(body) !== null) {
      throw new Error(`valid suggestion rejected: ${JSON.stringify(body)}`);
    }
  }
  for (
    const body of [
      { ...flag, field: '' },
      { ...flag, field: '位置' },
      { ...flag, field: 'heavy_allowed' },
      { ...flag, field: 'Name' },
      { ...flag, field: ['name'] },
      { ...flag, field: ['格位類型'] },
      { ...flag, field: null },
      { ...flag, field: true },
      { ...flag, field: 1 },
      { ...flag, proposed: [] },
      { ...flag, proposed: {} },
      { ...flag, proposed: { nested: { a: 1 } } },
      { ...flag, proposed: { user_id: 'someone' } },
      { ...flag, proposed: { last_confirmed_at: '2026-01-01' } },
      { ...flag, proposed: JSON.parse('{"toString":"x"}') },
      { ...flag, proposed: JSON.parse('{"__proto__":"x"}') },
      { ...flag, proposed: { note: 'a'.repeat(501) } },
      { ...flag, proposed: { name: ' ' } },
      { ...flag, proposed: { name: 'a'.repeat(101) } },
      { ...flag, proposed: { fee_note: 'a'.repeat(201) } },
      { ...flag, proposed: { space_type: 'bus' } },
      { ...flag, proposed: { space_type: null } },
      { ...flag, proposed: { heavy_allowed: 'true' } },
      { ...flag, proposed: { facility_type: 'tower' } },
      { ...flag, proposed: { facility_type: ['underground'] } },
      { ...flag, proposed: { facility_types: [] } },
      { ...flag, proposed: { facility_types: 'underground' } },
      { ...flag, proposed: { facility_types: ['surface', 'surface'] } },
      { ...flag, proposed: { facility_types: ['tower'] } },
      { ...flag, proposed: { parking_access: ['heavyOnly'] } },
      { ...flag, proposed: { space_type: ['car'] } },
      { ...flag, proposed: { lat: 0, lng: 121 } },
      { ...flag, proposed: { lng: '121' } },
      // Each source hides its own way, and riders may only ask to hide.
      { ...flag, proposed: { status: 'hidden' } },
      { ...community, proposed: { hidden: true } },
      { ...community, proposed: { status: 'confirmed' } },
      { ...flag, proposed: { hidden: 'yes' } },
      { ...flag, proposed: { hidden: false } },
    ]
  ) {
    if (validate(body) === null) {
      throw new Error(`bad suggestion accepted: ${JSON.stringify(body)}`);
    }
  }
});
Deno.test('a location suggestion carries both coordinates inside Taiwan', () => {
  const assertEquals = (got: unknown, want: unknown) => {
    if (got !== want) throw new Error(`expected ${want}, got ${got}`);
  };
  const flag = {
    device_id: base.device_id,
    action: 'flag',
    source_id: '10000000-0000-4000-8000-000000000002',
    reason: '停車點位置：建議移到 25.033900, 121.562300',
    field: 'location',
  };
  assertEquals(
    validate({ ...flag, proposed: { lat: 25.0339, lng: 121.5623 } }),
    null,
  );
  // With the county and district the app looked up.
  assertEquals(
    validate({
      ...flag,
      proposed: {
        lat: 25.0339,
        lng: 121.5623,
        city: '新北市',
        district: '板橋區',
      },
    }),
    null,
  );
  assertEquals(
    validate({
      ...flag,
      proposed: { lat: 25.0339, lng: 121.5623, city: '新北市', district: '' },
    }),
    null,
  );
  // TDX spots have no row to patch, so the app sends the summary only.
  assertEquals(validate({ ...flag, note: '格位在對面' }), null);
  for (
    const proposed of [
      { lat: 25.0339 },
      { lng: 121.5623 },
      { lat: 25.0339, lng: 121.5623, name: '改名' },
      { lat: 25.0339, lng: 121.5623, city: '' },
      { lat: 25.0339, lng: 121.5623, city: 'x'.repeat(31) },
      { lat: 25.0339, lng: 121.5623, district: 'x'.repeat(31) },
      { lat: 25.0339, lng: 121.5623, city: ['新北市'] },
      { lat: 25.0339, lng: 121.5623, district: 3 },
      { city: '新北市', district: '板橋區' },
      { lat: 25.0339, city: '新北市' },
    ]
  ) {
    assertEquals(validate({ ...flag, proposed }), 'invalid proposed');
  }
  for (
    const proposed of [
      { lat: 19.9, lng: 121.5 },
      { lat: 27.1, lng: 121.5 },
      { lat: 25, lng: 117.9 },
      { lat: 25, lng: 123.1 },
    ]
  ) {
    assertEquals(validate({ ...flag, proposed }), 'invalid coordinates');
  }
  // County and district never travel without a position, whatever the field.
  assertEquals(
    validate({ ...flag, field: 'name', proposed: { city: '新北市' } }),
    'invalid proposed',
  );
  for (
    const proposed of [{ lat: '25', lng: 121.5 }, { lat: NaN, lng: 121.5 }]
  ) {
    assertEquals(validate({ ...flag, proposed }), 'invalid proposed');
  }
});

Deno.test('fees are a rate per vehicle with known modes only', () => {
  for (
    const fee of [
      {},
      {
        scooter: {
          mode: 'hourly',
          amount: 20,
          per_minutes: 60,
          daily_cap: 100,
        },
        heavy: { mode: 'same_as_car' },
      },
      {
        scooter: { mode: 'per_visit', amount: 30, extension_amount: 30 },
        heavy: { mode: 'per_visit', amount: 50, renew: 'midnight' },
      },
      { scooter: { mode: 'free' }, heavy: { mode: 'not_applicable' } },
      { heavy: { mode: 'same_as_scooter' } },
      { car: { mode: 'free' } },
    ]
  ) {
    if (!validFee(fee)) {
      throw new Error(`valid fee refused: ${JSON.stringify(fee)}`);
    }
  }
  for (
    const fee of [
      null,
      [],
      'free',
      { scooter: 'free' },
      { bus: { mode: 'free' } },
      { scooter: { mode: 'monthly', amount: 300 } },
      { scooter: { mode: 'same_as_car' } },
      { scooter: { mode: 'hourly', amount: 20 } },
      { scooter: { mode: 'hourly', amount: '20', per_minutes: 60 } },
      { scooter: { mode: 'daily', amount: 20.5 } },
      { scooter: { mode: 'daily', amount: 10001 } },
      { scooter: { mode: 'hourly', amount: 20, per_minutes: 0 } },
      { scooter: { mode: 'free', amount: 0 } },
      { scooter: { mode: 'toString' } },
      { scooter: { mode: ['daily'], amount: 20 } },
    ]
  ) {
    if (validFee(fee)) {
      throw new Error(`bad fee accepted: ${JSON.stringify(fee)}`);
    }
  }
  const fee = {
    scooter: { mode: 'per_visit', amount: 30, renew: 'midnight' },
    heavy: { mode: 'not_applicable' },
    car: { mode: 'not_applicable' },
  };
  if (validate({ ...base, spot: { ...base.spot, fee } }) !== null) {
    throw new Error('create with a fee refused');
  }
  // A new spot names all three vehicles, each rate whole (#188 layer 2).
  for (
    const partial of [
      { scooter: fee.scooter },
      { ...fee, scooter: { mode: 'per_visit', amount: 30 } },
      { ...fee, scooter: { mode: 'daily', amount: 30 } },
    ]
  ) {
    if (
      validate({ ...base, spot: { ...base.spot, fee: partial } }) !==
        'invalid fee'
    ) throw new Error(`incomplete fee accepted: ${JSON.stringify(partial)}`);
  }
  if (
    validate({
      ...base,
      spot: { ...base.spot, fee: { scooter: { mode: 'weekly' } } },
    }) !== 'invalid fee'
  ) throw new Error('create with a bad fee accepted');
  const flag = {
    device_id: base.device_id,
    action: 'flag',
    source_id: '10000000-0000-4000-8000-000000000002',
    reason: '收費資訊：每日 30 元',
    field: 'fee_note',
  };
  if (
    validate({ ...flag, proposed: { fee, fee_note: '每次 30 元' } }) !== null
  ) throw new Error('suggested fee refused');
  // A suggestion names the vehicles it changes, each rate whole.
  if (
    validate({
      ...flag,
      proposed: { fee: { scooter: { mode: 'per_visit', amount: 30 } } },
    }) === null
  ) throw new Error('a per-visit rate without renew accepted');
  if (
    validate({
      ...flag,
      proposed: { fee: { scooter: { mode: 'weekly' } } },
    }) ===
      null
  ) throw new Error('suggested bad fee accepted');
});
Deno.test('new lots may carry their type, access, entrance, guide and zones', () => {
  const lot = {
    ...base,
    spot: {
      ...base.spot,
      space_type: 'offStreet',
      facility_type: 'underground',
      facility_types: ['underground', 'surface'],
      parking_access: 'scooterHeavy',
      entrance_note: '入口在松仁路側',
      parking_guide: 'B2 機車區靠電梯',
      parking_zones: [
        { name: 'B2 機車區', access: 'scooterHeavy', guide: '靠電梯' },
        { name: 'B3 汽車區', access: 'heavyCar' },
      ],
    },
  };
  if (validate(lot) !== null) throw new Error('lot details refused');
  for (
    const [key, value] of [
      ['facility_type', 'tower'],
      ['facility_type', ['underground']],
      ['facility_types', []],
      ['facility_types', 'underground'],
      ['facility_types', ['underground', 'underground']],
      ['facility_types', ['tower']],
      ['facility_types', [null]],
      ['parking_access', 'everyone'],
      ['entrance_note', 'a'.repeat(501)],
      ['parking_guide', 42],
      ['parking_zones', {}],
      ['parking_zones', [{ name: '' }]],
      ['parking_zones', [{ name: 'B2', access: 'all' }]],
      ['parking_zones', [{ name: 'B2', fee: 20 }]],
      [
        'parking_zones',
        Array.from({ length: 11 }, (_, i) => ({ name: `Z${i}` })),
      ],
    ] as const
  ) {
    if (validate({ ...lot, spot: { ...lot.spot, [key]: value } }) === null) {
      throw new Error(`bad ${key} accepted: ${JSON.stringify(value)}`);
    }
  }
  if (!validZones([]) || validZones(null)) throw new Error('zone list shape');
});
Deno.test('identity hashes are deterministic, namespaced and keyed', async () => {
  const a = await identityHash('secret', 'ip:127.0.0.1');
  if (
    a.length !== 64 || a !== await identityHash('secret', 'ip:127.0.0.1') ||
    a === await identityHash('other', 'ip:127.0.0.1') ||
    a === await identityHash('secret', 'device:127.0.0.1')
  ) throw new Error('incorrect HMAC');
});
Deno.test('every app space kind is accepted; unknown kinds fail', () => {
  for (
    const kind of [
      'disabledMotorcycle',
      'timedMotorcycle',
      'flexShared',
      'evMotorcycle',
    ]
  ) {
    const body = { ...base, spot: { ...base.spot, space_type: kind } };
    if (validate(body) !== null) throw new Error(`${kind} rejected`);
  }
  const unknown = { ...base, spot: { ...base.spot, space_type: 'bus' } };
  if (validate(unknown) === null) throw new Error('unknown kind accepted');
});
Deno.test('riders never send a source link; suggestions cannot carry one', () => {
  const update = {
    ...base,
    action: 'update',
    spot_id: '10000000-0000-4000-8000-000000000002',
    spot: { name: '更新' },
  };
  // Not even an https one: the link is set by admins and imports only, and
  // the table (202610270040) takes nothing but https.
  for (
    const url of [
      'javascript:alert(1)',
      'data:text/html,<script>alert(1)</script>',
      'intent://scan/#Intent;scheme=zxing;end',
      'http://www.gov.taipei/',
      'https://www.gov.taipei/',
      '',
      null,
    ]
  ) {
    for (
      const body of [
        { ...base, spot: { ...base.spot, source_url: url } },
        { ...update, spot: { ...update.spot, source_url: url } },
      ]
    ) {
      if (validate(body) !== 'invalid source_url') {
        throw new Error(`source link accepted: ${JSON.stringify(body)}`);
      }
    }
  }
  const flag = {
    device_id: base.device_id,
    action: 'flag',
    source_id: '10000000-0000-4000-8000-000000000002',
    reason: '來源網址',
    proposed: { source_url: 'javascript:alert(1)' },
  };
  if (validate(flag) !== 'invalid proposed') {
    throw new Error('a suggested source link was accepted');
  }
});

Deno.test('a closure suggestion carries its cause and a real date (#116)', () => {
  const flag = (proposed: unknown, field = 'gone') => ({
    action: 'flag',
    device_id: '00000000-0000-4000-8000-000000000000',
    source_id: '00000000-0000-4000-8000-000000000001',
    reason: '這裡已經不能停車：施工中',
    field,
    proposed,
  });
  for (
    const ok of [
      { closure: { reason: 'works' } },
      { closure: { reason: 'closed', until: '2026-11-30' } },
    ]
  ) {
    const error = validate(flag(ok));
    if (error) throw new Error(`valid closure refused: ${error}`);
  }
  const reopened = validate(flag({ closure: null }, 'reopened'));
  if (reopened) throw new Error(`reopened refused: ${reopened}`);
  for (
    const bad of [
      { closure: { reason: 'gone' } },
      { closure: { reason: 'works', until: '2026-02-30' } },
      { closure: { reason: 'works', until: '11/30' } },
      { closure: { reason: 'works', since: '2026-10-01' } },
      { closure: 'works' },
    ]
  ) {
    if (!validate(flag(bad))) {
      throw new Error(`invalid closure accepted: ${JSON.stringify(bad)}`);
    }
  }
});

Deno.test('new street spots may carry segments; zones and segments take no ids from riders (#188)', () => {
  const street = {
    ...base,
    spot: {
      ...base.spot,
      space_type: 'paidMotorcycle',
      condition: { bay: 'motorcycle', use: 'usual', charge: 'toll' },
      parking_segments: [
        {
          name: '北側一般機車格',
          side: 'north',
          range: '建國北路口至松江路口',
          total: 18,
          condition: {
            bay: 'motorcycle',
            use: 'usual',
            allow: { scooter: true, heavy: false },
          },
          evidence_url: 'https://example.com/n.jpg',
          fee: {
            scooter: { mode: 'hourly', amount: 20, per_minutes: 60 },
            heavy: { mode: 'not_applicable' },
            car: { mode: 'not_applicable' },
          },
        },
        {
          name: '南側',
          condition: {
            bay: 'car',
            use: 'share',
            share: 'car_motorcycle',
            allow: { scooter: true, heavy: 'not_stated' },
          },
        },
      ],
    },
  };
  if (validate(street) !== null) throw new Error('segments refused');
  for (
    const segments of [
      [{ id: 's1', name: '北側' }],
      [{
        name: '北側',
        condition: { bay: 'motorcycle', basis: { source_url: 'https://x.tw' } },
      }],
      // Each new segment states both vehicles (#188 layer 2).
      [{
        name: '北側',
        condition: { bay: 'motorcycle', allow: { scooter: true } },
      }],
      [{ name: '北側' }],
      [{ name: '' }],
      // A segment's fee is written whole; plans are an admin's.
      [{
        name: '北側',
        condition: { allow: { scooter: true, heavy: true } },
        fee: {},
      }],
      [{
        name: '北側',
        condition: { allow: { scooter: true, heavy: true } },
        fee_plan: 'p1',
      }],
      {},
    ]
  ) {
    if (
      validate({
        ...street,
        spot: { ...street.spot, parking_segments: segments },
      }) ===
        null
    ) throw new Error(`bad segments accepted: ${JSON.stringify(segments)}`);
  }
  const lot = {
    ...base,
    spot: {
      ...base.spot,
      space_type: 'offStreet',
      parking_zones: [{
        name: 'B1',
        access: 'scooterOnly',
        evidence_url: 'https://example.com/b1.jpg',
      }],
    },
  };
  if (validate(lot) !== null) throw new Error('a zone notice link refused');
  for (
    const zones of [[{ id: 'b1', name: 'B1', access: 'scooterOnly' }], [{
      name: 'B1',
      access: 'scooterOnly',
      evidence_url: 'http://x.tw',
    }], [{ name: 'B1' }]]
  ) {
    if (
      validate({ ...lot, spot: { ...lot.spot, parking_zones: zones } }) === null
    ) {
      throw new Error(`bad zones accepted: ${JSON.stringify(zones)}`);
    }
  }
});

Deno.test('suggestions may change zones and segments by id (#188)', () => {
  const flag = {
    device_id: base.device_id,
    action: 'flag',
    source_id: '10000000-0000-4000-8000-000000000002',
    reason: '分區：修改',
    field: 'zones',
  };
  for (
    const proposed of [
      { parking_zones: [{ id: 'b1', guide: '走右側坡道' }] },
      { parking_zones: [{ id: 'b1', guide: null, access: 'scooterHeavy' }] },
      {
        parking_zones: [{ id: 'b2', removed: true }, {
          name: 'B3',
          access: 'heavyOnly',
        }],
      },
      {
        parking_zones: [{
          id: 'b1',
          evidence_url: 'https://example.com/b1.jpg',
        }],
      },
      { parking_segments: [{ id: 's1', total: 20, range: '全段' }] },
      {
        parking_segments: [{
          id: 's1',
          condition: {
            bay: 'car',
            use: 'share',
            share: 'car_motorcycle',
            allow: { scooter: true, heavy: true },
          },
        }],
      },
      {
        parking_segments: [{ id: 's1', removed: true }, {
          name: '南側',
          side: 'south',
          condition: { allow: { scooter: true, heavy: false } },
        }],
      },
    ]
  ) {
    const body = { ...flag, proposed };
    if (validate(body) !== null) {
      throw new Error(`refused: ${JSON.stringify(proposed)}`);
    }
  }
  for (
    const proposed of [
      { parking_zones: [] },
      { parking_zones: [{ id: 'b1' }] },
      { parking_zones: [{ id: 'b1', name: null }] },
      { parking_zones: [{ id: 'b1', guide: 'x' }, { id: 'b1', guide: 'y' }] },
      { parking_zones: [{ id: 'B1', guide: 'x' }] },
      { parking_zones: [{ id: 'b1', removed: false }] },
      { parking_zones: [{ id: 'b1', removed: true, name: 'B1' }] },
      { parking_zones: [{ name: 'B3', removed: true }] },
      { parking_zones: [{ id: 'b1', access: 'all' }] },
      { parking_zones: [{ id: 'b1', condition: { bay: 'car' } }] },
      { parking_zones: [{ id: 'b1', evidence_url: 'http://x.tw' }] },
      { parking_zones: [{ name: '' }] },
      { parking_zones: { id: 'b1' } },
      { parking_segments: [{ id: 's1', side: 'left' }] },
      {
        parking_segments: [{
          id: 's1',
          condition: { bay: 'motorcycle', allow: { heavy: true } },
        }],
      },
      {
        parking_segments: [{
          id: 's1',
          condition: {
            bay: 'motorcycle',
            basis: { source_url: 'https://x.tw' },
          },
        }],
      },
      { parking_segments: [{ id: 's1', total: 0 }] },
    ]
  ) {
    if (validate({ ...flag, proposed }) === null) {
      throw new Error(`accepted: ${JSON.stringify(proposed)}`);
    }
  }
});

Deno.test('a new spot states both vehicles; a suggestion never clears one (#201)', () => {
  const spot = (extra: Record<string, unknown>) =>
    validate({
      ...base,
      spot: {
        name: '機車格',
        lat: 25,
        lng: 121,
        city: '臺北市',
        space_type: 'paidMotorcycle',
        ...extra,
      },
    });
  if (spot({ scooter_allowed: true, heavy_allowed: false }) !== null) {
    throw new Error('a street spot with both vehicles refused');
  }
  for (
    const bad of [
      { scooter_allowed: true },
      { scooter_allowed: true, heavy_allowed: null },
      { scooter_allowed: true, heavy_not_stated: true },
      { scooter_allowed: 'yes', heavy_allowed: true },
    ]
  ) {
    if (spot(bad) === null) throw new Error(`accepted ${JSON.stringify(bad)}`);
  }
  if (
    spot({
      space_type: 'offStreet',
      scooter_allowed: true,
      heavy_not_stated: true,
    }) !== null
  ) throw new Error('a lot may say 官方未標示');
  if (
    spot({
      space_type: 'offStreet',
      scooter_allowed: true,
      heavy_allowed: true,
      heavy_not_stated: true,
    }) === null
  ) throw new Error('a boolean beside not_stated accepted');
  const flag = {
    device_id: base.device_id,
    action: 'flag',
    source_id: '10000000-0000-4000-8000-000000000002',
    reason: '資格',
    field: 'eligibility',
  };
  for (
    const proposed of [
      { scooter_allowed: null },
      { heavy_not_stated: false },
      { heavy_allowed: true, heavy_not_stated: true },
      { parking_zones: [{ name: '新分區' }] },
    ]
  ) {
    if (validate({ ...flag, proposed }) === null) {
      throw new Error(`accepted ${JSON.stringify(proposed)}`);
    }
  }
  // The pairs the app sends (Eligible.payload) are accepted.
  for (
    const proposed of [
      { heavy_allowed: null, heavy_not_stated: true },
      { heavy_not_stated: true },
      { heavy_allowed: true, heavy_not_stated: false },
      { scooter_allowed: false },
    ]
  ) {
    const got = validate({ ...flag, proposed });
    if (got !== null) {
      throw new Error(`refused ${JSON.stringify(proposed)}: ${got}`);
    }
  }
});

Deno.test('a zone a suggestion changes states both vehicles once applied (#201)', () => {
  const stored = [
    { id: 'a', name: 'A', access: 'scooterOnly' },
    { id: 'b', name: 'B' },
  ];
  if (!zonePatchesStated([{ id: 'a', guide: '右側' }], stored)) {
    throw new Error('a stated zone refused');
  }
  if (zonePatchesStated([{ id: 'b', guide: '右側' }], stored)) {
    throw new Error('a changed old zone left unstated');
  }
  if (!zonePatchesStated([{ id: 'b', access: 'heavyOnly' }], stored)) {
    throw new Error('filling an old zone in refused');
  }
  if (zonePatchesStated([{ id: 'a', access: null }], stored)) {
    throw new Error('clearing access accepted');
  }
  if (!zonePatchesStated([{ id: 'b', removed: true }], stored)) {
    throw new Error('removing refused');
  }
  if (!zonePatchesStated([{ id: 'b', guide: 'x' }], undefined)) {
    throw new Error('without the stored list the review decides');
  }
});

Deno.test('a deleted spot is refused with a sentence the app shows (#200)', () => {
  if (spotDeletedResponse.error !== 'spot deleted') throw new Error('error');
  if (spotDeletedResponse.message !== '這個點已被刪除') {
    throw new Error('message');
  }
});

Deno.test("segments are a street spot's; a changed segment states both vehicles (#188 layer 2)", () => {
  const lot = {
    ...base,
    spot: {
      ...base.spot,
      space_type: 'offStreet',
      parking_segments: [{
        name: '北側',
        condition: { allow: { scooter: true, heavy: false } },
      }],
    },
  };
  if (validate(lot) !== 'invalid parking_segments') {
    throw new Error('a lot with segments accepted');
  }
  const stored = [{ id: 's1', name: '北側' }, {
    id: 's2',
    name: '南側',
    condition: { allow: { scooter: true, heavy: false } },
  }];
  if (segmentPatchesStated([{ id: 's1', total: 3 }], stored)) {
    throw new Error('a changed segment without eligibility accepted');
  }
  if (!segmentPatchesStated([{ id: 's2', total: 3 }], stored)) {
    throw new Error('a stated segment refused');
  }
  if (
    !segmentPatchesStated(
      [{ id: 's1', condition: { allow: { scooter: false, heavy: true } } }],
      stored,
    )
  ) throw new Error('a segment filled in refused');
});
