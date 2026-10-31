import { Link, Outlet, useLocation } from 'react-router';
import { LineIcon } from '../ui/icons';
import { MORE, MORE_PATHS, SECTIONS, sectionLabel, type Section } from './sections';
import './AppShell.css';

const within = (pathname: string, path: string) => pathname === path || pathname.startsWith(`${path}/`);

function NavItem({ section, active }: { section: Section; active: boolean }) {
  const className = [
    'shell-nav__item',
    active && 'is-active',
    section.phoneTab ? 'shell-nav__item--phone' : 'shell-nav__item--wide',
    section === MORE && 'shell-nav__item--more',
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <Link to={section.path} className={className} aria-current={active ? 'page' : undefined}>
      <LineIcon name={section.icon} className="shell-nav__icon" />
      <span className="shell-nav__label">{section.label}</span>
    </Link>
  );
}

/**
 * One navigation landmark, three layouts (DESIGN.md Layout):
 * desktop ≥ 1040 a 96px rail, tablet 680–1039 a 64px top tab bar,
 * phone < 680 a 56px top bar plus 72px bottom tabs (審核、點位、規則、更多).
 */
export function AppShell() {
  const { pathname } = useLocation();
  // 「更多」 stays active on every page it leads to. On wider layouts those
  // pages have their own item, so 「更多」 is hidden there (AppShell.css).
  const inMore = MORE_PATHS.some((path) => within(pathname, path));

  return (
    <div className="shell">
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
            <NavItem key={section.path} section={section} active={within(pathname, section.path)} />
          ))}
          <NavItem section={MORE} active={inMore} />
        </nav>
      </header>
      <main className="shell-main">
        <Outlet />
      </main>
    </div>
  );
}
