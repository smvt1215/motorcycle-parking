import { adminApi } from '../app/adminApi';
import { makeStore } from '../app/store';
import { fixtureSource } from './fixtureSource';
import { decisionQueued, decisionUndone, draftReopened, UNDO_MS } from './reviewSlice';

const request = (reportId: string) => ({
  reportId,
  decision: 'accepted' as const,
  patch: { scooter_allowed: true },
  edited: false,
  note: '',
  force: false,
});

async function setup() {
  const source = fixtureSource({ now: Date.parse('2026-10-31T10:00:00Z') });
  const store = makeStore({ source });
  await store.dispatch(adminApi.endpoints.getQueue.initiate());
  return { source, store };
}

describe('undo window', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('writes nothing until the window closes, then writes once', async () => {
    const { source, store } = await setup();
    store.dispatch(decisionQueued({ request: request('r-ximen'), name: '西門' }));
    expect(store.getState().review.pending['r-ximen']).toBeDefined();

    await vi.advanceTimersByTimeAsync(UNDO_MS - 1);
    expect(source.resolved).toEqual([]);

    await vi.advanceTimersByTimeAsync(1);
    expect(source.resolved.map((r) => r.reportId)).toEqual(['r-ximen']);
    const state = store.getState();
    expect(state.review.pending).toEqual({});
    expect(state.review.resolvedCount).toBe(1);
    // The written report leaves the cached queue.
    const queue = adminApi.endpoints.getQueue.select()(state).data!;
    expect(queue.reports.some((r) => r.id === 'r-ximen')).toBe(false);
    expect(queue.spots['official:33333333-3333-4333-8333-333333333333']!.values.scooter_allowed).toBe(true);
  });

  it('undo inside the window never reaches the server', async () => {
    const { source, store } = await setup();
    store.dispatch(decisionQueued({ request: request('r-ximen'), name: '西門' }));
    await vi.advanceTimersByTimeAsync(UNDO_MS - 100);
    store.dispatch(decisionUndone('r-ximen'));
    await vi.advanceTimersByTimeAsync(UNDO_MS * 2);
    expect(source.resolved).toEqual([]);
    expect(store.getState().review.pending).toEqual({});
    expect(store.getState().review.lastQueued).toBeNull();
  });

  it('undo keeps the draft for the detail to reopen, once (#217)', () => {
    const store = makeStore();
    const draft = { mode: 'reject', kind: 'duplicate' } as const;
    store.dispatch(
      decisionQueued({
        request: { reportId: 'r-x', decision: 'rejected', resolutionKind: 'duplicate', note: '' },
        name: 'x',
        draft,
      }),
    );
    expect(store.getState().review.drafts).toEqual({});
    store.dispatch(decisionUndone('r-x'));
    expect(store.getState().review.drafts).toEqual({ 'r-x': draft });
    store.dispatch(draftReopened('r-x'));
    expect(store.getState().review.drafts).toEqual({});
  });

  it('a failed write puts the report back with its error and keeps the note', async () => {
    const { source, store } = await setup();
    source.failNextResolve('network');
    store.dispatch({ type: 'review/noteChanged', payload: { reportId: 'r-ximen', note: '已比對公告' } });
    store.dispatch(decisionQueued({ request: request('r-ximen'), name: '西門' }));
    await vi.advanceTimersByTimeAsync(UNDO_MS);
    const { review } = store.getState();
    expect(review.failures['r-ximen']?.error.code).toBe('network');
    expect(review.notes['r-ximen']).toBe('已比對公告');
    expect(review.resolvedCount).toBe(0);
  });

  it('a report another admin resolved just leaves the queue', async () => {
    const { source, store } = await setup();
    source.failNextResolve('alreadyResolved');
    store.dispatch(decisionQueued({ request: request('r-ximen'), name: '西門' }));
    await vi.advanceTimersByTimeAsync(UNDO_MS);
    const state = store.getState();
    expect(state.review.failures).toEqual({});
    const queue = adminApi.endpoints.getQueue.select()(state).data!;
    expect(queue.reports.some((r) => r.id === 'r-ximen')).toBe(false);
  });

  it('stops offering undo once the write is in flight (Codex review, PR #214)', async () => {
    const source = fixtureSource({ now: Date.parse('2026-10-31T10:00:00Z'), latencyMs: 400 });
    const store = makeStore({ source });
    const loading = store.dispatch(adminApi.endpoints.getQueue.initiate());
    await vi.advanceTimersByTimeAsync(400);
    await loading;
    store.dispatch(decisionQueued({ request: request('r-ximen'), name: '西門' }));
    await vi.advanceTimersByTimeAsync(UNDO_MS + 100);

    // The request is out; the window is closed and the report stays hidden.
    expect(store.getState().review.lastQueued).toBeNull();
    expect(store.getState().review.pending['r-ximen']?.writing).toBe(true);
    store.dispatch(decisionUndone('r-ximen'));
    expect(store.getState().review.pending['r-ximen']).toBeDefined();

    await vi.advanceTimersByTimeAsync(400);
    expect(source.resolved.map((r) => r.reportId)).toEqual(['r-ximen']);
    expect(store.getState().review.pending).toEqual({});
    expect(store.getState().review.resolvedCount).toBe(1);
  });

  it('keeps separate windows for separate decisions', async () => {
    const { source, store } = await setup();
    store.dispatch(decisionQueued({ request: request('r-ximen'), name: '西門' }));
    await vi.advanceTimersByTimeAsync(2000);
    store.dispatch(decisionQueued({ request: request('r-banqiao'), name: '板橋' }));
    await vi.advanceTimersByTimeAsync(3000);
    expect(source.resolved.map((r) => r.reportId)).toEqual(['r-ximen']);
    await vi.advanceTimersByTimeAsync(2000);
    expect(source.resolved.map((r) => r.reportId)).toEqual(['r-ximen', 'r-banqiao']);
  });
});
