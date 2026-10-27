/**
 * A rider's on-site sighting (#154): what the app sends to submit-sighting.
 * Only the spot is sent, never where the rider is.
 */
export interface Sighting {
  spot_id: string;
  kind: 'available' | 'full' | 'closed';
  vehicle: 'scooter' | 'heavy';
  device_id: string;
}

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
/** The app's spot ids: official spots and community spots. */
const spotId = new RegExp(`^(official:)?${uuid}$`, 'i');
const deviceId = new RegExp(`^${uuid}$`, 'i');
const kinds = new Set(['available', 'full', 'closed']);
const vehicles = new Set(['scooter', 'heavy']);
const keys = new Set(['spot_id', 'kind', 'vehicle', 'device_id']);

/** The sighting, or why it is refused. */
export function validate(body: Record<string, unknown>): Sighting | string {
  const extra = Object.keys(body).find((k) => !keys.has(k));
  if (extra) return `unknown field ${extra}`;
  const { spot_id, kind, vehicle, device_id } = body;
  if (typeof spot_id !== 'string' || !spotId.test(spot_id)) {
    return 'invalid spot';
  }
  if (typeof kind !== 'string' || !kinds.has(kind)) return 'invalid kind';
  if (typeof vehicle !== 'string' || !vehicles.has(vehicle)) {
    return 'invalid vehicle';
  }
  if (typeof device_id !== 'string' || !deviceId.test(device_id)) {
    return 'invalid device';
  }
  return {
    spot_id,
    kind: kind as Sighting['kind'],
    vehicle: vehicle as Sighting['vehicle'],
    device_id,
  };
}
