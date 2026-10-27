// Taipei parking office feeds (availability-coverage.md §4.2):
// TCMSV_allavailable.xml (V2) for the counts, TCMSV_alldesc.json for the
// capacities. Values pass through as the source sent them, codes such as
// -9 included; the database decides what they mean
// (availability_classify), so the rules live in one place.

/** One lot's raw counts; null where the tag is missing or not an integer. */
export type ParkCounts = {
  id: string;
  scooter: number | null;
  heavy: number | null;
  car: number | null;
};

/** One lot's capacities from the description file. */
export type ParkCapacity = ParkCounts;

const months: Record<string, number> = {
  Jan: 0,
  Feb: 1,
  Mar: 2,
  Apr: 3,
  May: 4,
  Jun: 5,
  Jul: 6,
  Aug: 7,
  Sep: 8,
  Oct: 9,
  Nov: 10,
  Dec: 11,
};

/**
 * 'Mon Oct 26 16:20:00 CST 2026' — CST here is Taiwan time (UTC+8), not US
 * Central — as a UTC instant; null when it does not read as one.
 */
export function parseTaipeiTime(text: string | null | undefined): Date | null {
  const m =
    /^\s*[A-Z][a-z]{2} ([A-Z][a-z]{2}) (\d{1,2}) (\d{2}):(\d{2}):(\d{2}) CST (\d{4})\s*$/
      .exec(text ?? '');
  if (!m) return null;
  const month = months[m[1]];
  const [day, hour, minute, second, year] = [m[2], m[3], m[4], m[5], m[6]]
    .map(Number);
  if (
    month === undefined || day < 1 || day > 31 || hour > 23 || minute > 59 ||
    second > 59
  ) {
    return null;
  }
  const utc = Date.UTC(year, month, day, hour - 8, minute, second);
  const check = new Date(utc + 8 * 3600_000);
  // Reject 31 Feb and the like instead of rolling over.
  if (check.getUTCDate() !== day || check.getUTCMonth() !== month) return null;
  return new Date(utc);
}

/** An integer as written, or null. */
export function rawInt(text: string | null | undefined): number | null {
  if (text == null) return null;
  const t = text.trim();
  if (!/^-?\d{1,6}$/.test(t)) return null;
  return Number(t);
}

function tag(block: string, name: string): string | null {
  const m = new RegExp(`<${name}>([^<]*)</${name}>`).exec(block);
  return m ? m[1] : null;
}

/**
 * The XML's header time and lots. The file is flat (DATA > UPDATETIME,
 * PARK*), so a scan for the PARK blocks reads it without a DOM; nested
 * charging-station lists inside a PARK are ignored.
 */
export function parseTaipeiAvailability(
  xml: string,
): { updatedAt: Date | null; parks: ParkCounts[] } {
  const text = xml.replace(/^﻿/, '');
  if (!/<DATA>/.test(text)) throw new Error('not a TCMSV availability file');
  const head = text.split('<PARK>', 1)[0];
  const updatedAt = parseTaipeiTime(tag(head, 'UPDATETIME'));
  const parks: ParkCounts[] = [];
  for (const m of text.matchAll(/<PARK>([\s\S]*?)<\/PARK>/g)) {
    const id = tag(m[1], 'ID')?.trim();
    if (!id || id.length > 100) continue;
    parks.push({
      id,
      scooter: rawInt(tag(m[1], 'AVAILABLEMOTOR')),
      heavy: rawInt(tag(m[1], 'AVAILABLEHEAVYMOTOR')),
      car: rawInt(tag(m[1], 'AVAILABLECAR')),
    });
  }
  return { updatedAt, parks };
}

function count(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isInteger(value) && value >= 0 ? value : null;
  }
  if (typeof value === 'string') {
    const n = rawInt(value);
    return n !== null && n >= 0 ? n : null;
  }
  return null;
}

/**
 * Capacities from TCMSV_alldesc.json. totallargemotor arrives as a string
 * ("3"), the others as numbers; anything that is not a non-negative
 * integer is unknown.
 */
export function parseTaipeiCapacities(json: string): ParkCapacity[] {
  const data = JSON.parse(json.replace(/^﻿/, ''));
  const parks = data?.data?.park;
  if (!Array.isArray(parks)) throw new Error('not a TCMSV description file');
  const out: ParkCapacity[] = [];
  for (const p of parks) {
    const id = typeof p?.id === 'string' ? p.id.trim() : '';
    if (!id || id.length > 100) continue;
    out.push({
      id,
      scooter: count(p.totalmotor),
      heavy: count(p.totallargemotor),
      car: count(p.totalcar),
    });
  }
  return out;
}
