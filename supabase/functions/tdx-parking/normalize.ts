import { cityNames, type Row } from '../_shared/tdx.ts';
export interface Spot {
  id: string;
  name: string;
  lat: number;
  lng: number;
  city: string;
  source: 'tdx';
  space_type: 'offStreet' | 'paidMotorcycle';
  fee_note: string;
  scooter_total: number | null;
  available: number | null;
  heavy_allowed: null;
  scooter_allowed: boolean;
  status: 'confirmed';
  updated_at: string | null;
  note: string;
}
const obj = (v: unknown): Row =>
  v && typeof v === 'object' && !Array.isArray(v) ? v as Row : {};
const list = (v: unknown): Row[] =>
  Array.isArray(v) ? v.filter((x) => x && typeof x === 'object') as Row[] : [];
export function count(v: unknown): number | null {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : null;
}
function motorcycle(row: Row): Row | undefined {
  return list(row.Spaces).find((s) => Number(s.SpaceType) === 2);
}
function time(row: Row): string | null {
  const raw = row.DataCollectTime ?? row.UpdateTime;
  return typeof raw === 'string' && Number.isFinite(Date.parse(raw))
    ? raw
    : null;
}
export function validPosition(lat: unknown, lng: unknown): boolean {
  return typeof lat === 'number' && typeof lng === 'number' &&
    Number.isFinite(lat) && Number.isFinite(lng) && lat >= 20 && lat <= 27 &&
    lng >= 118 && lng <= 123;
}
export function normalize(
  city: string,
  parks: Row[],
  spaces: Row[],
  availability: Row[],
  onStreet = false,
  now = Date.now(),
): Spot[] {
  const key = onStreet ? 'ParkingSegmentID' : 'CarParkID';
  const totals = new Map(spaces.map((r) => [String(r[key]), r]));
  const live = new Map(availability.map((r) => [String(r[key]), r]));
  const output: Spot[] = [];
  for (const park of parks) {
    const id = String(park[key] ?? '');
    if (!id) continue;
    const position = obj(
      park.CarParkPosition ?? park.ParkingSegmentPosition ?? park.Position,
    );
    const lat = position.PositionLat, lng = position.PositionLon;
    if (!validPosition(lat, lng)) continue;
    const space = motorcycle(totals.get(id) ?? park);
    const total = count(space?.NumberOfSpaces);
    const current = live.get(id) ?? {};
    const moto = motorcycle(current);
    if (total === null && !moto) continue; // Never substitute car totals or car availability.
    const updated = time(current);
    const fresh = updated !== null && now - Date.parse(updated) <= 5 * 60_000 &&
      Date.parse(updated) <= now + 60_000;
    const label = obj(park.CarParkName ?? park.ParkingSegmentName).Zh_tw;
    output.push({
      id: `tdx:${city}:${onStreet ? 'segment' : 'park'}:${id}`,
      name: typeof label === 'string' ? label : id,
      lat: lat as number,
      lng: lng as number,
      city: cityNames[city] ?? city,
      source: 'tdx',
      space_type: onStreet ? 'paidMotorcycle' : 'offStreet',
      fee_note: String(park.FareDescription ?? '請依現場公告'),
      scooter_total: total,
      available: fresh ? count(moto?.AvailableSpaces) : null,
      heavy_allowed: null,
      scooter_allowed: true,
      status: 'confirmed',
      updated_at: updated ?? time(park),
      note: fresh ? '' : '即時資料缺漏或超過 5 分鐘，不顯示剩餘格數',
    });
  }
  return output;
}
