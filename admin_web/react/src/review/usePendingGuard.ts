import { useEffect } from 'react';
import { useAppSelector } from '../app/hooks';

/**
 * Decisions wait out the undo window (and their write) in the store, which
 * outlives every page. Closing or reloading the tab meanwhile would drop
 * them, so while any is pending the browser asks first, wherever the admin
 * is (Codex review, PR #214). Mounted by the shell, never by a page.
 */
export function usePendingGuard() {
  const pending = useAppSelector((state) => Object.keys(state.review.pending).length > 0);
  useEffect(() => {
    if (!pending) return;
    const warn = (event: BeforeUnloadEvent) => event.preventDefault();
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [pending]);
}
