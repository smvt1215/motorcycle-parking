import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, vi } from 'vitest';
import { SIGN_IN_TIMEOUT_MS, useSignInChecking } from './useSignInChecking';

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

function open(onTimeout = vi.fn()) {
  return { ...renderHook(() => useSignInChecking(onTimeout)), onTimeout };
}

describe('a sign-in attempt', () => {
  it('is waited for until it ends', () => {
    const { result, onTimeout } = open();
    const attempt = result.current.attempt();
    let gaveUp = () => true;
    act(() => {
      gaveUp = attempt.onChecking();
    });
    expect(result.current.checking).toBe(true);
    expect(gaveUp()).toBe(false);
    let accepted = false;
    act(() => {
      accepted = attempt.accept();
    });
    expect(accepted).toBe(true);
    expect(result.current.checking).toBe(false);
    act(() => void vi.advanceTimersByTime(SIGN_IN_TIMEOUT_MS));
    expect(onTimeout).not.toHaveBeenCalled();
  });

  it('expires at the timeout and stays expired', () => {
    const { result, onTimeout } = open();
    const attempt = result.current.attempt();
    let gaveUp = () => false;
    act(() => {
      gaveUp = attempt.onChecking();
    });
    act(() => void vi.advanceTimersByTime(SIGN_IN_TIMEOUT_MS - 1));
    expect(gaveUp()).toBe(false);
    act(() => void vi.advanceTimersByTime(1));
    expect(onTimeout).toHaveBeenCalledTimes(1);
    expect(gaveUp()).toBe(true);
    expect(attempt.accept()).toBe(false);
  });

  it('is not given up when a successful sign-in unmounts the page first', () => {
    // The session arrives before signInWithIdToken returns: the buttons are gone by then.
    const { result, unmount, onTimeout } = open();
    const attempt = result.current.attempt();
    let gaveUp = () => true;
    act(() => {
      gaveUp = attempt.onChecking();
    });
    unmount();
    expect(gaveUp()).toBe(false);
    vi.advanceTimersByTime(SIGN_IN_TIMEOUT_MS);
    expect(gaveUp()).toBe(false);
    expect(onTimeout).not.toHaveBeenCalled();
  });

  it('stays expired after a later attempt has ended', () => {
    const { result } = open();
    const first = result.current.attempt();
    let gaveUp = () => false;
    act(() => {
      gaveUp = first.onChecking();
    });
    act(() => void vi.advanceTimersByTime(SIGN_IN_TIMEOUT_MS));

    // Ended without the provider answering.
    const second = result.current.attempt();
    expect(second.accept()).toBe(true);
    // Ended after answering.
    const third = result.current.attempt();
    act(() => {
      third.onChecking();
    });
    act(() => {
      third.accept();
    });

    expect(gaveUp()).toBe(true);
    expect(first.accept()).toBe(false);
  });

  it('leaves another attempt waiting when one ends without the provider answering', () => {
    const { result } = open();
    const waiting = result.current.attempt();
    act(() => {
      waiting.onChecking();
    });
    act(() => {
      result.current.attempt().accept();
    });
    expect(result.current.checking).toBe(true);
  });
});
