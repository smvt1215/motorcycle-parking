import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { signInButton } from '../deletion/text';
import type { AuthPort, SignedInUser, SignInResult } from './port';

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
  onResult,
}: {
  auth: AuthPort;
  reauthFor?: SignedInUser;
  onResult: (result: SignInResult) => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState<number | null>(null);
  // The latest callback, without drawing the button again for a new one.
  const latest = useRef(onResult);
  useLayoutEffect(() => {
    latest.current = onResult;
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

  useEffect(() => {
    const element = box.current;
    if (!element || width === null) return;
    return auth.mountGoogleButton(element, {
      reauthFor,
      width,
      onResult: (result) => latest.current(result),
    });
  }, [auth, reauthFor, width]);

  return <div ref={box} className="signin-google" />;
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
