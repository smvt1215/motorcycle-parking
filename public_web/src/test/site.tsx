import { render } from '@testing-library/react';
import { act } from 'react';
import { Provider } from 'react-redux';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { vi } from 'vitest';
import { makeStore } from '../app/store';
import { AuthProvider } from '../auth/AuthContext';
import type {
  AppleRevoke,
  AuthPort,
  Provider as ProviderName,
  SignedInUser,
  SignInOptions,
  SignInResult,
} from '../auth/port';
import { routes } from '../routes';

/** How the fake ends a sign-in through either button; tests read its calls. */
type SignIn = (provider: ProviderName, options?: SignInOptions) => Promise<SignInResult>;

/** A sign-in the test drives: who is signed in, how the next sign-in ends, what the page asked for. */
export interface FakeAuth extends AuthPort {
  /** Every sign-in through the Google or the Apple button. */
  signIn: ReturnType<typeof vi.fn<SignIn>>;
  signOut: ReturnType<typeof vi.fn<() => Promise<void>>>;
  revokeApple: ReturnType<typeof vi.fn<() => Promise<AppleRevoke>>>;
  /** While set, a sign-in stays in the checking state until the promise resolves. */
  hold: Promise<void> | null;
  /** How the next sign-in ends; a `signedIn` result also signs that user in. */
  next: SignInResult;
  /** How revoking Apple's grant ends. */
  nextRevoke: AppleRevoke;
}

/**
 * Stands in for the production sign-in. Its Google button is a plain
 * button with Google's label, where production has Google's own.
 */
export function fakeAuth(initial: SignedInUser | null = null): FakeAuth {
  let user = initial;
  const listeners = new Set<(user: SignedInUser | null) => void>();
  const change = (next: SignedInUser | null) => {
    user = next;
    listeners.forEach((listener) => listener(next));
  };
  /** The provider answers: the page is told, and `hold` keeps the sign-in open. */
  async function answered(onChecking?: () => void) {
    if (onChecking) act(onChecking);
    if (auth.hold) await auth.hold;
  }
  const auth: FakeAuth = {
    hold: null,
    next: { kind: 'cancelled' },
    nextRevoke: { kind: 'revoked' },
    signIn: vi.fn<SignIn>(async () => {
      const result = auth.next;
      if (result.kind === 'signedIn') act(() => change(result.user));
      return result;
    }),
    mountGoogleButton(container, { reauthFor, onChecking, onResult }) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'signin-button signin-button--google';
      button.textContent = '使用 Google 登入';
      button.addEventListener('click', () => {
        void answered(onChecking)
          .then(() => (reauthFor ? auth.signIn('google', { reauthFor }) : auth.signIn('google')))
          .then((result) => act(() => onResult(result)));
      });
      container.append(button);
      return { resize() {}, unmount: () => button.remove() };
    },
    prepareApple() {},
    async signInWithApple(options) {
      await answered(options?.onChecking);
      return options?.reauthFor
        ? auth.signIn('apple', { reauthFor: options.reauthFor })
        : auth.signIn('apple');
    },
    revokeApple: vi.fn(async () => auth.nextRevoke),
    signOut: vi.fn(async () => act(() => change(null))),
    accessToken: async () => (user ? `token-${user.id}` : null),
    onChange(listener) {
      listeners.add(listener);
      listener(user);
      return () => {
        listeners.delete(listener);
      };
    },
  };
  return auth;
}

export const rider: SignedInUser = { id: 'u-1', email: 'rider@gmail.com', provider: 'google' };

/** An API answer: the body with its HTTP status, or no answer at all. */
export type Answer = { status?: number; body: unknown } | 'network';

/**
 * Stubs fetch for the api_v1 RPCs by function name. Each name takes one
 * answer, or a list used in turn (the last repeats).
 */
export function stubApi(answers: Record<string, Answer | Answer[]>) {
  const calls: { fn: string; body: unknown; token: string | null }[] = [];
  const used: Record<string, number> = {};
  const fetchStub = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const fn = url.slice(url.lastIndexOf('/') + 1);
    const headers = new Headers(init?.headers);
    calls.push({
      fn,
      body: init?.body ? JSON.parse(String(init.body)) : null,
      token: headers.get('Authorization'),
    });
    const listed = answers[fn];
    if (!listed) throw new Error(`no answer for ${fn}`);
    const list = Array.isArray(listed) ? listed : [listed];
    const index = Math.min(used[fn] ?? 0, list.length - 1);
    used[fn] = (used[fn] ?? 0) + 1;
    const answer = list[index]!;
    if (answer === 'network') throw new TypeError('Failed to fetch');
    return new Response(JSON.stringify(answer.body), {
      status: answer.status ?? 200,
      headers: { 'Content-Type': 'application/json' },
    });
  });
  vi.stubGlobal('fetch', fetchStub);
  return calls;
}

export function apiError(status: number, message: string): Answer {
  return { status, body: { code: `PT${status}`, message, details: null, hint: null } };
}

export const noRequest = {
  status: 'none',
  requested_at: null,
  scheduled_at: null,
  can_self_delete: true,
  cannot_self_delete_reason: null,
};

export function pendingUntil(scheduledAt: string) {
  return { ...noRequest, status: 'pending', requested_at: '2026-11-05T02:00:00Z', scheduled_at: scheduledAt };
}

/** Renders the site at `path` with a store, the given sign-in and a test backend. */
export function openSite(path: string, auth: AuthPort | null = fakeAuth()) {
  const store = makeStore({
    postgrest: auth
      ? { url: 'https://api.test', anonKey: 'anon', accessToken: () => auth.accessToken() }
      : null,
  });
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  render(
    <Provider store={store}>
      <AuthProvider auth={auth}>
        <RouterProvider router={router} />
      </AuthProvider>
    </Provider>,
  );
  return { router, store };
}
