import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { backendEnv, supportEnv } from './app/env';
import { productionSignIn } from './app/signIn';
import { makeStore } from './app/store';
import { appCheckTokens } from './auth/appCheck';
import type { AuthPort } from './auth/port';
import { createSupportClient, type SupportPort } from './support/client';
import './styles.css';

const env = backendEnv(import.meta.env);

/**
 * The sign-in: the ID-token sign-in when the build has all its settings,
 * else none (the explanation and the support form only). The smoke build
 * signs in with its fake; the condition is fixed at build time, so
 * production drops that code.
 */
async function signIn(): Promise<AuthPort | null> {
  if (import.meta.env.MODE === 'smoke') return (await import('./smoke/smokeAuth')).smokeAuth();
  return productionSignIn(import.meta.env, window.location.origin);
}

/**
 * The support pages' backend: the one-time links need only the backend, the
 * form also App Check. The smoke build has no App Check settings; it uses a
 * fixed token the smoke script's backend accepts.
 */
function support(): SupportPort | null {
  const settings = supportEnv(import.meta.env);
  if (!settings) return null;
  const appCheckToken =
    import.meta.env.MODE === 'smoke'
      ? async () => 'smoke-app-check'
      : settings.appCheck
        ? appCheckTokens(settings.appCheck)
        : null;
  return createSupportClient({
    supabaseUrl: settings.backend.url,
    publishableKey: settings.backend.publishableKey,
    appCheckToken,
    fetch: (input, init) => fetch(input, init),
  });
}

void signIn().then((auth) => {
  const store = makeStore({
    postgrest:
      env && auth
        ? { url: env.url, anonKey: env.publishableKey, accessToken: () => auth.accessToken() }
        : null,
  });
  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <App store={store} auth={auth} support={support()} />
    </StrictMode>,
  );
});
