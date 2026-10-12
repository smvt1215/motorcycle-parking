import { cityBounds } from './city_bounds.ts';

export type Bounds = {
  south: number;
  west: number;
  north: number;
  east: number;
};
export function parseBounds(value: unknown): Bounds | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const b = value as Bounds;
  if (
    ![b.south, b.west, b.north, b.east].every((n) =>
      typeof n === 'number' && Number.isFinite(n)
    )
  ) return null;
  if (
    b.south < -90 || b.north > 90 || b.west < -180 || b.east > 180 ||
    b.north <= b.south || b.east <= b.west || b.north - b.south > .5 ||
    b.east - b.west > .5
  ) return null;
  return { south: b.south, west: b.west, north: b.north, east: b.east };
}
export function citiesInBounds(b: Bounds): string[] {
  return Object.entries(cityBounds).filter(([, [south, west, north, east]]) =>
    b.north >= south && b.south <= north && b.east >= west && b.west <= east
  ).map(([city]) => city);
}
export function contains(
  b: Bounds,
  spot: { lat: number; lng: number },
): boolean {
  return spot.lat >= b.south && spot.lat <= b.north && spot.lng >= b.west &&
    spot.lng <= b.east;
}
