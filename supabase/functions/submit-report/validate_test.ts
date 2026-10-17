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
Deno.test('identity hashes are deterministic, namespaced and keyed', async () => {
  const a = await identityHash('secret', 'ip:127.0.0.1');
  if (
    a.length !== 64 || a !== await identityHash('secret', 'ip:127.0.0.1') ||
    a === await identityHash('other', 'ip:127.0.0.1') ||
    a === await identityHash('secret', 'device:127.0.0.1')
  ) throw new Error('incorrect HMAC');
});
