/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Supabase project URL of the deployment (staging until RC, #304). */
  readonly VITE_SUPABASE_URL?: string;
  /** The project's publishable key (public by design). */
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
  /** Google web OAuth client id for Google Identity Services. */
  readonly VITE_GOOGLE_CLIENT_ID?: string;
  /** Apple Services ID for Sign in with Apple JS. */
  readonly VITE_APPLE_SERVICES_ID?: string;
  /** Firebase web app (App Check); the apiKey comes from CD, never the repo. */
  readonly VITE_FIREBASE_API_KEY?: string;
  readonly VITE_FIREBASE_APP_ID?: string;
  readonly VITE_FIREBASE_PROJECT_ID?: string;
  /** reCAPTCHA Enterprise site key of the App Check provider. */
  readonly VITE_RECAPTCHA_SITE_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
