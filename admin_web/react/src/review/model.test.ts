import { sampleQueue } from './fixtureSource';
import {
  applyPlan,
  diffRows,
  plateOf,
  proposedMove,
  relativeTime,
  reportKind,
  riderText,
  shortDateTime,
  spotName,
  suggestionKey,
  type ReviewReport,
  type ReviewSpot,
} from './model';

const NOW = Date.parse('2026-10-31T10:00:00Z');

const report = (r: Partial<ReviewReport>): ReviewReport => ({
  id: 'r',
  sourceId: 's',
  reason: '',
  field: null,
  proposed: null,
  note: '',
  createdAt: '2026-10-31T09:00:00Z',
  baseSpot: null,
  risk: null,
  riskFlags: [],
  evidenceUrl: null,
  ...r,
});

const community: ReviewSpot = {
  sourceId: 's',
  official: false,
  values: {
    name: '路邊機車格',
    city: '臺北市',
    district: '大安區',
    lat: 25,
    lng: 121.5,
    status: 'confirmed',
  },
};
const official: ReviewSpot = {
  sourceId: 'official:o',
  official: true,
  values: { name: '地下停車場', hidden: false, heavy_allowed: true, scooter_allowed: null },
};

describe('reportKind (review_models.dart ReviewReport.kind, plus 位置)', () => {
  it.each([
    [{ field: 'gone' }, 'gone'],
    [{ reason: '加權負向回報達門檻' }, 'gone'],
    [{ proposed: { status: 'hidden' } }, 'gone'],
    [{ proposed: { hidden: true } }, 'gone'],
    [{ field: 'eligibility' }, 'access'],
    [{ proposed: { heavy_allowed: true } }, 'access'],
    [{ field: 'location', proposed: { lat: 25, lng: 121 } }, 'location'],
    [{ proposed: { lat: 25 } }, 'location'],
    [{ field: 'name', proposed: { name: 'x' } }, 'info'],
    // Older builds wrote the field before 「：」.
    [{ reason: '機車停放資格：建議可停' }, 'access'],
  ] as const)('%j → %s', (r, kind) => {
    expect(reportKind(report(r as Partial<ReviewReport>))).toBe(kind);
  });

  it('reads older labels as keys', () => {
    expect(suggestionKey('位置或其他備註')).toBe('note');
    expect(suggestionKey('點位已不存在')).toBe('gone');
    expect(suggestionKey('unknown')).toBeNull();
  });
});

describe('riderText', () => {
  it('is the reason for gone and unstructured reports, else the note', () => {
    expect(riderText(report({ field: 'gone', reason: '已改建', proposed: { status: 'hidden' } }))).toBe(
      '已改建',
    );
    expect(riderText(report({ reason: '舊版文字' }))).toBe('舊版文字');
    expect(riderText(report({ proposed: { name: 'x' }, note: '  現場看到  ' }))).toBe('現場看到');
    expect(riderText(report({ proposed: { name: 'x' } }))).toBeNull();
  });
});

describe('plateOf', () => {
  it('maps stored eligibility; null is legacy 未確認', () => {
    expect(plateOf(true)).toBe('allowed');
    expect(plateOf(false)).toBe('denied');
    expect(plateOf(null)).toBe('legacyUnknown');
    expect(plateOf(undefined)).toBe('legacyUnknown');
  });
});

describe('diffRows', () => {
  it('marks only what the rider changed and labels values', () => {
    const rows = diffRows(report({ proposed: { space_type: 'heavyOnly', name: '路邊機車格' } }), {
      ...community,
      values: { ...community.values, space_type: 'freeMotorcycle' },
    });
    const byKey = Object.fromEntries(rows.map((r) => [r.key, r]));
    expect(byKey.space_type).toMatchObject({ current: '免費機車格', proposed: '重機專用格', changed: true });
    // Same value as stored: shown, not changed.
    expect(byKey.name?.changed).toBe(false);
    expect(byKey.city).toMatchObject({ current: '臺北市', proposed: '臺北市', changed: false });
  });

  it('uses status for community spots and hidden for official ones', () => {
    expect(diffRows(report({}), community).map((r) => r.key)).toContain('status');
    expect(diffRows(report({}), community).map((r) => r.key)).not.toContain('hidden');
    expect(diffRows(report({}), official).map((r) => r.key)).toContain('hidden');
    expect(diffRows(report({}), official).map((r) => r.key)).not.toContain('status');
  });
});

describe('applyPlan', () => {
  it('sends the keys this spot accepts', () => {
    const plan = applyPlan(
      report({ proposed: { name: '新名', hidden: true, scooter_allowed: true } }),
      community,
    );
    expect(plan).toEqual({ ok: true, patch: { name: '新名', scooter_allowed: true }, ignored: ['hidden'] });
  });

  it.each(['fee', 'condition', 'closure', 'parking_zones', 'parking_segments'])(
    'leaves %s to the Flutter admin, which merges it before writing',
    (key) => {
      // A fee naming only one vehicle must not clear the other (mergeFeeJson).
      expect(applyPlan(report({ proposed: { [key]: { scooter: null } } }), community)).toEqual({
        ok: false,
        reason: 'structured',
        keys: [key],
      });
    },
  );

  it('cannot apply to a missing spot or an empty patch', () => {
    expect(applyPlan(report({ proposed: { name: 'x' } }), undefined)).toMatchObject({
      reason: 'missingSpot',
    });
    expect(applyPlan(report({ proposed: { status: 'hidden' } }), official)).toMatchObject({
      reason: 'empty',
    });
  });
});

describe('formatting', () => {
  it('measures a proposed move in metres', () => {
    const move = proposedMove(report({ proposed: { lat: 25.00034, lng: 121.5 } }), community);
    expect(move).toBe(38);
    expect(proposedMove(report({ proposed: { name: 'x' } }), community)).toBeNull();
  });

  it('says how long ago, in Chinese', () => {
    expect(relativeTime('2026-10-31T09:59:40Z', NOW)).toBe('剛剛');
    expect(relativeTime('2026-10-31T09:15:00Z', NOW)).toBe('45 分鐘前');
    expect(relativeTime('2026-10-31T05:00:00Z', NOW)).toBe('5 小時前');
    expect(relativeTime('2026-10-28T10:00:00Z', NOW)).toBe('3 天前');
  });

  it('prints Taiwan time', () => {
    expect(shortDateTime('2026-10-31T01:12:00Z')).toBe('10/31 09:12');
  });

  it('falls back to the name the rider saw', () => {
    expect(spotName(report({ baseSpot: { name: '舊名' } }), undefined)).toBe('舊名');
    expect(spotName(report({}), undefined)).toBe('找不到這個點位');
  });
});

describe('sampleQueue', () => {
  it('is oldest first and every report has its spot', () => {
    const { reports, spots } = sampleQueue(NOW);
    const times = reports.map((r) => r.createdAt);
    expect(times).toEqual([...times].sort());
    for (const r of reports) expect(spots[r.sourceId]).toBeDefined();
  });
});
