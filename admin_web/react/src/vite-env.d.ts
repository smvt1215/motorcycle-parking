/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** `fixture` only under `--mode fixture`; unset in production. */
  readonly VITE_ADMIN_DATA?: 'fixture';
  /** Set by CD for the deployed page; without them sign-in says it is not set up. */
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
