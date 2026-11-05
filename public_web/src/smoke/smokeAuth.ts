import type { AuthPort, SignedInUser, SignInResult } from '../auth/port';

/**
 * Sign-in for `npm run smoke` only (main.tsx loads it in the smoke build;
 * production builds drop it). The script stores who is signed in and how
 * the next sign-in ends before the page loads.
 */
export const SMOKE_USER = 'motopark-smoke-user';
export const SMOKE_SIGN_IN = 'motopark-smoke-sign-in';

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
  return {
    async signIn() {
      const result = read<SignInResult>(SMOKE_SIGN_IN) ?? { kind: 'cancelled' };
      if (result.kind === 'signedIn') change(result.user);
      return result;
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
