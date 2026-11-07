import { signInEnv, supportEnv } from './env';
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

describe('the support settings', () => {
  it('need the backend; the form also needs every App Check setting, not the sign-in ones', () => {
    expect(supportEnv({} as ImportMetaEnv)).toBeNull();
    const backend = { url: 'https://project.supabase.test', publishableKey: 'sb_publishable_test' };
    const appCheck = {
      firebase: { apiKey: 'firebase-key', appId: '1:1:web:1', projectId: 'project' },
      recaptchaSiteKey: 'site-key',
    };
    expect(supportEnv(full)).toEqual({ backend, appCheck });
    expect(supportEnv({ ...full, VITE_GOOGLE_CLIENT_ID: '', VITE_APPLE_SERVICES_ID: '' })).toEqual({
      backend,
      appCheck,
    });
    for (const name of [
      'VITE_FIREBASE_API_KEY',
      'VITE_FIREBASE_APP_ID',
      'VITE_FIREBASE_PROJECT_ID',
      'VITE_RECAPTCHA_SITE_KEY',
    ] as const) {
      expect(supportEnv({ ...full, [name]: ' ' })).toEqual({ backend, appCheck: null });
    }
    expect(supportEnv({ ...full, VITE_SUPABASE_URL: '' })).toBeNull();
  });
});
