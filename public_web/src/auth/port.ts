/** The two ways a rider signs in to the App; the web offers the same two. */
export type Provider = 'google' | 'apple';

/** Who is signed in on the page, as much as the deletion flow needs. */
export interface SignedInUser {
  id: string;
  email: string | null;
  provider: Provider;
}

/**
 * How a sign-in ended, without leaving the page. Signing in for deletion
 * never creates an account (PM_ANS_20261105_186): the identity is checked
 * first, and one the App has never seen ends as `noAccount`.
 */
export type SignInResult =
  | { kind: 'signedIn'; user: SignedInUser }
  /** The identity has no account: nothing to delete, nothing was created. */
  | { kind: 'noAccount'; email: string | null }
  /** Signing in again for `reauthFor`, the rider picked another identity; the session is unchanged. */
  | { kind: 'wrongAccount'; email: string | null }
  /** Too many sign-in checks from this network (the backend allows 30 an hour). */
  | { kind: 'rateLimited' }
  /** The check or the sign-in could not be reached (`network`) or is down. */
  | { kind: 'unavailable'; network: boolean }
  /** Closed, refused or failed at the provider, or a token the backend refused. */
  | { kind: 'cancelled' };

/** How revoking Apple's grant before the request ended. */
export type AppleRevoke =
  | { kind: 'revoked' }
  /** No usable authorization code on this page (none, used, or older than about 4.5 minutes): sign in with Apple again. */
  | { kind: 'signInNeeded' }
  /** Apple or the network did not revoke it; the request still goes, and the rider is told afterwards. */
  | { kind: 'notRevoked' }
  /** The API stopped it, with its error code (e.g. `auth.recent_sign_in_required`, `account.admin_cannot_self_delete`). */
  | { kind: 'refused'; error: string };

export interface SignInOptions {
  /**
   * Sign in again as this user to prove it is them (the request needs a
   * sign-in in the last 10 minutes). Another identity ends as
   * `wrongAccount` and the session does not change.
   */
  reauthFor?: SignedInUser;
}

/** A mounted Google button. */
export interface GoogleButtonMount {
  /**
   * Draws the button at a new width. The sign-in set up for it (callback,
   * nonce) stays, so a sign-in already under way still reports its result.
   */
  resize(width: number): void;
  /** Removes the button; results of a sign-in still under way are dropped. */
  unmount(): void;
}

export interface GoogleButtonOptions extends SignInOptions {
  /** The button's width in CSS pixels. */
  width: number;
  /** Called after each sign-in through the button has ended. */
  onResult: (result: SignInResult) => void;
}

/**
 * Sign-in as the pages use it. Production signs in with the provider's ID
 * token (src/auth/idTokenAuth.ts); tests and the smoke build hand in
 * fakes. A build without the sign-in settings has none, and the page
 * offers the support form only.
 */
export interface AuthPort {
  /**
   * Puts the Google button in `container`: Google issues ID tokens only
   * through its own button.
   */
  mountGoogleButton(container: HTMLElement, options: GoogleButtonOptions): GoogleButtonMount;
  /**
   * Gets Apple's sign-in ready (script, nonce), so that `signInWithApple`
   * can open the popup straight from the click. Safe to call repeatedly.
   */
  prepareApple(): void;
  /** Opens Apple's popup; call it synchronously inside the click handler. */
  signInWithApple(options?: SignInOptions): Promise<SignInResult>;
  /**
   * Revokes the Apple grant with the authorization code of the latest
   * Apple sign-in on this page. Only right before the request: a rider who
   * signs in to cancel keeps Sign in with Apple.
   */
  revokeApple(): Promise<AppleRevoke>;
  /** Signs out on this browser only; other devices were signed out by the request. */
  signOut(): Promise<void>;
  /** The access token for API calls, or null when signed out. */
  accessToken(): Promise<string | null>;
  /** Calls back with the current user now and after every change; returns the unsubscribe. */
  onChange(listener: (user: SignedInUser | null) => void): () => void;
}
