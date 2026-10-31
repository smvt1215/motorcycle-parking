import { useState } from 'react';
import { Link, useNavigate } from 'react-router';
import { useDataConnection } from '../app/connection';
import { useAppSelector } from '../app/hooks';
import { Button, Chip } from '../ui/controls';
import { EligibilityPair, PlateStack } from '../ui/PlateStack';
import { STATUS_LABEL } from '../ui/eligibility';
import { LineIcon } from '../ui/icons';
import { useIsPhone, useKindFilter, useReviewQueue, type KindFilter } from './hooks';
import {
  diffRows,
  KIND_LABEL,
  plateOf,
  proposedMove,
  relativeTime,
  reportKind,
  REVIEW_KINDS,
  spotArea,
  spotName,
  type ReviewReport,
  type ReviewSpot,
} from './model';

const FILTERS: readonly KindFilter[] = ['all', ...REVIEW_KINDS];

/** One line under the name: area, age, and what makes this row different. */
function rowCaption(report: ReviewReport, spot: ReviewSpot | undefined, sameSpot: number, now: number) {
  const move = proposedMove(report, spot);
  return [
    spotArea(spot),
    relativeTime(report.createdAt, now),
    move !== null ? `建議移動 ${move} m` : null,
    sameSpot > 1 ? `同一點位 ${sameSpot} 筆` : null,
  ]
    .filter(Boolean)
    .join('　');
}

/** The phone's in-place expansion (ReviewPhoneList.dc.html): the change at a glance. */
function ExpandedRow({
  report,
  spot,
  search,
  onCollapse,
}: {
  report: ReviewReport;
  spot: ReviewSpot | undefined;
  search: string;
  onCollapse: () => void;
}) {
  const proposed = report.proposed ?? {};
  const vehicles = (['scooter', 'heavy'] as const).filter((v) => `${v}_allowed` in proposed);
  const others = diffRows(report, spot).filter((row) => row.changed);
  return (
    <div className="queue-expanded">
      {vehicles.map((vehicle) => {
        const key = `${vehicle}_allowed`;
        const from = plateOf(spot?.values[key]);
        const to = plateOf(proposed[key]);
        return (
          <p key={vehicle} className="queue-expanded__plates">
            <span className="t-title">{vehicle === 'scooter' ? '普通機車' : '大型重機'}</span>
            <PlateStack vehicle={vehicle} status={from} label={`目前${STATUS_LABEL[from]}`} />
            <LineIcon name="arrow" size={18} strokeWidth={2} className="muted" />
            <PlateStack vehicle={vehicle} status={to} label={`建議${STATUS_LABEL[to]}`} />
            <span className="t-caption">建議改為{STATUS_LABEL[to]}</span>
          </p>
        );
      })}
      {others.length > 0 && (
        <p className="t-caption">
          {vehicles.length ? '另改 ' : '改 '}
          {others.map((row) => `${row.label}：${row.current} → ${row.proposed}`).join('；')}
        </p>
      )}
      <div className="queue-expanded__actions">
        <Link className="btn btn--primary" to={`/review/${report.id}${search}`}>
          看完整差異
        </Link>
        <Button onClick={onCollapse}>收起</Button>
      </div>
    </div>
  );
}

/** The queue, oldest first (Main.dc.html 待審佇列). */
export function QueuePane({ selectedId }: { selectedId: string | null }) {
  const connection = useDataConnection();
  const isPhone = useIsPhone();
  const navigate = useNavigate();
  const [kind, setKind, search] = useKindFilter();
  const { query, open, visible, counts, spots } = useReviewQueue();
  const [expanded, setExpanded] = useState<string | null>(null);
  // Ages are relative to when the queue arrived, so rows do not shift while read.
  const now = query.fulfilledTimeStamp ?? 0;

  const sameSpot = (report: ReviewReport) => open.filter((r) => r.sourceId === report.sourceId).length;
  // A failed write puts the report back; by then the reviewer has moved on.
  const failures = useAppSelector((state) => state.review.failures);

  return (
    <section className="queue" aria-label="待審佇列">
      <header className="queue__header">
        <div className="queue__title">
          <h1 className="t-headline page-headline">審核</h1>
          <span className="t-caption">最舊的在最上面</span>
          {connection === 'fixture' && <span className="fixture-tag">示範資料，不會寫入伺服器</span>}
        </div>
        <div className="queue__filters" role="group" aria-label="依類型篩選">
          {FILTERS.map((filter) => (
            <Chip
              key={filter}
              selected={kind === filter}
              count={filter === 'all' ? open.length : counts[filter]}
              onClick={() => setKind(filter)}
            >
              {filter === 'all' ? '待審' : KIND_LABEL[filter]}
            </Chip>
          ))}
        </div>
      </header>

      {query.isLoading && (
        <div className="queue__skeleton" role="status" aria-busy="true">
          <span className="visually-hidden">正在讀取待審回報</span>
          {[30, 25, 35].map((w) => (
            <div key={w} className="skeleton-row" aria-hidden="true">
              <div>
                <span className="skeleton-bar" style={{ width: `${w}%` }} />
                <span className="skeleton-bar" style={{ width: `${w * 2 + 15}%` }} />
              </div>
              <span className="skeleton-bar skeleton-bar--plates" />
            </div>
          ))}
        </div>
      )}

      {query.isError && (
        <div className="queue__error" role="alert">
          <p className="t-title">讀取失敗</p>
          <p className="muted">
            {(query.error as { code?: string }).code === 'timeout'
              ? '超過 10 秒還沒讀到待審回報。'
              : '連不上伺服器，沒有讀到待審回報。'}
          </p>
          <Button variant="primary" onClick={() => void query.refetch()}>
            重試
          </Button>
        </div>
      )}

      {query.isSuccess && (
        <ol className="queue__list" aria-label="待審回報">
          {visible.map((report) => {
            const spot = spots[report.sourceId];
            const selected = report.id === selectedId;
            const isOpen = isPhone && expanded === report.id;
            return (
              <li key={report.id} className={`queue-row${selected || isOpen ? ' is-selected' : ''}`}>
                <button
                  type="button"
                  className="queue-row__main"
                  aria-current={selected ? 'true' : undefined}
                  aria-expanded={isPhone ? isOpen : undefined}
                  onClick={() => {
                    if (isPhone) setExpanded(isOpen ? null : report.id);
                    else navigate(`/review/${report.id}${search}`);
                  }}
                >
                  <span className="queue-row__text">
                    <span className="t-label">{KIND_LABEL[reportKind(report)]}</span>
                    <span className="queue-row__name">{spotName(report, spot)}</span>
                    <span className="t-caption">{rowCaption(report, spot, sameSpot(report), now)}</span>
                    {failures[report.id] && (
                      <span className="t-label queue-row__failed">沒有套用，打開處理</span>
                    )}
                  </span>
                  <EligibilityPair
                    scooter={plateOf(spot?.values.scooter_allowed)}
                    heavy={plateOf(spot?.values.heavy_allowed)}
                  />
                </button>
                {isOpen && (
                  <ExpandedRow
                    report={report}
                    spot={spot}
                    search={search}
                    onCollapse={() => setExpanded(null)}
                  />
                )}
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
