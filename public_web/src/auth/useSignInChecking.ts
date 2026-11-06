import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

/** How long the page waits for the check and the sign-in (user, 2026-11-08). */
export const SIGN_IN_TIMEOUT_MS = 30_000;

/**
 * From the provider's popup answering until the result arrives: the page
 * shows it is checking instead of the buttons, and gives up after
 * SIGN_IN_TIMEOUT_MS (canvas SignInLoading, PhoneSignInLoading).
 */
export function useSignInChecking(onTimeout: () => void) {
  const [checking, setChecking] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const timedOut = useRef(false);
  const latest = useRef(onTimeout);
  useLayoutEffect(() => {
    latest.current = onTimeout;
  });

  const clear = useCallback(() => {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
  }, []);
  useEffect(() => clear, [clear]);

  const start = useCallback(() => {
    clear();
    timedOut.current = false;
    setChecking(true);
    timer.current = setTimeout(() => {
      timer.current = null;
      timedOut.current = true;
      setChecking(false);
      latest.current();
    }, SIGN_IN_TIMEOUT_MS);
  }, [clear]);

  /** The sign-in ended; false when the page already gave up on it. */
  const settle = useCallback(() => {
    clear();
    setChecking(false);
    const inTime = !timedOut.current;
    timedOut.current = false;
    return inTime;
  }, [clear]);

  return { checking, start, settle };
}
