import { createAction, createSlice, type PayloadAction, type TypedStartListening } from '@reduxjs/toolkit';
import { adminApi, type ApiError } from '../app/adminApi';
import type { ResolveRequest } from './source';

/** 「處理完自動跳到下一筆，5 秒內可復原」 (Main.dc.html). */
export const UNDO_MS = 5000;

export interface QueuedDecision {
  request: ResolveRequest;
  /** Spot name, for 「已套用 復興南路…」. */
  name: string;
  /**
   * The window has closed and the write is in flight: it can no longer be
   * undone, and the report stays out of the queue until the write settles.
   */
  writing?: boolean;
}

export interface ReviewState {
  /** Decisions waiting out the undo window or being written, by report id. */
  pending: Record<string, QueuedDecision>;
  /** The decision the action bar offers to undo. */
  lastQueued: string | null;
  /** Writes that failed; the report is back in the queue with this error. */
  failures: Record<string, ApiError>;
  /** 處理說明 per report, kept until the report is written. */
  notes: Record<string, string>;
  /** Reports reloaded after a version conflict, so 「仍然套用」 may force. */
  reloaded: Record<string, true>;
  /** Reports written in this session, for the empty state. */
  resolvedCount: number;
}

const initialState: ReviewState = {
  pending: {},
  lastQueued: null,
  failures: {},
  notes: {},
  reloaded: {},
  resolvedCount: 0,
};

export const reviewSlice = createSlice({
  name: 'review',
  initialState,
  reducers: {
    noteChanged(state, action: PayloadAction<{ reportId: string; note: string }>) {
      state.notes[action.payload.reportId] = action.payload.note;
    },
    decisionQueued(state, action: PayloadAction<QueuedDecision>) {
      const id = action.payload.request.reportId;
      state.pending[id] = action.payload;
      state.lastQueued = id;
      delete state.failures[id];
    },
    decisionUndone(state, action: PayloadAction<string>) {
      // Too late once the write has started: the server may already have it.
      if (state.pending[action.payload]?.writing) return;
      delete state.pending[action.payload];
      if (state.lastQueued === action.payload) state.lastQueued = null;
    },
    decisionWriting(state, action: PayloadAction<string>) {
      const decision = state.pending[action.payload];
      if (decision) decision.writing = true;
      if (state.lastQueued === action.payload) state.lastQueued = null;
    },
    decisionCommitted(state, action: PayloadAction<string>) {
      const id = action.payload;
      delete state.pending[id];
      delete state.notes[id];
      delete state.reloaded[id];
      if (state.lastQueued === id) state.lastQueued = null;
      state.resolvedCount += 1;
    },
    decisionFailed(state, action: PayloadAction<{ reportId: string; error: ApiError }>) {
      const { reportId, error } = action.payload;
      delete state.pending[reportId];
      if (state.lastQueued === reportId) state.lastQueued = null;
      // Another admin resolved it: it simply leaves the queue.
      if (error.code !== 'alreadyResolved') state.failures[reportId] = error;
    },
    failureDismissed(state, action: PayloadAction<string>) {
      delete state.failures[action.payload];
    },
    reportReloaded(state, action: PayloadAction<string>) {
      state.reloaded[action.payload] = true;
    },
  },
});

export const {
  noteChanged,
  decisionQueued,
  decisionUndone,
  decisionWriting,
  decisionCommitted,
  decisionFailed,
  failureDismissed,
  reportReloaded,
} = reviewSlice.actions;

/** Re-reads the queue after a conflict; then 「仍然套用」 may force the write. */
export const reloadForConflict = createAction<string>('review/reloadForConflict');

/**
 * Holds every decision for UNDO_MS, then writes it. Undo inside the window
 * cancels it without any server call (there is no RPC that reopens a
 * resolved report). The window lives in the store, so leaving the review
 * page does not lose a decision.
 */
export function startReviewListeners(startListening: TypedStartListening<unknown>) {
  startListening({
    actionCreator: decisionQueued,
    effect: async (action, api) => {
      const { request } = action.payload;
      const undone = await api.condition(
        (next) => decisionUndone.match(next) && next.payload === request.reportId,
        UNDO_MS,
      );
      if (undone) return;
      // Close the undo offer before the request leaves (Codex review, PR #214).
      api.dispatch(decisionWriting(request.reportId));
      const result = await api.dispatch(
        adminApi.endpoints.resolveReport.initiate(request, { fixedCacheKey: request.reportId }),
      );
      if ('error' in result && result.error) {
        api.dispatch(decisionFailed({ reportId: request.reportId, error: result.error as ApiError }));
      } else {
        api.dispatch(decisionCommitted(request.reportId));
      }
    },
  });

  startListening({
    actionCreator: reloadForConflict,
    effect: async (action, api) => {
      const result = await api.dispatch(
        adminApi.endpoints.getQueue.initiate(undefined, { forceRefetch: true, subscribe: false }),
      );
      if (!('error' in result) || !result.error) api.dispatch(reportReloaded(action.payload));
    },
  });
}
