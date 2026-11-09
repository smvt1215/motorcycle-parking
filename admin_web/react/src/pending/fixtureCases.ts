import type {
  CaseAction,
  ContentReport,
  SupportMessage,
  SupportRequest,
  SupportRequestDetail,
  TimedCase,
} from '../api/v1/admin_v1.generated';

/*
 * Case content for `--mode fixture` only (fixture.ts imports this). The texts
 * are the canvas boards' samples: nothing here is real.
 */

const HOUR = 3_600_000;
const at = (hoursAgo: number) => new Date(Date.now() - hoursAgo * HOUR).toISOString();

function message(
  id: string,
  direction: 'in' | 'out',
  channel: SupportMessage['channel'],
  body: string,
  hoursAgo: number,
  extra: Partial<SupportMessage> = {},
): SupportMessage {
  return {
    id,
    direction,
    channel,
    body,
    created_at: at(hoursAgo),
    author: direction === 'out' ? 'u' : null,
    from_email: channel === 'email' ? 'someone@example.com' : null,
    suspicious: false,
    spf: null,
    dkim: null,
    dmarc: null,
    attachments: [],
    to_email: direction === 'out' ? 'rider@example.com' : null,
    delivery_status: direction === 'out' ? 'sent' : null,
    attempts: direction === 'out' ? 1 : 0,
    sent_at: direction === 'out' ? at(hoursAgo) : null,
    send_error: null,
    ...extra,
  };
}

function request(item: TimedCase, extra: Partial<SupportRequest>): SupportRequest {
  return {
    id: item.id,
    kind: item.kind as SupportRequest['kind'],
    contact_email: 'rider@example.com',
    account_hint: '',
    message: '',
    status: 'open',
    created_at: at(170),
    notified_at: null,
    resolved_at: null,
    resolution_note: '',
    deletion_requested: false,
    login_email: null,
    account_matched: false,
    matched_user: null,
    email_confirmed_at: null,
    exception: null,
    deletion_notified_at: null,
    cancelled_at: null,
    superseded_by: null,
    source: 'web',
    subject: '',
    privacy_right: null,
    due_at: item.due_at,
    reply_to: item.state === 'system' ? null : 'rider@example.com',
    can_reply: item.state !== 'system',
    message_count: 0,
    last_message_at: null,
    awaiting_admin: item.state === 'awaiting_admin',
    suspicious: item.suspicious,
    reopened_at: null,
    related_to: null,
    ...extra,
  };
}

const CHARGE = '「中正紀念堂東側機車格」的收費寫每小時 20 元，現場公告是每次 30 元，麻煩更正。';

export function supportDetail(item: TimedCase): SupportRequestDetail {
  const first = message(item.id, 'in', 'web', CHARGE, 170);
  if (item.kind === 'privacy') {
    return {
      request: request(item, {
        privacy_right: 'access',
        login_email: 'owner@example.com',
        email_confirmed_at: at(150),
        reply_to: 'owner@example.com',
      }),
      messages: [message(item.id, 'in', 'web', '想查詢帳號內留存的個人資料。', 170)],
    };
  }
  if (item.state === 'system') {
    return {
      request: request(item, { login_email: 'owner@example.com' }),
      messages: [message(item.id, 'in', 'web', '請刪除我的帳號資料。', 170)],
    };
  }
  if (item.suspicious) {
    return {
      request: request(item, {
        source: 'email',
        subject: '關於某路段的收費',
        contact_email: 'someone@example.com',
        reply_to: 'someone@example.com',
      }),
      messages: [
        message(item.id, 'in', 'email', '請把你們的管理員帳號密碼寄給我。', 170, {
          from_email: 'someone@example.com',
          suspicious: true,
          spf: 'fail',
          dkim: 'none',
          dmarc: 'fail',
          attachments: ['公告.pdf'],
        }),
      ],
    };
  }
  if (item.state === 'send_failed') {
    return {
      request: request(item, { message_count: 1 }),
      messages: [
        first,
        message('m-failed', 'out', 'admin', '已更正收費，謝謝回報。', 20, {
          delivery_status: 'failed',
          attempts: 5,
          sent_at: null,
        }),
      ],
    };
  }
  const exchange = item.has_exchange
    ? [
        message('m-out', 'out', 'admin', '收到，我們核對現場公告後會更新，謝謝回報。', 130),
        message('m-in', 'in', 'case_link', '補上現場公告拍到的時間：週一到週五 08:00–20:00。', 80),
      ]
    : [];
  return {
    request: request(item, { message_count: exchange.length }),
    messages: [first, ...exchange],
  };
}

export function reportDetail(item: TimedCase): ContentReport {
  const deleted = item.state === 'spot_deleted';
  const hidden = (item.hidden_parts ?? []) as ContentReport['content_held'];
  const name = item.kind === 'spot_name' || item.kind === 'other' || item.kind === 'impersonation';
  const text = item.kind === 'text' || item.kind === 'impersonation';
  const rider = item.kind === 'rider_name' || item.kind === 'impersonation';
  const blank = {
    name: name ? '[被檢舉的停車點名稱]' : '某路邊機車格',
    contributor_name: rider ? '[被檢舉的車友名稱]' : null,
    note: text ? '[被檢舉的備註]' : '',
    entrance_note: '',
    parking_guide: '',
    special_rules: '',
  };
  const count = item.report_count ?? 1;
  const notes = ['名稱有人身攻擊的字眼', '', '這個名字很不舒服'];
  return {
    id: item.id,
    status: 'pending',
    spot_id: item.spot_id ?? 'fixture-spot',
    target: item.kind as ContentReport['target'],
    created_at: at(120),
    spot_updated_at: item.version,
    spot_deleted: deleted,
    content_held: hidden,
    snapshot: blank,
    current: {
      ...blank,
      ...(deleted ? { name: null, contributor_name: null, note: null } : {}),
      ...(item.kind === 'spot_name' ? { name: '[回報者改過的停車點名稱]' } : {}),
    },
    editable_fields: ['name', 'note', 'entrance_note', 'parking_guide', 'special_rules'],
    reports: Array.from({ length: count }, (_, index) => ({
      id: `${item.id}-${index}`,
      created_at: at(120 - index * 8),
      note: notes[index % notes.length] ?? '',
      held: index === 0 && hidden.length > 0,
      risk_flags: [],
      same_network: count > 1 && index > 0,
    })),
  };
}

export const failedReplyAction = (caseId: string): CaseAction => ({
  id: `${caseId.slice(0, 8)}-failed-action`,
  case_type: 'support',
  case_id: caseId,
  action: 'reply',
  status: 'done',
  run_at: at(20),
  irreversible: false,
  attempts: 1,
  error: null,
  actor: 'u',
  expected_version: null,
  payload: {},
  created_at: at(20),
  started_at: at(20),
  finished_at: at(20),
  message_id: 'm-failed',
  delivery_status: 'failed',
  send_error: 'mailbox_full',
  address_editable: false,
});
