import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';

/** How long the page waits for the check and the sign-in (user, 2026-11-08). */
export const SIGN_IN_TIMEOUT_MS = 30_000;

/** One press of a sign-in button, from the provider answering to its result. */
export interface SignInAttempt {
  /** The provider answered: show checking. Returns whether the page gave up on this attempt. */
  onChecking: () => () => boolean;
  /** The attempt ended; false when the page already gave up on it. */
  accept: () => boolean;
}

/**
 * From the provider's popup answering until the result arrives: the page
 * shows it is checking instead of the buttons, and gives up after
 * SIGN_IN_TIMEOUT_MS (canvas SignInLoading, PhoneSignInLoading).
 *
 * Each press is its own attempt: an expired one stays expired whatever a
 * later attempt does, so a late success can never act (it could otherwise
 * send a deletion request nobody is waiting for).
 */
export function useSignInChecking(onTimeout: () => void) {
  const [checking, setChecking] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  /** The attempt the page is waiting for; null when it waits for none. */
  const waitingFor = useRef<object | null>(null);
  const latest = useRef(onTimeout);
  useLayoutEffect(() => {
    latest.current = onTimeout;
  });

  const clear = useCallback(() => {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
  }, []);
  // Only the timer stops. A sign-in that succeeds unmounts this page before
  // signInWithIdToken returns (the session arrives first); it must not then
  // read as given up, or the rider would be signed straight out again.
  useEffect(() => clear, [clear]);

  const attempt = useCallback((): SignInAttempt => {
    const self = {};
    let started = false;
    return {
      onChecking() {
        started = true;
        clear();
        waitingFor.current = self;
        setChecking(true);
        timer.current = setTimeout(() => {
          timer.current = null;
          waitingFor.current = null;
          setChecking(false);
          latest.current();
        }, SIGN_IN_TIMEOUT_MS);
        return () => waitingFor.current !== self;
      },
      accept() {
        // Ended before the provider answered (a closed popup): nothing to
        // stop, and another attempt's wait must stay as it is.
        if (!started) return true;
        if (waitingFor.current !== self) return false;
        clear();
        waitingFor.current = null;
        setChecking(false);
        return true;
      },
    };
  }, [clear]);

  return { checking, attempt };
}
