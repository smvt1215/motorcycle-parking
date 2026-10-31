/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** `fixture` only under `--mode fixture`; unset in production. */
  readonly VITE_ADMIN_DATA?: 'fixture';
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
