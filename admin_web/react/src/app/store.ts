import { combineReducers, configureStore, createListenerMiddleware } from '@reduxjs/toolkit';
import type { AdminDataSource } from '../review/source';
import { reviewSlice, startReviewListeners } from '../review/reviewSlice';
import { adminApi, type AppExtra } from './adminApi';
import { prefsSlice } from './prefsSlice';

const rootReducer = combineReducers({
  [prefsSlice.name]: prefsSlice.reducer,
  [reviewSlice.name]: reviewSlice.reducer,
  [adminApi.reducerPath]: adminApi.reducer,
});

export type RootState = ReturnType<typeof rootReducer>;

interface StoreOptions {
  /** Null means no data is connected: pages say so instead of showing data. */
  source?: AdminDataSource | null;
  preloadedState?: Partial<RootState>;
}

/** A fresh store per call, so tests never share state or timers. */
export function makeStore({ source = null, preloadedState }: StoreOptions = {}) {
  const extra: AppExtra = { source };
  const listener = createListenerMiddleware({ extra });
  startReviewListeners(listener.startListening);
  return configureStore({
    reducer: rootReducer,
    preloadedState,
    middleware: (getDefault) =>
      getDefault({ thunk: { extraArgument: extra } })
        .prepend(listener.middleware)
        .concat(adminApi.middleware),
  });
}

export type AppStore = ReturnType<typeof makeStore>;
export type AppDispatch = AppStore['dispatch'];
