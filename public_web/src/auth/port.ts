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
  /** Closed, refused or failed at the provider. */
  | { kind: 'cancelled' };

/**
 * Sign-in as the pages use it. The backend's ID-token sign-in implements it
 * (pending T_DEL_WEB_Q1); tests and the smoke build hand in fakes. Until
 * then a build has none, and the page offers the support form only.
 */
export interface AuthPort {
  /**
   * Signs in with the provider's own dialog. With `reauthFor`, the rider
   * signs in again as that user to prove it is them (the request needs a
   * sign-in in the last 10 minutes).
   */
  signIn(provider: Provider, options?: { reauthFor?: SignedInUser }): Promise<SignInResult>;
  /** Signs out on this browser only; other devices were signed out by the request. */
  signOut(): Promise<void>;
  /** The access token for API calls, or null when signed out. */
  accessToken(): Promise<string | null>;
  /** Calls back with the current user now and after every change; returns the unsubscribe. */
  onChange(listener: (user: SignedInUser | null) => void): () => void;
}
