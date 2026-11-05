import { AuthClient } from '@supabase/auth-js';
import type { SignInEnv } from '../app/env';
import { appCheckTokens } from './appCheck';
import { createIdTokenAuth } from './idTokenAuth';
import type { AuthPort } from './port';
import { loadApple, loadGoogle } from './providers';

/**
 * The deployed site's sign-in: Supabase Auth with the provider's ID token,
 * the providers' own browser SDKs, and App Check for the sign-in check.
 * `origin` is the page's: Apple's Return URL is this page, and in
 * production must be https://motoparking.smvtstudio.com/account-deletion.
 */
export function productionAuth(env: SignInEnv, origin: string): AuthPort {
  const { url, publishableKey } = env.backend;
  const client = new AuthClient({
    url: `${url.replace(/\/$/, '')}/auth/v1`,
    headers: { apikey: publishableKey, Authorization: `Bearer ${publishableKey}` },
    storageKey: 'motopark-public-auth',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  });
  return createIdTokenAuth({
    config: {
      supabaseUrl: url,
      publishableKey,
      googleClientId: env.googleClientId,
      appleServicesId: env.appleServicesId,
      appleRedirectUri: `${origin}/account-deletion`,
    },
    client,
    google: loadGoogle,
    apple: loadApple,
    appCheckToken: appCheckTokens(env),
    fetch: (input, init) => fetch(input, init),
    now: () => Date.now(),
  });
}
