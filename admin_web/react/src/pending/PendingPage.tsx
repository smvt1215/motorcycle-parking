import { useEffect, useLayoutEffect, useRef } from 'react';
import { Outlet, useLocation, useNavigate, useParams } from 'react-router';
import { useDataConnection } from '../app/connection';
import { takeReturnPath } from '../auth/returnPath';
import { Page } from '../pages/Page';
import { EmptyState } from '../ui/EmptyState';
import { CountdownDock } from './CountdownDock';
import { PendingList } from './PendingList';
import { useActionWatcher, useKeyboardInset } from './useCaseEffects';
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
  const location = useLocation();
  const navigate = useNavigate();
  const root = useRef<HTMLDivElement>(null);
  const keyboard = useKeyboardInset();
  useActionWatcher();

  useLayoutEffect(() => {
    const target = caseId ? 0 : listScroll.current;
    if (window.scrollY !== target) window.scrollTo(0, target);
  }, [caseId]);

  // Back from Google at /pending: go where the sign-in started.
  useEffect(() => {
    const path = takeReturnPath();
    if (path && path !== `${location.pathname}${location.search}`) {
      void navigate(path, { replace: true });
    }
    // Once, on arrival.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    root.current?.style.setProperty('--kb', `${keyboard}px`);
  }, [keyboard]);

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
    <div
      ref={root}
      className={`pending ${caseId ? 'pending--detail' : 'pending--list'}${keyboard > 0 ? ' pending--keyboard' : ''}`}
    >
      <PendingList
        selectedId={caseId ?? null}
        onOpen={() => {
          listScroll.current = window.scrollY;
        }}
      />
      <div className="pending-main">
        <Outlet />
      </div>
      <CountdownDock />
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
