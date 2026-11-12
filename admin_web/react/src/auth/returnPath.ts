const KEY = 'motopark-admin-return-path';

/** /pending and /pending/:caseId, with query only: never another site or section. */
const ALLOWED = /^\/pending(\/[^/?#]+)?(\?[^#]*)?$/;

/**
 * The Google redirect always lands on /pending (one allow-listed address), so
 * the deep link goes along in sessionStorage. Same tab, same origin, one use.
 */
export function saveReturnPath(location: Pick<Location, 'pathname' | 'search'>) {
  const path = `${location.pathname}${location.search}`;
  if (!ALLOWED.test(path)) return;
  try {
    sessionStorage.setItem(KEY, path);
  } catch {
    // Private mode: the sign-in still works, it just lands on the list.
  }
}

export function takeReturnPath(): string | null {
  try {
    const path = sessionStorage.getItem(KEY);
    sessionStorage.removeItem(KEY);
    return path !== null && ALLOWED.test(path) ? path : null;
  } catch {
    return null;
  }
}
