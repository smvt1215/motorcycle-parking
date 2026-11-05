import { createContext, useContext, useEffect, type ReactNode } from 'react';
import { apiV1Base } from '../api/base';
import { useAppDispatch } from '../app/store';
import type { AuthPort } from './port';
import { userChanged } from './sessionSlice';

const AuthContext = createContext<AuthPort | null>(null);

/**
 * Hands the pages their sign-in and keeps the store's session in step with
 * it. `auth` is null when the build has no backend: the page then explains
 * and offers the support form, without sign-in buttons that cannot work.
 */
export function AuthProvider({ auth, children }: { auth: AuthPort | null; children: ReactNode }) {
  const dispatch = useAppDispatch();
  useEffect(() => {
    if (!auth) {
      dispatch(userChanged(null));
      return;
    }
    let current: string | null = null;
    return auth.onChange((user) => {
      // Another account (or none): nothing cached for the last one may show.
      if ((user?.id ?? null) !== current) dispatch(apiV1Base.util.resetApiState());
      current = user?.id ?? null;
      dispatch(userChanged(user));
    });
  }, [auth, dispatch]);
  return <AuthContext.Provider value={auth}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthPort | null {
  return useContext(AuthContext);
}
