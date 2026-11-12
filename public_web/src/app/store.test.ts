import { SHOULD_AUTOBATCH } from '@reduxjs/toolkit';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { makeStore } from './store';

/** A low-priority action, as RTK Query dispatches for its status updates. */
const lowPriority = { type: 'noop', meta: { [SHOULD_AUTOBATCH]: true } };

describe('makeStore autoBatch (#441)', () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('by default falls back to a timer next to requestAnimationFrame', () => {
    vi.useFakeTimers();
    const raf = vi.fn(() => 1);
    vi.stubGlobal('requestAnimationFrame', raf);
    vi.stubGlobal('cancelAnimationFrame', vi.fn());
    makeStore({ postgrest: null }).dispatch(lowPriority);
    expect(raf).toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(1);
  });

  it("with 'tick' queues the notification as a microtask, with no frame and no timer", () => {
    vi.useFakeTimers();
    const raf = vi.fn(() => 1);
    const microtask = vi.fn();
    vi.stubGlobal('requestAnimationFrame', raf);
    // RTK picks its queue function when the store is made, so stub it first.
    vi.stubGlobal('queueMicrotask', microtask);
    const store = makeStore({ postgrest: null, autoBatch: 'tick' });
    store.dispatch(lowPriority);
    // Fails if the tick setting is dropped: the notification would then go
    // through requestAnimationFrame and a timer, or not be batched at all.
    expect(microtask).toHaveBeenCalledTimes(1);
    expect(raf).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });
});
