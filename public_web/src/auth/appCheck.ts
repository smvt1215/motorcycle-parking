import type { AppCheckEnv } from '../app/env';

/**
 * Firebase App Check tokens for `deletion-precheck` (reCAPTCHA Enterprise,
 * the same web app as the support form). Firebase loads on first use, in a
 * chunk of its own; tokens refresh themselves from then on. The sign-in and
 * the support form share one getter per web app: Firebase allows one app of
 * a name.
 */
export function appCheckTokens(env: AppCheckEnv): () => Promise<string> {
  const key = `${env.firebase.appId} ${env.recaptchaSiteKey}`;
  let getter = getters.get(key);
  if (!getter) {
    getter = newAppCheckTokens(env);
    getters.set(key, getter);
  }
  return getter;
}

const getters = new Map<string, () => Promise<string>>();

function newAppCheckTokens(env: AppCheckEnv): () => Promise<string> {
  let started: Promise<{
    instance: import('firebase/app-check').AppCheck;
    getToken: typeof import('firebase/app-check').getToken;
  }> | null = null;
  const start = async () => {
    const [{ initializeApp }, appCheck] = await Promise.all([
      import('firebase/app'),
      import('firebase/app-check'),
    ]);
    // Local development only: Firebase prints a debug token to register in
    // the console, instead of asking reCAPTCHA on a host it does not allow.
    if (import.meta.env.DEV) {
      (self as unknown as { FIREBASE_APPCHECK_DEBUG_TOKEN?: boolean }).FIREBASE_APPCHECK_DEBUG_TOKEN = true;
    }
    const app = initializeApp(env.firebase, 'motopark-public');
    const instance = appCheck.initializeAppCheck(app, {
      provider: new appCheck.ReCaptchaEnterpriseProvider(env.recaptchaSiteKey),
      isTokenAutoRefreshEnabled: true,
    });
    return { instance, getToken: appCheck.getToken };
  };
  return async () => {
    if (!started) {
      started = start();
      // A failed start (e.g. offline) is tried again next time.
      started.catch(() => {
        started = null;
      });
    }
    const { instance, getToken } = await started;
    return (await getToken(instance)).token;
  };
}
