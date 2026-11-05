import { signInEnv } from './env';
import { productionSignIn } from './signIn';

const full: ImportMetaEnv = {
  VITE_SUPABASE_URL: 'https://project.supabase.test',
  VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test',
  VITE_GOOGLE_CLIENT_ID: 'google-client',
  VITE_APPLE_SERVICES_ID: 'tw.motopark.web',
  VITE_FIREBASE_API_KEY: 'firebase-key',
  VITE_FIREBASE_APP_ID: '1:1:web:1',
  VITE_FIREBASE_PROJECT_ID: 'project',
  VITE_RECAPTCHA_SITE_KEY: 'site-key',
} as ImportMetaEnv;

describe('the production sign-in', () => {
  it('is offered only when every setting is there', async () => {
    expect(await productionSignIn({} as ImportMetaEnv, 'https://motoparking.smvtstudio.com')).toBeNull();
    for (const name of Object.keys(full) as (keyof ImportMetaEnv)[]) {
      const missing = { ...full, [name]: ' ' } as ImportMetaEnv;
      expect(signInEnv(missing)).toBeNull();
      expect(await productionSignIn(missing, 'https://motoparking.smvtstudio.com')).toBeNull();
    }
  });

  it('is the ID-token sign-in when configured', async () => {
    expect(signInEnv(full)).toEqual({
      backend: { url: 'https://project.supabase.test', publishableKey: 'sb_publishable_test' },
      googleClientId: 'google-client',
      appleServicesId: 'tw.motopark.web',
      firebase: { apiKey: 'firebase-key', appId: '1:1:web:1', projectId: 'project' },
      recaptchaSiteKey: 'site-key',
    });
    const auth = await productionSignIn(full, 'https://motoparking.smvtstudio.com');
    expect(auth).not.toBeNull();
    expect(await auth!.accessToken()).toBeNull();
  });
});
