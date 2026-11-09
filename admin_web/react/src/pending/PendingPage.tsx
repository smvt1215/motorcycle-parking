import { useLayoutEffect, useRef } from 'react';
import { Link, Outlet, useLocation, useParams } from 'react-router';
import { useDataConnection } from '../app/connection';
import { Page } from '../pages/Page';
import { EmptyState } from '../ui/EmptyState';
import { usePendingCounts } from './api';
import { PendingList } from './PendingList';
import './Pending.css';

/**
 * 待處理: the list stays mounted while the right pane follows the URL
 * (/pending/:caseId), so choosing a row only replaces that pane. Below 680px
 * the two take turns and returning restores the scroll position.
 */
export function PendingPage() {
  const connection = useDataConnection();
  const { caseId } = useParams();
  const listScroll = useRef(0);

  useLayoutEffect(() => {
    const target = caseId ? 0 : listScroll.current;
    if (window.scrollY !== target) window.scrollTo(0, target);
  }, [caseId]);

  if (connection === 'none') {
    return (
      <Page title="待處理" caption="最快到期的在最上面">
        <EmptyState title="這一頁還沒接上資料">
          <p>請先連接 Supabase 與 admin_v1。</p>
        </EmptyState>
      </Page>
    );
  }

  return (
    <div className={`pending ${caseId ? 'pending--detail' : 'pending--list'}`}>
      <PendingList
        selectedId={caseId ?? null}
        onOpen={() => {
          listScroll.current = window.scrollY;
        }}
      />
      <div className="pending-main">
        <Outlet />
      </div>
    </div>
  );
}

/** The right pane before a row is chosen. */
export function PendingIndex() {
  return (
    <div className="pending-pane">
      <EmptyState title="從清單選一筆案件">
        <p>案件的內容會顯示在這裡。</p>
      </EmptyState>
    </div>
  );
}

/**
 * The case pane. Replies, closing and report handling come with the next
 * layer of #295, which replaces this component and keeps the route.
 */
export function PendingCase() {
  const { search } = useLocation();
  const counts = usePendingCounts();
  const remaining = counts.isError ? undefined : counts.data?.all;
  return (
    <div className="pending-pane">
      <div className="pending-back">
        <Link className="btn btn--quiet" to={`/pending${search}`}>
          返回清單
          {remaining !== undefined && (
            <>
              （剩 <span className="num">{remaining}</span> 筆）
            </>
          )}
        </Link>
      </div>
      <EmptyState title="案件內容還沒接上">
        <p>這一版只有待處理清單。回覆、結案和檢舉處理會在下一版加入。</p>
      </EmptyState>
    </div>
  );
}
