import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { backendEnv } from './app/env';
import { makeStore } from './app/store';
import type { AuthPort } from './auth/port';
import './styles.css';

const env = backendEnv(import.meta.env);

/**
 * The sign-in: none until the ID-token sign-in lands (T_DEL_WEB_Q1), so a
 * build offers the explanation and the support form only. The smoke build
 * signs in with its fake; the condition is fixed at build time, so
 * production drops that code.
 */
async function signIn(): Promise<AuthPort | null> {
  if (import.meta.env.MODE === 'smoke') return (await import('./smoke/smokeAuth')).smokeAuth();
  return null;
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
