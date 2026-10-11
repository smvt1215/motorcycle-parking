import { cities } from './tdx.ts';
import { cityBounds } from './city_bounds.ts';
import { citiesInBounds, contains, parseBounds } from './viewport.ts';

Deno.test('viewport crossing a city border selects both endpoints', () => {
  const b = parseBounds({
    south: 25.00,
    west: 121.49,
    north: 25.02,
    east: 121.52,
  })!;
  const selected = citiesInBounds(b);
  assert(selected.includes('Taipei'));
  assert(selected.includes('NewTaipei'));
  assert(!selected.includes('Kaohsiung'));
  assertEquals(Object.keys(cityBounds).sort(), [...cities].sort());
});
Deno.test('viewport rejects broad, reversed, nonfinite and nonnumeric coordinates', () => {
  for (
    const b of [
      null,
      [],
      { south: 20, west: 118, north: 27, east: 123 },
      { south: 25, west: 121.5, north: 24, east: 121.6 },
      { south: '25', west: 121.5, north: 25.1, east: 121.6 },
      { south: NaN, west: 121.5, north: 25.1, east: 121.6 },
    ]
  ) assertEquals(parseBounds(b), null);
});
Deno.test('candidate cities do not include distant endpoints; exact bounds filter their spots', () => {
  const b = { south: 25.03, west: 121.55, north: 25.04, east: 121.57 };
  assert(contains(b, { lat: 25.035, lng: 121.56 }));
  assert(!contains(b, { lat: 25.035, lng: 121.58 }));
  assertEquals(
    citiesInBounds({ south: 35, west: 139, north: 35.1, east: 139.1 }),
    [],
  );
});

function assert(value: unknown) {
  if (!value) throw new Error('assertion failed');
}
function assertEquals(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
