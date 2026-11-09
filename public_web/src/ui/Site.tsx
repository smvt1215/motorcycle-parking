import { useEffect, type ReactNode } from 'react';
import { Link, useLocation } from 'react-router';
import { appName, developer } from '../content';
import { routePath, SiteNav } from './SiteNav';
import './Site.css';

/** What each path is called, in the browser's tab and in search results. */
const TITLES: Record<string, string> = {
  '/roadmap': '接下來',
  '/account-deletion': '刪除帳號',
  '/privacy': '隱私權政策',
  '/terms': '服務條款',
  '/support': '聯絡我們',
  '/support/verify': '確認申請',
  '/support/cancel': '取消刪除帳號',
  '/support/case': '客服案件',
};

export function pageTitle(pathname: string): string {
  const path = routePath(pathname);
  if (path === '') return appName;
  return `${TITLES[path] ?? '找不到這個頁面'}｜${appName}`;
}

/** The same five links on every page. Questions go through the form, never a mail link (#295). */
const FOOTER_LINKS = [
  { label: '隱私權政策', to: '/privacy' },
  { label: '服務條款', to: '/terms' },
  { label: '接下來', to: '/roadmap' },
  { label: '聯絡我們', to: '/support' },
  { label: '刪除帳號', to: '/account-deletion' },
] as const;

/** Navigation, page and footer shared by every public page. */
export function Site({
  children,
  aside,
  overlay = false,
}: {
  children: ReactNode;
  /** A page's own action, under the navigation. */
  aside?: ReactNode;
  /** The navigation floats over the page's first section (the home page's street map). */
  overlay?: boolean;
}) {
  const { pathname, hash, key } = useLocation();
  const path = routePath(pathname);
  useEffect(() => {
    document.title = pageTitle(pathname);
  }, [pathname]);
  // A new page opens at its top; a link to a section keeps its place.
  useEffect(() => {
    if (!hash) window.scrollTo(0, 0);
  }, [pathname, hash]);
  // The router does not scroll to a fragment. By key: the same link again goes there again.
  useEffect(() => {
    if (hash) document.getElementById(hash.slice(1))?.scrollIntoView();
  }, [hash, key]);
  return (
    <div className="site">
      <header className={overlay ? 'site-header site-header--overlay' : 'site-header'}>
        <SiteNav />
        {aside ? <div className="site-aside">{aside}</div> : null}
      </header>
      <main className="site-main">{children}</main>
      <footer className="site-footer">
        <div className="site-footer-inner">
          <span>{developer}</span>
          {FOOTER_LINKS.map((link) => (
            <Link key={link.to} to={link.to} aria-current={link.to === path ? 'page' : undefined}>
              {link.label}
            </Link>
          ))}
        </div>
      </footer>
    </div>
  );
}
