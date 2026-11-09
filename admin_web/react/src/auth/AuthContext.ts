import { createContext, useContext, useSyncExternalStore } from 'react';
import type { AuthController } from './controller';

/** Null where no sign-in applies: unit tests of a single page. */
export const AuthContext = createContext<AuthController | null>(null);

export const useAuthController = () => useContext(AuthContext);

export function useAuthState(controller: AuthController) {
  return useSyncExternalStore(controller.subscribe, controller.getState);
}
