import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { Vehicle } from '../ui/eligibility';

/**
 * Reviewer preferences that outlive a page. Server data will live in RTK
 * Query once admin_v1 exists (#195); only UI state belongs here.
 */
export interface PrefsState {
  /** 車種切換 on the spots map: every marker and plate follows it. */
  vehicle: Vehicle;
}

const initialState: PrefsState = { vehicle: 'scooter' };

export const prefsSlice = createSlice({
  name: 'prefs',
  initialState,
  reducers: {
    vehicleChanged(state, action: PayloadAction<Vehicle>) {
      state.vehicle = action.payload;
    },
  },
});

export const { vehicleChanged } = prefsSlice.actions;
