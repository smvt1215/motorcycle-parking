import { Link } from 'react-router';
import { EmptyState } from '../ui/EmptyState';
import { LineIcon } from '../ui/icons';
import { Page } from './Page';

/*
 * Sections wait for the unified API (admin_v1, #195). Until then they say
 * so plainly instead of showing sample rows that could pass for real data.
 */
function NotConnected({ what }: { what: string }) {
  return (
    <EmptyState title="這一頁還沒接上資料">
      <p>{what}要等統一 API（admin_v1，#195）完成後才接上。</p>
      <p>在那之前，請繼續用目前的管理站處理。</p>
    </EmptyState>
  );
}

export function ReviewPage() {
  return (
    <Page title="審核" caption="最舊的在最上面">
      <NotConnected what="待審佇列" />
    </Page>
  );
}

export function SpotsPage() {
  return (
    <Page title="點位">
      <NotConnected what="點位地圖與表單" />
    </Page>
  );
}

export function RulesPage() {
  return (
    <Page title="規則">
      <NotConnected what="縣市規則" />
    </Page>
  );
}

export function ImportPage() {
  return (
    <Page title="匯入">
      <NotConnected what="匯入試算" />
    </Page>
  );
}

export function UsersPage() {
  return (
    <Page title="使用者">
      <NotConnected what="使用者清單" />
    </Page>
  );
}

export function MorePage() {
  return (
    <Page title="更多">
      <ul className="link-list panel" aria-label="其他功能">
        <li>
          <Link to="/import">
            <LineIcon name="import" />
            匯入
          </Link>
        </li>
        <li>
          <Link to="/users">
            <LineIcon name="users" />
            使用者
          </Link>
        </li>
        <li>
          <Link to="/design">
            <LineIcon name="rules" />
            設計基礎
          </Link>
        </li>
      </ul>
    </Page>
  );
}

export function NotFoundPage() {
  return (
    <Page title="找不到這一頁">
      <EmptyState
        title="網址可能打錯了"
        actions={
          <Link className="btn btn--secondary" to="/review">
            回到審核
          </Link>
        }
      >
        <p>從導覽列選一個功能，或回到審核。</p>
      </EmptyState>
    </Page>
  );
}
