import { sampleQueue } from './fixtureSource';
import {
  applyPlan,
  diffRows,
  editOutcome,
  editStart,
  needsRejectNote,
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

describe('reject', () => {
  it('needs a written reason only for 其他原因', () => {
    expect(needsRejectNote('other', '  ')).toBe(true);
    expect(needsRejectNote('other', '現場沒有標線')).toBe(false);
    expect(needsRejectNote('wrong', '')).toBe(false);
  });
});

describe('editStart / editOutcome (修改後套用)', () => {
  const report2 = report({ proposed: { heavy_allowed: true, space_type: 'heavyOnly' } });
  const spot2: ReviewSpot = {
    ...community,
    values: { ...community.values, heavy_allowed: false, space_type: 'freeMotorcycle', note: '' },
  };

  it('starts from the rider proposal over current values', () => {
    const start = editStart(report2, spot2);
    expect(start).toMatchObject({ heavy_allowed: true, space_type: 'heavyOnly', name: '路邊機車格' });
    // Community spots hide through status, never hidden.
    expect('hidden' in start).toBe(false);
  });

  it('sends every proposal key, and other columns only when they change', () => {
    const values = { ...editStart(report2, spot2), heavy_allowed: false, note: '標線寫普通及大型重型機車' };
    const outcome = editOutcome(report2, spot2, values);
    // heavy_allowed equals the spot but was proposed: sent, so it is recorded as admin-verified.
    expect(outcome.patch).toEqual({
      heavy_allowed: false,
      space_type: 'heavyOnly',
      note: '標線寫普通及大型重型機車',
    });
    expect(outcome.changedFromRider).toEqual(['heavy_allowed']);
    expect(outcome.added).toEqual(['note']);
    expect(outcome.errors).toEqual({});
  });

  it('writes a vehicle column the admin restated, so it counts as verified (cross review, PR #216)', () => {
    const values = { ...editStart(report2, spot2), scooter_allowed: true };
    const spot3: ReviewSpot = { ...spot2, values: { ...spot2.values, scooter_allowed: true } };
    expect(editOutcome(report2, spot3, values).patch).not.toHaveProperty('scooter_allowed');
    expect(editOutcome(report2, spot3, values, new Set(['scooter_allowed'])).patch).toMatchObject({
      scooter_allowed: true,
    });
  });

  it('refuses values the table rejects: empty space_type or city, fee_note under a structured fee', () => {
    const values = { ...editStart(report2, spot2), space_type: null, city: '' };
    expect(Object.keys(editOutcome(report2, spot2, values).errors).sort()).toEqual(['city', 'space_type']);
    const feeSpot: ReviewSpot = {
      ...spot2,
      values: {
        ...spot2.values,
        fee: { scooter: { mode: 'hourly', amount: 20 } },
        fee_note: '機車每小時 20 元',
      },
    };
    const feeValues = { ...editStart(report2, feeSpot), fee_note: '機車每小時 30 元' };
    expect(editOutcome(report2, feeSpot, feeValues).errors).toHaveProperty('fee_note');
    expect(applyPlan(report({ proposed: { fee_note: '每小時 30 元' } }), feeSpot)).toMatchObject({
      ok: false,
      reason: 'feeNote',
    });
  });

  it('reads an emptied text field as the stored null, and accepts Dongsha latitude', () => {
    const values = { ...editStart(report2, spot2), entrance_note: '', lat: 20.7 };
    const outcome = editOutcome(report2, spot2, values);
    expect(outcome.patch).not.toHaveProperty('entrance_note');
    expect(outcome.errors).not.toHaveProperty('lat');
  });

  it('refuses an empty name, a too-long text, a bad coordinate and a cleared eligibility', () => {
    const values = {
      ...editStart(report2, spot2),
      name: '  ',
      fee_note: 'x'.repeat(201),
      lat: 99,
      heavy_allowed: null,
    };
    expect(Object.keys(editOutcome(report2, spot2, values).errors).sort()).toEqual(
      ['fee_note', 'heavy_allowed', 'lat', 'name'].sort(),
    );
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
