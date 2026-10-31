import { useMemo, useSyncExternalStore } from 'react';
import { useSearchParams } from 'react-router';
import { useGetQueueQuery } from '../app/adminApi';
import { useDataConnection } from '../app/connection';
import { useAppSelector } from '../app/hooks';
import { REVIEW_KINDS, reportKind, type ReviewKind, type ReviewReport } from './model';

const PHONE_QUERY = '(max-width: 679.98px)';

function subscribePhone(onChange: () => void) {
  if (typeof window.matchMedia !== 'function') return () => {};
  const query = window.matchMedia(PHONE_QUERY);
  query.addEventListener('change', onChange);
  return () => query.removeEventListener('change', onChange);
}

/** True below 680px, where the queue and the detail take turns (DESIGN.md Layout). */
export function useIsPhone(): boolean {
  return useSyncExternalStore(
    subscribePhone,
    () => typeof window.matchMedia === 'function' && window.matchMedia(PHONE_QUERY).matches,
    () => false,
  );
}

export type KindFilter = ReviewKind | 'all';

/** The type filter lives in the URL (`?kind=access`), so it survives selection and reloads. */
export function useKindFilter(): [KindFilter, (next: KindFilter) => void, string] {
  const [params, setParams] = useSearchParams();
  const raw = params.get('kind');
  const kind: KindFilter = REVIEW_KINDS.includes(raw as ReviewKind) ? (raw as ReviewKind) : 'all';
  const set = (next: KindFilter) =>
    setParams(
      (current) => {
        const copy = new URLSearchParams(current);
        if (next === 'all') copy.delete('kind');
        else copy.set('kind', next);
        return copy;
      },
      { replace: true },
    );
  const search = kind === 'all' ? '' : `?kind=${kind}`;
  return [kind, set, search];
}

/**
 * The queue as the reviewer sees it: oldest first, without decisions still
 * in their undo window, filtered by type. Skipped (no data source) when
 * nothing is connected.
 */
export function useReviewQueue() {
  const connection = useDataConnection();
  const query = useGetQueueQuery(undefined, { skip: connection === 'none' });
  const pending = useAppSelector((state) => state.review.pending);
  const [kind] = useKindFilter();

  return useMemo(() => {
    const open: ReviewReport[] = (query.data?.reports ?? []).filter((r) => !(r.id in pending));
    const visible = kind === 'all' ? open : open.filter((r) => reportKind(r) === kind);
    const counts = Object.fromEntries(REVIEW_KINDS.map((k) => [k, 0])) as Record<ReviewKind, number>;
    for (const r of open) counts[reportKind(r)] += 1;
    return { query, open, visible, counts, spots: query.data?.spots ?? {} };
  }, [query, pending, kind]);
}

/** Where to go after `id` leaves the queue: the next row, else the previous one. */
export function neighbourOf(list: readonly ReviewReport[], id: string): ReviewReport | null {
  const index = list.findIndex((r) => r.id === id);
  if (index < 0) return list[0] ?? null;
  return list[index + 1] ?? list[index - 1] ?? null;
}
