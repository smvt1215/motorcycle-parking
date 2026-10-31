import { combineReducers, configureStore } from '@reduxjs/toolkit';
import { prefsSlice } from './prefsSlice';

const rootReducer = combineReducers({
  [prefsSlice.name]: prefsSlice.reducer,
});

export type RootState = ReturnType<typeof rootReducer>;

/** A fresh store per call, so tests never share state. */
export function makeStore(preloadedState?: Partial<RootState>) {
  return configureStore({ reducer: rootReducer, preloadedState });
}

export type AppStore = ReturnType<typeof makeStore>;
export type AppDispatch = AppStore['dispatch'];
