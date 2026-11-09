import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { adminV1 } from '../api/v1/admin_v1.generated';
import { useAppDispatch, useAppSelector, useAppStore } from '../app/hooks';
import { useIsPhone } from '../review/hooks';
import { actionSettled, ticked, type TrackedAction } from './actionsSlice';

const TICK_MS = 500;
const POLL_MS = 1_200;

/**
 * Advances every countdown and, once a deadline has passed, asks the server
 * how each one ended. Lives as long as 待處理 is on screen; the server does
 * not depend on it.
 */
export function useActionWatcher() {
  const dispatch = useAppDispatch();
  const store = useAppStore();
  const active = useAppSelector((state) => state.pendingActions.actions.length > 0);
  const inFlight = useRef(new Set<string>());
  const lastPoll = useRef(new Map<string, number>());

  useEffect(() => {
    if (!active) return undefined;

    const poll = async (caseId: string) => {
      inFlight.current.add(caseId);
      const result = await dispatch(
        adminV1.endpoints.adminV1CaseActions.initiate(
          { body: { p_case: caseId } },
          { subscribe: false, forceRefetch: true },
        ),
      );
      inFlight.current.delete(caseId);
      lastPoll.current.set(caseId, Date.now());
      // Not answered (offline, a 5xx): ask again next tick.
      if (!result.data) return;
      const listed = result.data;
      const waiting = store
        .getState()
        .pendingActions.actions.filter(
          (a: TrackedAction) => a.caseId === caseId && a.phase === 'sending' && !a.cancelling,
        );
      for (const action of waiting) {
        const server = listed.find((row) => row.id === action.id);
        // Only unfinished, failed and stale actions are listed: done ones drop out.
        if (!server || server.status === 'done') {
          dispatch(actionSettled({ id: action.id, outcome: 'done', now: Date.now() }));
        } else if (server.status === 'failed' || server.status === 'stale' || server.status === 'cancelled') {
          dispatch(actionSettled({ id: action.id, outcome: server.status, now: Date.now() }));
        }
      }
    };

    const timer = setInterval(() => {
      const now = Date.now();
      dispatch(ticked(now));
      const cases = new Set(
        store
          .getState()
          .pendingActions.actions.filter((a) => a.phase === 'sending' && !a.cancelling)
          .map((a) => a.caseId),
      );
      for (const caseId of cases) {
        if (inFlight.current.has(caseId)) continue;
        if (now - (lastPoll.current.get(caseId) ?? 0) < POLL_MS) continue;
        void poll(caseId);
      }
    }, TICK_MS);
    return () => clearInterval(timer);
  }, [active, dispatch, store]);
}

const subscribeOnline = (listener: () => void) => {
  window.addEventListener('online', listener);
  window.addEventListener('offline', listener);
  return () => {
    window.removeEventListener('online', listener);
    window.removeEventListener('offline', listener);
  };
};

export const useOnline = () => useSyncExternalStore(subscribeOnline, () => navigator.onLine);

/** A clock that ticks while `active`; the digits never need more than this. */
export function useTick(active: boolean, intervalMs = 250) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return undefined;
    const update = () => setNow(Date.now());
    update();
    const timer = setInterval(update, intervalMs);
    return () => clearInterval(timer);
  }, [active, intervalMs]);
  return now;
}

const typingTarget = (node: Element | null) =>
  node instanceof HTMLTextAreaElement ||
  (node instanceof HTMLInputElement && !['radio', 'checkbox', 'button'].includes(node.type));

/**
 * How much the on-screen keyboard covers (t7: the action bar stays on it).
 * Only on phones, and only while a text field has focus, because a pinch zoom
 * shrinks the visual viewport too.
 */
export function useKeyboardInset(): number {
  const phone = useIsPhone();
  const [inset, setInset] = useState(0);

  useEffect(() => {
    const viewport = window.visualViewport;
    if (!phone || !viewport) return undefined;
    const measure = () => {
      const covered = window.innerHeight - viewport.height - viewport.offsetTop;
      setInset(typingTarget(document.activeElement) ? Math.max(0, Math.round(covered)) : 0);
    };
    measure();
    viewport.addEventListener('resize', measure);
    viewport.addEventListener('scroll', measure);
    document.addEventListener('focusin', measure);
    document.addEventListener('focusout', measure);
    return () => {
      viewport.removeEventListener('resize', measure);
      viewport.removeEventListener('scroll', measure);
      document.removeEventListener('focusin', measure);
      document.removeEventListener('focusout', measure);
    };
  }, [phone]);

  return phone ? inset : 0;
}
