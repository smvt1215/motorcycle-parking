import { applyAnnotations } from './annotations.ts';
import type { Spot } from './normalize.ts';
const eq = (actual: unknown, expected: unknown) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`,
    );
  }
};
const spot = (id: string, note = ''): Spot => ({
  id,
  name: id,
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  source: 'tdx',
  space_type: 'offStreet',
  fee_note: '請依現場公告',
  scooter_total: 10,
  available: null,
  heavy_allowed: null,
  scooter_allowed: true,
  status: 'confirmed',
  updated_at: null,
  note,
});
Deno.test('confirmed annotations set heavy access and explain the source', () => {
  const [allowed, denied, car, untouched] = applyAnnotations(
    [spot('a'), spot('d', '即時資料缺漏'), spot('c'), spot('u')],
    [
      { source_id: 'a', heavy_access: 'allowed' },
      { source_id: 'd', heavy_access: 'denied' },
      { source_id: 'c', heavy_access: 'car_space' },
    ],
  );
  eq(allowed.heavy_allowed, true);
  eq(allowed.note, '社群回報經審核：大型重機可停');
  eq(denied.heavy_allowed, false);
  eq(denied.note, '即時資料缺漏；社群回報經審核：大型重機不可停');
  eq(car.heavy_allowed, true);
  eq(car.note, '社群回報經審核：大型重機須停汽車格');
  eq(untouched, spot('u'));
});
Deno.test('unknown annotation values leave the spot unchanged', () => {
  const [result] = applyAnnotations([spot('a')], [
    { source_id: 'a', heavy_access: 'maybe' as 'allowed' },
  ]);
  eq(result, spot('a'));
});
