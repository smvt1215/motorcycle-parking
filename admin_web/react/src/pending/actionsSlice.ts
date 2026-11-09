import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import { adminV1, type TimedCase } from '../api/v1/admin_v1.generated';
import type { V1Error } from '../api/v1/base';
import type { AppDispatch, RootState } from '../app/store';
import {
  describeAction,
  type ActionContext,
  type ActionKind,
  type ActionLabels,
  type CaseDraft,
} from './caseCopy';

/*
 * The server runs every action (schedule_case_action); this slice only follows
 * them. Each has its own deadline, a new one never shortens an earlier one,
 * and nothing here pauses. Drafts sit here rather than in the page so they
 * survive moving between cases and re-verifying the second factor, which
 * unmounts the whole app (AuthGate).
 */

export type Phase = 'counting' | 'sending' | 'done' | 'cancelled' | 'failed' | 'stale' | 'slow';

export interface TrackedAction {
  id: string;
  caseId: string;
  action: ActionKind;
  labels: ActionLabels;
  /** When the countdown ends, on this browser's clock. */
  deadline: number;
  irreversible: boolean;
  phase: Phase;
  /** Order of starting: Z cancels the highest. */
  seq: number;
  /** The server has started it, so 「取消」 no longer can. */
  late: boolean;
  cancelling: boolean;
  /** The last cancel could not reach the server. */
  cancelError: boolean;
  /** Put back when the action does not happen; null once it has. */
  draft: CaseDraft | null;
  sendingSince: number | null;
  settledAt: number | null;
}

export interface PendingActionsState {
  actions: TrackedAction[];
  seq: number;
  drafts: Record<string, CaseDraft>;
  /** Actions already followed or restored, so a stale read cannot bring them back. */
  seen: string[];
  /** Bumped whenever an action starts or ends: the list and counts read again. */
  revision: number;
  /** The one sentence a screen reader hears; only at the start and the end. */
  announcement: string;
}

const initialState: PendingActionsState = {
  actions: [],
  seq: 0,
  drafts: {},
  seen: [],
  revision: 0,
  announcement: '',
};

/** How long a finished line stays. Failures and conflicts stay longest. */
export const RESULT_MS: Record<Phase, number> = {
  counting: Infinity,
  sending: Infinity,
  done: 3_000,
  cancelled: 8_000,
  slow: 10_000,
  failed: 15_000,
  stale: 15_000,
};

/** pg_cron picks up anything pg_net missed within a minute; past that, say so. */
export const SLOW_AFTER_MS = 90_000;

const SEEN_LIMIT = 200;

const remember = (state: PendingActionsState, id: string) => {
  if (state.seen.includes(id)) return;
  state.seen.push(id);
  if (state.seen.length > SEEN_LIMIT) state.seen.shift();
};

const isFinished = (phase: Phase) => phase !== 'counting' && phase !== 'sending';

const OUTCOME_LINE: Partial<Record<Phase, (labels: ActionLabels) => string>> = {
  done: (l) => `${l.doneTitle}，${l.doneBody}`,
  cancelled: (l) => `${l.cancelledTitle}，${l.cancelledBody}`,
  failed: (l) => `${l.failedTitle}，${l.failedBody}`,
  stale: (l) => `${l.staleTitle}，${l.staleBody}`,
  slow: (l) => `${l.sendingTitle}，結果會顯示在清單`,
};

export interface TrackPayload {
  id: string;
  caseId: string;
  action: ActionKind;
  labels: ActionLabels;
  deadline: number;
  irreversible: boolean;
  /** Take the case's draft along, to give back if this does not happen. */
  draft: CaseDraft | null | 'take';
  /** Not started from this page: no announcement. */
  quiet?: boolean;
  now: number;
}

export const pendingActionsSlice = createSlice({
  name: 'pendingActions',
  initialState,
  reducers: {
    draftChanged(state, action: PayloadAction<{ caseId: string; patch: Partial<CaseDraft> }>) {
      const { caseId, patch } = action.payload;
      state.drafts[caseId] = { ...state.drafts[caseId], ...patch };
    },
    actionTracked(state, { payload }: PayloadAction<TrackPayload>) {
      if (state.actions.some((a) => a.id === payload.id)) return;
      remember(state, payload.id);
      const draft = payload.draft === 'take' ? (state.drafts[payload.caseId] ?? null) : payload.draft;
      if (payload.draft === 'take') delete state.drafts[payload.caseId];
      state.seq += 1;
      state.actions.push({
        id: payload.id,
        caseId: payload.caseId,
        action: payload.action,
        labels: payload.labels,
        deadline: payload.deadline,
        irreversible: payload.irreversible,
        phase: payload.deadline <= payload.now ? 'sending' : 'counting',
        seq: state.seq,
        late: false,
        cancelling: false,
        cancelError: false,
        draft,
        sendingSince: payload.deadline <= payload.now ? payload.now : null,
        settledAt: null,
      });
      state.revision += 1;
      if (!payload.quiet) {
        const seconds = Math.max(1, Math.ceil((payload.deadline - payload.now) / 1000));
        const suffix = payload.irreversible ? '，之後不能復原' : '';
        state.announcement = `${payload.labels.subject}，${seconds} 秒後${payload.labels.verb}，按 Z 取消${suffix}`;
      }
    },
    ticked(state, { payload: now }: PayloadAction<number>) {
      for (const item of state.actions) {
        if (item.phase === 'counting' && item.deadline <= now) {
          item.phase = 'sending';
          item.sendingSince = now;
        } else if (
          item.phase === 'sending' &&
          item.sendingSince !== null &&
          now - item.sendingSince >= SLOW_AFTER_MS
        ) {
          item.phase = 'slow';
          item.settledAt = now;
          item.draft = null;
        }
      }
      state.actions = state.actions.filter(
        (item) => item.settledAt === null || now - item.settledAt < RESULT_MS[item.phase],
      );
    },
    cancelStarted(state, { payload: id }: PayloadAction<string>) {
      const item = state.actions.find((a) => a.id === id);
      if (item && !isFinished(item.phase)) {
        item.cancelling = true;
        item.cancelError = false;
      }
    },
    cancelRefused(state, { payload }: PayloadAction<{ id: string; late: boolean; now: number }>) {
      const item = state.actions.find((a) => a.id === payload.id);
      if (!item || isFinished(item.phase)) return;
      item.cancelling = false;
      if (payload.late) {
        item.late = true;
        if (item.phase === 'counting') {
          item.phase = 'sending';
          item.sendingSince = payload.now;
        }
        state.announcement = `來不及取消，${item.labels.lateBody}`;
      } else {
        item.cancelError = true;
        state.announcement = '連線中斷，現在無法取消';
      }
    },
    /** Any late answer is ignored: only the first outcome counts. */
    actionSettled(
      state,
      {
        payload,
      }: PayloadAction<{ id: string; outcome: 'done' | 'cancelled' | 'failed' | 'stale'; now: number }>,
    ) {
      const item = state.actions.find((a) => a.id === payload.id);
      if (!item || isFinished(item.phase)) return;
      item.phase = payload.outcome;
      item.settledAt = payload.now;
      item.cancelling = false;
      if (payload.outcome !== 'done' && item.draft) {
        state.drafts[item.caseId] = { ...state.drafts[item.caseId], ...item.draft };
      }
      item.draft = null;
      state.revision += 1;
      state.announcement = OUTCOME_LINE[payload.outcome]?.(item.labels) ?? '';
    },
    dismissed(state, { payload: id }: PayloadAction<string>) {
      state.actions = state.actions.filter((a) => a.id !== id);
    },
    draftRestored(state, { payload }: PayloadAction<{ actionId: string; caseId: string; draft: CaseDraft }>) {
      if (state.seen.includes(payload.actionId)) return;
      remember(state, payload.actionId);
      state.drafts[payload.caseId] = { ...payload.draft, ...state.drafts[payload.caseId] };
    },
    actionsReset: () => initialState,
  },
});

export const {
  actionSettled,
  actionsReset,
  actionTracked,
  cancelRefused,
  cancelStarted,
  dismissed,
  draftChanged,
  draftRestored,
  ticked,
} = pendingActionsSlice.actions;

const isLive = (a: TrackedAction) => a.phase === 'counting' || a.phase === 'sending';

/** The server's clock minus ours, from the counts the shell always holds. */
function clockOffset(state: RootState): number {
  const counts = adminV1.endpoints.adminV1TimedCaseCounts.select({ body: {} })(state);
  return counts.data && counts.fulfilledTimeStamp
    ? Date.parse(counts.data.as_of) - counts.fulfilledTimeStamp
    : 0;
}

/** A server `run_at` on this browser's clock, so the countdown counts real seconds. */
export const localDeadline = (state: RootState, runAt: string): number =>
  Date.parse(runAt) - clockOffset(state);

type Thunk<R> = (dispatch: AppDispatch, getState: () => RootState) => R;

export type RunResult = { ok: true } | { ok: false; error: V1Error };

const failure = (error: unknown): RunResult => ({ ok: false, error: error as V1Error });

/** Writes the action, then follows it. The draft moves only after the server has accepted. */
export function scheduleAction(
  item: Pick<TimedCase, 'id' | 'type' | 'kind' | 'hidden_parts' | 'version'>,
  action: ActionKind,
  payload: Record<string, unknown>,
  context: Pick<ActionContext, 'replyTo' | 'resolveStatus'> = {},
): Thunk<Promise<RunResult>> {
  return async (dispatch, getState) => {
    const result = await dispatch(
      adminV1.endpoints.adminV1ScheduleCaseAction.initiate({
        body: {
          p_case: item.id,
          p_action: action,
          p_payload: payload,
          p_expected_version: item.version,
        },
      }),
    );
    if ('error' in result) return failure(result.error);
    dispatch(
      actionTracked({
        id: result.data.action_id,
        caseId: item.id,
        action,
        labels: describeAction({ action, item, ...context }),
        deadline: localDeadline(getState(), result.data.run_at),
        irreversible: result.data.irreversible,
        draft: 'take',
        now: Date.now(),
      }),
    );
    return { ok: true };
  };
}

/** 再寄一次: the reply already exists, so there is no draft to carry. */
export function retryReply(
  item: Pick<TimedCase, 'id' | 'type' | 'kind' | 'hidden_parts'>,
  actionId: string,
  replyTo: string | null,
): Thunk<Promise<RunResult>> {
  return async (dispatch, getState) => {
    const result = await dispatch(
      adminV1.endpoints.adminV1RetryCaseAction.initiate({ body: { p_action_id: actionId } }),
    );
    if ('error' in result) return failure(result.error);
    dispatch(
      actionTracked({
        id: result.data.action_id,
        caseId: item.id,
        action: 'reply',
        labels: describeAction({ action: 'reply', item, replyTo }),
        deadline: localDeadline(getState(), result.data.run_at),
        irreversible: false,
        draft: null,
        now: Date.now(),
      }),
    );
    return { ok: true };
  };
}

/** Cancels if the server has not started; the answer decides what is shown. */
export function cancelAction(id: string): Thunk<Promise<void>> {
  return async (dispatch, getState) => {
    const item = getState().pendingActions.actions.find((a) => a.id === id);
    if (!item || item.phase !== 'counting' || item.cancelling) return;
    dispatch(cancelStarted(id));
    const result = await dispatch(
      adminV1.endpoints.adminV1CancelCaseAction.initiate({ body: { p_action_id: id } }),
    );
    if ('error' in result) {
      const late = (result.error as V1Error).message === 'case_action.started';
      dispatch(cancelRefused({ id, late, now: Date.now() }));
      return;
    }
    dispatch(actionSettled({ id, outcome: 'cancelled', now: Date.now() }));
  };
}

/** The newest action still counting, which Z cancels. */
export const newestCounting = (actions: readonly TrackedAction[]): TrackedAction | undefined =>
  actions.filter((a) => a.phase === 'counting').sort((a, b) => b.seq - a.seq)[0];

export const liveActionsOf = (actions: readonly TrackedAction[], caseId: string) =>
  actions.filter((a) => a.caseId === caseId && isLive(a));
