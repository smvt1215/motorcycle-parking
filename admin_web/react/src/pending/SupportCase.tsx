import type {
  CaseAction,
  SupportMessage,
  SupportRequestDetail,
  TimedCase,
} from '../api/v1/admin_v1.generated';
import { useAuthController, useAuthState } from '../auth/AuthContext';
import type { AuthController } from '../auth/controller';
import { dateTime } from './model';
import { DefinitionList, Notice, Tag } from './CaseParts';
import { Button } from '../ui/controls';
import type { TrackedAction } from './actionsSlice';

const PRIVACY_RIGHT: Record<string, string> = { access: '查詢', correction: '更正', copy: '複本' };

const SOURCE_NAME: Record<string, string> = { web: '客服表單', email: 'Email' };

const OUTBOUND_MINE = '你的回覆';

function messageLabel(message: SupportMessage, index: number, mine: boolean): string {
  if (message.direction === 'out') return mine ? OUTBOUND_MINE : '其他管理員的回覆';
  if (index === 0) return `對方的原始內容（${SOURCE_NAME[message.channel] ?? '客服表單'}）`;
  return message.channel === 'email' ? '對方的回信（Email）' : '對方的補充（案件連結）';
}

function Delivery({ message, now }: { message: SupportMessage; now: number }) {
  if (message.direction !== 'out') return null;
  if (message.delivery_status === 'sent') {
    return (
      <span className="t-caption">
        已寄到 {message.to_email}
        {message.sent_at && (
          <>
            ，<span className="num">{dateTime(message.sent_at, now)}</span>
          </>
        )}
      </span>
    );
  }
  if (message.delivery_status === 'failed') {
    return (
      <span className="case-delivery--failed">
        沒有寄出，系統已試了 <span className="num">{message.attempts}</span> 次
      </span>
    );
  }
  return <span className="t-caption">寄送中，寄到 {message.to_email}</span>;
}

/** The current admin's id, when a sign-in applies (absent in unit tests). */
function MineLabel({
  controller,
  children,
}: {
  controller: AuthController;
  children: (id: string | null) => React.ReactNode;
}) {
  const state = useAuthState(controller);
  return <>{children(state.access.userId)}</>;
}

function CaseLog({
  detail,
  now,
  meId,
  pending,
}: {
  detail: SupportRequestDetail;
  now: number;
  meId: string | null;
  pending: PendingReply[];
}) {
  return (
    <section aria-labelledby="case-log" className="case-section">
      <h3 id="case-log" className="t-title">
        往來紀錄
      </h3>
      <ol className="case-log">
        {detail.messages.map((message, index) => (
          <li key={message.id} className={`case-message case-message--${message.direction}`}>
            <span className="case-message__head">
              <span className="t-label">
                {messageLabel(message, index, meId === null || message.author === meId)}
              </span>
              <span className="num t-caption">{dateTime(message.created_at, now)}</span>
            </span>
            <span className="case-message__body">{message.body}</span>
            {message.attachments.length > 0 && (
              <span className="t-caption">附件：{message.attachments.join('、')}（只有檔名）</span>
            )}
            <Delivery message={message} now={now} />
          </li>
        ))}
        {pending.map((reply) => (
          <li key={reply.id} className="case-message case-message--out">
            <span className="case-message__head">
              <span className="t-label">{OUTBOUND_MINE}</span>
            </span>
            <span className="case-message__body">{reply.body}</span>
            <span className="t-caption">{reply.line}</span>
            <span className="pending-tag pending-tag--dashed case-message__tag">等待寄出</span>
            {reply.onCancel && (
              <Button onClick={reply.onCancel} className="case-message__cancel">
                取消寄出
              </Button>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
}

export interface PendingReply {
  id: string;
  body: string;
  line: string;
  onCancel: (() => void) | null;
}

export function SupportNotices({
  item,
  request,
  failedSend,
}: {
  item: TimedCase;
  request: SupportRequestDetail['request'];
  failedSend: boolean;
}) {
  const replyTo = request.reply_to ?? request.contact_email;
  return (
    <>
      {item.bucket === 'overdue' && request.can_reply && (
        <Notice tone="alert" title="已超過回覆期限">
          仍然可以回覆。回覆或結案後才會移出待處理。
        </Notice>
      )}
      {request.suspicious && (
        <Notice tone="alert" title="對方可能不是這個寄件人">
          這封信沒有通過寄件人驗證。不要照信裡的要求提供資料或改帳號。可以回覆或結案，回覆會寄到寄件地址。
        </Notice>
      )}
      {!request.can_reply && item.kind === 'privacy' && (
        <Notice title="現在還不能回覆">確認信已寄到登入 email。對方按下「是我」後，這筆才會回到清單。</Notice>
      )}
      {!request.can_reply && item.kind === 'account_deletion' && (
        <Notice title="不需要回覆">
          確認和刪除都由系統處理。聯絡 email 只收到固定回條，不要回覆是否找到帳號。
        </Notice>
      )}
      {request.can_reply && item.kind === 'privacy' && (
        <Notice title="只寄到登入 email">回覆會寄到 {replyTo}，不會寄到對方填的聯絡 email。</Notice>
      )}
      {failedSend && (
        <Notice tone="alert" title="回覆沒有寄出">
          系統已試了 <span className="num">5</span>{' '}
          次，對方沒有收到。地址是對方填的，這裡不能改；地址有誤就結案。
          {item.kind === 'privacy' && '個資權利請求只寄到登入 email。'}
        </Notice>
      )}
    </>
  );
}

export function SupportBody({
  detail,
  now,
  pending,
}: {
  detail: SupportRequestDetail;
  now: number;
  pending: PendingReply[];
}) {
  const auth = useAuthController();
  const { request } = detail;
  const rows: [string, React.ReactNode][] = [
    ['聯絡 email', request.contact_email],
    [
      '送出時間',
      <>
        <span className="num">{dateTime(request.created_at, now)}</span>，{SOURCE_NAME[request.source]}
      </>,
    ],
  ];
  if (request.subject) rows.push(['主旨', request.subject]);
  if (request.login_email) rows.push(['登入 email', request.login_email]);
  if (request.account_hint) rows.push(['帳號線索', request.account_hint]);
  if (request.privacy_right) {
    rows.push([
      '請求項目',
      <Tag key="r" tag={{ label: PRIVACY_RIGHT[request.privacy_right] ?? '', tone: 'outline' }} />,
    ]);
  }
  return (
    <>
      <DefinitionList rows={rows} />
      {auth ? (
        <MineLabel controller={auth}>
          {(meId) => <CaseLog detail={detail} now={now} meId={meId} pending={pending} />}
        </MineLabel>
      ) : (
        <CaseLog detail={detail} now={now} meId={null} pending={pending} />
      )}
    </>
  );
}

/** Which action can 再寄一次, if any: only a reply whose mail failed for good. */
export const failedReply = (actions: readonly CaseAction[]) =>
  actions.find((a) => a.action === 'reply' && a.message_id !== null && a.delivery_status === 'failed');

/** The reply bubbles shown while waiting: this tab's and ones already running. */
export function pendingReplies(
  actions: readonly TrackedAction[],
  drafts: Record<string, string>,
  replyTo: string | null,
  cancel: (id: string) => void,
  now: number,
): PendingReply[] {
  return actions
    .filter((a) => a.action === 'reply' && (a.phase === 'counting' || a.phase === 'sending'))
    .map((action) => {
      const seconds = Math.max(0, Math.ceil((action.deadline - now) / 1000));
      const to = replyTo ?? '對方';
      return {
        id: action.id,
        body: drafts[action.id] ?? action.draft?.reply ?? '',
        line: action.phase === 'counting' ? `${seconds} 秒後寄到 ${to}` : `寄送中，寄到 ${to}`,
        onCancel: action.phase === 'counting' ? () => cancel(action.id) : null,
      };
    });
}
