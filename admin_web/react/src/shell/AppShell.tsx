import { Link, Outlet, useLocation, useMatch } from 'react-router';
import { useDataConnection } from '../app/connection';
import { useAuthController } from '../auth/AuthContext';
import { usePendingCounts } from '../pending/api';
import { usePendingGuard } from '../review/usePendingGuard';
import { LineIcon } from '../ui/icons';
import {
  LIVE_MORE_PATH,
  MORE,
  MORE_PATHS,
  SECTIONS,
  sectionHref,
  sectionLabel,
  type Section,
} from './sections';
import './AppShell.css';

const within = (pathname: string, path: string) => pathname === path || pathname.startsWith(`${path}/`);

function PendingBadge() {
  const { data, isError } = usePendingCounts();
  if (isError) {
    return (
      <span className="shell-nav__badge" role="img" aria-label="待處理數量未知">
        ?
      </span>
    );
  }
  if (data === undefined) return null;
  return (
    <span className="shell-nav__badge" aria-label={`${data.all} 筆待處理`}>
      {data.all}
    </span>
  );
}

interface NavItemProps {
  section: Section;
  active: boolean;
  live: boolean;
  badge: boolean;
}

function NavItem({ section, active, live, badge }: NavItemProps) {
  const className = [
    'shell-nav__item',
    active && 'is-active',
    section.phoneTab ? 'shell-nav__item--phone' : 'shell-nav__item--wide',
    section === MORE && 'shell-nav__item--more',
  ]
    .filter(Boolean)
    .join(' ');
  const content = (
    <>
      <LineIcon name={section.icon} className="shell-nav__icon" />
      <span className="shell-nav__label">{section.label}</span>
      {badge && <PendingBadge />}
    </>
  );
  // On the deployed site only 待處理 and 更多 are React; the rest are Flutter.
  const internal = !live || section.path === '/pending' || section === MORE;
  const current = active ? 'page' : undefined;
  if (internal) {
    return (
      <Link
        to={live && section === MORE ? LIVE_MORE_PATH : section.path}
        className={className}
        aria-current={current}
      >
        {content}
      </Link>
    );
  }
  return (
    <a href={sectionHref(section)} className={className} aria-current={current}>
      {content}
    </a>
  );
}

/**
 * One navigation landmark, three layouts (DESIGN.md Layout):
 * desktop ≥ 1040 a 96px rail, tablet 680–1039 a 64px top tab bar,
 * phone < 680 a 56px top bar plus 72px bottom tabs (審核、待處理、點位、更多).
 */
export function AppShell() {
  const { pathname } = useLocation();
  const connection = useDataConnection();
  const auth = useAuthController();
  const live = connection === 'live';
  const onLiveMore = pathname === LIVE_MORE_PATH;
  // 「更多」 stays active on every page it leads to. On wider layouts those
  // pages have their own item, so 「更多」 is hidden there (AppShell.css).
  const inMore = MORE_PATHS.some((path) => within(pathname, path));
  // A case or a report's detail fills a phone screen; its own bar leads back.
  const reviewDetail = useMatch('/review/:reportId') !== null;
  const caseDetail = useMatch('/pending/:caseId') !== null && !onLiveMore;
  usePendingGuard();

  return (
    <div
      className={`shell${reviewDetail || caseDetail ? ' shell--focus' : ''}${caseDetail ? ' shell--case' : ''}`}
    >
      <header className="shell-bar">
        <span className="shell-logo" role="img" aria-label="機車停車指南管理">
          <span aria-hidden="true">P</span>
          <span aria-hidden="true" className="shell-logo__han">
            管
          </span>
        </span>
        {/* Phones name the page in the bar; the page's own headline is hidden there. */}
        <span className="shell-bar__title" aria-hidden="true">
          {sectionLabel(pathname)}
        </span>
        <nav className="shell-nav" aria-label="管理功能">
          {SECTIONS.map((section) => (
            <NavItem
              key={section.path}
              section={section}
              active={within(pathname, section.path) && !onLiveMore}
              live={live}
              badge={section.path === '/pending' && connection !== 'none'}
            />
          ))}
          <NavItem section={MORE} active={inMore} live={live} badge={false} />
        </nav>
        {auth && (
          <button type="button" className="shell-signout" onClick={() => void auth.signOut()}>
            登出
          </button>
        )}
      </header>
      <main className="shell-main">
        <Outlet />
      </main>
    </div>
  );
}
