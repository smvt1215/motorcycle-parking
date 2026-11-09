import { useEffect, useState, useSyncExternalStore } from 'react';
import { useLocation, useSearchParams } from 'react-router';
import type { TimedCaseCounts } from '../api/v1/admin_v1.generated';
import { useAuthController } from '../auth/AuthContext';
import { Button, Chip } from '../ui/controls';
import { needsSecondFactor, usePendingCounts, useTimedCasePagesInfiniteQuery } from './api';
import { groupCases, parseTab, PENDING_TABS, tabCount, type PendingTab } from './model';
import { PendingRow } from './PendingRow';

const subscribeOnline = (listener: () => void) => {
  window.addEventListener('online', listener);
  window.addEventListener('offline', listener);
  return () => {
    window.removeEventListener('online', listener);
    window.removeEventListener('offline', listener);
  };
};

const useOnline = () => useSyncExternalStore(subscribeOnline, () => navigator.onLine);

/** Re-reads the clock each minute, so 「今天」 turns over at Taiwan's midnight. */
function useNow() {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(timer);
  }, []);
  return now;
}

const EMPTY_TEXT: Record<Exclude<PendingTab, 'all'>, string> = {
  support: '沒有要回覆的客服案件。',
  report: '沒有要處理的內容檢舉。',
  waiting: '沒有在等對方的案件。',
};

function Alert({ title, children }: { title: string; children: string }) {
  return (
    <div className="pending-alert">
      <span className="t-title pending-alert__title">{title}</span>
      <span>{children}</span>
    </div>
  );
}

function SecondFactorNeeded({ onRetry }: { onRetry: () => void }) {
  const auth = useAuthController();
  return (
    <div className="pending-state">
      <Alert title="請重新完成第二步驗證">處理案件需要第二步驗證。驗證後會回到這裡，填的內容還在。</Alert>
      <div className="pending-state__actions">
        <Button variant="primary" onClick={() => void auth?.refresh().then(onRetry)}>
          前往驗證
        </Button>
        <Button onClick={() => void auth?.signOut()}>切換帳號</Button>
      </div>
    </div>
  );
}

function Empty({
  tab,
  counts,
  onShow,
}: {
  tab: PendingTab;
  counts: TimedCaseCounts | undefined;
  onShow: (tab: PendingTab) => void;
}) {
  if (tab !== 'all') {
    return (
      <div className="pending-state">
        <p className="t-title">{EMPTY_TEXT[tab]}</p>
        <div className="pending-state__actions">
          <Button onClick={() => onShow('all')}>看全部</Button>
        </div>
      </div>
    );
  }
  const waiting = counts?.waiting ?? 0;
  return (
    <div className="pending-state">
      <p className="t-title">現在沒有待處理的案件。</p>
      {waiting > 0 && (
        <>
          <p className="muted">
            有 <span className="num">{waiting}</span> 筆在等對方回覆或確認。
          </p>
          <div className="pending-state__actions">
            <Button onClick={() => onShow('waiting')}>看等對方的案件</Button>
          </div>
        </>
      )}
    </div>
  );
}

interface PendingListProps {
  selectedId: string | null;
  onOpen: () => void;
}

/** 左欄 (TimedCase, TimedTablet, TimedPhoneList, TimedBasics boards). */
export function PendingList({ selectedId, onOpen }: PendingListProps) {
  const [params, setParams] = useSearchParams();
  const { search } = useLocation();
  const tab = parseTab(params.get('tab'));
  const now = useNow();
  const online = useOnline();
  const counts = usePendingCounts();
  const list = useTimedCasePagesInfiniteQuery(tab, { refetchOnFocus: true, refetchOnReconnect: true });

  const show = (next: PendingTab) => setParams(next === 'all' ? {} : { tab: next });
  // currentData, not data: data keeps the previous tab's rows after a switch.
  const pages = list.currentData?.pages;
  const items = pages?.flatMap((page) => page.items) ?? [];
  const groups = groupCases(items);
  const countsKnown = counts.data !== undefined && !counts.isError;
  const firstLoadFailed = list.isError && pages === undefined;
  const secondFactor = needsSecondFactor(list.error) || needsSecondFactor(counts.error);
  const retry = () => {
    void list.refetch();
    void counts.refetch();
  };

  return (
    <section className="pending-list" aria-label="待處理清單">
      <div className="pending-list__header">
        <div className="pending-list__title">
          <h1 className="t-headline page-headline">待處理</h1>
          <p className="t-caption">最快到期的在最上面</p>
        </div>
        <div role="group" aria-label="篩選" className="pending-list__filters">
          {PENDING_TABS.map(({ id, label }) => (
            <Chip key={id} selected={id === tab} onClick={() => show(id)}>
              {label}{' '}
              {countsKnown ? (
                <span className="num">{tabCount(counts.data as TimedCaseCounts, id)}</span>
              ) : counts.isError ? (
                <span className="t-caption pending-unknown">未知</span>
              ) : null}
            </Chip>
          ))}
        </div>
      </div>

      {!online && (
        <div className="pending-state">
          <Alert title="目前離線">清單是上次讀到的內容，現在無法回覆或處理。連線恢復後會自動更新。</Alert>
        </div>
      )}

      {secondFactor ? (
        <SecondFactorNeeded onRetry={retry} />
      ) : firstLoadFailed ? (
        <div className="pending-state">
          <Alert title="讀不到待處理清單">
            {counts.isError
              ? '這不代表沒有案件。導覽的數字會顯示未知，請再試一次。'
              : '這不代表沒有案件。請再試一次。'}
          </Alert>
          <div className="pending-state__actions">
            <Button variant="primary" onClick={retry}>
              重試
            </Button>
          </div>
        </div>
      ) : pages === undefined ? (
        <div role="status" aria-label="正在讀取待處理清單" className="pending-skeleton">
          <div aria-hidden="true" />
          <div aria-hidden="true" />
          <div aria-hidden="true" />
        </div>
      ) : items.length === 0 ? (
        <Empty tab={tab} counts={counts.data} onShow={show} />
      ) : (
        <>
          {list.isError && !list.isFetchNextPageError && (
            <div className="pending-state">
              <Alert title="清單沒有更新">這是上次讀到的內容，請再試一次。</Alert>
              <div className="pending-state__actions">
                <Button onClick={retry}>重試</Button>
              </div>
            </div>
          )}
          {groups.map((group, index) => {
            const partial = list.hasNextPage && index === groups.length - 1;
            return (
              <div key={group.key}>
                <h2
                  className={`pending-group t-label${group.key === 'overdue' || group.key === 'failed' ? ' is-alert' : ''}`}
                >
                  {group.label}{' '}
                  <span className="num">
                    {group.items.length}
                    {partial ? '+' : ''}
                  </span>
                </h2>
                <ol className="pending-rows">
                  {group.items.map((item) => (
                    <PendingRow
                      key={item.id}
                      item={item}
                      selected={item.id === selectedId}
                      now={now}
                      search={search}
                      onOpen={onOpen}
                    />
                  ))}
                </ol>
              </div>
            );
          })}
          {list.isFetchNextPageError && (
            <div className="pending-state">
              <Alert title="讀不到更多案件">上面的案件還在，請再試一次。</Alert>
            </div>
          )}
          {list.hasNextPage && (
            <div className="pending-more">
              <Button disabled={list.isFetchingNextPage} onClick={() => void list.fetchNextPage()}>
                {list.isFetchingNextPage ? '讀取中…' : list.isFetchNextPageError ? '重試' : '載入更多'}
              </Button>
            </div>
          )}
        </>
      )}
    </section>
  );
}
