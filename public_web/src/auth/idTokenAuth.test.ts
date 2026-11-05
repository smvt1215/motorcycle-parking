import type { User } from '@supabase/auth-js';
import { vi } from 'vitest';
import { idTokenClaims, makeNonce, sha256Hex } from './idToken';
import {
  APPLE_CODE_MAX_AGE_MS,
  createIdTokenAuth,
  signedInUser,
  type AuthClientLike,
  type IdTokenAuthDeps,
} from './idTokenAuth';
import type { SignInResult } from './port';
import type { AppleIdAuthApi, AppleSignInResponse, GoogleIdApi } from './providers';

const SUPABASE = 'https://project.supabase.test';

/** An unsigned ID token with these claims (the page never checks signatures). */
function idToken(claims: Record<string, unknown>): string {
  const part = (value: object) =>
    btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${part({ alg: 'RS256' })}.${part(claims)}.signature`;
}

function user(provider: 'google' | 'apple', sub: string, id = 'u-1'): User {
  return {
    id,
    email: 'rider@example.com',
    app_metadata: { provider },
    user_metadata: {},
    aud: 'authenticated',
    created_at: '2026-01-01T00:00:00Z',
    identities: [
      {
        id: sub,
        identity_id: `identity-${sub}`,
        user_id: id,
        provider,
        identity_data: { sub },
      },
    ],
  } as User;
}

function fakeClient(initial: User | null = null) {
  let session: { access_token: string; user: User } | null = initial
    ? { access_token: 'access-1', user: initial }
    : null;
  let signsInAs: User | null = initial;
  const client = {
    signInWithIdToken: vi.fn(async () => {
      if (!signsInAs) return { data: { user: null, session: null }, error: new Error('refused') };
      session = { access_token: 'access-2', user: signsInAs };
      return { data: { user: signsInAs, session }, error: null };
    }),
    getSession: vi.fn(async () => ({ data: { session }, error: null })),
    signOut: vi.fn(async () => {
      session = null;
      return { error: null };
    }),
    onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: () => undefined } } })),
  };
  return {
    client,
    /** Who signInWithIdToken signs in (the backend's account for the token). */
    signsInAs(next: User | null) {
      signsInAs = next;
    },
  };
}

function fakeGoogle() {
  let config: Parameters<GoogleIdApi['initialize']>[0] | null = null;
  const api: GoogleIdApi = {
    initialize: vi.fn((next) => {
      config = next;
    }),
    renderButton: vi.fn(),
  };
  return {
    api,
    nonce: () => config?.nonce,
    /** Google hands the page an ID token, as after a press on its button. */
    press(credential: string) {
      config!.callback({ credential });
    },
  };
}

function fakeApple() {
  let settle: ((response: AppleSignInResponse) => void) | null = null;
  let fail: ((error: unknown) => void) | null = null;
  const api: AppleIdAuthApi = {
    init: vi.fn(),
    signIn: vi.fn(
      () =>
        new Promise<AppleSignInResponse>((resolve, reject) => {
          settle = resolve;
          fail = reject;
        }),
    ),
  };
  return {
    api,
    answer: (response: AppleSignInResponse) => settle!(response),
    close: () => fail!({ error: 'popup_closed_by_user' }),
  };
}

type Answer = { status: number; body: unknown } | 'network';

function fakeFetch(answers: Record<string, Answer[]>) {
  const calls: { fn: string; headers: Headers; body: Record<string, unknown> }[] = [];
  const fetch = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const fn = String(input).replace(`${SUPABASE}/functions/v1/`, '');
    calls.push({ fn, headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
    const answer = answers[fn]?.shift();
    if (!answer) throw new Error(`no answer for ${fn}`);
    if (answer === 'network') throw new TypeError('Failed to fetch');
    return new Response(JSON.stringify(answer.body), { status: answer.status });
  });
  return { fetch: fetch as unknown as typeof globalThis.fetch, calls };
}

async function settle() {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
}

function setup({
  signedIn = null,
  answers = {},
}: { signedIn?: User | null; answers?: Record<string, Answer[]> } = {}) {
  const { client, signsInAs } = fakeClient(signedIn);
  const google = fakeGoogle();
  const apple = fakeApple();
  const http = fakeFetch(answers);
  let now = 1_000_000;
  let count = 0;
  const appCheckToken = vi.fn(async () => 'app-check-token');
  const deps: IdTokenAuthDeps = {
    config: {
      supabaseUrl: SUPABASE,
      publishableKey: 'sb_publishable_test',
      googleClientId: 'google-client',
      appleServicesId: 'tw.motopark.web',
      appleRedirectUri: 'https://motoparking.smvtstudio.com/account-deletion',
    },
    client: client as unknown as AuthClientLike,
    google: async () => google.api,
    apple: async () => apple.api,
    appCheckToken,
    fetch: http.fetch,
    now: () => now,
    nonce: async () => {
      count += 1;
      return { raw: `raw-${count}`, hashed: `hashed-${count}` };
    },
  };
  return {
    auth: createIdTokenAuth(deps),
    client,
    signsInAs,
    google,
    apple,
    http,
    appCheckToken,
    advance: (ms: number) => (now += ms),
  };
}

/** Mounts the Google button and returns the results it reports. */
async function mountGoogle(world: ReturnType<typeof setup>, reauthFor?: Parameters<typeof signedInUser>[0]) {
  const results: SignInResult[] = [];
  const container = document.createElement('div');
  world.auth.mountGoogleButton(container, {
    width: 300,
    reauthFor: reauthFor ? signedInUser(reauthFor) : undefined,
    onResult: (result) => results.push(result),
  });
  await settle();
  return { results, container };
}

describe('the nonce and the token', () => {
  it('hashes the raw nonce as hex SHA-256, as Supabase Auth compares it', async () => {
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    const nonce = await makeNonce();
    expect(nonce.raw).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(nonce.hashed).toBe(await sha256Hex(nonce.raw));
  });

  it('reads the sub and the email, and nothing from a broken token', () => {
    expect(idTokenClaims(idToken({ sub: 's-1', email: 'a@b.c' }))).toEqual({ sub: 's-1', email: 'a@b.c' });
    expect(idTokenClaims('nope')).toEqual({ sub: null, email: null });
  });

  it('names the account Apple when any identity is Apple, as the App does', () => {
    expect(signedInUser(user('apple', 'a')).provider).toBe('apple');
    expect(signedInUser(user('google', 'g')).provider).toBe('google');
    const linked = user('google', 'g');
    linked.identities!.push({ ...linked.identities![0]!, provider: 'apple' });
    expect(signedInUser(linked).provider).toBe('apple');
  });
});

describe('Google', () => {
  it('draws Google’s button with a hashed nonce', async () => {
    const world = setup();
    const { container } = await mountGoogle(world);
    expect(world.google.api.initialize).toHaveBeenCalledWith(
      expect.objectContaining({ client_id: 'google-client', nonce: 'hashed-1', auto_select: false }),
    );
    expect(world.google.api.renderButton).toHaveBeenCalledWith(
      container,
      expect.objectContaining({ theme: 'outline', size: 'large', text: 'signin_with', width: 300 }),
    );
  });

  it('an identity without an account: never signed in, nothing created', async () => {
    const world = setup({
      answers: { 'deletion-precheck': [{ status: 200, body: { has_account: false } }] },
    });
    const { results } = await mountGoogle(world);
    world.google.press(idToken({ sub: 'g-new', email: 'new@gmail.com' }));
    await settle();
    expect(results).toEqual([{ kind: 'noAccount', email: 'new@gmail.com' }]);
    expect(world.client.signInWithIdToken).not.toHaveBeenCalled();
    const call = world.http.calls[0]!;
    expect(call.fn).toBe('deletion-precheck');
    expect(call.body).toEqual({
      provider: 'google',
      id_token: idToken({ sub: 'g-new', email: 'new@gmail.com' }),
      nonce: 'raw-1',
    });
    expect(call.headers.get('x-firebase-appcheck')).toBe('app-check-token');
    expect(call.headers.get('apikey')).toBe('sb_publishable_test');
    expect(call.headers.get('Authorization')).toBeNull();
    // A fresh nonce for the next press.
    expect(world.google.nonce()).toBe('hashed-2');
  });

  it('an identity with an account signs in with the same token and the raw nonce', async () => {
    const world = setup({ answers: { 'deletion-precheck': [{ status: 200, body: { has_account: true } }] } });
    world.signsInAs(user('google', 'g-1'));
    const { results } = await mountGoogle(world);
    const token = idToken({ sub: 'g-1', email: 'rider@example.com' });
    world.google.press(token);
    await settle();
    expect(world.client.signInWithIdToken).toHaveBeenCalledWith({
      provider: 'google',
      token,
      nonce: 'raw-1',
    });
    expect(results).toEqual([
      { kind: 'signedIn', user: { id: 'u-1', email: 'rider@example.com', provider: 'google' } },
    ]);
  });

  it.each([
    [{ status: 429, body: { error: 'rate_limited' } }, { kind: 'rateLimited' }],
    [{ status: 400, body: { error: 'invalid_token' } }, { kind: 'cancelled' }],
    [
      { status: 401, body: { error: 'app_check.required' } },
      { kind: 'unavailable', network: false },
    ],
    [
      { status: 503, body: { error: 'server.unavailable' } },
      { kind: 'unavailable', network: false },
    ],
    ['network' as const, { kind: 'unavailable', network: true }],
  ])('a precheck answering %j ends as %j, signed out', async (answer, expected) => {
    const world = setup({ answers: { 'deletion-precheck': [answer] } });
    const { results } = await mountGoogle(world);
    world.google.press(idToken({ sub: 'g-1' }));
    await settle();
    expect(results).toEqual([expected]);
    expect(world.client.signInWithIdToken).not.toHaveBeenCalled();
  });

  it('signing in again as another Google account changes nothing and asks nothing', async () => {
    const rider = user('google', 'g-1');
    const world = setup({ signedIn: rider });
    const { results } = await mountGoogle(world, rider);
    world.google.press(idToken({ sub: 'g-other', email: 'other@gmail.com' }));
    await settle();
    expect(results).toEqual([{ kind: 'wrongAccount', email: 'other@gmail.com' }]);
    expect(world.http.calls).toEqual([]);
    expect(world.client.signInWithIdToken).not.toHaveBeenCalled();
    expect(world.appCheckToken).not.toHaveBeenCalled();
  });

  it('signing in again as the same account refreshes the sign-in without the check', async () => {
    const rider = user('google', 'g-1');
    const world = setup({ signedIn: rider });
    const { results } = await mountGoogle(world, rider);
    world.google.press(idToken({ sub: 'g-1' }));
    await settle();
    expect(world.http.calls).toEqual([]);
    expect(world.client.signInWithIdToken).toHaveBeenCalledTimes(1);
    expect(results[0]).toMatchObject({ kind: 'signedIn', user: { id: 'u-1' } });
  });

  it('a new width only redraws: a sign-in under way still reports, with its own nonce', async () => {
    const world = setup({
      answers: { 'deletion-precheck': [{ status: 200, body: { has_account: false } }] },
    });
    const results: SignInResult[] = [];
    const mount = world.auth.mountGoogleButton(document.createElement('div'), {
      width: 300,
      onResult: (result) => results.push(result),
    });
    await settle();
    const initialized = vi.mocked(world.google.api.initialize).mock.calls.length;
    mount.resize(360);
    expect(vi.mocked(world.google.api.initialize).mock.calls.length).toBe(initialized);
    expect(vi.mocked(world.google.api.renderButton).mock.calls.at(-1)?.[1]).toMatchObject({ width: 360 });
    world.google.press(idToken({ sub: 'g-1', email: 'new@gmail.com' }));
    await settle();
    expect(results).toEqual([{ kind: 'noAccount', email: 'new@gmail.com' }]);
  });

  it('stops reporting once the button is gone', async () => {
    const world = setup({
      answers: { 'deletion-precheck': [{ status: 200, body: { has_account: false } }] },
    });
    const results: SignInResult[] = [];
    const mount = world.auth.mountGoogleButton(document.createElement('div'), {
      width: 300,
      onResult: (result) => results.push(result),
    });
    await settle();
    mount.unmount();
    world.google.press(idToken({ sub: 'g-1' }));
    await settle();
    expect(results).toEqual([]);
  });
});

describe('Apple', () => {
  async function ready(world: ReturnType<typeof setup>) {
    world.auth.prepareApple();
    await settle();
  }

  const appleAnswer = (sub: string, code = 'code-1'): AppleSignInResponse => ({
    authorization: { id_token: idToken({ sub, email: 'x@privaterelay.appleid.com' }), code },
  });

  it('is prepared ahead with a hashed nonce, and the popup opens inside the click', async () => {
    const world = setup({ answers: { 'deletion-precheck': [{ status: 200, body: { has_account: true } }] } });
    world.signsInAs(user('apple', 'a-1'));
    await ready(world);
    expect(world.apple.api.init).toHaveBeenCalledWith(
      expect.objectContaining({
        clientId: 'tw.motopark.web',
        redirectURI: 'https://motoparking.smvtstudio.com/account-deletion',
        nonce: 'hashed-1',
        usePopup: true,
      }),
    );
    const pending = world.auth.signInWithApple();
    // Synchronously: no await between the click and Apple's popup.
    expect(world.apple.api.signIn).toHaveBeenCalledTimes(1);
    world.apple.answer(appleAnswer('a-1'));
    expect(await pending).toMatchObject({ kind: 'signedIn', user: { provider: 'apple' } });
    expect(world.http.calls[0]!.body).toMatchObject({ provider: 'apple', nonce: 'raw-1' });
    await settle();
    // Ready again for another attempt, with a new nonce.
    expect(world.apple.api.init).toHaveBeenLastCalledWith(expect.objectContaining({ nonce: 'hashed-2' }));
  });

  it('a closed popup is a sign-in that did not finish', async () => {
    const world = setup();
    await ready(world);
    const pending = world.auth.signInWithApple();
    world.apple.close();
    expect(await pending).toEqual({ kind: 'cancelled' });
    expect(world.http.calls).toEqual([]);
  });

  async function signedInWithApple(answers: Record<string, Answer[]>) {
    const world = setup({
      answers: { 'deletion-precheck': [{ status: 200, body: { has_account: true } }], ...answers },
    });
    world.signsInAs(user('apple', 'a-1'));
    await ready(world);
    const pending = world.auth.signInWithApple();
    world.apple.answer(appleAnswer('a-1'));
    await pending;
    return world;
  }

  it('revokes with the sign-in’s code, once, as the signed-in rider', async () => {
    const world = await signedInWithApple({ 'apple-revoke': [{ status: 200, body: { revoked: true } }] });
    expect(world.http.calls.map((c) => c.fn)).toEqual(['deletion-precheck']);
    expect(await world.auth.revokeApple()).toEqual({ kind: 'revoked' });
    const call = world.http.calls[1]!;
    expect(call.fn).toBe('apple-revoke');
    expect(call.body).toEqual({ authorization_code: 'code-1' });
    expect(call.headers.get('Authorization')).toBe('Bearer access-2');
    // The code is single use.
    expect(await world.auth.revokeApple()).toEqual({ kind: 'signInNeeded' });
  });

  it('a code older than about 4.5 minutes asks for a new Apple sign-in, without calling Apple', async () => {
    const world = await signedInWithApple({});
    world.advance(APPLE_CODE_MAX_AGE_MS + 1);
    expect(await world.auth.revokeApple()).toEqual({ kind: 'signInNeeded' });
    expect(world.http.calls.map((c) => c.fn)).toEqual(['deletion-precheck']);
  });

  it.each([
    [{ status: 502, body: { error: 'apple.code_exchange_failed' } }, { kind: 'notRevoked' }],
    [{ status: 502, body: { error: 'apple.revoke_failed' } }, { kind: 'notRevoked' }],
    [{ status: 400, body: { error: 'apple.code_account_mismatch' } }, { kind: 'notRevoked' }],
    ['network' as const, { kind: 'notRevoked' }],
    [
      { status: 401, body: { error: 'auth.recent_sign_in_required' } },
      { kind: 'refused', error: 'auth.recent_sign_in_required' },
    ],
    [
      { status: 403, body: { error: 'account.admin_cannot_self_delete' } },
      { kind: 'refused', error: 'account.admin_cannot_self_delete' },
    ],
  ])('apple-revoke answering %j ends as %j', async (answer, expected) => {
    const world = await signedInWithApple({ 'apple-revoke': [answer] });
    expect(await world.auth.revokeApple()).toEqual(expected);
  });

  it('signing in again as another Apple ID changes nothing', async () => {
    const rider = user('apple', 'a-1');
    const world = setup({ signedIn: rider });
    await ready(world);
    const pending = world.auth.signInWithApple({ reauthFor: signedInUser(rider) });
    world.apple.answer(appleAnswer('a-other'));
    expect(await pending).toMatchObject({ kind: 'wrongAccount' });
    expect(world.client.signInWithIdToken).not.toHaveBeenCalled();
    expect(world.http.calls).toEqual([]);
    expect(await world.auth.revokeApple()).toEqual({ kind: 'signInNeeded' });
  });

  it('a session restored without an Apple sign-in on this page has no code', async () => {
    const world = setup({ signedIn: user('apple', 'a-1') });
    expect(await world.auth.revokeApple()).toEqual({ kind: 'signInNeeded' });
    expect(world.http.calls).toEqual([]);
  });
});
