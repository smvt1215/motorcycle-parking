import type { TimedCase, TimedCaseCounts } from '../api/v1/admin_v1.generated';

export type PendingTab = 'all' | 'support' | 'report' | 'waiting';

export const PENDING_TABS: readonly { id: PendingTab; label: string }[] = [
  { id: 'all', label: '全部' },
  { id: 'support', label: '客服' },
  { id: 'report', label: '內容檢舉' },
  { id: 'waiting', label: '等對方' },
];

export const parseTab = (value: string | null): PendingTab =>
  PENDING_TABS.some((tab) => tab.id === value) ? (value as PendingTab) : 'all';

/** What each tab asks admin_v1.timed_cases for. */
export const TAB_QUERY: Record<PendingTab, { kind: string; bucket: string }> = {
  all: { kind: 'all', bucket: 'all' },
  support: { kind: 'support', bucket: 'all' },
  report: { kind: 'report', bucket: 'all' },
  waiting: { kind: 'all', bucket: 'waiting' },
};

/** A tab's badge. `all` already leaves out what is waiting on the other side. */
export function tabCount(counts: TimedCaseCounts, tab: PendingTab): number {
  switch (tab) {
    case 'all':
      return counts.all;
    case 'support':
      return counts.by_kind.support ?? 0;
    case 'report':
      return counts.by_kind.report ?? 0;
    case 'waiting':
      return counts.waiting;
  }
}

const SUPPORT_KINDS: Record<string, string> = {
  general: '一般問題',
  data_issue: '資料錯誤或侵權',
  complaint: '檢舉與申訴',
  privacy: '個資權利請求',
  account_deletion: '刪除帳號',
};

const REPORT_TARGETS: Record<string, string> = {
  rider_name: '不當內容：車友名稱',
  spot_name: '不當內容：停車點名稱',
  text: '不當內容：說明文字',
  impersonation: '不當內容：個人資料或冒充他人',
  other: '不當內容：其他原因',
};

export const caseTitle = (item: Pick<TimedCase, 'type' | 'kind'>): string =>
  item.type === 'support'
    ? (SUPPORT_KINDS[item.kind] ?? '客服案件')
    : (REPORT_TARGETS[item.kind] ?? '內容檢舉');

/** 「S-630F13C7」: the ticket number the canvas shows, from the case's own id. */
export const caseNumber = (item: Pick<TimedCase, 'type' | 'id'>): string =>
  `${item.type === 'support' ? 'S' : 'R'}-${item.id.replace(/-/g, '').slice(0, 8).toUpperCase()}`;

const taipei = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Taipei',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

/** [year, month, day] as Taiwan's calendar has it. */
function taipeiDate(time: number): [number, number, number] {
  return taipei.format(new Date(time)).split('-').map(Number) as [number, number, number];
}

/** 「2026-11-09」: changes when Taiwan's day does. */
export const taipeiDay = (time: number): string => taipei.format(new Date(time));

/**
 * due_at is the instant the last working day ends, which is 00:00 of the day
 * after: step back inside the day the deadline actually names.
 */
const lastMoment = (dueAt: string) => new Date(dueAt).getTime() - 1;

/** 「11/10」, with the year only when it is not this one. */
export function dueDate(dueAt: string, now: number): string {
  const [year, month, day] = taipeiDate(lastMoment(dueAt));
  const short = `${String(month).padStart(2, '0')}/${String(day).padStart(2, '0')}`;
  return year === taipeiDate(now)[0] ? short : `${year}/${short}`;
}

/** Whole Taiwan calendar days the deadline has passed by; at least 1. */
export function overdueDays(dueAt: string, now: number): number {
  const utcDay = ([year, month, day]: [number, number, number]) => Date.UTC(year, month - 1, day);
  const days = Math.round((utcDay(taipeiDate(now)) - utcDay(taipeiDate(lastMoment(dueAt)))) / 86_400_000);
  return Math.max(days, 1);
}

export function dueHint(item: Pick<TimedCase, 'bucket' | 'due_at'>, now: number): string | null {
  if (item.bucket === 'overdue') return `逾期 ${overdueDays(item.due_at, now)} 天`;
  return item.bucket === 'today' ? '今天' : null;
}

const SCHEDULED_LABEL: Record<string, string> = {
  reply: '等待寄出',
  resolve_support: '等待結案',
};

const scheduledLabel = (item: TimedCase) => SCHEDULED_LABEL[item.pending_action?.action ?? ''] ?? '等待處理';

/** The row's second line. A report counts its reports, whatever its state. */
export function caseStatus(item: TimedCase): string {
  if (item.type === 'report') return `${item.report_count ?? 1} 則檢舉`;
  switch (item.state) {
    case 'send_failed':
      return '回覆沒有寄出';
    case 'scheduled':
      return scheduledLabel(item);
    case 'awaiting_user':
      return '等對方回覆';
    case 'system':
      return item.kind === 'privacy' ? '等對方確認' : '系統處理中';
    default:
      return item.has_exchange ? '對方補充了' : '等你回覆';
  }
}

export type TagTone = 'danger' | 'dashed' | 'outline' | 'solid';

export interface CaseTag {
  label: string;
  tone: TagTone;
}

export function caseTags(item: TimedCase): CaseTag[] {
  const tags: CaseTag[] = [];
  if (item.state === 'send_failed') {
    tags.push({ label: item.type === 'support' ? '寄送失敗' : '沒有套用', tone: 'danger' });
  } else if (item.pending_action?.status === 'stale') {
    tags.push({ label: '沒有套用', tone: 'danger' });
  }
  if (item.type === 'report') {
    if (item.state === 'scheduled') tags.push({ label: scheduledLabel(item), tone: 'dashed' });
    if (item.state === 'spot_deleted') tags.push({ label: '點位已刪除', tone: 'danger' });
    else if (item.hidden_parts?.length) tags.push({ label: '暫時隱藏中', tone: 'dashed' });
    else if (item.state === 'open') tags.push({ label: '沒有隱藏', tone: 'outline' });
  }
  if (item.suspicious) tags.push({ label: '寄件人未驗證', tone: 'danger' });
  return tags;
}

const dateTimeFormat = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'Asia/Taipei',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

/** 「11/03 09:41」 Taiwan time, with the year only when it is not this one (t7). */
export function dateTime(iso: string, now: number): string {
  const time = Date.parse(iso);
  const parts = Object.fromEntries(dateTimeFormat.formatToParts(time).map((p) => [p.type, p.value]));
  const short = `${parts.month}/${parts.day} ${parts.hour}:${parts.minute}`;
  const year = taipeiDate(time)[0];
  return year === taipeiDate(now)[0] ? short : `${year}/${short}`;
}

/** The case header's tags: lateness first, then where it stands. */
export function caseHeadTags(item: TimedCase, now: number, confirmed: boolean): CaseTag[] {
  const tags: CaseTag[] = [];
  if (item.bucket === 'overdue')
    tags.push({ label: `逾期 ${overdueDays(item.due_at, now)} 天`, tone: 'danger' });
  if (item.type === 'report') return [...tags, ...caseTags(item)];
  switch (item.state) {
    case 'scheduled':
      tags.push({ label: scheduledLabel(item), tone: 'dashed' });
      break;
    case 'awaiting_user':
      tags.push({ label: '等對方回覆', tone: 'outline' });
      break;
    case 'system':
      tags.push({
        label: item.kind === 'account_deletion' && confirmed ? '系統處理中' : '等對方確認',
        tone: 'dashed',
      });
      break;
    case 'send_failed':
      break;
    default:
      tags.push({ label: item.has_exchange ? '對方補充了' : '等你回覆', tone: 'solid' });
  }
  return [...tags, ...caseTags(item)];
}

export type CaseGroupKey = 'failed' | TimedCase['bucket'];

const GROUP_LABEL: Record<CaseGroupKey, string> = {
  failed: '寄送失敗',
  overdue: '逾期',
  today: '今天到期',
  later: '之後',
  waiting: '等對方',
};

export interface CaseGroup {
  key: CaseGroupKey;
  label: string;
  items: TimedCase[];
}

/** Keeps the server's order; a failed send sits above every deadline. */
export function groupCases(items: readonly TimedCase[]): CaseGroup[] {
  const groups = new Map<CaseGroupKey, CaseGroup>();
  for (const item of items) {
    const key: CaseGroupKey = item.rank === 0 ? 'failed' : item.bucket;
    let group = groups.get(key);
    if (!group) {
      group = { key, label: GROUP_LABEL[key], items: [] };
      groups.set(key, group);
    }
    group.items.push(item);
  }
  return [...groups.values()];
}
