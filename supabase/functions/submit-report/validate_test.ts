import { identityHash, validate } from './validate.ts';
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
