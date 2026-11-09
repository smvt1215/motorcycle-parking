import { describe, expect, it } from 'vitest';
import type { TimedCase } from '../api/v1/admin_v1.generated';
import {
  caseNumber,
  caseStatus,
  caseTags,
  caseTitle,
  dueDate,
  dueHint,
  groupCases,
  overdueDays,
  tabCount,
} from './model';

const base: TimedCase = {
  id: '630f13c7-aaaa-4000-8000-000000000000',
  type: 'support',
  kind: 'data_issue',
  state: 'awaiting_admin',
  due_at: '2026-11-10T16:00:00Z',
  bucket: 'later',
  rank: 2,
  version: null,
  last_activity_at: '2026-11-01T00:00:00Z',
  suspicious: false,
  report_count: null,
  hidden_parts: null,
  spot_id: null,
  pending_action: null,
};
const report: TimedCase = {
  ...base,
  type: 'report',
  kind: 'spot_name',
  state: 'held',
  report_count: 3,
  hidden_parts: ['spot_name'],
};

// 2026-11-09 12:00 Taiwan time.
const NOW = Date.parse('2026-11-09T04:00:00Z');

describe('deadlines', () => {
  it('names the working day that ends at the deadline, in Taiwan time', () => {
    // due_at is 00:00 on 11/11 Taiwan time: the last moment of 11/10.
    expect(dueDate('2026-11-10T16:00:00Z', NOW)).toBe('11/10');
  });

  it('adds the year only across a year boundary', () => {
    expect(dueDate('2027-01-04T16:00:00Z', NOW)).toBe('2027/01/04');
  });

  it('counts overdue days on the Taiwan calendar', () => {
    expect(overdueDays('2026-11-08T16:00:00Z', NOW)).toBe(1);
    expect(overdueDays('2026-11-05T16:00:00Z', NOW)).toBe(4);
  });

  it('hints only at overdue and today', () => {
    expect(dueHint({ bucket: 'overdue', due_at: '2026-11-08T16:00:00Z' }, NOW)).toBe('逾期 1 天');
    expect(dueHint({ bucket: 'today', due_at: '2026-11-09T16:00:00Z' }, NOW)).toBe('今天');
    expect(dueHint({ bucket: 'later', due_at: '2026-11-10T16:00:00Z' }, NOW)).toBeNull();
  });
});

describe('row text', () => {
  it('shows the canvas ticket number', () => {
    expect(caseNumber(base)).toBe('S-630F13C7');
    expect(caseNumber(report)).toBe('R-630F13C7');
  });

  it('names known kinds and falls back for new ones', () => {
    expect(caseTitle(base)).toBe('資料錯誤或侵權');
    expect(caseTitle(report)).toBe('不當內容：停車點名稱');
    expect(caseTitle({ type: 'support', kind: 'new_kind' })).toBe('客服案件');
    expect(caseTitle({ type: 'report', kind: 'new_kind' })).toBe('內容檢舉');
  });

  it('says what each support state is waiting for', () => {
    expect(caseStatus(base)).toBe('等你回覆');
    expect(caseStatus({ ...base, state: 'send_failed' })).toBe('回覆沒有寄出');
    expect(caseStatus({ ...base, state: 'awaiting_user' })).toBe('等對方回覆');
    expect(caseStatus({ ...base, kind: 'privacy', state: 'system' })).toBe('等對方確認');
    expect(caseStatus({ ...base, kind: 'account_deletion', state: 'system' })).toBe('系統處理中');
  });

  it('counts reports whatever their state', () => {
    expect(caseStatus(report)).toBe('3 則檢舉');
    expect(caseStatus({ ...report, state: 'send_failed' })).toBe('3 則檢舉');
  });

  it('tags a report by what it hides', () => {
    expect(caseTags(report)).toEqual([{ label: '暫時隱藏中', tone: 'dashed' }]);
    expect(caseTags({ ...report, state: 'open', hidden_parts: [] })).toEqual([
      { label: '沒有隱藏', tone: 'outline' },
    ]);
    expect(caseTags({ ...report, state: 'spot_deleted', hidden_parts: [] })).toEqual([
      { label: '點位已刪除', tone: 'danger' },
    ]);
  });

  it('flags failures and an unverified sender', () => {
    expect(caseTags({ ...base, state: 'send_failed' })).toEqual([{ label: '寄送失敗', tone: 'danger' }]);
    expect(caseTags({ ...base, suspicious: true })).toEqual([{ label: '寄件人未驗證', tone: 'danger' }]);
    expect(
      caseTags({
        ...base,
        pending_action: {
          id: 'a',
          action: 'reply',
          run_at: base.due_at,
          irreversible: false,
          status: 'stale',
        },
      }),
    ).toEqual([{ label: '沒有套用', tone: 'danger' }]);
  });
});

describe('groups and counts', () => {
  it('puts failed sends above deadlines and keeps the server order inside', () => {
    const overdue = { ...base, id: 'a', bucket: 'overdue', rank: 1 } as TimedCase;
    const failed = { ...base, id: 'b', bucket: 'later', rank: 0, state: 'send_failed' } as TimedCase;
    const today = { ...base, id: 'c', bucket: 'today', rank: 2 } as TimedCase;
    const groups = groupCases([failed, overdue, today]);
    expect(groups.map((group) => group.label)).toEqual(['寄送失敗', '逾期', '今天到期']);
  });

  it('reads each tab from the counts, 0 when a kind has none', () => {
    const counts = {
      all: 6,
      overdue: 1,
      today: 2,
      later: 3,
      waiting: 3,
      send_failed: 0,
      by_kind: { support: 4 },
      as_of: '',
    };
    expect(tabCount(counts, 'all')).toBe(6);
    expect(tabCount(counts, 'support')).toBe(4);
    expect(tabCount(counts, 'report')).toBe(0);
    expect(tabCount(counts, 'waiting')).toBe(3);
  });
});
