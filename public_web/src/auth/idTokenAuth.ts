import { isAuthRetryableFetchError, type GoTrueClient, type User } from '@supabase/auth-js';
import { idTokenClaims, makeNonce, randomToken, type Nonce } from './idToken';
import type { AuthPort, AppleRevoke, Provider, SignedInUser, SignInOptions, SignInResult } from './port';
import type { AppleIdAuthApi, GoogleIdApi } from './providers';

/** Apple's authorization code lives about 5 minutes; past this the page asks for a new one. */
export const APPLE_CODE_MAX_AGE_MS = 4.5 * 60 * 1000;

export interface IdTokenAuthConfig {
  /** Supabase project URL. */
  supabaseUrl: string;
  publishableKey: string;
  googleClientId: string;
  appleServicesId: string;
  /** Apple's Return URL: this page, e.g. https://motoparking.smvtstudio.com/account-deletion. */
  appleRedirectUri: string;
}

export type AuthClientLike = Pick<
  GoTrueClient,
  'signInWithIdToken' | 'signOut' | 'getSession' | 'onAuthStateChange'
>;

export interface IdTokenAuthDeps {
  config: IdTokenAuthConfig;
  client: AuthClientLike;
  google: () => Promise<GoogleIdApi>;
  apple: () => Promise<AppleIdAuthApi>;
  /** A Firebase App Check token for the sign-in check. */
  appCheckToken: () => Promise<string>;
  fetch: typeof fetch;
  now: () => number;
  nonce?: () => Promise<Nonce>;
}

/** The provider the App would say the account signs in with (lib/data/account_deletion.dart). */
export function signedInUser(user: User): SignedInUser {
  const apple =
    user.app_metadata?.provider === 'apple' || (user.identities ?? []).some((i) => i.provider === 'apple');
  return { id: user.id, email: user.email ?? null, provider: apple ? 'apple' : 'google' };
}

/** The provider's user ids (sub) of the account's identities with that provider. */
function subjectsOf(user: User, provider: Provider): string[] {
  return (user.identities ?? [])
    .filter((identity) => identity.provider === provider)
    .map((identity) => {
      const sub = identity.identity_data?.sub;
      return typeof sub === 'string' && sub ? sub : identity.id;
    });
}

type Precheck = { hasAccount: boolean } | { result: SignInResult };

/**
 * Production sign-in (PM_ANS_20261105_186: signing in for deletion never
 * creates an account). The provider's ID token is taken in the browser and
 * checked with `deletion-precheck` first; only an identity that has an
 * account is signed in with `signInWithIdToken`, with the same token and
 * raw nonce. Signing in again (`reauthFor`) skips the check but must be the
 * same identity, or nothing is signed in.
 */
export function createIdTokenAuth(deps: IdTokenAuthDeps): AuthPort {
  const { config, client } = deps;
  const nonce = deps.nonce ?? makeNonce;
  const functions = `${config.supabaseUrl.replace(/\/$/, '')}/functions/v1`;

  /** The code of the latest Apple sign-in, kept in memory only. */
  let appleCode: { code: string; at: number } | null = null;
  /** Apple's script and the nonce it was given, ready for the next click. */
  let appleReady: { api: AppleIdAuthApi; nonce: Nonce } | null = null;
  let applePreparing: Promise<void> | null = null;

  function warmAppCheck() {
    deps.appCheckToken().catch(() => undefined);
  }

  async function precheck(provider: Provider, idToken: string, rawNonce: string): Promise<Precheck> {
    let appCheck: string;
    try {
      appCheck = await deps.appCheckToken();
    } catch {
      return {
        result: { kind: 'unavailable', network: typeof navigator !== 'undefined' && !navigator.onLine },
      };
    }
    let response: Response;
    try {
      response = await deps.fetch(`${functions}/deletion-precheck`, {
        method: 'POST',
        headers: {
          apikey: config.publishableKey,
          'Content-Type': 'application/json',
          'x-firebase-appcheck': appCheck,
        },
        body: JSON.stringify({ provider, id_token: idToken, nonce: rawNonce }),
      });
    } catch {
      return { result: { kind: 'unavailable', network: true } };
    }
    const body = (await response.json().catch(() => null)) as { has_account?: unknown } | null;
    if (response.ok && typeof body?.has_account === 'boolean') return { hasAccount: body.has_account };
    if (response.status === 429) return { result: { kind: 'rateLimited' } };
    // invalid_token / request.invalid: this token cannot sign in; try again.
    if (response.status === 400) return { result: { kind: 'cancelled' } };
    // app_check.required, server.unavailable, anything else.
    return { result: { kind: 'unavailable', network: false } };
  }

  async function signInWithToken(
    provider: Provider,
    idToken: string,
    rawNonce: string,
  ): Promise<SignInResult> {
    let answer;
    try {
      answer = await client.signInWithIdToken({ provider, token: idToken, nonce: rawNonce });
    } catch {
      return { kind: 'unavailable', network: true };
    }
    const { data, error } = answer;
    if (error || !data.user) {
      return isAuthRetryableFetchError(error)
        ? { kind: 'unavailable', network: true }
        : { kind: 'cancelled' };
    }
    return { kind: 'signedIn', user: signedInUser(data.user) };
  }

  /** After the provider handed over its ID token. */
  async function complete(
    provider: Provider,
    idToken: string,
    rawNonce: string,
    options: SignInOptions | undefined,
  ): Promise<SignInResult> {
    const claims = idTokenClaims(idToken);
    const reauthFor = options?.reauthFor;
    if (reauthFor) {
      // The same identity, or nothing is sent anywhere and the session stays.
      const { data } = await client.getSession();
      const current = data.session?.user;
      if (
        !current ||
        current.id !== reauthFor.id ||
        !claims.sub ||
        !subjectsOf(current, provider).includes(claims.sub)
      ) {
        return { kind: 'wrongAccount', email: claims.email };
      }
      return signInWithToken(provider, idToken, rawNonce);
    }
    const checked = await precheck(provider, idToken, rawNonce);
    if ('result' in checked) return checked.result;
    if (!checked.hasAccount) return { kind: 'noAccount', email: claims.email };
    return signInWithToken(provider, idToken, rawNonce);
  }

  function prepareApple() {
    if (appleReady || applePreparing) return;
    applePreparing = (async () => {
      const api = await deps.apple();
      const next = await nonce();
      api.init({
        clientId: config.appleServicesId,
        scope: 'email',
        redirectURI: config.appleRedirectUri,
        state: randomToken(),
        nonce: next.hashed,
        usePopup: true,
      });
      appleReady = { api, nonce: next };
    })()
      .catch(() => undefined)
      .finally(() => {
        applePreparing = null;
      });
  }

  return {
    mountGoogleButton(container, { reauthFor, width, onResult }) {
      let alive = true;
      let current: Nonce | null = null;
      if (!reauthFor) warmAppCheck();
      const arm = async () => {
        const [api, next] = await Promise.all([deps.google(), nonce()]);
        if (!alive) return;
        current = next;
        // initialize() replaces the whole configuration, nonce included.
        api.initialize({
          client_id: config.googleClientId,
          nonce: next.hashed,
          auto_select: false,
          cancel_on_tap_outside: true,
          ux_mode: 'popup',
          itp_support: true,
          callback: (response) => {
            const raw = current?.raw;
            // A fresh nonce for the next press, whatever this one ends as.
            void arm().catch(() => undefined);
            const finish = (result: SignInResult) => {
              if (alive) onResult(result);
            };
            if (!response.credential || !raw) return finish({ kind: 'cancelled' });
            complete('google', response.credential, raw, reauthFor ? { reauthFor } : undefined).then(
              finish,
              () => finish({ kind: 'cancelled' }),
            );
          },
        });
        container.replaceChildren();
        api.renderButton(container, {
          type: 'standard',
          theme: 'outline',
          size: 'large',
          text: 'signin_with',
          shape: 'pill',
          logo_alignment: 'center',
          width,
          locale: 'zh_TW',
        });
      };
      // Without Google's script there is no button; Apple and the support form remain.
      arm().catch(() => undefined);
      return () => {
        alive = false;
        container.replaceChildren();
      };
    },

    prepareApple() {
      warmAppCheck();
      prepareApple();
    },

    signInWithApple(options) {
      const ready = appleReady;
      if (!ready) {
        // Not ready yet (script still loading): nothing opened.
        prepareApple();
        return Promise.resolve({ kind: 'cancelled' });
      }
      appleReady = null;
      // Called before any await: the popup needs the click's activation.
      const popup = ready.api.signIn();
      return (async (): Promise<SignInResult> => {
        try {
          const response = await popup;
          const idToken = response.authorization?.id_token;
          const code = response.authorization?.code;
          if (!idToken) return { kind: 'cancelled' };
          const result = await complete('apple', idToken, ready.nonce.raw, options);
          if (result.kind === 'signedIn') appleCode = code ? { code, at: deps.now() } : null;
          return result;
        } catch {
          // popup_closed_by_user, user_cancelled_authorize, ...
          return { kind: 'cancelled' };
        } finally {
          prepareApple();
        }
      })();
    },

    async revokeApple(): Promise<AppleRevoke> {
      const code = appleCode;
      // Single use: whatever happens next, this code is spent.
      appleCode = null;
      if (!code || deps.now() - code.at > APPLE_CODE_MAX_AGE_MS) return { kind: 'signInNeeded' };
      const { data } = await client.getSession();
      const token = data.session?.access_token;
      if (!token) return { kind: 'refused', error: 'auth.sign_in_required' };
      let response: Response;
      try {
        response = await deps.fetch(`${functions}/apple-revoke`, {
          method: 'POST',
          headers: {
            apikey: config.publishableKey,
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ authorization_code: code.code }),
        });
      } catch {
        return { kind: 'notRevoked' };
      }
      const body = (await response.json().catch(() => null)) as { revoked?: unknown; error?: unknown } | null;
      if (response.ok && body?.revoked === true) return { kind: 'revoked' };
      const error = typeof body?.error === 'string' ? body.error : null;
      if (
        error === 'auth.sign_in_required' ||
        error === 'auth.recent_sign_in_required' ||
        error === 'account.admin_cannot_self_delete'
      ) {
        return { kind: 'refused', error };
      }
      // apple.code_exchange_failed, apple.revoke_failed, apple.code_account_mismatch,
      // apple.not_configured, account.not_apple_sign_in, server trouble.
      return { kind: 'notRevoked' };
    },

    async signOut() {
      appleCode = null;
      // The local session is removed even when the server could not be told.
      await client.signOut({ scope: 'local' });
    },

    async accessToken() {
      const { data } = await client.getSession();
      return data.session?.access_token ?? null;
    },

    onChange(listener) {
      let last: string | null = null;
      const {
        data: { subscription },
      } = client.onAuthStateChange((_event, session) => {
        const user = session?.user ? signedInUser(session.user) : null;
        // A refreshed token is the same rider: only a change is passed on.
        const key = user ? `${user.id}|${user.email}|${user.provider}` : '';
        if (key === last) return;
        last = key;
        listener(user);
      });
      return () => subscription.unsubscribe();
    },
  };
}
