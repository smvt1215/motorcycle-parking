import {
  useAdminV1TimedCaseCountsQuery,
  type TimedCaseCursor,
  type TimedCasePage,
} from '../api/v1/admin_v1.generated';
import { adminV1Base, type V1Error } from '../api/v1/base';
import { TAB_QUERY, type PendingTab } from './model';

export const PAGE_SIZE = 50;

/**
 * timed_cases, one keyset page at a time. Hand-written because the generated
 * endpoint is a single-page query; the request and response types still come
 * from the OpenAPI document.
 */
export const pendingApi = adminV1Base.injectEndpoints({
  endpoints: (build) => ({
    timedCasePages: build.infiniteQuery<TimedCasePage, PendingTab, TimedCaseCursor | null>({
      infiniteQueryOptions: {
        initialPageParam: null,
        getNextPageParam: (last) => last.next_cursor ?? undefined,
      },
      query: ({ queryArg, pageParam }) => ({
        url: '/rpc/timed_cases',
        method: 'POST',
        body: {
          p_kind: TAB_QUERY[queryArg].kind,
          p_bucket: TAB_QUERY[queryArg].bucket,
          p_cursor: pageParam,
          p_limit: PAGE_SIZE,
        },
      }),
    }),
  }),
});

export const { useTimedCasePagesInfiniteQuery } = pendingApi;

const COUNTS_POLL_MS = 60_000;

/** The nav badge and the tabs share this one cache entry. */
export function usePendingCounts(skip = false) {
  return useAdminV1TimedCaseCountsQuery(
    { body: {} },
    {
      skip,
      pollingInterval: COUNTS_POLL_MS,
      skipPollingIfUnfocused: true,
      refetchOnFocus: true,
      refetchOnReconnect: true,
    },
  );
}

export const needsSecondFactor = (error: unknown): boolean =>
  (error as V1Error | undefined)?.message === 'auth.aal2_required';
