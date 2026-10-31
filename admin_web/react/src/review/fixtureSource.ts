import type { ReviewQueue, ReviewReport, ReviewSpot } from './model';
import { SourceError, type AdminDataSource, type ResolveRequest, type SourceErrorCode } from './source';

/**
 * Production builds must never contain this module; CI greps the bundle for
 * this marker (.github/workflows/ci.yml, admin-react job).
 */
export const FIXTURE_MARKER = 'MOTOPARK_ADMIN_FIXTURE_DATA';

const HOUR = 3600000;

function spot(sourceId: string, values: Record<string, unknown>): ReviewSpot {
  return { sourceId, official: sourceId.startsWith('official:'), values };
}

/** Sample queue drawn from the canvas boards (Main.dc.html, ReviewPhoneList.dc.html). */
export function sampleQueue(now: number): ReviewQueue {
  const at = (hoursAgo: number) => new Date(now - hoursAgo * HOUR).toISOString();
  const ids = {
    fuxing: '11111111-1111-4111-8111-111111111111',
    daan: 'official:22222222-2222-4222-8222-222222222222',
    ximen: 'official:33333333-3333-4333-8333-333333333333',
    xinyi: '44444444-4444-4444-8444-444444444444',
    cks: '55555555-5555-4555-8555-555555555555',
    banqiao: '66666666-6666-4666-8666-666666666666',
  };
  const spots: ReviewSpot[] = [
    spot(ids.fuxing, {
      name: '復興南路一段 107 巷路邊機車格',
      city: '臺北市',
      district: '大安區',
      lat: 25.0418,
      lng: 121.5437,
      space_type: 'freeMotorcycle',
      scooter_allowed: true,
      heavy_allowed: false,
      note: '',
    }),
    spot(ids.daan, {
      name: '大安森林公園地下停車場',
      city: '臺北市',
      district: '大安區',
      lat: 25.0297,
      lng: 121.5359,
      space_type: 'offStreet',
      facility_type: 'underground',
      scooter_allowed: true,
      heavy_allowed: true,
      fee_note: '機車每小時 20 元',
      entrance_note: '新生南路側入口',
      source_name: '臺北市停車管理工程處',
      hidden: false,
    }),
    spot(ids.ximen, {
      name: '西門町峨眉立體停車場',
      city: '臺北市',
      district: '萬華區',
      lat: 25.0441,
      lng: 121.5055,
      space_type: 'offStreet',
      facility_type: 'multiStorey',
      scooter_allowed: null,
      heavy_allowed: false,
      source_name: '臺北市停車管理工程處',
      hidden: false,
    }),
    spot(ids.xinyi, {
      name: '信義廣場平面停車場',
      city: '臺北市',
      district: '信義區',
      lat: 25.0335,
      lng: 121.5645,
      space_type: 'offStreet',
      facility_type: 'surface',
      scooter_allowed: true,
      heavy_allowed: null,
      status: 'confirmed',
    }),
    spot(ids.cks, {
      name: '中正紀念堂愛國東路側機車格',
      city: '臺北市',
      district: '中正區',
      lat: 25.0335,
      lng: 121.5197,
      space_type: 'paidMotorcycle',
      scooter_allowed: true,
      heavy_allowed: false,
      status: 'confirmed',
    }),
    spot(ids.banqiao, {
      name: '板橋車站 B1 機車停車場',
      city: '新北市',
      district: '板橋區',
      lat: 25.0141,
      lng: 121.4637,
      space_type: 'offStreet',
      facility_type: 'underground',
      scooter_allowed: true,
      heavy_allowed: false,
      status: 'confirmed',
    }),
  ];
  const report = (r: Partial<ReviewReport> & Pick<ReviewReport, 'id' | 'sourceId'>): ReviewReport => ({
    reason: '',
    field: null,
    proposed: null,
    note: '',
    createdAt: at(1),
    baseSpot: null,
    risk: null,
    riskFlags: [],
    evidenceUrl: null,
    ...r,
  });
  const reports: ReviewReport[] = [
    report({
      id: 'r-ximen',
      sourceId: ids.ximen,
      field: 'eligibility',
      reason: '機車停放資格：建議「普通機車可停」',
      proposed: { scooter_allowed: true },
      note: '入口告示寫機車可停，一樓收費亭旁有機車格。',
      createdAt: at(72),
      baseSpot: { scooter_allowed: null },
      risk: 'high',
    }),
    report({
      id: 'r-fuxing',
      sourceId: ids.fuxing,
      field: 'eligibility',
      reason: '機車停放資格：建議「大型重機可停」',
      proposed: { heavy_allowed: true, space_type: 'heavyOnly' },
      note: '地面標線寫「普通及大型重型機車」，旁邊有臺北市停管處的牌子，下午看到兩台黃牌停在這裡。',
      createdAt: at(5),
      baseSpot: { heavy_allowed: false, space_type: 'freeMotorcycle' },
      risk: 'high',
    }),
    report({
      id: 'r-fuxing-2',
      sourceId: ids.fuxing,
      field: 'eligibility',
      reason: '機車停放資格：建議「大型重機可停」',
      proposed: { heavy_allowed: true },
      createdAt: at(48),
      baseSpot: { heavy_allowed: false },
      risk: 'high',
    }),
    report({
      id: 'r-daan',
      sourceId: ids.daan,
      field: 'fee_note',
      reason: '收費資訊：建議更新',
      proposed: {
        fee_note: '機車每小時 30 元，當日最高 150 元',
        entrance_note: '新生南路側車道，機車走右側',
      },
      note: '現場告示 11 月起調整費率。',
      createdAt: at(30),
      baseSpot: { fee_note: '機車每小時 20 元', entrance_note: '新生南路側入口' },
      risk: 'medium',
      evidenceUrl: 'https://example.org/notice/daan-fee',
    }),
    report({
      id: 'r-xinyi',
      sourceId: ids.xinyi,
      field: 'gone',
      reason: '點位已不存在：已改建工地',
      proposed: { status: 'hidden' },
      createdAt: at(20),
      baseSpot: { status: 'confirmed' },
      risk: 'medium',
    }),
    report({
      id: 'r-cks',
      sourceId: ids.cks,
      field: 'location',
      reason: '位置不正確',
      proposed: { lat: 25.03384, lng: 121.51945 },
      note: '格子在愛國東路靠信義路口那側。',
      createdAt: at(10),
      baseSpot: { lat: 25.0335, lng: 121.5197 },
      risk: 'medium',
    }),
    report({
      id: 'r-banqiao',
      sourceId: ids.banqiao,
      field: 'name',
      reason: '停車點名稱：建議改名',
      proposed: { name: '板橋車站 B1 機車停車場（南側）' },
      createdAt: at(3),
      baseSpot: { name: '板橋車站 B1 機車停車場' },
      risk: 'low',
    }),
  ];
  return {
    reports: reports.sort((a, b) => a.createdAt.localeCompare(b.createdAt)),
    spots: Object.fromEntries(spots.map((s) => [s.sourceId, s])),
  };
}

export interface FixtureSource extends AdminDataSource {
  readonly marker: typeof FIXTURE_MARKER;
  /** Make the next resolve fail with this code (tests, demos). */
  failNextResolve(code: SourceErrorCode): void;
  /** Requests the source received, oldest first. */
  readonly resolved: ResolveRequest[];
}

/** In-memory admin data for development (`--mode fixture`) and tests. */
export function fixtureSource(options: { now?: number; latencyMs?: number } = {}): FixtureSource {
  const queue = sampleQueue(options.now ?? Date.now());
  const latency = options.latencyMs ?? 0;
  let nextFailure: SourceErrorCode | null = null;
  const resolved: ResolveRequest[] = [];
  const wait = () => (latency > 0 ? new Promise((r) => setTimeout(r, latency)) : Promise.resolve());

  return {
    marker: FIXTURE_MARKER,
    resolved,
    failNextResolve(code) {
      nextFailure = code;
    },
    async loadQueue() {
      await wait();
      return structuredClone(queue);
    },
    async resolve(request) {
      await wait();
      if (nextFailure) {
        const code = nextFailure;
        nextFailure = null;
        throw new SourceError(code, code);
      }
      const index = queue.reports.findIndex((r) => r.id === request.reportId);
      if (index < 0) throw new SourceError('alreadyResolved', 'already resolved');
      const [report] = queue.reports.splice(index, 1);
      const target = queue.spots[report!.sourceId];
      if (target) Object.assign(target.values, request.patch);
      resolved.push(request);
      return { reportId: request.reportId, spot: target ? structuredClone(target) : null };
    },
  };
}
