/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Supabase project URL of the deployment (staging until RC, #304). */
  readonly VITE_SUPABASE_URL?: string;
  /** The project's publishable key (public by design). */
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
