/** The build's backend: both set for a deployed site, neither for a local preview. */
export interface BackendEnv {
  url: string;
  publishableKey: string;
}

export function backendEnv(env: ImportMetaEnv): BackendEnv | null {
  const url = env.VITE_SUPABASE_URL?.trim();
  const publishableKey = env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();
  return url && publishableKey ? { url, publishableKey } : null;
}
