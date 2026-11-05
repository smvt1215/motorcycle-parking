import { accountLine, deletionDateLabel, isPrivateRelay, maskEmail } from './format';

describe('deletionDateLabel', () => {
  it('is the calendar day in Taiwan', () => {
    expect(deletionDateLabel('2026-11-12T02:00:00Z')).toBe('11 月 12 日');
    // 17:00 UTC is already the next day in Taiwan.
    expect(deletionDateLabel('2026-11-12T17:00:00Z')).toBe('11 月 13 日');
  });

  it('falls back to 「7 天」 without a date', () => {
    expect(deletionDateLabel(null)).toBe('7 天');
    expect(deletionDateLabel('not a date')).toBe('7 天');
  });
});

describe('the account line', () => {
  it('names the provider and the address', () => {
    expect(accountLine('google', 'rider@gmail.com')).toBe('以 Google 登入：rider@gmail.com');
    expect(accountLine('google', null)).toBe('以 Google 登入');
  });

  it("labels Apple's hidden address", () => {
    expect(accountLine('apple', 'x1y2@privaterelay.appleid.com')).toBe(
      '以 Apple 登入：隱藏的電子郵件（x1y2@privaterelay.appleid.com）',
    );
  });

  it('takes only Apple’s own relay domain for a hidden address', () => {
    expect(isPrivateRelay('x1y2@privaterelay.appleid.com')).toBe(true);
    expect(isPrivateRelay('x1y2@PrivateRelay.AppleID.com')).toBe(true);
    expect(isPrivateRelay('x1y2@evilprivaterelay.appleid.com')).toBe(false);
    expect(isPrivateRelay('privaterelay.appleid.com')).toBe(false);
    expect(isPrivateRelay(null)).toBe(false);
  });

  it('masks an address as the App does', () => {
    expect(maskEmail('other@gmail.com')).toBe('o••••@gmail.com');
    expect(maskEmail('nope')).toBe('••••');
  });
});
