import { cors, readBody, response } from '../_shared/http.ts';
import { cities, fetchRows, type Row } from '../_shared/tdx.ts';
import { normalize, type Spot } from './normalize.ts';
import { citiesInBounds, contains, parseBounds } from '../_shared/viewport.ts';
const cache = new Map<string, { expires: number; spots: Spot[] }>();
const basic = new Map<
  string,
  { expires: number; parks: Row[]; spaces: Row[] }
>();
const pending = new Map<string, Promise<Spot[]>>();
export async function parking(city: string): Promise<Spot[]> {
  if (Deno.env.get('TDX_MODE') === 'fixture') {
    if (city !== 'Taipei') return [];
    const j = JSON.parse(
      await Deno.readTextFile(
        new URL('./fixtures/taipei.json', import.meta.url),
      ),
    );
    return normalize(
      city,
      j.parks,
      j.spaces,
      j.availability,
      false,
      Date.parse(j.as_of),
    );
  }
  const prior = cache.get(city);
  if (prior && prior.expires > Date.now()) return prior.spots;
  const flight = pending.get(city);
  if (flight) return flight;
  const work = (async () => {
    let staticData = basic.get(city);
    if (!staticData || staticData.expires < Date.now()) {
      const [parks, spaces] = await Promise.all([
        fetchRows(city, 'OffStreet/CarPark'),
        fetchRows(city, 'OffStreet/ParkingSpace'),
      ]);
      staticData = { parks, spaces, expires: Date.now() + 3_600_000 };
      basic.set(city, staticData);
    }
    const availability = await fetchRows(city, 'OffStreet/ParkingAvailability');
    const spots = normalize(
      city,
      staticData.parks,
      staticData.spaces,
      availability,
    );
    cache.set(city, { expires: Date.now() + 120_000, spots });
    return spots;
  })();
  pending.set(city, work);
  try {
    return await work;
  } finally {
    pending.delete(city);
  }
}
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') {
    return response({ error: 'method not allowed' }, 405);
  }
  try {
    const body = await readBody(req);
    if ('bounds' in body) {
      const bounds = parseBounds(body.bounds);
      if (!bounds) return response({ error: 'invalid viewport bounds' }, 400);
      const selected = citiesInBounds(bounds);
      const results = await Promise.allSettled(selected.map(parking));
      const failed = results.filter((r) => r.status === 'rejected').length;
      if (selected.length > 0 && failed === selected.length) {
        return response({ error: 'TDX unavailable' }, 502);
      }
      const spots = results.flatMap((r) =>
        r.status === 'fulfilled' ? r.value : []
      )
        .filter((s) => contains(bounds, s));
      return response({
        spots: spots.slice(0, 500),
        truncated: spots.length > 500,
        partial: failed > 0,
        fixture: Deno.env.get('TDX_MODE') === 'fixture',
      });
    }
    const city = body.city;
    if (
      typeof city !== 'string' ||
      !cities.includes(city as typeof cities[number])
    ) return response({ error: 'unsupported city' }, 400);
    return response({
      spots: await parking(city),
      fixture: Deno.env.get('TDX_MODE') === 'fixture',
    });
  } catch {
    return response({
      error: 'TDX unavailable; verify credentials and upstream connectivity',
    }, 502);
  }
});
