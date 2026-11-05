import type { AuthPort } from '../auth/port';
import { signInEnv } from './env';

/**
 * The deployed site's sign-in, or null when the build lacks any of its
 * settings: the page then explains and offers the support form only. The
 * smoke build's fake is chosen in main.tsx, where the mode is fixed at
 * build time so production drops it.
 */
export async function productionSignIn(env: ImportMetaEnv, origin: string): Promise<AuthPort | null> {
  const settings = signInEnv(env);
  if (!settings) return null;
  const { productionAuth } = await import('../auth/production');
  return productionAuth(settings, origin);
}
