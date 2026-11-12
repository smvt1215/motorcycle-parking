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

  it("with 'tick' queues neither a frame nor a timer, so nothing fires after teardown", async () => {
    vi.useFakeTimers();
    const raf = vi.fn(() => 1);
    vi.stubGlobal('requestAnimationFrame', raf);
    const store = makeStore({ postgrest: null, autoBatch: 'tick' });
    const listener = vi.fn();
    store.subscribe(listener);
    store.dispatch(lowPriority);
    expect(raf).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
    await Promise.resolve();
    // Subscribers are still told, by a microtask instead of a timer.
    expect(listener).toHaveBeenCalled();
  });
});
