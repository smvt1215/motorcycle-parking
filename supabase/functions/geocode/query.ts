// Provider-independent half of the `geocode` function (docs/ADMIN_WEB.md
// 「位置選擇」): what a rider typed becomes a query a provider understands,
// and what the provider found becomes the candidates both clients show.

export type CandidateKind = 'address' | 'road' | 'intersection' | 'area';
// How close the point is to what was asked for: an exact door, a door
// interpolated along the street, the centre of a street or area, or a guess.
export type Precision = 'exact' | 'interpolated' | 'center' | 'approximate';

export interface Candidate {
  kind: CandidateKind;
  // Text for the list, and what an address or road field receives.
  label: string;
  // County and district, when [label] (a road or crossing) lacks them.
  place?: string;
  lat: number;
  lng: number;
  precision: Precision;
}

export type ParsedQuery =
  | { kind: 'intersection'; text: string; roads: [string, string] }
  | { kind: 'text'; text: string };

export interface LatLng {
  lat: number;
  lng: number;
}

export const minQuery = 2, maxQuery = 100, maxCandidates = 5;

// A road name ends in one of these, optionally followed by a section
// (「一段」「4段」); 「巷」「弄」 count, since small intersections are lanes.
const roadEnd = /(路|街|大道|道|巷|弄|線)([0-9一二三四五六七八九十]+段)?$/;
// Separators that cannot be part of a road name. 「和」 is left out because
// it starts 和平東路; a space only counts between two road names.
const joiner = /\s*(?:&|與|\/|＆)\s*/;

// Full-width digits and symbols to half-width, then single spaces.
export function normalize(input: string): string {
  return input.normalize('NFKC').replace(/\s+/g, ' ').trim();
}

// 「敦化南路口」 and 「敦化南路路口」 name the road, not a lane called 口.
const stripCorner = (road: string) =>
  road.replace(/(?<=路|街|道|段)路?口$/, '');

export function parseQuery(input: string): ParsedQuery {
  const text = normalize(input);
  const pair = (a: string, b: string): ParsedQuery | null => {
    const roads = [stripCorner(a.trim()), stripCorner(b.trim())];
    if (roads.some((r) => !r || r.includes('號'))) return null;
    return {
      kind: 'intersection',
      roads: [roads[0], roads[1]],
      text: `${roads[0]} & ${roads[1]}`,
    };
  };
  const joined = text.split(joiner);
  if (joined.length === 2) {
    return pair(joined[0], joined[1]) ?? { kind: 'text', text };
  }
  const words = text.split(' ');
  if (
    words.length === 2 &&
    words.every((w) => roadEnd.test(stripCorner(w)))
  ) {
    return pair(words[0], words[1]) ?? { kind: 'text', text };
  }
  return { kind: 'text', text };
}

// Cache entries are shared between riders, so the key holds only what the
// provider saw: the query and the bias point rounded to about 5 km.
export function cacheKey(q: ParsedQuery, near?: LatLng): string {
  const bias = near
    ? `${(Math.round(near.lat * 20) / 20).toFixed(2)},${
      (Math.round(near.lng * 20) / 20).toFixed(2)
    }`
    : '-';
  return `${q.kind}|${q.text}|${bias}`;
}

// The spot tables accept latitude 20–27 and longitude 118–123.
const inTaiwan = (c: Candidate) =>
  c.lat >= 20 && c.lat <= 27 && c.lng >= 118 && c.lng <= 123;

// Keeps what the forms can store, drops the same point listed twice, and
// lists at most [maxCandidates].
export function shape(found: Candidate[]): Candidate[] {
  const seen = new Set<string>();
  const out: Candidate[] = [];
  for (const c of found) {
    if (!Number.isFinite(c.lat) || !Number.isFinite(c.lng) || !inTaiwan(c)) {
      continue;
    }
    const label = c.label.trim().slice(0, 200);
    if (!label) continue;
    const key = `${label}|${c.lat.toFixed(5)}|${c.lng.toFixed(5)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ ...c, label });
    if (out.length === maxCandidates) break;
  }
  return out;
}

export interface Request {
  query: ParsedQuery;
  near?: LatLng;
}

// Error codes are stable for both clients; see lib/core/address_search.dart.
export function readRequest(body: Record<string, unknown>): Request | string {
  const raw = body.query;
  if (typeof raw !== 'string') return 'invalid_query';
  const text = normalize(raw);
  if (text.length < minQuery || text.length > maxQuery) return 'invalid_query';
  let near: LatLng | undefined;
  if (body.near !== undefined && body.near !== null) {
    const n = body.near as Record<string, unknown>;
    if (
      typeof n !== 'object' || Array.isArray(n) ||
      typeof n.lat !== 'number' || typeof n.lng !== 'number' ||
      !Number.isFinite(n.lat) || !Number.isFinite(n.lng) ||
      Math.abs(n.lat) > 90 || Math.abs(n.lng) > 180
    ) {
      return 'invalid_query';
    }
    near = { lat: n.lat, lng: n.lng };
  }
  return { query: parseQuery(text), near };
}

// What a provider throws: the service refused for quota, or is unreachable.
export class ProviderError extends Error {
  constructor(readonly reason: 'quota' | 'unavailable') {
    super(reason);
  }
}

export type Provider = (q: ParsedQuery, near?: LatLng) => Promise<Candidate[]>;
