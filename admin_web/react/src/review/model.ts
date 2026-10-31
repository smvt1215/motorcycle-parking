import type { PlateStatus } from '../ui/eligibility';

/**
 * A row of `moderation_queue` as the Flutter admin loads it
 * (lib/admin/admin_gateway.dart, lib/admin/review/review_models.dart
 * ReviewReport). Field names stay snake_case where they are wire values.
 */
export interface ReviewReport {
  id: string;
  /** Community spot uuid, or `official:<uuid>` for an official spot. */
  sourceId: string;
  /** Readable summary; the only content of reports from older app builds. */
  reason: string;
  /** Stable suggestion key (name, eligibility, location, gone…), or an older label. */
  field: string | null;
  proposed: Record<string, unknown> | null;
  note: string;
  /** ISO timestamp. */
  createdAt: string;
  /** The spot as the rider saw it; null for reports queued before versions. */
  baseSpot: Record<string, unknown> | null;
  risk: 'low' | 'medium' | 'high' | null;
  riskFlags: string[];
  evidenceUrl: string | null;
}

/** The reported spot's current values (`admin_spot_rows`). */
export interface ReviewSpot {
  sourceId: string;
  official: boolean;
  values: Record<string, unknown>;
}

export interface ReviewQueue {
  reports: ReviewReport[];
  /** Keyed by source id; a missing key means the spot was not found. */
  spots: Record<string, ReviewSpot>;
}

/** Queue filters on the canvas (Main.dc.html): 停放資格／點位資訊／位置／已不存在. */
export const REVIEW_KINDS = ['access', 'info', 'location', 'gone'] as const;
export type ReviewKind = (typeof REVIEW_KINDS)[number];

export const KIND_LABEL: Record<ReviewKind, string> = {
  access: '停放資格',
  info: '點位資訊',
  location: '位置',
  gone: '已不存在',
};

/** Votes hide a community spot themselves and queue this reason. */
export const AUTO_HIDDEN_REASON = '加權負向回報達門檻';

/** Stable `field` keys the app sends (review_models.dart suggestionFieldLabels). */
export const SUGGESTION_LABEL: Record<string, string> = {
  name: '停車點名稱',
  space_type: '格位類型',
  fee_note: '收費資訊',
  eligibility: '機車停放資格',
  guide: '入口與停車指引',
  note: '其他備註',
  location: '位置不正確',
  gone: '點位已不存在',
  reopened: '暫時封閉已恢復',
  zones: '分區',
  segments: '路邊分段',
};

const LEGACY_FIELD_LABEL: Record<string, string> = { 位置或其他備註: 'note' };

/** The key for `field`, whether it arrived as a key or as an older label. */
export function suggestionKey(field: string | null | undefined): string | null {
  if (!field) return null;
  if (field in SUGGESTION_LABEL) return field;
  if (field in LEGACY_FIELD_LABEL) return LEGACY_FIELD_LABEL[field]!;
  return Object.entries(SUGGESTION_LABEL).find(([, label]) => label === field)?.[0] ?? null;
}

/** What builds before structured fields wrote before 「：」 in the reason. */
function reasonPrefix(reason: string): string | null {
  const cut = reason.indexOf('：');
  return cut > 0 && cut <= 12 ? reason.slice(0, cut) : null;
}

export const isOfficial = (sourceId: string) => sourceId.startsWith('official:');

export function reportKind(report: ReviewReport): ReviewKind {
  const proposed = report.proposed ?? {};
  const key = suggestionKey(report.field ?? reasonPrefix(report.reason));
  if (
    key === 'gone' ||
    report.reason === AUTO_HIDDEN_REASON ||
    proposed.status === 'hidden' ||
    proposed.hidden === true
  ) {
    return 'gone';
  }
  if (key === 'eligibility' || 'scooter_allowed' in proposed || 'heavy_allowed' in proposed) {
    return 'access';
  }
  if (key === 'location' || 'lat' in proposed || 'lng' in proposed) return 'location';
  return 'info';
}

/** The rider's own words (review_models.dart riderText). */
export function riderText(report: ReviewReport): string | null {
  if (report.proposed === null || reportKind(report) === 'gone') return report.reason || null;
  return report.note.trim() || null;
}

/** Stored eligibility → plate. Null is legacy 「未確認」, read but never written. */
export function plateOf(value: unknown): PlateStatus {
  if (value === true) return 'allowed';
  if (value === false) return 'denied';
  return 'legacyUnknown';
}

export const SPACE_TYPE_LABEL: Record<string, string> = {
  paidMotorcycle: '路邊收費機車格',
  freeMotorcycle: '免費機車格',
  heavyOnly: '重機專用格',
  car: '汽車格',
  offStreet: '路外停車場',
  disabledMotorcycle: '身障機車專用格',
  timedMotorcycle: '限時停車機車格',
  flexShared: '汽機車彈性共用格',
  evMotorcycle: '電動機車充換電格',
};

export const FACILITY_LABEL: Record<string, string> = {
  multiStorey: '立體停車場',
  underground: '地下停車場',
  surface: '路外平面停車場',
  roadside: '路邊停車格',
};

export const ACCESS_LABEL: Record<string, string> = {
  scooterOnly: '普機專用',
  scooterHeavy: '普大共用',
  heavyCar: '大汽共用',
  noMotorcycle: '機車不可停',
  heavyOnly: '大重專用',
};

type Formatter = (value: unknown) => string;

const text: Formatter = (v) => (typeof v === 'string' && v.trim() ? v : '沒有');
const choice =
  (labels: Record<string, string>): Formatter =>
  (v) =>
    typeof v === 'string' ? (labels[v] ?? v) : '沒有';
const coordinate: Formatter = (v) => (typeof v === 'number' ? v.toFixed(6) : '沒有');
const count =
  (unit: string): Formatter =>
  (v) =>
    Array.isArray(v) ? `${v.length} ${unit}` : '沒有';
const present: Formatter = (v) => (v === null || v === undefined ? '沒有' : '已設定');

/**
 * Spot columns `admin_resolve_report` may change, in diff order
 * (review_models.dart reviewFields). Eligibility is drawn as plates, not here.
 * Structured values (fee, condition, closure, zones) are summarised; their
 * full editors come with 「修改後套用」.
 */
export const DIFF_FIELDS: readonly { key: string; label: string; format: Formatter }[] = [
  { key: 'name', label: '停車點名稱', format: text },
  { key: 'space_type', label: '格位類型', format: choice(SPACE_TYPE_LABEL) },
  { key: 'facility_type', label: '場站類型', format: choice(FACILITY_LABEL) },
  {
    key: 'facility_types',
    label: '場站類型（複選）',
    format: (v) => (Array.isArray(v) && v.length ? v.map((t) => FACILITY_LABEL[t] ?? t).join('、') : '沒有'),
  },
  { key: 'parking_access', label: '車種開放', format: choice(ACCESS_LABEL) },
  { key: 'condition', label: '停放條件', format: present },
  { key: 'fee', label: '費率', format: present },
  { key: 'fee_note', label: '收費資訊', format: text },
  { key: 'note', label: '備註', format: text },
  { key: 'entrance_note', label: '入口說明', format: text },
  { key: 'parking_guide', label: '停放方式', format: text },
  { key: 'status', label: '地圖顯示', format: (v) => (v === 'hidden' ? '隱藏' : '顯示') },
  { key: 'hidden', label: '地圖顯示', format: (v) => (v === true ? '隱藏' : '顯示') },
  { key: 'lat', label: '緯度', format: coordinate },
  { key: 'lng', label: '經度', format: coordinate },
  { key: 'city', label: '縣市', format: text },
  { key: 'district', label: '行政區', format: text },
  { key: 'closure', label: '暫時無法停車', format: present },
  { key: 'parking_zones', label: '分區', format: count('個分區') },
  { key: 'parking_segments', label: '路邊分段', format: count('段') },
];

export const ELIGIBILITY_KEYS = ['scooter_allowed', 'heavy_allowed'] as const;

export interface DiffRow {
  key: string;
  label: string;
  current: string;
  proposed: string;
  changed: boolean;
}

const same = (a: unknown, b: unknown) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

/**
 * Field / current / proposed rows. Rows the rider did not touch carry the
 * current value on both sides and `changed: false`; the page folds them away.
 */
export function diffRows(report: ReviewReport, spot: ReviewSpot | undefined): DiffRow[] {
  const proposed = report.proposed ?? {};
  const current = spot?.values ?? {};
  return DIFF_FIELDS.filter(({ key }) => {
    // Community spots hide through `status`, official ones through `hidden`.
    if (key === (spot?.official ? 'status' : 'hidden')) return false;
    return key in proposed || key in current;
  }).map(({ key, label, format }) => {
    const changed = key in proposed && !same(proposed[key], current[key]);
    return {
      key,
      label,
      current: format(current[key]),
      proposed: format(key in proposed ? proposed[key] : current[key]),
      changed,
    };
  });
}

/**
 * Proposal keys the Flutter admin rewrites before writing
 * (review_models.dart initialProposal): a fee is merged per vehicle with the
 * stored fee and its fee_note regenerated, a closure gets its start date
 * and basis, zone and segment patches are checked by id. Sending them as
 * the rider wrote them could clear the other vehicle's fee, so this page
 * does not apply them until that logic is shared (#195 core).
 */
export const STRUCTURED_KEYS = ['fee', 'condition', 'closure', 'parking_zones', 'parking_segments'] as const;

/** Columns `admin_resolve_report` accepts for this spot (review_models.dart ReviewSpot.allows). */
export function allowsKey(spot: ReviewSpot, key: string): boolean {
  if (key === (spot.official ? 'status' : 'hidden')) return false;
  return (ELIGIBILITY_KEYS as readonly string[]).includes(key) || DIFF_FIELDS.some((f) => f.key === key);
}

export type ApplyPlan =
  | { ok: true; patch: Record<string, unknown>; ignored: string[] }
  | { ok: false; reason: 'missingSpot' | 'structured' | 'empty'; keys: string[] };

/** What 「套用建議」 would write, or why it cannot (applicablePatch in the Flutter admin). */
export function applyPlan(report: ReviewReport, spot: ReviewSpot | undefined): ApplyPlan {
  if (!spot) return { ok: false, reason: 'missingSpot', keys: [] };
  const proposed = report.proposed ?? {};
  const structured = Object.keys(proposed).filter((k) => (STRUCTURED_KEYS as readonly string[]).includes(k));
  if (structured.length) return { ok: false, reason: 'structured', keys: structured };
  const patch: Record<string, unknown> = {};
  const ignored: string[] = [];
  for (const [key, value] of Object.entries(proposed)) {
    if (allowsKey(spot, key)) patch[key] = value;
    else ignored.push(key);
  }
  if (Object.keys(patch).length === 0) return { ok: false, reason: 'empty', keys: ignored };
  return { ok: true, patch, ignored };
}

/** Metres between two points (haversine), for 「建議移動 38 m」. */
export function distanceMetres(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}

/** How far a location report moves the spot, in whole metres; null if it does not. */
export function proposedMove(report: ReviewReport, spot: ReviewSpot | undefined): number | null {
  const p = report.proposed ?? {};
  const v = spot?.values ?? {};
  if (typeof p.lat !== 'number' || typeof p.lng !== 'number') return null;
  if (typeof v.lat !== 'number' || typeof v.lng !== 'number') return null;
  return Math.round(distanceMetres({ lat: v.lat, lng: v.lng }, { lat: p.lat, lng: p.lng }));
}

/** 「5 小時前」「3 天前」, relative to `now`. */
export function relativeTime(iso: string, now: number): string {
  const minutes = Math.max(0, Math.floor((now - Date.parse(iso)) / 60000));
  if (minutes < 1) return '剛剛';
  if (minutes < 60) return `${minutes} 分鐘前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小時前`;
  return `${Math.floor(hours / 24)} 天前`;
}

/** 「10/31 09:12」 in Taiwan time. */
export function shortDateTime(iso: string): string {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Taipei',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(new Date(iso));
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  return `${get('month')}/${get('day')} ${get('hour')}:${get('minute')}`;
}

/** Display name: the spot's, else the one the rider saw, else a plain fallback. */
export function spotName(report: ReviewReport, spot: ReviewSpot | undefined): string {
  const name = spot?.values.name ?? report.baseSpot?.name;
  return typeof name === 'string' && name ? name : '找不到這個點位';
}

export function spotArea(spot: ReviewSpot | undefined): string {
  const city = spot?.values.city;
  const district = spot?.values.district;
  return [city, district].filter((v): v is string => typeof v === 'string' && v !== '').join('');
}
