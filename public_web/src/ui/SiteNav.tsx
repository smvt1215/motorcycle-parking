import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router';
import { appName } from '../content';
import { Mark } from './Mark';

/** The same four links everywhere; off the home page 功能 and 規則 lead back to its sections. */
const LINKS = [
  { label: '功能', to: '/#features' },
  { label: '規則', to: '/#rules' },
  { label: '接下來', to: '/roadmap' },
  { label: '聯絡我們', to: '/support' },
] as const;

/** A path as the router matches it: any case, with or without a trailing slash. */
export function routePath(pathname: string): string {
  return pathname.toLowerCase().replace(/\/+$/, '');
}

/** Set on a link followed from the open menu, so the next page can put focus back. */
interface FromMenu {
  fromMenu?: boolean;
}

/**
 * The main navigation (canvas boards Home, PhoneHome, PhoneNav): the four
 * links in the bar from 680px, behind 選單 below it. One list serves both, so
 * the closed menu cannot be tabbed into.
 */
export function SiteNav() {
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const toggle = useRef<HTMLButtonElement>(null);
  const path = routePath(location.pathname);

  // Without preventScroll, focus would pull a section link back up to the bar.
  const focusToggle = useCallback(() => toggle.current?.focus({ preventScroll: true }), []);
  const collapse = useCallback(() => {
    setOpen(false);
    focusToggle();
  }, [focusToggle]);

  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') collapse();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, collapse]);

  // A link can open another page, whose bar is a new one: the focus follows there.
  const arrivedFromMenu = (location.state as FromMenu | null)?.fromMenu === true;
  useEffect(() => {
    if (arrivedFromMenu) focusToggle();
  }, [arrivedFromMenu, location.key, focusToggle]);

  return (
    <>
      {open ? <div className="site-menu-scrim" aria-hidden="true" onClick={collapse} /> : null}
      <nav className="site-nav" aria-label="主要">
        <Link to="/" className="site-brand">
          <Mark />
          <span className="site-brand-name">{appName}</span>
        </Link>
        <button
          ref={toggle}
          type="button"
          className="site-menu-toggle"
          aria-expanded={open}
          aria-controls="site-menu"
          // Closing moves the focus itself: Safari does not focus a pressed button.
          onClick={() => (open ? collapse() : setOpen(true))}
        >
          <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
            <path
              d={open ? 'M4.5 4.5l11 11M15.5 4.5l-11 11' : 'M3 5.5h14M3 10h14M3 14.5h14'}
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
            />
          </svg>
          {open ? '關閉' : '選單'}
        </button>
        <ul id="site-menu" className={open ? 'site-nav-links site-nav-links--open' : 'site-nav-links'}>
          {LINKS.map((link) => (
            <li key={link.label}>
              <Link
                to={link.to}
                state={open ? ({ fromMenu: true } satisfies FromMenu) : undefined}
                aria-current={link.to === path ? 'page' : undefined}
                onClick={() => setOpen(false)}
              >
                {link.label}
              </Link>
            </li>
          ))}
        </ul>
      </nav>
    </>
  );
}
