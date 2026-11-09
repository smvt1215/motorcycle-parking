import { AuthClient } from '@supabase/auth-js';
import { SIGNED_OUT, type AdminAuthGateway, type AdminFactor, type FactorKind } from './gateway';

/**
 * Not the default `sb-<ref>-auth-token`: the Flutter admin on this origin
 * stores its session under that key, in a shape auth-js rejects and removes.
 * Sharing it would sign the Flutter admin out, so this page has its own.
 */
export const REACT_ADMIN_STORAGE_KEY = 'motopark-admin-react-auth';

export function supabaseGateway(url: string, anonKey: string, origin: string): AdminAuthGateway {
  const client = new AuthClient({
    url: `${url.replace(/\/$/, '')}/auth/v1`,
    headers: { apikey: anonKey, Authorization: `Bearer ${anonKey}` },
    storageKey: REACT_ADMIN_STORAGE_KEY,
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    flowType: 'pkce',
  });

  let signInError = false;
  const ready = client.initialize().then(({ error }) => {
    signInError = error !== null;
  });

  const unwrap = <T>(result: { data: T; error: unknown }): NonNullable<T> => {
    if (result.error) throw result.error;
    return result.data as NonNullable<T>;
  };

  return {
    async access() {
      await ready;
      const session = unwrap(await client.getSession()).session;
      if (!session) return SIGNED_OUT;
      const level = unwrap(await client.mfa.getAuthenticatorAssuranceLevel());
      return {
        signedIn: true,
        userId: session.user.id,
        email: session.user.email ?? null,
        isAdmin: session.user.app_metadata?.role === 'admin',
        aal2: level.currentLevel === 'aal2',
      };
    },
    onChange(listener) {
      // auth-js holds a lock while it notifies; calling back into it from
      // inside the callback would wait on that same lock.
      const { data } = client.onAuthStateChange(() => {
        setTimeout(listener, 0);
      });
      return () => data.subscription.unsubscribe();
    },
    async accessToken() {
      await ready;
      return unwrap(await client.getSession()).session?.access_token ?? null;
    },
    takeSignInError() {
      const failed = signInError;
      signInError = false;
      return failed;
    },
    async signIn() {
      unwrap(
        await client.signInWithOAuth({
          provider: 'google',
          // One fixed address, so the redirect allow-list needs one entry.
          options: { redirectTo: `${origin}/pending` },
        }),
      );
    },
    async signOut() {
      const { error } = await client.signOut({ scope: 'local' });
      if (error) throw error;
    },
    async listFactors() {
      const { all } = unwrap(await client.mfa.listFactors());
      return all
        .filter((factor) => factor.factor_type === 'totp' || factor.factor_type === 'phone')
        .map(
          (factor): AdminFactor => ({
            id: factor.id,
            name: factor.friendly_name ?? null,
            type: factor.factor_type as FactorKind,
            verified: factor.status === 'verified',
          }),
        );
    },
    async enroll(type, name, phone) {
      if (type === 'phone') {
        const data = unwrap(
          await client.mfa.enroll({ factorType: 'phone', friendlyName: name, phone: phone ?? '' }),
        );
        return { id: data.id, type, phone: data.phone };
      }
      const data = unwrap(await client.mfa.enroll({ factorType: 'totp', friendlyName: name }));
      return { id: data.id, type, qrCode: data.totp.qr_code, secret: data.totp.secret };
    },
    async challenge(factorId) {
      const data = unwrap(await client.mfa.challenge({ factorId }));
      return { id: data.id, expiresAt: data.expires_at * 1000 };
    },
    async verify(factorId, challengeId, code) {
      unwrap(await client.mfa.verify({ factorId, challengeId, code }));
    },
    async unenroll(factorId) {
      unwrap(await client.mfa.unenroll({ factorId }));
    },
  };
}
