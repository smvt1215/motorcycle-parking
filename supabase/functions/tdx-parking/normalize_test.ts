import { normalize } from './normalize.ts';
const fixture = JSON.parse(
  await Deno.readTextFile(new URL('./fixtures/taipei.json', import.meta.url)),
);
function eq(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
Deno.test('only motorcycle totals and availability are used', () => {
  const spots = normalize(
    'Taipei',
    fixture.parks,
    fixture.spaces,
    fixture.availability,
    false,
    Date.parse(fixture.as_of),
  );
  eq(spots.length, 1);
  eq(spots[0].scooter_total, 30);
  eq(spots[0].available, 7);
  eq(spots[0].heavy_allowed, null);
});
Deno.test('negative counts, stale data and unknown dates remain unknown', () => {
  const negative = structuredClone(fixture.availability);
  negative[0].Spaces[1].AvailableSpaces = -9;
  eq(
    normalize(
      'Taipei',
      fixture.parks,
      fixture.spaces,
      negative,
      false,
      Date.parse(fixture.as_of),
    )[0].available,
    null,
  );
  eq(
    normalize(
      'Taipei',
      fixture.parks,
      fixture.spaces,
      fixture.availability,
      false,
      Date.parse(fixture.as_of) + 3600000,
    )[0].available,
    null,
  );
  delete negative[0].DataCollectTime;
  eq(
    normalize('Taipei', fixture.parks, fixture.spaces, negative)[0].available,
    null,
  );
});
Deno.test('car-only data and invalid coordinates are excluded', () => {
  const carOnly = structuredClone(fixture.spaces);
  carOnly[0].Spaces = carOnly[0].Spaces.slice(0, 1);
  eq(normalize('Taipei', fixture.parks, carOnly, []).length, 0);
  const bad = structuredClone(fixture.parks);
  bad[0].CarParkPosition.PositionLat = 0;
  eq(normalize('Taipei', bad, fixture.spaces, fixture.availability).length, 0);
});
