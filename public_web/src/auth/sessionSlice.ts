import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { SignedInUser } from './port';

/** Sign-in as the page sees it: `loading` until the auth client has read the stored session. */
export interface SessionState {
  phase: 'loading' | 'signedOut' | 'signedIn';
  user: SignedInUser | null;
}

const initialState: SessionState = { phase: 'loading', user: null };

export const sessionSlice = createSlice({
  name: 'session',
  initialState,
  reducers: {
    userChanged(state, action: PayloadAction<SignedInUser | null>) {
      state.user = action.payload;
      state.phase = action.payload ? 'signedIn' : 'signedOut';
    },
  },
});

export const { userChanged } = sessionSlice.actions;
