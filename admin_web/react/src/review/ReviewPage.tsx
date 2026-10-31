import { Outlet, useParams } from 'react-router';
import { useDataConnection } from '../app/connection';
import { EmptyState } from '../ui/EmptyState';
import { Page } from '../pages/Page';
import { QueuePane } from './QueuePane';
import './Review.css';

/**
 * 審核: the queue stays mounted on the left while the detail on the right
 * follows the URL (/review/:reportId), so choosing a row keeps the list's
 * scroll, filter and selection (rwd rule, 2026-10-27). Below 680px the two
 * take turns.
 */
export function ReviewPage() {
  const connection = useDataConnection();
  const { reportId } = useParams();

  if (connection === 'none') {
    return (
      <Page title="審核" caption="最舊的在最上面">
        <EmptyState title="這一頁還沒接上資料">
          <p>待審佇列要等統一 API（admin_v1，#195）完成後才接上。</p>
          <p>在那之前，請繼續用目前的管理站處理。</p>
        </EmptyState>
      </Page>
    );
  }

  return (
    <div className={`review ${reportId ? 'review--detail' : 'review--list'}`}>
      <QueuePane selectedId={reportId ?? null} />
      <div className="review-main">
        <Outlet />
      </div>
    </div>
  );
}
