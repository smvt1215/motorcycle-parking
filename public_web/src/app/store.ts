import { configureStore } from '@reduxjs/toolkit';
import { useDispatch, useSelector } from 'react-redux';
import { apiV1Base, type PostgrestConnection } from '../api/base';
import { sessionSlice } from '../auth/sessionSlice';

export interface StoreOptions {
  /** The API, or null when the build has no backend configured. */
  postgrest: PostgrestConnection | null;
  /**
   * How the store queues its batched subscriber notifications. Omit it for
   * RTK's default (requestAnimationFrame with a 100 ms timer as fallback).
   * Tests pass 'tick' so no timer outlives the jsdom environment.
   */
  autoBatch?: 'tick';
}

export function makeStore({ postgrest, autoBatch }: StoreOptions) {
  return configureStore({
    reducer: {
      [apiV1Base.reducerPath]: apiV1Base.reducer,
      session: sessionSlice.reducer,
    },
    middleware: (getDefault) =>
      getDefault({ thunk: { extraArgument: { postgrest } } }).concat(apiV1Base.middleware),
    enhancers: (getDefaultEnhancers) =>
      getDefaultEnhancers(autoBatch ? { autoBatch: { type: autoBatch } } : {}),
  });
}

export type AppStore = ReturnType<typeof makeStore>;
export type RootState = ReturnType<AppStore['getState']>;
export type AppDispatch = AppStore['dispatch'];

export const useAppDispatch = useDispatch.withTypes<AppDispatch>();
export const useAppSelector = useSelector.withTypes<RootState>();
