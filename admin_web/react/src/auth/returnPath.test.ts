import { beforeEach, describe, expect, it } from 'vitest';
import { saveReturnPath, takeReturnPath } from './returnPath';

describe('returnPath', () => {
  beforeEach(() => sessionStorage.clear());

  it('returns a case deep link once', () => {
    saveReturnPath({ pathname: '/pending/abc', search: '?tab=support' });
    expect(takeReturnPath()).toBe('/pending/abc?tab=support');
    expect(takeReturnPath()).toBeNull();
  });

  it('ignores anywhere that is not 待處理', () => {
    saveReturnPath({ pathname: '/spots', search: '' });
    expect(takeReturnPath()).toBeNull();
  });

  it('refuses a stored path that leaves the page', () => {
    sessionStorage.setItem('motopark-admin-return-path', '//evil.example/pending');
    expect(takeReturnPath()).toBeNull();
    sessionStorage.setItem('motopark-admin-return-path', '/pending/a/b');
    expect(takeReturnPath()).toBeNull();
  });
});
