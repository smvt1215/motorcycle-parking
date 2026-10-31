/**
 * A rider's on-site sighting (#154, #189): what the app sends to
 * submit-sighting. Only the spot, and the zone or segment of it, is sent,
 * never where the rider is.
 */
export interface Sighting {
  spot_id: string;
  /** A level of the scale, or closed (the whole spot). */
  kind: 'level' | 'closed';
  /** 0 很多空位, 1 還有一些, 2 快滿了, 3 已停滿; null when closed. */
  level: 0 | 1 | 2 | 3 | null;
  /** The zone (off-street) or segment (roadside) seen, by its id (#188). */
  zone_id: string | null;
  segment_id: string | null;
  vehicle: 'scooter' | 'heavy';
  device_id: string;
}

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
/** The app's spot ids: official spots and community spots. */
const spotId = new RegExp(`^(official:)?${uuid}$`, 'i');
const deviceId = new RegExp(`^${uuid}$`, 'i');
/** A zone's or segment's id (parking_contract.json zone.id_pattern). */
const entryId = /^[a-z0-9_-]{1,32}$/;
const kinds = new Set(['level', 'closed']);
const vehicles = new Set(['scooter', 'heavy']);
const keys = new Set([
  'spot_id',
  'kind',
  'level',
  'zone_id',
  'segment_id',
  'vehicle',
  'device_id',
]);

function optionalId(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  return typeof value === 'string' && entryId.test(value) ? value : undefined;
}

/** The sighting, or why it is refused. */
export function validate(body: Record<string, unknown>): Sighting | string {
  const extra = Object.keys(body).find((k) => !keys.has(k));
  if (extra) return `unknown field ${extra}`;
  const { spot_id, kind, level, vehicle, device_id } = body;
  if (typeof spot_id !== 'string' || !spotId.test(spot_id)) {
    return 'invalid spot';
  }
  if (typeof kind !== 'string' || !kinds.has(kind)) return 'invalid kind';
  const zone_id = optionalId(body.zone_id);
  const segment_id = optionalId(body.segment_id);
  if (zone_id === undefined || segment_id === undefined) return 'invalid area';
  if (zone_id !== null && segment_id !== null) return 'invalid area';
  if (kind === 'level') {
    if (typeof level !== 'number' || ![0, 1, 2, 3].includes(level)) {
      return 'invalid level';
    }
  } else {
    // Closed is the whole spot: no level, no zone or segment.
    if (level !== undefined && level !== null) return 'invalid level';
    if (zone_id !== null || segment_id !== null) return 'invalid area';
  }
  if (typeof vehicle !== 'string' || !vehicles.has(vehicle)) {
    return 'invalid vehicle';
  }
  if (typeof device_id !== 'string' || !deviceId.test(device_id)) {
    return 'invalid device';
  }
  return {
    spot_id,
    kind: kind as Sighting['kind'],
    level: kind === 'level' ? (level as Sighting['level']) : null,
    zone_id,
    segment_id,
    vehicle: vehicle as Sighting['vehicle'],
    device_id,
  };
}
