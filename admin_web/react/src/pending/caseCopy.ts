import type { CaseAction, TimedCase } from '../api/v1/admin_v1.generated';
import { caseNumber, caseTitle } from './model';

export type ActionKind = CaseAction['action'];

/** How a report can be closed as 檢舉不成立 (TimedReportActions). */
export const RESTORE_REASONS = [
  { value: 'wrong', label: '檢舉內容不實', description: '看過內容，沒有不當的地方' },
  { value: 'duplicate', label: '重複檢舉', description: '同樣的內容已經處理過' },
  { value: 'insufficient', label: '資訊不足', description: '說明不夠，無法判斷' },
  { value: 'outdated', label: '內容已改好', description: '回報者已經改掉不當的部分' },
  { value: 'abuse', label: '濫用檢舉', description: '刻意檢舉沒有問題的內容' },
  { value: 'other', label: '其他原因', description: '要在處理說明寫下原因' },
] as const;

export type RestoreReason = (typeof RESTORE_REASONS)[number]['value'];

/** What the admin has typed for a case, kept while moving between cases. */
export interface CaseDraft {
  reply?: string;
  resolveStatus?: 'done' | 'rejected';
  resolveNote?: string;
  restoreReason?: RestoreReason;
  restoreNote?: string;
  keepName?: string;
  /** Only the fields changed from the current text. */
  edits?: Record<string, string>;
}

/** The confirm button and the countdown both follow what was reported. */
const KEEP_VERB: Record<string, string> = {
  rider_name: '永久清除車友名稱',
  spot_name: '換掉停車點名稱',
  text: '移除說明文字',
  impersonation: '清除並換掉名稱',
  other: '結案',
};

export const keepButtonLabel = (kind: string): string => KEEP_VERB[kind] ?? '結案';

export const NEEDS_NEW_NAME = new Set(['spot_name', 'impersonation']);

export interface ActionLabels {
  /** 「寄出」, read as 「3 秒後寄出」. */
  verb: string;
  /** 「回覆 S-630F13C7 資料錯誤或侵權」. */
  subject: string;
  cancel: string;
  sendingTitle: string;
  sendingBody: string;
  doneTitle: string;
  doneBody: string;
  cancelledTitle: string;
  cancelledBody: string;
  lateBody: string;
  failedTitle: string;
  failedBody: string;
  staleTitle: string;
  staleBody: string;
}

export interface ActionContext {
  action: ActionKind;
  item: Pick<TimedCase, 'id' | 'type' | 'kind' | 'hidden_parts'>;
  /** Reply: where it goes. */
  replyTo?: string | null;
  resolveStatus?: 'done' | 'rejected';
}

/** Every line the dock can show for one action, fixed when it starts. */
export function describeAction({ action, item, replyTo, resolveStatus }: ActionContext): ActionLabels {
  const number = caseNumber(item);
  const title = caseTitle(item);
  const hidden = (item.hidden_parts?.length ?? 0) > 0;
  if (action === 'reply') {
    return {
      verb: '寄出',
      subject: `回覆 ${number} ${title}`,
      cancel: '取消寄出',
      sendingTitle: '寄送中',
      sendingBody: `回覆 ${number}，已經來不及取消`,
      doneTitle: '已寄出',
      doneBody: replyTo ? `回覆 ${number} 寄往 ${replyTo}` : `回覆 ${number}`,
      cancelledTitle: '已取消寄出',
      cancelledBody: `回覆回到 ${number} 的回覆框，內容還在`,
      lateBody: `回覆 ${number} 已經開始寄送`,
      failedTitle: '回覆沒有寄出',
      failedBody: `${number} 已回到清單最上方，內容還在`,
      staleTitle: '這筆案件有新的變動',
      staleBody: `${number} 你的回覆沒有寄出，內容還在`,
    };
  }
  const verb =
    action === 'resolve_support'
      ? '結案'
      : action === 'report_keep'
        ? keepButtonLabel(item.kind)
        : hidden
          ? '放回 App'
          : '結案';
  const lead =
    action === 'resolve_support'
      ? resolveStatus === 'rejected'
        ? '無法處理'
        : '已處理'
      : action === 'report_restore'
        ? '檢舉不成立'
        : action === 'report_keep'
          ? '檢舉成立'
          : '改內容';
  const isSupport = action === 'resolve_support';
  return {
    verb,
    subject: `${lead} ${number}`,
    cancel: isSupport ? '取消結案' : '取消',
    sendingTitle: '處理中',
    sendingBody: `${number}，已經來不及取消`,
    doneTitle: verb === '結案' ? '已結案' : `已${verb}`,
    doneBody: `${lead} ${number}`,
    cancelledTitle: isSupport ? '已取消結案' : '已取消',
    cancelledBody: `${number} 回到清單原來的位置，填的內容還在`,
    lateBody: `${number} 已經開始處理`,
    failedTitle: '處理沒有套用',
    failedBody: `${number} 已回到清單最上方，填的內容還在`,
    staleTitle: isSupport ? '這筆案件有新的變動' : '這個點位已被修改',
    staleBody: `${number} 你的處理沒有套用，填的內容還在`,
  };
}

/** A draft from the payload the server kept, for a reload after stale or failed. */
export function draftFromPayload(action: ActionKind, payload: Record<string, unknown>): CaseDraft {
  const text = (key: string) => (typeof payload[key] === 'string' ? (payload[key] as string) : undefined);
  const patch = (payload.patch ?? {}) as Record<string, string>;
  switch (action) {
    case 'reply':
      return { reply: text('body') };
    case 'resolve_support':
      return {
        resolveStatus: text('status') === 'rejected' ? 'rejected' : 'done',
        resolveNote: text('note') ?? '',
      };
    case 'report_restore':
      return { restoreReason: text('reason') as RestoreReason | undefined, restoreNote: text('note') ?? '' };
    case 'report_keep':
      return { keepName: patch.name };
    case 'report_edit':
      return { edits: patch };
  }
}
