import { useState } from 'react';
import { Provider } from 'react-redux';
import { createBrowserRouter, RouterProvider } from 'react-router';
import type { AppStore } from './app/store';
import { AuthProvider } from './auth/AuthContext';
import type { AuthPort } from './auth/port';
import { routes } from './routes';
import type { SupportPort } from './support/client';
import { SupportContext } from './support/SupportContext';

/** The site: the store and sign-in around the browser router. */
export function App({
  store,
  auth,
  support,
}: {
  store: AppStore;
  auth: AuthPort | null;
  support: SupportPort | null;
}) {
  // Made on first render, not when the module loads (tests import routes alone).
  const [router] = useState(() => createBrowserRouter(routes));
  return (
    <Provider store={store}>
      <AuthProvider auth={auth}>
        <SupportContext.Provider value={support}>
          <RouterProvider router={router} />
        </SupportContext.Provider>
      </AuthProvider>
    </Provider>
  );
}
