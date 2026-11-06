import type { AppleRevoke, AuthPort, SignedInUser, SignInResult } from '../auth/port';

/**
 * Sign-in for `npm run smoke` only (main.tsx loads it in the smoke build;
 * production builds drop it). The script stores who is signed in, how the
 * next sign-in ends and how revoking Apple's grant ends before the page
 * loads. The Google button is a plain one of the same size as Google's.
 */
export const SMOKE_USER = 'motopark-smoke-user';
export const SMOKE_SIGN_IN = 'motopark-smoke-sign-in';
export const SMOKE_APPLE_REVOKE = 'motopark-smoke-apple-revoke';

function read<T>(key: string): T | null {
  const raw = localStorage.getItem(key);
  return raw ? (JSON.parse(raw) as T) : null;
}

export function smokeAuth(): AuthPort {
  let user = read<SignedInUser>(SMOKE_USER);
  const listeners = new Set<(user: SignedInUser | null) => void>();
  const change = (next: SignedInUser | null) => {
    user = next;
    listeners.forEach((listener) => listener(next));
  };
  async function signIn(onChecking?: () => void): Promise<SignInResult> {
    const result = read<SignInResult | { kind: 'hold' }>(SMOKE_SIGN_IN) ?? { kind: 'cancelled' };
    onChecking?.();
    // Stays in the checking state, for its screenshot.
    if (result.kind === 'hold') return new Promise(() => {});
    if (result.kind === 'signedIn') change(result.user);
    return result;
  }
  return {
    mountGoogleButton(container, { onChecking, onResult }) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'signin-button signin-button--google';
      button.textContent = '使用 Google 登入';
      button.addEventListener('click', () => void signIn(onChecking).then(onResult));
      container.append(button);
      return { resize() {}, unmount: () => button.remove() };
    },
    prepareApple() {},
    signInWithApple: (options) => signIn(options?.onChecking),
    async revokeApple() {
      return read<AppleRevoke>(SMOKE_APPLE_REVOKE) ?? { kind: 'revoked' };
    },
    async signOut() {
      change(null);
    },
    async accessToken() {
      return user ? 'smoke-token' : null;
    },
    onChange(listener) {
      listeners.add(listener);
      listener(user);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
