import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { appName, developer, footerNote } from '../content';
import './Site.css';

function Mark() {
  return (
    <svg className="site-mark" width="32" height="32" viewBox="0 0 32 32" aria-hidden="true">
      <rect x="1" y="1" width="30" height="30" rx="8" fill="#176273" />
      <path
        d="M11 23V9h6.2a4.4 4.4 0 0 1 0 8.8H11"
        fill="none"
        stroke="#FFFFFF"
        strokeWidth="2.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** Header, page and footer shared by every public page. */
export function Site({
  children,
  aside,
  current,
}: {
  children: ReactNode;
  aside?: ReactNode;
  /** The footer link of the page being shown, marked as the current page. */
  current?: string;
}) {
  return (
    <div className="site">
      <header className="site-header">
        <div className="site-header-inner">
          <Link to="/account-deletion" className="site-brand">
            <Mark />
            <span className="site-brand-text">
              <span className="site-brand-name">{appName}</span>
              <span className="site-brand-developer">{developer}</span>
            </span>
          </Link>
          {aside}
        </div>
      </header>
      <main className="site-main">{children}</main>
      <footer className="site-footer">
        <div className="site-footer-inner">
          <span>{footerNote}</span>
          <Link to="/privacy" aria-current={current === '隱私權政策' ? 'page' : undefined}>
            隱私權政策
          </Link>
          <Link to="/account-deletion">刪除帳號</Link>
          <a href="/terms">服務條款</a>
          {/* Questions go through the support form, never a mail link (#295). */}
          <Link to="/support">聯絡我們</Link>
        </div>
      </footer>
    </div>
  );
}
