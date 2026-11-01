import { createApi, fakeBaseQuery } from '@reduxjs/toolkit/query/react';
import type { PostgrestConnection } from '../api/v1/base';
import type { ReviewQueue } from '../review/model';
import {
  SourceError,
  type AdminDataSource,
  type ResolveRequest,
  type ResolveResult,
  type SourceErrorCode,
} from '../review/source';

export interface ApiError {
  code: SourceErrorCode;
  message: string;
}

/** Thunk extra argument: the data source, or null when none is connected. */
export interface AppExtra {
  source: AdminDataSource | null;
  /** The unified API (#195) for src/api/v1; null until a backend is connected. */
  postgrest: PostgrestConnection | null;
}

/** 「超過 10 秒還沒載入，就改顯示讀取失敗與重試」 (States.dc.html). */
export const LOAD_TIMEOUT_MS = 10000;

async function call<T>(extra: unknown, run: (source: AdminDataSource) => Promise<T>, timeoutMs?: number) {
  const source = (extra as AppExtra).source;
  if (!source) return { error: { code: 'unknown', message: 'no data source' } satisfies ApiError };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const work = run(source);
    const data = await (timeoutMs === undefined
      ? work
      : Promise.race([
          work,
          new Promise<never>((_, reject) => {
            timer = setTimeout(() => reject(new SourceError('timeout', 'timeout')), timeoutMs);
          }),
        ]));
    return { data };
  } catch (error) {
    const code: SourceErrorCode = error instanceof SourceError ? error.code : 'network';
    return {
      error: { code, message: error instanceof Error ? error.message : String(error) } satisfies ApiError,
    };
  } finally {
    clearTimeout(timer);
  }
}

export const adminApi = createApi({
  reducerPath: 'adminApi',
  baseQuery: fakeBaseQuery<ApiError>(),
  tagTypes: ['Queue'],
  endpoints: (build) => ({
    getQueue: build.query<ReviewQueue, void>({
      queryFn: (_arg, api) => call(api.extra, (source) => source.loadQueue(), LOAD_TIMEOUT_MS),
      providesTags: ['Queue'],
    }),
    resolveReport: build.mutation<ResolveResult, ResolveRequest>({
      queryFn: (request, api) => call(api.extra, (source) => source.resolve(request)),
      // A written report leaves the queue and its spot takes the new values;
      // one another admin already resolved leaves it as well.
      async onQueryStarted(request, { dispatch, queryFulfilled }) {
        const drop = (spot?: ResolveResult['spot']) =>
          dispatch(
            adminApi.util.updateQueryData('getQueue', undefined, (draft) => {
              draft.reports = draft.reports.filter((r) => r.id !== request.reportId);
              if (spot) draft.spots[spot.sourceId] = spot;
            }),
          );
        try {
          const { data } = await queryFulfilled;
          drop(data.spot);
        } catch (failure) {
          const error = (failure as { error?: ApiError }).error;
          if (error?.code === 'alreadyResolved') drop();
        }
      },
    }),
  }),
});

export const { useGetQueueQuery } = adminApi;
