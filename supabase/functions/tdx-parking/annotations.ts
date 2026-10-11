import type { Spot } from './normalize.ts';
export interface Annotation {
  source_id: string;
  heavy_access: 'allowed' | 'denied' | 'car_space';
}
const effects = {
  allowed: [true, '社群回報經審核：大型重機可停'],
  denied: [false, '社群回報經審核：大型重機不可停'],
  car_space: [true, '社群回報經審核：大型重機須停汽車格'],
} as const;
/** Applies moderator-confirmed annotations; TDX has no heavy-motorcycle field. */
export function applyAnnotations(
  spots: Spot[],
  annotations: Annotation[],
): Spot[] {
  const byId = new Map(annotations.map((a) => [a.source_id, a.heavy_access]));
  return spots.map((spot) => {
    const access = byId.get(spot.id);
    if (!access || !(access in effects)) return spot;
    const [heavy, note] = effects[access];
    return {
      ...spot,
      heavy_allowed: heavy,
      note: [spot.note, note].filter(Boolean).join('；'),
    };
  });
}
