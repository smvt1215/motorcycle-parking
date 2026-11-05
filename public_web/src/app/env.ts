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

/** What the ID-token sign-in needs; none of it is secret, but the Firebase key is not committed. */
export interface SignInEnv {
  backend: BackendEnv;
  /** Google's web OAuth client (the one the Supabase Google provider accepts). */
  googleClientId: string;
  /** Apple's Services ID for the web (the Supabase Apple provider's client). */
  appleServicesId: string;
  /** The Firebase web app whose App Check the sign-in check enforces. */
  firebase: { apiKey: string; appId: string; projectId: string };
  /** reCAPTCHA Enterprise site key of that App Check provider. */
  recaptchaSiteKey: string;
}

/** The sign-in settings, or null unless every one is set: the page then offers the support form only. */
export function signInEnv(env: ImportMetaEnv): SignInEnv | null {
  const backend = backendEnv(env);
  const value = (raw: string | undefined) => raw?.trim() || null;
  const googleClientId = value(env.VITE_GOOGLE_CLIENT_ID);
  const appleServicesId = value(env.VITE_APPLE_SERVICES_ID);
  const apiKey = value(env.VITE_FIREBASE_API_KEY);
  const appId = value(env.VITE_FIREBASE_APP_ID);
  const projectId = value(env.VITE_FIREBASE_PROJECT_ID);
  const recaptchaSiteKey = value(env.VITE_RECAPTCHA_SITE_KEY);
  if (
    !backend ||
    !googleClientId ||
    !appleServicesId ||
    !apiKey ||
    !appId ||
    !projectId ||
    !recaptchaSiteKey
  ) {
    return null;
  }
  return {
    backend,
    googleClientId,
    appleServicesId,
    firebase: { apiKey, appId, projectId },
    recaptchaSiteKey,
  };
}
