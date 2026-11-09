import { useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate, useParams, useSearchParams } from 'react-router';
import {
  adminV1,
  useAdminV1CaseActionsQuery,
  useAdminV1ContentReportQuery,
  useAdminV1SupportRequestQuery,
  useAdminV1TimedCaseQuery,
  type CaseAction,
  type ContentReport,
  type SupportRequestDetail,
  type TimedCase,
} from '../api/v1/admin_v1.generated';
import type { V1Error } from '../api/v1/base';
import { useAppDispatch, useAppSelector, useAppStore } from '../app/hooks';
import { useAuthController } from '../auth/AuthContext';
import { useIsPhone } from '../review/hooks';
import { Button } from '../ui/controls';
import { EmptyState } from '../ui/EmptyState';
import { LineIcon } from '../ui/icons';
import {
  actionTracked,
  cancelAction,
  draftChanged,
  draftRestored,
  liveActionsOf,
  localDeadline,
  retryReply,
  scheduleAction,
  type RunResult,
} from './actionsSlice';
import { needsSecondFactor, usePendingCounts, useTimedCasePagesInfiniteQuery } from './api';
import { draftFromPayload, describeAction, type ActionKind, type CaseDraft } from './caseCopy';
import { Alert, Notice, SecondFactorNeeded, Tag } from './CaseParts';
import { ConfirmResolvePanel, EditPanel, KeepPanel, ResolvePanel, RestorePanel } from './CasePanels';
import { caseHeadTags, caseNumber, caseTitle, dueDate, parseTab } from './model';
import { ReportBody, ReportNotices } from './ReportCase';
import { failedReply, pendingReplies, SupportBody, SupportNotices } from './SupportCase';
import { useTick } from './useCaseEffects';
import './Case.css';

const FOREIGN_POLL_MS = 2_000;

type PanelName = 'resolve' | 'confirm-resolve' | 'restore' | 'keep' | 'edit' | null;

interface Conflict {
  title: string;
  body: string;
  /** `reload` reads again; `force` (點位已被修改) re-sends what was entered. */
  kind: 'reload' | 'force' | 'plain' | 'factor';
  reloaded?: boolean;
}

const REPLY_LOST = '你的回覆沒有寄出，內容還在回覆框。先看過最新內容，再決定要不要寄。';
const WORK_LOST = '你的處理沒有套用，填的內容還在。先看過最新內容，再決定要不要處理。';

function parseDetails(details: string | null): Record<string, unknown> {
  if (!details) return {};
  try {
    return JSON.parse(details) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function conflictOf(error: V1Error, action: ActionKind, repliesSent: number): Conflict {
  const lost = action === 'reply' ? REPLY_LOST : WORK_LOST;
  switch (error.message) {
    case 'auth.aal2_required':
      return { kind: 'factor', title: '', body: '' };
    case 'case.stale':
    case 'content_report.stale': {
      const by = error.message === 'content_report.stale' ? 'spot_edited' : parseDetails(error.details).by;
      if (by === 'spot_edited') {
        return {
          kind: 'force',
          title: '儲存前，這個點位已被修改',
          body: '你的處理沒有套用，案件已回到清單並標示「沒有套用」，填的內容還在。先重新讀取最新資料，再決定是否仍然套用。',
        };
      }
      return {
        kind: 'reload',
        title: by === 'user_reply' ? '對方剛補充了內容' : '這筆已由其他管理員處理',
        body: lost,
      };
    }
    case 'support.already_resolved':
    case 'content_report.already_resolved':
      return { kind: 'reload', title: '這筆已由其他管理員處理', body: lost };
    case 'support.reply_limited':
      return repliesSent >= 50
        ? { kind: 'plain', title: '這個案件不能再回覆', body: '每個案件總共最多 50 則，已經用完。請結案。' }
        : {
            kind: 'plain',
            title: '今天不能再回覆這個案件',
            body: '每個案件每天最多 10 則。內容還在，明天可以再寄，也可以先結案。',
          };
    case 'support.reply_not_allowed':
      return { kind: 'plain', title: '現在不能回覆這個案件', body: '這個案件由系統處理或還沒確認本人。' };
    case 'case_action.not_retryable':
    case 'case_action.retry_limit':
      return { kind: 'reload', title: '這則回覆不能再寄一次', body: '寄送狀態已經改變，請重新讀取。' };
    case 'content_report.invalid_patch':
    case 'content_report.name_required':
    case 'content_report.reason_required':
    case 'request.invalid':
      return {
        kind: 'plain',
        title: '內容不符合要求',
        body: '名稱和文字不能留空，名稱最多 100 字、其他欄位最多 500 字。',
      };
    case 'client.network':
      return { kind: 'plain', title: '連線中斷', body: '這次沒有送出，填的內容還在。連線恢復後再試一次。' };
    default:
      return { kind: 'plain', title: '沒有送出', body: '這次沒有送出，填的內容還在。請再試一次。' };
  }
}

function ConflictBanner({
  conflict,
  onReload,
  onForce,
}: {
  conflict: Conflict;
  onReload: () => void;
  onForce: () => void;
}) {
  return (
    <div className="case-conflict">
      <Alert title={conflict.title}>{conflict.body}</Alert>
      {(conflict.kind === 'reload' || conflict.kind === 'force') && (
        <div className="pending-state__actions">
          <Button variant="primary" onClick={onReload} disabled={conflict.reloaded}>
            {conflict.kind === 'force' ? '重新讀取最新資料' : '重新讀取'}
          </Button>
          {conflict.kind === 'force' && (
            <Button onClick={onForce} disabled={!conflict.reloaded}>
              仍然套用
            </Button>
          )}
        </div>
      )}
    </div>
  );
}

function ClosedCase({ draft, backTo }: { draft: CaseDraft | undefined; backTo: string }) {
  return (
    <div className="pending-pane">
      <EmptyState title="這筆案件已經處理完">
        <p>它不在待處理清單裡了。</p>
      </EmptyState>
      {draft?.reply && (
        <section className="case-section" aria-label="沒有寄出的回覆">
          <h2 className="t-title">你沒有寄出的回覆</h2>
          <p className="case-message__body">{draft.reply}</p>
        </section>
      )}
      <div>
        <Link className="btn btn--secondary" to={backTo}>
          返回清單
        </Link>
      </div>
    </div>
  );
}

interface CaseViewProps {
  item: TimedCase;
  support: SupportRequestDetail | undefined;
  report: ContentReport | undefined;
  serverActions: CaseAction[];
  reload: () => Promise<void>;
  remaining: number | undefined;
}

function CaseView({ item, support, report, serverActions, reload, remaining }: CaseViewProps) {
  const caseId = item.id;
  const dispatch = useAppDispatch();
  const store = useAppStore();
  const navigate = useNavigate();
  const location = useLocation();
  const [params] = useSearchParams();
  const isPhone = useIsPhone();
  const auth = useAuthController();
  const list = useTimedCasePagesInfiniteQuery(parseTab(params.get('tab')));

  const actions = useAppSelector((state) => state.pendingActions.actions);
  const seen = useAppSelector((state) => state.pendingActions.seen);
  const draft: CaseDraft = useAppSelector((state) => state.pendingActions.drafts[caseId]) ?? {};
  const live = liveActionsOf(actions, caseId);
  const now = useTick(live.length > 0);

  const [panel, setPanel] = useState<PanelName>(null);
  const [busy, setBusy] = useState(false);
  const [conflict, setConflict] = useState<Conflict | null>(null);
  const lastAttempt = useRef<(() => Promise<void>) | null>(null);
  const titleRef = useRef<HTMLHeadingElement>(null);

  const search = location.search;
  const isSupport = item.type === 'support';
  const request = support?.request;
  const replyTo = request?.reply_to ?? null;
  const count = report?.reports.length ?? item.report_count ?? 1;
  const hidden = (report?.content_held.length ?? item.hidden_parts?.length ?? 0) > 0;
  const onDraft = (patch: Partial<CaseDraft>) => dispatch(draftChanged({ caseId, patch }));

  // Follow what the server already has for this case: a reload during a
  // countdown, or another tab's action. Another admin's is shown, not adopted.
  const me = auth?.getState().access.userId ?? null;
  useEffect(() => {
    for (const action of serverActions) {
      if (action.status !== 'scheduled' && action.status !== 'running') continue;
      if (action.actor !== me && me !== null) continue;
      if (seen.includes(action.id)) continue;
      dispatch(
        actionTracked({
          id: action.id,
          caseId: item.id,
          action: action.action,
          labels: describeAction({
            action: action.action,
            item,
            replyTo,
            resolveStatus: (action.payload as { status?: 'done' | 'rejected' }).status,
          }),
          deadline: localDeadline(store.getState(), action.run_at),
          irreversible: action.irreversible,
          draft: draftFromPayload(action.action, action.payload as Record<string, unknown>),
          expectedVersion: action.message_id ? undefined : action.expected_version,
          quiet: true,
          now: Date.now(),
        }),
      );
    }
  }, [serverActions, seen, me, item, replyTo, dispatch, store]);

  // After a reload the only copy of an unsent reply is the server's.
  const latest = serverActions[0];
  useEffect(() => {
    if (!latest || (latest.status !== 'stale' && latest.status !== 'failed')) return;
    const payload = latest.payload as Record<string, unknown>;
    if (Object.keys(payload).length === 0) return;
    dispatch(draftRestored({ actionId: latest.id, caseId, draft: draftFromPayload(latest.action, payload) }));
  }, [latest, caseId, dispatch]);

  // Next-case focus: the title, read after the case is on screen.
  useEffect(() => {
    if ((location.state as { focus?: string } | null)?.focus === 'case') titleRef.current?.focus();
  }, [location.state]);

  const goNext = () => {
    const items = list.currentData?.pages.flatMap((page) => page.items) ?? [];
    const taken = new Set(
      store
        .getState()
        .pendingActions.actions.filter((a) => a.phase === 'counting' || a.phase === 'sending')
        .map((a) => a.caseId),
    );
    taken.add(caseId);
    const index = items.findIndex((row) => row.id === caseId);
    const order = [...items.slice(index + 1), ...items.slice(0, Math.max(index, 0))];
    const next = order.find((row) => !taken.has(row.id) && row.state !== 'scheduled');
    if (next) {
      void navigate(`/pending/${encodeURIComponent(next.id)}${search}`, { state: { focus: 'case' } });
    } else {
      void navigate(`/pending${search}`, { state: { focus: 'list' } });
    }
  };

  const attempt = async (action: ActionKind, send: () => Promise<RunResult>) => {
    setBusy(true);
    setConflict(null);
    const result = await send();
    setBusy(false);
    // Also on failure: a sheet would cover the banner, and the form is in the draft.
    setPanel(null);
    if (result.ok) {
      goNext();
      return;
    }
    const sent = support?.messages.filter((m) => m.direction === 'out').length ?? 0;
    setConflict(conflictOf(result.error, action, sent));
  };

  /** The row as of now: a reload may have brought a newer version. */
  const currentItem = () =>
    adminV1.endpoints.adminV1TimedCase.select({ body: { p_id: caseId } })(store.getState()).data ?? item;

  const run = (action: ActionKind, payload: Record<string, unknown>, resolveStatus?: 'done' | 'rejected') => {
    const send = () =>
      attempt(action, () =>
        dispatch(scheduleAction(currentItem(), action, payload, { replyTo, resolveStatus })),
      );
    lastAttempt.current = send;
    void send();
  };

  const reloadAndNote = async () => {
    await reload();
    setConflict((current) =>
      current?.kind === 'force'
        ? { ...current, reloaded: true }
        : current?.kind === 'reload'
          ? null
          : current,
    );
  };

  const failedAction = failedReply(serverActions, support?.messages ?? []);
  const failedSend =
    item.state === 'send_failed' && isSupport && (failedAction !== undefined || item.pending_action === null);
  const canReply = request?.can_reply === true && !failedAction;
  const othersScheduled = serverActions.filter(
    (a) => (a.status === 'scheduled' || a.status === 'running') && !actions.some((t) => t.id === a.id),
  );
  const locked = busy || live.length > 0 || othersScheduled.length > 0;
  const trimmedReply = (draft.reply ?? '').trim();

  const pending = pendingReplies(
    live,
    Object.fromEntries(serverActions.map((a) => [a.id, (a.payload as { body?: string }).body ?? ''])),
    replyTo,
    (id) => void dispatch(cancelAction(id)),
    now,
  );

  const staleNotice =
    !conflict && latest?.status === 'stale' && live.length === 0 ? (
      <Notice tone="alert" title={isSupport ? '這筆案件有新的變動' : '這個點位已被修改'}>
        {latest.action === 'reply' ? REPLY_LOST : WORK_LOST}
      </Notice>
    ) : null;

  const failedNotice =
    !conflict && latest?.status === 'failed' && !failedAction && live.length === 0 ? (
      <Notice tone="alert" title={latest.action === 'reply' ? '回覆沒有寄出' : '處理沒有套用'}>
        {latest.error === 'support.reply_limited'
          ? '今天或這個案件的回覆次數已用完。內容還在回覆框。'
          : latest.action === 'reply'
            ? '這則回覆沒有寄出，內容還在回覆框。可以再試一次。'
            : '這次處理沒有完成，填的內容還在。可以再試一次。'}
      </Notice>
    ) : null;

  const openPanel = (next: PanelName) => setPanel(next);
  const closePanel = () => setPanel(null);
  const panelContext = { sheet: isPhone, draft, onDraft, busy, onClose: closePanel };
  const changedReport =
    report !== undefined && JSON.stringify(report.snapshot) !== JSON.stringify(report.current);

  const panelNode = (() => {
    switch (panel) {
      case 'confirm-resolve':
        return (
          <ConfirmResolvePanel sheet={isPhone} onClose={closePanel} onContinue={() => setPanel('resolve')} />
        );
      case 'resolve':
        return (
          <ResolvePanel
            {...panelContext}
            onSubmit={(status, note) => run('resolve_support', { status, note }, status)}
          />
        );
      case 'restore':
        return (
          <RestorePanel
            {...panelContext}
            hidden={hidden}
            count={count}
            changed={changedReport}
            onSubmit={(reason, note) => run('report_restore', { reason, note })}
          />
        );
      case 'keep':
        return (
          <KeepPanel
            {...panelContext}
            item={item}
            count={count}
            onSubmit={(name) => run('report_keep', { patch: name === null ? {} : { name }, note: '' })}
          />
        );
      case 'edit':
        return report ? (
          <EditPanel
            {...panelContext}
            report={report}
            hidden={hidden}
            onSubmit={(patch) => run('report_edit', { patch, note: '' })}
          />
        ) : null;
      default:
        return null;
    }
  })();

  const backLabel = remaining === undefined ? '返回待處理' : `返回待處理，還有 ${remaining} 筆`;
  const confirmed = Boolean(request?.email_confirmed_at);

  return (
    <article className="case" aria-label="案件內容">
      <header className="case-bar">
        <Link to={`/pending${search}`} className="case-bar__back" aria-label={backLabel}>
          <LineIcon name="arrow" style={{ transform: 'scaleX(-1)' }} />
        </Link>
        待處理
        {remaining !== undefined && <span className="num">{remaining}</span>}
      </header>

      <div className="case__body">
        <header className="case-head">
          <h2 ref={titleRef} tabIndex={-1} className="t-headline case-head__title">
            {caseTitle(item)}
          </h2>
          <div className="case-head__meta t-caption">
            <span className="num">{caseNumber(item)}</span>
            {caseHeadTags(item, now, confirmed).map((tag) => (
              <Tag key={tag.label} tag={tag} />
            ))}
            <span>
              {isSupport ? '回覆期限' : '處理期限'} <span className="num">{dueDate(item.due_at, now)}</span>
              {item.bucket === 'today' && '（今天）'}
            </span>
          </div>
        </header>

        {conflict?.kind === 'factor' && (
          <SecondFactorNeeded
            onRetry={() => {
              setConflict(null);
              void reload();
            }}
          />
        )}
        {conflict && conflict.kind !== 'factor' && (
          <ConflictBanner
            conflict={conflict}
            onReload={() => void reloadAndNote()}
            onForce={() => void lastAttempt.current?.()}
          />
        )}
        {staleNotice}
        {failedNotice}
        {othersScheduled.length > 0 && (
          <Notice title="這筆有排定的處理">其他管理員或分頁已排定處理，完成前不能操作。</Notice>
        )}

        {isSupport && support && (
          <SupportNotices item={item} request={support.request} failedSend={failedSend} />
        )}
        {!isSupport && report && <ReportNotices item={item} report={report} />}

        {isSupport && support && <SupportBody detail={support} now={now} pending={pending} />}
        {!isSupport && report && <ReportBody report={report} now={now} />}

        {isSupport && canReply && (
          <div className="case-field">
            <label htmlFor="case-reply" className="t-label">
              回覆
            </label>
            <textarea
              id="case-reply"
              rows={4}
              maxLength={4000}
              placeholder="寫給對方的回覆"
              value={draft.reply ?? ''}
              readOnly={live.length > 0}
              onChange={(event) => onDraft({ reply: event.target.value })}
            />
            <span className="t-caption">會寄到 {replyTo}。回覆裡不要提到這個 email 有沒有帳號。</span>
          </div>
        )}

        {!isPhone && panelNode}
      </div>

      <ActionBar
        item={item}
        report={report}
        canReply={canReply}
        retryable={failedAction}
        isSupport={isSupport}
        systemHandled={isSupport && request !== undefined && !request.can_reply}
        locked={locked}
        hasReply={trimmedReply.length > 0}
        onSendReply={() => run('reply', { body: trimmedReply })}
        onRetry={() => {
          const action = failedAction;
          if (!action) return;
          const send = () => attempt('reply', () => dispatch(retryReply(item, action.id, replyTo)));
          lastAttempt.current = send;
          void send();
        }}
        onResolve={() => openPanel(trimmedReply && canReply ? 'confirm-resolve' : 'resolve')}
        onCloseDeleted={() => run('report_restore', { reason: 'outdated', note: '點位已刪除，內容已不存在' })}
        onPanel={openPanel}
        hint={
          isSupport && canReply
            ? '5 秒後寄出，時間內可以取消'
            : !isSupport && !report?.spot_deleted
              ? '處理後跳到下一筆，時間內可以取消'
              : null
        }
      />

      {isPhone && panelNode}
    </article>
  );
}

function ActionBar({
  item,
  report,
  canReply,
  retryable,
  isSupport,
  systemHandled,
  locked,
  hasReply,
  onSendReply,
  onRetry,
  onResolve,
  onCloseDeleted,
  onPanel,
  hint,
}: {
  item: TimedCase;
  report: ContentReport | undefined;
  canReply: boolean;
  retryable: CaseAction | undefined;
  isSupport: boolean;
  systemHandled: boolean;
  locked: boolean;
  hasReply: boolean;
  onSendReply: () => void;
  onRetry: () => void;
  onResolve: () => void;
  onCloseDeleted: () => void;
  onPanel: (name: PanelName) => void;
  hint: string | null;
}) {
  const barRef = useRef<HTMLDivElement>(null);

  // The dock and the phone layout sit above the bar's real height.
  useEffect(() => {
    const bar = barRef.current;
    const root = bar?.closest<HTMLElement>('.pending');
    if (!bar || !root) return undefined;
    const apply = () =>
      root.style.setProperty('--case-actions-height', `${bar.getBoundingClientRect().height}px`);
    apply();
    if (typeof ResizeObserver === 'undefined') return undefined;
    const observer = new ResizeObserver(apply);
    observer.observe(bar);
    return () => {
      observer.disconnect();
      root.style.removeProperty('--case-actions-height');
    };
  }, [systemHandled]);

  if (systemHandled) return null;
  const spotDeleted = report?.spot_deleted === true;
  return (
    <div ref={barRef} role="group" aria-label="處理" className="case__actions">
      {isSupport && canReply && (
        <Button variant="primary" disabled={locked || !hasReply} onClick={onSendReply}>
          寄出回覆
        </Button>
      )}
      {isSupport && retryable && (
        <Button variant="primary" disabled={locked} onClick={onRetry}>
          再寄一次
        </Button>
      )}
      {isSupport && (
        <Button disabled={locked} onClick={onResolve}>
          結案
        </Button>
      )}
      {!isSupport && spotDeleted && (
        <Button disabled={locked} onClick={onCloseDeleted}>
          結案
        </Button>
      )}
      {!isSupport && !spotDeleted && report && (
        <>
          <Button disabled={locked} onClick={() => onPanel('restore')}>
            檢舉不成立
          </Button>
          <Button variant="destructive" disabled={locked} onClick={() => onPanel('keep')}>
            檢舉成立
          </Button>
          {item.kind !== 'rider_name' && (
            <Button disabled={locked} onClick={() => onPanel('edit')}>
              改內容
            </Button>
          )}
        </>
      )}
      {hint && <span className="t-caption case__hint">{hint}</span>}
    </div>
  );
}

/** Row, then the case's own content: an unknown id ends at the row. */
export function PendingCase() {
  const { caseId = '' } = useParams();
  return <CaseLoader key={caseId} caseId={caseId} />;
}

function CaseLoader({ caseId }: { caseId: string }) {
  const { search } = useLocation();
  const counts = usePendingCounts();
  const remaining = counts.isError ? undefined : counts.data?.all;
  const draft = useAppSelector((state) => state.pendingActions.drafts[caseId]);
  const live = useAppSelector((state) => liveActionsOf(state.pendingActions.actions, caseId).length);

  const options = {
    refetchOnMountOrArgChange: true,
    refetchOnFocus: true,
    refetchOnReconnect: true,
  } as const;
  const row = useAdminV1TimedCaseQuery({ body: { p_id: caseId } }, options);
  const item = row.currentData;
  const support = useAdminV1SupportRequestQuery(
    { body: { p_id: caseId } },
    { ...options, skip: item?.type !== 'support' },
  );
  const report = useAdminV1ContentReportQuery(
    { body: { p_id: caseId } },
    { ...options, skip: item?.type !== 'report' },
  );
  // Someone else's countdown is on no watcher: keep reading until it ends.
  const foreign = useAppSelector((state) => {
    const tracked = new Set(state.pendingActions.actions.map((a) => a.id));
    const listed = adminV1.endpoints.adminV1CaseActions.select({ body: { p_case: caseId } })(state).data;
    return (listed ?? []).filter(
      (a) => (a.status === 'scheduled' || a.status === 'running') && !tracked.has(a.id),
    ).length;
  });
  const actions = useAdminV1CaseActionsQuery(
    { body: { p_case: caseId } },
    { ...options, skip: !item, pollingInterval: foreign > 0 ? FOREIGN_POLL_MS : 0 },
  );

  const reload = async () => {
    await row.refetch();
    if (item?.type === 'support') await support.refetch();
    else if (item?.type === 'report') await report.refetch();
    if (item) await actions.refetch();
  };

  // A live action on this case just ended: everything about it changed.
  const lastBusy = useRef(live + foreign);
  useEffect(() => {
    if (lastBusy.current > live + foreign) void reload();
    lastBusy.current = live + foreign;
  });

  const error = (row.error ?? support.error ?? report.error ?? actions.error) as V1Error | undefined;
  if (needsSecondFactor(error)) {
    return (
      <div className="pending-pane">
        <SecondFactorNeeded onRetry={() => void reload()} />
      </div>
    );
  }
  const code = (row.error as V1Error | undefined)?.message;
  if (code === 'case.not_found' || code === 'request.invalid') {
    return <ClosedCase draft={draft} backTo={`/pending${search}`} />;
  }
  const loading =
    !item || (item.type === 'support' ? !support.currentData : !report.currentData) || !actions.currentData;
  if (error && loading) {
    return (
      <div className="pending-pane">
        <div className="pending-state">
          <Alert title="讀不到這筆案件">這不代表案件不存在。請再試一次。</Alert>
          <div className="pending-state__actions">
            <Button variant="primary" onClick={() => void reload()}>
              重試
            </Button>
          </div>
        </div>
      </div>
    );
  }
  if (loading) {
    return (
      <div className="pending-pane">
        <div role="status" aria-label="正在讀取案件" className="pending-skeleton">
          <div aria-hidden="true" />
          <div aria-hidden="true" />
          <div aria-hidden="true" />
        </div>
      </div>
    );
  }

  return (
    <CaseView
      item={item}
      support={support.currentData}
      report={report.currentData}
      serverActions={actions.currentData ?? []}
      reload={reload}
      remaining={remaining}
    />
  );
}
