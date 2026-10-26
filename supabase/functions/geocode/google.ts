// Google Geocoding API (docs/ADMIN_WEB.md 後端變更 7, chosen 2026-10-25).
// Results are shown only on Google maps (Service Specific Terms 6.2), and
// the shared cache keeps them at most 30 days (6.3.1, see the migration).
import {
  type Candidate,
  type CandidateKind,
  type LatLng,
  type ParsedQuery,
  type Precision,
  type Provider,
  ProviderError,
} from './query.ts';

interface Component {
  long_name: string;
  types: string[];
}
interface Result {
  formatted_address?: string;
  types?: string[];
  address_components?: Component[];
  geometry?: { location?: LatLng; location_type?: string };
}

const precisions: Record<string, Precision> = {
  ROOFTOP: 'exact',
  RANGE_INTERPOLATED: 'interpolated',
  GEOMETRIC_CENTER: 'center',
  APPROXIMATE: 'approximate',
};

function kindOf(types: string[]): CandidateKind {
  if (types.includes('intersection')) return 'intersection';
  if (
    types.some((t) => ['street_address', 'premise', 'subpremise'].includes(t))
  ) {
    return 'address';
  }
  if (types.includes('route')) return 'road';
  return 'area';
}

// The spot tables and the county lookup write 臺, not 台.
const official = (s: string) => s.replace(/台(?=北|中|南|東|灣)/g, '臺');

// 「臺北市」「中山區」 from the components, largest first.
function placesOf(components: Component[]): string[] {
  const names: string[] = [];
  for (const c of [...components].reverse()) {
    const admin = c.types.some((t) =>
      t.startsWith('administrative_area_level_') || t === 'locality'
    );
    const name = official(c.long_name);
    if (admin && /[市縣區鄉鎮]$/.test(name) && !names.includes(name)) {
      names.push(name);
    }
  }
  return names;
}

// Measured 2026-10-25: road and crossing names often come back in English
// even with language=zh-TW, so their labels use what the rider typed.
const latin = /[A-Za-z]/;
// The 22 counties and cities; districts are only trusted when the result's
// components name them, so a road such as 鎮中路 keeps its first character.
const counties = [
  '臺北市',
  '新北市',
  '桃園市',
  '臺中市',
  '臺南市',
  '高雄市',
  '基隆市',
  '新竹市',
  '嘉義市',
  '新竹縣',
  '苗栗縣',
  '彰化縣',
  '南投縣',
  '雲林縣',
  '嘉義縣',
  '屏東縣',
  '宜蘭縣',
  '花蓮縣',
  '臺東縣',
  '澎湖縣',
  '金門縣',
  '連江縣',
];
// What was typed, without the county and district at its start: only
// names in [counties] or [known] are removed.
function withoutPlace(s: string, known: string[]): string {
  let rest = official(s.trim());
  for (let changed = true; changed;) {
    changed = false;
    for (const name of [...counties, ...known]) {
      if (rest.startsWith(name) && rest.length > name.length) {
        rest = rest.slice(name.length).trimStart();
        changed = true;
      }
    }
  }
  return rest;
}
// The county typed at the start, as the place of a result that names none.
const typedCounty = (s: string) =>
  counties.find((c) => official(s.trim()).startsWith(c)) ?? '';
// Asked for two roads that never meet, Google answers with a lane off one
// of them; that is not the crossing the rider asked for.
const strayLane = (name: string, q: ParsedQuery) =>
  latin.test(name) && /\b(Lane|Alley)\b/i.test(name) && !/[巷弄]/.test(q.text);

// 「臺北市中正區忠孝西路一段49號」: county, district, road and number, without
// the village Google adds (黎明里), as addresses in the spot tables read.
function addressOf(r: Result, components: Component[]): string {
  const named = (type: string) =>
    components.find((c) => c.types.includes(type))?.long_name ?? '';
  const route = named('route'), number = named('street_number');
  if (route && number && !latin.test(route + number)) {
    return official(
      named('administrative_area_level_1') +
        named('administrative_area_level_2') + route +
        (number.endsWith('號') ? number : `${number}號`),
    );
  }
  return official(r.formatted_address ?? '').replace(
    /^(臺灣)?\s*\d{3,6}\s*/,
    '',
  )
    .replace(/^臺灣\s*/, '').trim();
}

export function toCandidate(r: Result, q: ParsedQuery): Candidate | null {
  const at = r.geometry?.location;
  if (!at) return null;
  const components = r.address_components ?? [];
  const kind = kindOf(r.types ?? []);
  const named = (type: string) =>
    components.find((c) => c.types.includes(type))?.long_name;
  const places = placesOf(components);
  let label: string;
  switch (kind) {
    case 'intersection': {
      const roads = components.filter((c) => c.types.includes('route'))
        .map((c) => c.long_name);
      const name = named('intersection') ?? roads.slice(0, 2).join(' & ');
      if (strayLane(name, q)) return null;
      label = q.kind === 'intersection'
        ? q.roads.map((r) => withoutPlace(r, places)).join('與')
        : name.replace(/\s*&\s*/g, '與');
      break;
    }
    case 'road': {
      const name = named('route') ?? '';
      if (strayLane(name, q)) return null;
      // Which of two typed roads an English name is cannot be told.
      // Nor can an English name for a door that was not found: the typed
      // 「…99號」 must not become a road name.
      if (
        (latin.test(name) || !name) &&
        (q.kind === 'intersection' || /\d+號/.test(q.text))
      ) return null;
      label = latin.test(name) || !name ? withoutPlace(q.text, places) : name;
      break;
    }
    default:
      label = addressOf(r, components);
  }
  label = official(label);
  if (!label) return null;
  const place = places.join('') || typedCounty(q.text);
  return {
    kind,
    label,
    ...(place && kind !== 'address' && !label.startsWith(place)
      ? { place }
      : {}),
    lat: at.lat,
    lng: at.lng,
    precision: precisions[r.geometry?.location_type ?? ''] ?? 'approximate',
  };
}

export function googleProvider(
  key: string,
  fetcher: typeof fetch = fetch,
): Provider {
  return async (q, near) => {
    const params = new URLSearchParams({
      address: q.text,
      language: 'zh-TW',
      region: 'tw',
      components: 'country:TW',
      key,
    });
    // Prefer about 10 km around where the map is; not a hard limit.
    if (near) {
      params.set(
        'bounds',
        `${near.lat - 0.1},${near.lng - 0.1}|${near.lat + 0.1},${
          near.lng + 0.1
        }`,
      );
    }
    let body: { status?: string; results?: Result[] };
    try {
      // The URL holds the key; it never reaches a log or an error message.
      const res = await fetcher(
        `https://maps.googleapis.com/maps/api/geocode/json?${params}`,
        { signal: AbortSignal.timeout(8000) },
      );
      if (!res.ok) throw new ProviderError('unavailable');
      body = await res.json();
    } catch (e) {
      if (e instanceof ProviderError) throw e;
      throw new ProviderError('unavailable');
    }
    switch (body.status) {
      case 'OK':
        return (body.results ?? []).map((r) => toCandidate(r, q))
          .filter((c): c is Candidate => c !== null);
      case 'ZERO_RESULTS':
        return [];
      case 'OVER_QUERY_LIMIT':
      case 'OVER_DAILY_LIMIT':
        throw new ProviderError('quota');
      default:
        throw new ProviderError('unavailable');
    }
  };
}
