import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { backendEnv } from './app/env';
import { productionSignIn } from './app/signIn';
import { makeStore } from './app/store';
import type { AuthPort } from './auth/port';
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

void signIn().then((auth) => {
  const store = makeStore({
    postgrest:
      env && auth
        ? { url: env.url, anonKey: env.publishableKey, accessToken: () => auth.accessToken() }
        : null,
  });
  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <App store={store} auth={auth} />
    </StrictMode>,
  );
});
