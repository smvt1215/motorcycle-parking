import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { checking, checkingHint, signInButton } from '../deletion/text';
import type { AuthPort, GoogleButtonMount, SignedInUser, SignInResult } from './port';
import type { SignInAttempt } from './useSignInChecking';

/** Google draws its button between 200 and 400px wide. */
const MIN_WIDTH = 200;
const MAX_WIDTH = 400;

function clampWidth(width: number): number {
  return Math.round(Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, width)));
}

/**
 * The Google button, drawn by Google into a box as wide as the layout's
 * column (Google issues ID tokens only through its own button). It is drawn
 * again when the column changes width.
 */
export function GoogleButton({
  auth,
  reauthFor,
  attempt,
  onResult,
}: {
  auth: AuthPort;
  reauthFor?: SignedInUser;
  /** Starts tracking a press of the button (useSignInChecking). */
  attempt: () => SignInAttempt;
  onResult: (result: SignInResult) => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState<number | null>(null);
  // The latest callback, without drawing the button again for a new one.
  const latest = useRef(onResult);
  const latestAttempt = useRef(attempt);
  useLayoutEffect(() => {
    latest.current = onResult;
    latestAttempt.current = attempt;
  });

  useLayoutEffect(() => {
    const element = box.current;
    if (!element) return;
    setWidth(clampWidth(element.clientWidth));
    if (typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(() => setWidth(clampWidth(element.clientWidth)));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // Mounted once per sign-in setup; a new width only draws it again, so a
  // sign-in under way when the column changes still reports its result.
  const mount = useRef<GoogleButtonMount | null>(null);
  const mounted = width !== null;
  useEffect(() => {
    const element = box.current;
    if (!element || !mounted) return;
    let pressed: SignInAttempt | null = null;
    const current = auth.mountGoogleButton(element, {
      reauthFor,
      width: clampWidth(element.clientWidth),
      onChecking: () => {
        pressed = latestAttempt.current();
        return pressed.onChecking();
      },
      onResult: (result) => {
        const ended = pressed;
        pressed = null;
        if (ended?.accept() ?? true) latest.current(result);
      },
    });
    mount.current = current;
    return () => {
      mount.current = null;
      current.unmount();
    };
  }, [auth, reauthFor, mounted]);
  useEffect(() => {
    if (width !== null) mount.current?.resize(width);
  }, [width]);

  return <div ref={box} className="signin-google" />;
}

/** In place of the buttons while the sign-in is being checked (canvas SignInLoading). */
export function SignInChecking() {
  return (
    <div className="signin-checking" role="status">
      <svg className="signin-checking-ring" width="28" height="28" viewBox="0 0 28 28" aria-hidden="true">
        <circle cx="14" cy="14" r="11" fill="none" stroke="var(--line)" strokeWidth="3.5" />
        <path
          d="M14 3a11 11 0 0 1 11 11"
          fill="none"
          stroke="var(--brand)"
          strokeWidth="3.5"
          strokeLinecap="round"
        />
      </svg>
      <span className="signin-checking-text">
        <strong>{checking}</strong>
        <span>{checkingHint}</span>
      </span>
    </div>
  );
}

/**
 * Our Apple button (Apple's JS has no button that returns the code in a
 * popup the way we lay it out). The popup opens straight from the click, so
 * Apple's sign-in is prepared when the button appears.
 */
export function AppleButton({ auth, onClick }: { auth: AuthPort; onClick: () => void }) {
  useEffect(() => auth.prepareApple(), [auth]);
  return (
    <button type="button" className="signin-button signin-button--apple" onClick={onClick}>
      {signInButton('apple')}
    </button>
  );
}
