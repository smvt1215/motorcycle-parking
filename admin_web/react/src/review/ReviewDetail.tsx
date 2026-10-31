import { useEffect, useId, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { useAppDispatch, useAppSelector } from '../app/hooks';
import { Button, ModifiedTag, SourceTag } from '../ui/controls';
import { STATUS_LABEL, VEHICLE_LABEL, VEHICLES } from '../ui/eligibility';
import { LineIcon } from '../ui/icons';
import { PlateStack } from '../ui/PlateStack';
import { actionVerb } from './decisionText';
import { EditPanel } from './EditPanel';
import { neighbourOf, useIsPhone, useKindFilter, useReviewQueue } from './hooks';
import {
  applyPlan,
  diffRows,
  editOutcome,
  editStart,
  isOfficial,
  needsRejectNote,
  plateOf,
  proposedMove,
  RESOLUTION_KINDS,
  riderText,
  shortDateTime,
  spotArea,
  spotName,
  type ApplyPlan,
  type ResolutionKind,
  type ReviewReport,
  type ReviewSpot,
} from './model';
import { RejectPanel } from './RejectPanel';
import {
  decisionQueued,
  failureDismissed,
  noteChanged,
  reloadForConflict,
  type FailedDecision,
} from './reviewSlice';
import type { ResolveRequest } from './source';
import { UndoNotice } from './UndoNotice';

/** 普通機車／大型重機: current plate → proposed plate (Main.dc.html 資格變更). */
function EligibilityChange({ report, spot }: { report: ReviewReport; spot: ReviewSpot | undefined }) {
  const proposed = report.proposed ?? {};
  const heavyChanges = 'heavy_allowed' in proposed && proposed.heavy_allowed !== spot?.values.heavy_allowed;
  return (
    <section className="panel eligibility-change" aria-label="資格變更">
      {VEHICLES.map((vehicle) => {
        const key = `${vehicle}_allowed`;
        const from = plateOf(spot?.values[key]);
        const changes = key in proposed && proposed[key] !== spot?.values[key];
        const to = plateOf(proposed[key]);
        return (
          <div key={vehicle} className="eligibility-change__row">
            <span className="eligibility-change__vehicle t-title">{VEHICLE_LABEL[vehicle]}</span>
            <PlateStack
              vehicle={vehicle}
              status={from}
              size="large"
              label={changes ? `目前${STATUS_LABEL[from]}` : STATUS_LABEL[from]}
            />
            {changes ? (
              <>
                <LineIcon name="arrow" size={24} strokeWidth={2} className="muted" />
                <PlateStack
                  vehicle={vehicle}
                  status={to}
                  size="large"
                  label={`建議改為${STATUS_LABEL[to]}`}
                />
                <span className="t-title">建議改為{STATUS_LABEL[to]}</span>
              </>
            ) : (
              <span className="muted">維持{STATUS_LABEL[from]}</span>
            )}
          </div>
        );
      })}
      {heavyChanges && !spot?.official && (
        <p className="t-caption">
          重機資格只採官方說法。這是社群點，套用後會標示「車友回報」與日期，不會變成官方可停。
        </p>
      )}
    </section>
  );
}

/** 欄位／目前／建議, changed rows first; untouched ones fold away. */
function DiffTable({ report, spot }: { report: ReviewReport; spot: ReviewSpot | undefined }) {
  const [showAll, setShowAll] = useState(false);
  const rows = diffRows(report, spot);
  const changed = rows.filter((r) => r.changed);
  const unchanged = rows.filter((r) => !r.changed);
  if (rows.length === 0) return null;
  const shown = showAll ? [...changed, ...unchanged] : changed;
  return (
    <section className="panel diff" aria-label="其他欄位差異">
      {shown.length > 0 && (
        <div className="diff__scroll">
          <table className="diff__table">
            <thead>
              <tr>
                <th scope="col">欄位</th>
                <th scope="col">目前</th>
                <th scope="col">建議</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((row) => (
                <tr key={row.key}>
                  <th scope="row">{row.label}</th>
                  <td className="muted">{row.current}</td>
                  <td className={row.changed ? 'diff__changed' : undefined}>
                    {row.proposed}
                    {row.changed && <ModifiedTag />}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {unchanged.length > 0 && (
        <Button variant="quiet" className="diff__toggle" onClick={() => setShowAll(!showAll)}>
          {showAll ? (
            '收起沒有修改的欄位'
          ) : (
            <>
              顯示沒有修改的 <span className="num">{unchanged.length}</span> 個欄位
            </>
          )}
        </Button>
      )}
    </section>
  );
}

const errorText = (failure: FailedDecision): { title: string; body: string } => {
  const verb = actionVerb(failure.request);
  switch (failure.error.code) {
    case 'network':
      return {
        title: `沒有${verb}：連不上伺服器`,
        body: '這筆回報維持待審，你填的處理說明還在。檢查網路後再試一次。',
      };
    case 'timeout':
      return {
        title: `沒有${verb}：伺服器太久沒有回應`,
        body: '這筆回報維持待審，你填的處理說明還在。稍後再試一次。',
      };
    case 'stale':
      return {
        title: '儲存前，這個點位已被修改',
        body: '回報送出後，點位又被改過。先重新讀取最新資料，確認建議仍然適用再套用。',
      };
    case 'alreadyResolved':
      return { title: '這筆回報已經處理過了', body: '' };
    default:
      return {
        title: `沒有${verb}：伺服器拒絕了這次修改`,
        body: '這筆回報維持待審，你填的處理說明還在。',
      };
  }
};

const PLAN_TEXT: Record<Exclude<ApplyPlan, { ok: true }>['reason'], string> = {
  missingSpot: '找不到這個點位，可能已刪除，只能駁回。',
  structured:
    '這筆建議包含費率、停放條件、暫時封閉或分區分段，新版管理站還不能套用；可以駁回，或用目前的管理站處理。',
  empty: '這筆回報沒有可以套用到這個點位的欄位。',
};

type Mode = 'view' | 'reject' | 'edit';

const isTyping = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  target.closest('input, textarea, select, [contenteditable="true"]') !== null;

/** The report on the right, or the whole screen on a phone. Keyed by report, so modes never leak. */
export function ReviewDetail() {
  const { reportId = '' } = useParams();
  return <ReportDetail key={reportId} reportId={reportId} />;
}

function ReportDetail({ reportId }: { reportId: string }) {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const isPhone = useIsPhone();
  const [, , search] = useKindFilter();
  const { query, visible, open, spots } = useReviewQueue();
  const note = useAppSelector((state) => state.review.notes[reportId] ?? '');
  const failure = useAppSelector((state) => state.review.failures[reportId]);
  const reloaded = useAppSelector((state) => reportId in state.review.reloaded);
  const pendingDecision = useAppSelector((state) => state.review.pending[reportId]);
  const noteId = useId();

  const [mode, setMode] = useState<Mode>('view');
  const [rejectKind, setRejectKind] = useState<ResolutionKind | null>(null);
  const [editValues, setEditValues] = useState<Record<string, unknown>>({});
  const [showErrors, setShowErrors] = useState(false);
  const [editMessage, setEditMessage] = useState<string | null>(null);

  const report = open.find((r) => r.id === reportId);
  const spot = report ? spots[report.sourceId] : undefined;
  const plan = report ? applyPlan(report, spot) : null;
  const canEdit = Boolean(spot) && !(plan && !plan.ok && plan.reason === 'structured');
  const outcome = report && spot && mode === 'edit' ? editOutcome(report, spot, editValues) : null;
  const position = visible.findIndex((r) => r.id === reportId);

  const setNote = (value: string) => dispatch(noteChanged({ reportId, note: value }));

  const goNext = () => {
    const next = neighbourOf(visible, reportId);
    navigate(next && next.id !== reportId ? `/review/${next.id}${search}` : `/review${search}`);
  };

  /** Queue a decision (5 s undo window) and move to the next report. */
  const queue = (request: ResolveRequest) => {
    if (!report) return;
    const next = neighbourOf(visible, reportId);
    dispatch(decisionQueued({ request, name: spotName(report, spot) }));
    navigate(next ? `/review/${next.id}${search}` : `/review${search}`);
  };

  const apply = (force: boolean) => {
    if (!plan?.ok) return;
    queue({ reportId, decision: 'accepted', patch: plan.patch, edited: false, note: note.trim(), force });
  };

  const startReject = () => {
    setMode('reject');
    setShowErrors(false);
  };

  const confirmReject = () => {
    setShowErrors(true);
    if (rejectKind === null || needsRejectNote(rejectKind, note)) return;
    queue({ reportId, decision: 'rejected', resolutionKind: rejectKind, note: note.trim() });
  };

  const startEdit = () => {
    if (!report || !spot || !canEdit) return;
    setEditValues(editStart(report, spot));
    setShowErrors(false);
    setEditMessage(null);
    setMode('edit');
  };

  const saveEdit = () => {
    if (!outcome) return;
    setShowErrors(true);
    if (Object.keys(outcome.errors).length > 0) {
      setEditMessage('有欄位還不能儲存，先改好標紅的欄位。');
      return;
    }
    if (Object.keys(outcome.patch).length === 0) {
      setEditMessage('套用值和目前點位一樣，沒有要寫入的修改；不需要修改就用「駁回」結案。');
      return;
    }
    queue({
      reportId,
      decision: 'accepted',
      patch: outcome.patch,
      edited: true,
      note: note.trim(),
      force: false,
    });
  };

  const cancelMode = () => {
    setMode('view');
    setShowErrors(false);
    setEditMessage(null);
  };

  const retry = (force: boolean) => {
    if (!failure) return;
    const request = failure.request;
    queue(request.decision === 'accepted' ? { ...request, force } : request);
  };

  // Shortcuts (Palette.dc.html, ReviewReject / ReviewEdit boards). Letters and
  // digits are ignored while typing; Esc and Ctrl+Enter work everywhere.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.repeat || event.altKey) return;
      if (event.key === 'Escape' && mode !== 'view') {
        event.preventDefault();
        cancelMode();
        return;
      }
      if (mode === 'edit') {
        if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
          event.preventDefault();
          saveEdit();
        }
        return;
      }
      if (event.ctrlKey || event.metaKey) return;
      if (mode === 'reject') {
        if (event.target instanceof HTMLTextAreaElement) return;
        const digit = Number(event.key);
        if (Number.isInteger(digit) && digit >= 1 && digit <= RESOLUTION_KINDS.length) {
          event.preventDefault();
          setRejectKind(RESOLUTION_KINDS[digit - 1]!.kind);
        } else if (event.key === 'Enter') {
          event.preventDefault();
          confirmReject();
        }
        return;
      }
      if (isTyping(event.target) || !report || failure) return;
      const key = event.key.toLowerCase();
      if (key === 'a' && plan?.ok) {
        event.preventDefault();
        apply(false);
      } else if (key === 'e' && canEdit) {
        event.preventDefault();
        startEdit();
      } else if (key === 'r') {
        event.preventDefault();
        startReject();
      } else if (key === 'j') {
        event.preventDefault();
        goNext();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  });

  // Wide screens show loading and failure in the queue beside this pane; a
  // phone hides the queue while a report is open, so the detail says it
  // itself and offers retry and a way back (Codex review, PR #214).
  if (!query.isSuccess) {
    if (!isPhone) return null;
    return (
      <section className="review-done" aria-label={query.isError ? '讀取失敗' : '正在讀取'}>
        {query.isError ? (
          <div className="review-alert" role="alert">
            <p className="t-title">讀取失敗</p>
            <p>
              {(query.error as { code?: string }).code === 'timeout'
                ? '超過 10 秒還沒讀到這筆回報。'
                : '連不上伺服器，沒有讀到這筆回報。'}
            </p>
            <div className="review-alert__actions">
              <Button variant="primary" onClick={() => void query.refetch()}>
                重試
              </Button>
              <Link className="btn btn--secondary" to={`/review${search}`}>
                回到清單
              </Link>
            </div>
          </div>
        ) : (
          <p className="muted" role="status">
            正在讀取這筆回報
          </p>
        )}
      </section>
    );
  }

  if (!report) {
    const writing = pendingDecision?.writing === true;
    const verb = pendingDecision ? actionVerb(pendingDecision.request) : '';
    return (
      <section className="review-done" aria-label="找不到這筆回報">
        <h2 className="t-headline">
          {pendingDecision ? (writing ? '這筆回報正在寫入' : `這筆回報正在${verb}`) : '找不到這筆回報'}
        </h2>
        <p className="muted">
          {pendingDecision
            ? writing
              ? '已經送出，不能再復原。'
              : '5 秒後寫入，期間可以復原。'
            : '它可能已經被處理，或網址打錯了。'}
        </p>
        <UndoNotice />
        <Link className="btn btn--secondary" to={`/review${search}`}>
          回到佇列
        </Link>
      </section>
    );
  }

  const others = open.filter((r) => r.sourceId === report.sourceId && r.id !== report.id);
  const proposed = report.proposed ?? {};
  const showsEligibility = 'scooter_allowed' in proposed || 'heavy_allowed' in proposed;
  const move = proposedMove(report, spot);
  const words = riderText(report);
  const failureText = failure ? errorText(failure) : null;

  const noteField = (
    <section className="review-detail__note">
      <label htmlFor={noteId} className="t-title">
        處理說明 <span className="muted review-detail__optional">選填，會寫入稽核紀錄</span>
      </label>
      <textarea
        id={noteId}
        rows={2}
        maxLength={500}
        placeholder="例如：已比對停管處公告"
        value={note}
        onChange={(event) => setNote(event.target.value)}
      />
    </section>
  );

  return (
    <article className={`review-detail review-detail--${mode}`} aria-labelledby="review-detail-title">
      {isPhone && (
        <nav className="review-detail__phone-bar" aria-label="審核清單">
          <Link to={`/review${search}`} className="btn btn--quiet" aria-label="返回審核清單">
            <LineIcon name="arrow" style={{ transform: 'scaleX(-1)' }} />
            清單
          </Link>
          {position >= 0 && (
            <span className="num muted">
              {position + 1} / {visible.length}
            </span>
          )}
        </nav>
      )}

      <div className="review-detail__body">
        <div className="review-detail__main">
          <header className="review-detail__header">
            <p className="t-caption">
              <SourceTag source={isOfficial(report.sourceId) ? 'official' : 'community'} /> 騎士回報於{' '}
              <span className="num">{shortDateTime(report.createdAt)}</span>
            </p>
            <h2 id="review-detail-title" className="t-headline">
              {spotName(report, spot)}
            </h2>
            {mode === 'edit' ? (
              <p className="muted">修改要套用的值；黃底是和目前點位不同的欄位，下面一行是騎士原本的建議。</p>
            ) : (
              spotArea(spot) && <p className="muted">{spotArea(spot)}</p>
            )}
          </header>

          {failureText && failure && mode === 'view' && (
            <div
              className={`review-alert${failure.error.code === 'stale' ? ' review-alert--conflict' : ''}`}
              role="alert"
            >
              <p className="t-title">{failureText.title}</p>
              {failureText.body && <p>{failureText.body}</p>}
              <div className="review-alert__actions">
                {failure.error.code === 'stale' ? (
                  <>
                    <Button onClick={() => dispatch(reloadForConflict(reportId))}>重新讀取最新資料</Button>
                    <Button
                      variant="primary"
                      disabled={!reloaded}
                      onClick={() => retry(true)}
                      title={reloaded ? undefined : '先重新讀取最新資料'}
                    >
                      仍然套用
                    </Button>
                  </>
                ) : (
                  <>
                    <Button variant="primary" onClick={() => retry(false)}>
                      再試一次
                    </Button>
                    <Button
                      onClick={() => {
                        dispatch(failureDismissed(reportId));
                        goNext();
                      }}
                    >
                      跳過這筆
                    </Button>
                  </>
                )}
              </div>
            </div>
          )}

          {mode === 'edit' && spot && outcome ? (
            <>
              {editMessage && (
                <p className="review-alert" role="alert">
                  {editMessage}
                </p>
              )}
              <EditPanel
                report={report}
                spot={spot}
                values={editValues}
                errors={outcome.errors}
                showErrors={showErrors}
                onChange={(key, value) => {
                  setEditValues((current) => ({ ...current, [key]: value }));
                  setEditMessage(null);
                }}
              />
              {noteField}
            </>
          ) : (
            <>
              {showsEligibility && <EligibilityChange report={report} spot={spot} />}
              <DiffTable report={report} spot={spot} />

              {words && (
                <section className="review-detail__words" aria-labelledby={`${noteId}-words`}>
                  <h3 id={`${noteId}-words`} className="t-title">
                    騎士說明
                  </h3>
                  <p>{words}</p>
                </section>
              )}

              {report.evidenceUrl && (
                <p>
                  <a href={report.evidenceUrl} target="_blank" rel="noopener noreferrer">
                    騎士附的公告連結
                  </a>
                </p>
              )}

              {mode === 'reject' ? (
                <RejectPanel
                  kind={rejectKind}
                  onKind={setRejectKind}
                  note={note}
                  onNote={setNote}
                  showErrors={showErrors}
                  sheet={isPhone}
                  spotName={spotName(report, spot)}
                  onConfirm={confirmReject}
                  onCancel={cancelMode}
                />
              ) : null}
              {!(mode === 'reject' && !isPhone) && noteField}
            </>
          )}
        </div>

        <aside className="review-detail__aside" aria-label="點位脈絡">
          <section className="panel review-context">
            <h3 className="t-title">位置</h3>
            {typeof spot?.values.lat === 'number' && typeof spot?.values.lng === 'number' ? (
              <p className="num">
                {spot.values.lat.toFixed(5)}, {spot.values.lng.toFixed(5)}
              </p>
            ) : (
              <p className="muted">沒有座標</p>
            )}
            {move !== null && (
              <p>
                建議移動 <span className="num">{move}</span> m
              </p>
            )}
          </section>
          {others.length > 0 && (
            <section className="panel review-context">
              <h3 className="t-title">同一點位的其他回報</h3>
              <ul className="review-context__list">
                {others.map((other) => (
                  <li key={other.id}>
                    <Link to={`/review/${other.id}${search}`}>
                      <span className="num">{shortDateTime(other.createdAt)}</span>{' '}
                      {other.reason || '其他回報'}
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </aside>
      </div>

      {mode === 'view' && (
        <div role="toolbar" aria-label="處理這筆回報" className="review-toolbar">
          <Button
            variant="primary"
            shortcut="A"
            disabled={!plan?.ok}
            onClick={() => apply(false)}
            className="review-toolbar__apply"
          >
            套用建議
          </Button>
          <Button shortcut="E" disabled={!canEdit} onClick={startEdit} className="review-toolbar__edit">
            修改後套用
          </Button>
          <Button variant="destructive" shortcut="R" onClick={startReject} className="review-toolbar__reject">
            駁回
          </Button>
          <div className="review-toolbar__status">
            <UndoNotice />
            {plan && !plan.ok ? (
              <p className="t-caption">{PLAN_TEXT[plan.reason]}</p>
            ) : (
              <p className="t-caption review-toolbar__hint">
                處理完自動跳到下一筆，<span className="num">5</span> 秒內可復原
              </p>
            )}
          </div>
          <Button variant="quiet" shortcut="J" onClick={goNext} className="review-toolbar__skip">
            跳過
          </Button>
        </div>
      )}

      {mode === 'reject' && !isPhone && (
        <div role="toolbar" aria-label="駁回這筆回報" className="review-toolbar">
          <Button variant="danger" shortcut="Enter" onClick={confirmReject}>
            確定駁回
          </Button>
          <Button variant="quiet" shortcut="Esc" onClick={cancelMode}>
            取消
          </Button>
          <div className="review-toolbar__status">
            <p className="t-caption">
              駁回後自動跳到下一筆，<span className="num">5</span> 秒內可復原；點位不會改變
            </p>
          </div>
        </div>
      )}

      {mode === 'edit' && outcome && (
        <div role="toolbar" aria-label="修改後套用" className="review-toolbar review-toolbar--edit">
          <Button variant="primary" shortcut={isPhone ? undefined : 'Ctrl Enter'} onClick={saveEdit}>
            儲存並套用
          </Button>
          <Button
            variant={isPhone ? 'secondary' : 'quiet'}
            shortcut={isPhone ? undefined : 'Esc'}
            onClick={cancelMode}
          >
            取消修改
          </Button>
          <div className="review-toolbar__status">
            <p className="t-caption">
              你改了騎士建議的 <span className="num">{outcome.changedFromRider.length}</span> 處、加了{' '}
              <span className="num">{outcome.added.length}</span> 處；套用後 <span className="num">5</span>{' '}
              秒內可復原
            </p>
          </div>
        </div>
      )}
    </article>
  );
}
