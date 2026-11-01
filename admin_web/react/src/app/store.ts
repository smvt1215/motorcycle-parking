import { combineReducers, configureStore, createListenerMiddleware } from '@reduxjs/toolkit';
import { adminV1Base, type PostgrestConnection } from '../api/v1/base';
import { apiV1 } from '../api/v1/api_v1.generated';
import type { AdminDataSource } from '../review/source';
import { reviewSlice, startReviewListeners } from '../review/reviewSlice';
import { adminApi, type AppExtra } from './adminApi';
import { prefsSlice } from './prefsSlice';

const rootReducer = combineReducers({
  [prefsSlice.name]: prefsSlice.reducer,
  [reviewSlice.name]: reviewSlice.reducer,
  [adminApi.reducerPath]: adminApi.reducer,
  [apiV1.reducerPath]: apiV1.reducer,
  [adminV1Base.reducerPath]: adminV1Base.reducer,
});

export type RootState = ReturnType<typeof rootReducer>;

interface StoreOptions {
  /** Null means no data is connected: pages say so instead of showing data. */
  source?: AdminDataSource | null;
  /** The unified API (#195); null until a backend is connected. */
  postgrest?: PostgrestConnection | null;
  preloadedState?: Partial<RootState>;
}

/** A fresh store per call, so tests never share state or timers. */
export function makeStore({ source = null, postgrest = null, preloadedState }: StoreOptions = {}) {
  const extra: AppExtra = { source, postgrest };
  const listener = createListenerMiddleware({ extra });
  startReviewListeners(listener.startListening);
  return configureStore({
    reducer: rootReducer,
    preloadedState,
    middleware: (getDefault) =>
      getDefault({ thunk: { extraArgument: extra } })
        .prepend(listener.middleware)
        .concat(adminApi.middleware, apiV1.middleware, adminV1Base.middleware),
  });
}

export type AppStore = ReturnType<typeof makeStore>;
export type AppDispatch = AppStore['dispatch'];
