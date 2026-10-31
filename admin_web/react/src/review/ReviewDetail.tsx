import { useEffect, useId, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { useAppDispatch, useAppSelector } from '../app/hooks';
import type { ApiError } from '../app/adminApi';
import { Button, ModifiedTag, SourceTag } from '../ui/controls';
import { STATUS_LABEL, VEHICLE_LABEL, VEHICLES } from '../ui/eligibility';
import { LineIcon } from '../ui/icons';
import { PlateStack } from '../ui/PlateStack';
import { neighbourOf, useIsPhone, useKindFilter, useReviewQueue } from './hooks';
import {
  applyPlan,
  diffRows,
  isOfficial,
  plateOf,
  proposedMove,
  riderText,
  shortDateTime,
  spotArea,
  spotName,
  type ApplyPlan,
  type ReviewReport,
  type ReviewSpot,
} from './model';
import { decisionQueued, failureDismissed, noteChanged, reloadForConflict } from './reviewSlice';
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

const ERROR_TEXT: Record<ApiError['code'], { title: string; body: string }> = {
  network: {
    title: '沒有套用：連不上伺服器',
    body: '這筆回報維持待審，你填的處理說明還在。檢查網路後再試一次。',
  },
  timeout: {
    title: '沒有套用：伺服器太久沒有回應',
    body: '這筆回報維持待審，你填的處理說明還在。稍後再試一次。',
  },
  unknown: {
    title: '沒有套用：伺服器拒絕了這次修改',
    body: '這筆回報維持待審，你填的處理說明還在。',
  },
  stale: {
    title: '儲存前，這個點位已被修改',
    body: '回報送出後，點位又被改過。先重新讀取最新資料，確認建議仍然適用再套用。',
  },
  alreadyResolved: { title: '這筆回報已經處理過了', body: '' },
};

const PLAN_TEXT: Record<Exclude<ApplyPlan, { ok: true }>['reason'], string> = {
  missingSpot: '找不到這個點位，可能已刪除，不能套用。',
  structured:
    '這筆建議包含費率、停放條件、暫時封閉或分區分段，新版管理站還不能套用；請先用目前的管理站處理。',
  empty: '這筆回報沒有可以套用到這個點位的欄位。',
};

/** The report on the right, or the whole screen on a phone. */
export function ReviewDetail() {
  const { reportId = '' } = useParams();
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const isPhone = useIsPhone();
  const [, , search] = useKindFilter();
  const { query, visible, open, spots } = useReviewQueue();
  const note = useAppSelector((state) => state.review.notes[reportId] ?? '');
  const failure = useAppSelector((state) => state.review.failures[reportId]);
  const reloaded = useAppSelector((state) => reportId in state.review.reloaded);
  const pending = useAppSelector((state) => reportId in state.review.pending);
  const noteId = useId();

  const report = open.find((r) => r.id === reportId);
  const spot = report ? spots[report.sourceId] : undefined;
  const plan = report ? applyPlan(report, spot) : null;
  const position = visible.findIndex((r) => r.id === reportId);

  const goNext = () => {
    const next = neighbourOf(visible, reportId);
    navigate(next && next.id !== reportId ? `/review/${next.id}${search}` : `/review${search}`);
  };

  const apply = (force: boolean) => {
    if (!report || !plan?.ok) return;
    const next = neighbourOf(visible, reportId);
    dispatch(
      decisionQueued({
        request: { reportId, decision: 'accepted', patch: plan.patch, note: note.trim(), force },
        name: spotName(report, spot),
      }),
    );
    navigate(next ? `/review/${next.id}${search}` : `/review${search}`);
  };

  // A: 套用建議, J: 跳過 (Palette.dc.html). Ignored while typing.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.altKey || event.ctrlKey || event.metaKey || event.repeat) return;
      const target = event.target as HTMLElement | null;
      if (target?.closest('input, textarea, select, [contenteditable="true"]')) return;
      const key = event.key.toLowerCase();
      if (key === 'a' && plan?.ok && !failure) {
        event.preventDefault();
        apply(false);
      } else if (key === 'j') {
        event.preventDefault();
        goNext();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  });

  if (!query.isSuccess) return null;

  if (!report) {
    return (
      <section className="review-done" aria-label="找不到這筆回報">
        <h2 className="t-headline">{pending ? '這筆回報正在套用' : '找不到這筆回報'}</h2>
        <p className="muted">{pending ? '5 秒後寫入，期間可以復原。' : '它可能已經被處理，或網址打錯了。'}</p>
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
  const errorText = failure ? ERROR_TEXT[failure.code] : null;

  return (
    <article className="review-detail" aria-labelledby="review-detail-title">
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
            {spotArea(spot) && <p className="muted">{spotArea(spot)}</p>}
          </header>

          {errorText && failure && (
            <div
              className={`review-alert${failure.code === 'stale' ? ' review-alert--conflict' : ''}`}
              role="alert"
            >
              <p className="t-title">{errorText.title}</p>
              {errorText.body && <p>{errorText.body}</p>}
              <div className="review-alert__actions">
                {failure.code === 'stale' ? (
                  <>
                    <Button onClick={() => dispatch(reloadForConflict(reportId))}>重新讀取最新資料</Button>
                    <Button
                      variant="primary"
                      disabled={!reloaded}
                      onClick={() => apply(true)}
                      title={reloaded ? undefined : '先重新讀取最新資料'}
                    >
                      仍然套用
                    </Button>
                  </>
                ) : (
                  <>
                    <Button variant="primary" onClick={() => apply(false)} disabled={!plan?.ok}>
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
              onChange={(event) => dispatch(noteChanged({ reportId, note: event.target.value }))}
            />
          </section>
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

      <div role="toolbar" aria-label="處理這筆回報" className="review-toolbar">
        <Button variant="primary" shortcut="A" disabled={!plan?.ok} onClick={() => apply(false)}>
          套用建議
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
        <Button variant="quiet" shortcut="J" onClick={goNext}>
          跳過
        </Button>
      </div>
    </article>
  );
}
