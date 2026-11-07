import { createContext, useContext } from 'react';
import type { SupportPort } from './client';

/**
 * The support Edge Functions for the pages; null when the build has no
 * backend (a local preview): the pages then say the form is unavailable.
 */
export const SupportContext = createContext<SupportPort | null>(null);

export function useSupport(): SupportPort | null {
  return useContext(SupportContext);
}
