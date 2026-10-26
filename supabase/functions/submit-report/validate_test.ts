import { identityHash, validate, validFee, validZones } from './validate.ts';

Deno.test('zones carry the same structured fee contract, car prices included', () => {
  const zone = {
    name: 'B2',
    access: 'scooterHeavy',
    fee: {
      scooter: { mode: 'free' },
      heavy: { mode: 'hourly', amount: 20, per_minutes: 30, daily_cap: 100 },
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
    ]
  ) {
    if (validZones([{ ...zone, fee }])) {
      throw new Error('invalid zone fee accepted');
    }
  }
  if (!validZones([{ ...zone, fee: { car: { mode: 'free' } } }])) {
    throw new Error('zone car fee rejected');
  }
  if (!validZones([{ name: '舊分區' }])) {
    throw new Error('legacy zone rejected');
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
    heavy_allowed: null,
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
        proposed: { heavy_allowed: true, scooter_allowed: null },
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
        scooter: { mode: 'per_visit', amount: 30, max_minutes: 360 },
        heavy: { mode: 'daily', amount: 50 },
      },
      { scooter: { mode: 'free' }, heavy: { mode: 'posted' } },
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
  const fee = { scooter: { mode: 'daily', amount: 30 } };
  if (validate({ ...base, spot: { ...base.spot, fee } }) !== null) {
    throw new Error('create with a fee refused');
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
    validate({ ...flag, proposed: { fee, fee_note: '每日 30 元' } }) !== null
  ) throw new Error('suggested fee refused');
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
