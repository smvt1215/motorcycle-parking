import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { adminV1 } from '../api/v1/admin_v1.generated';
import { useAppDispatch, useAppSelector, useAppStore } from '../app/hooks';
import { useIsPhone } from '../review/hooks';
import type { V1Error } from '../api/v1/base';
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

    /**
     * Neither done nor cancelled actions are listed. A case still open at the
     * version it was scheduled against was left alone, so it was cancelled
     * (another tab); every action that ran closes the case or adds a message.
     */
    const settleUnlisted = async (caseId: string, unlisted: TrackedAction[]) => {
      const row = await dispatch(
        adminV1.endpoints.adminV1TimedCase.initiate(
          { body: { p_id: caseId } },
          { subscribe: false, forceRefetch: true },
        ),
      );
      if (row.error && (row.error as V1Error).message !== 'case.not_found') return;
      for (const action of unlisted) {
        const untouched = row.data !== undefined && row.data.version === action.expectedVersion;
        dispatch(
          actionSettled({ id: action.id, outcome: untouched ? 'cancelled' : 'done', now: Date.now() }),
        );
      }
    };

    const check = async (caseId: string) => {
      const result = await dispatch(
        adminV1.endpoints.adminV1CaseActions.initiate(
          { body: { p_case: caseId } },
          { subscribe: false, forceRefetch: true },
        ),
      );
      // Not answered (offline, a 5xx): ask again next tick. The error comes
      // with the last cached list, whose outcomes belong to earlier attempts.
      if (result.error || !result.data) return;
      const listed = result.data;
      const waiting = store
        .getState()
        .pendingActions.actions.filter(
          (a: TrackedAction) => a.caseId === caseId && a.phase === 'sending' && !a.cancelling,
        );
      const unlisted: TrackedAction[] = [];
      for (const action of waiting) {
        const server = listed.find((row) => row.id === action.id);
        if (!server && action.expectedVersion !== undefined) {
          unlisted.push(action);
        } else if (server?.status === 'done' && server.delivery_status === 'failed') {
          // Listed only because the mail failed: the action ran, the reply did not arrive.
          dispatch(actionSettled({ id: action.id, outcome: 'failed', now: Date.now() }));
        } else if (!server || server.status === 'done') {
          dispatch(actionSettled({ id: action.id, outcome: 'done', now: Date.now() }));
        } else if (server.status === 'failed' || server.status === 'stale' || server.status === 'cancelled') {
          dispatch(actionSettled({ id: action.id, outcome: server.status, now: Date.now() }));
        }
      }
      if (unlisted.length > 0) await settleUnlisted(caseId, unlisted);
    };

    const poll = async (caseId: string) => {
      inFlight.current.add(caseId);
      await check(caseId);
      inFlight.current.delete(caseId);
      lastPoll.current.set(caseId, Date.now());
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
