import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { linkToken, submittedLabel, supportCode } from './format';
import * as t from './text';

// The mails the backend sends about the same request
// (supabase/functions/support-request/resend.ts). Tests run from public_web/.
const mails = readFileSync(resolve(process.cwd(), '../supabase/functions/support-request/resend.ts'), 'utf8');

describe('the pages say what the mails say', () => {
  it('shows the request code the way the mails do', () => {
    expect(mails).toContain(
      'export const supportCode = (id: string) => `S-${id.slice(0, 8).toUpperCase()}`;',
    );
    expect(supportCode('1a2b3c4d-0000-4000-8000-000000000001')).toBe('S-1A2B3C4D');
  });

  it('names the sender the mails come from', () => {
    const address = mails.match(/export const supportAddress = '([^']+)';/)?.[1];
    expect(address).toBeTruthy();
    expect(t.receivedBody[0]).toContain(`寄件人是 ${address}`);
  });

  it('names the buttons the mails send riders to', () => {
    expect(mails).toContain(`「${t.verifyDeny}」`);
    expect(mails).toContain(`選「${t.cancelButton}」`);
  });

  it('names each kind the way the mails do', () => {
    const names = mails.match(/export const kindNames[^{]*\{([^}]+)\}/)?.[1];
    expect(names).toBeTruthy();
    const listed = [...names!.matchAll(/(\w+): '([^']+)'/g)].map(([, key, name]) => [key, name]);
    expect(Object.entries(t.kindNames).sort()).toEqual(listed.sort());
  });

  it('says what the privacy confirmation mail says', () => {
    expect(mails).toContain('按「是我」');
    expect(t.privacyVerifyConfirm.startsWith('是我')).toBe(true);
    expect(mails).toContain('資料也只會寄到這個信箱');
    expect(t.privacyVerifyBody).toContain('資料也只會寄到帳號的登入 email');
    const address = mails.match(/export const supportAddress = '([^']+)';/)?.[1];
    expect(t.privacyReceivedBody[0]).toContain(`寄件人是 ${address}`);
  });

  it('gives the case link the same lifetime', () => {
    expect(mails).toContain('或打開案件連結（30 天內有效）');
    expect(t.caseReceivedBody[1]).toContain('案件連結（30 天內有效）');
    expect(t.caseInvalidBody.before).toContain('（30 天）');
  });

  it('names no reply time on the pages', () => {
    const copy = Object.values(t)
      .flat()
      .map((value) => JSON.stringify(value))
      .join('');
    expect(copy).not.toContain('工作天');
  });

  it('gives the confirmation link the same lifetime', () => {
    expect(mails).toContain('請在 24 小時內打開下面的連結');
    expect(t.receivedBody[0]).toContain('連結 24 小時內有效、只能使用一次');
    expect(mails).toContain('申請後有 7 天冷靜期');
    expect(t.verifyBody).toContain('7 天冷靜期');
  });
});

describe('formatting', () => {
  it('shows the submitted time in Taiwan', () => {
    expect(submittedLabel('2026-11-06T16:05:00Z')).toBe('11 月 7 日 00:05');
    expect(submittedLabel(null)).toBeNull();
    expect(submittedLabel('nope')).toBeNull();
  });

  it('reads only a well-formed token from the fragment', () => {
    const id = '9f8e7d6c-0000-4000-8000-000000000002';
    const secret = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJ0123_-x';
    expect(linkToken(`#token=${id}.${secret}`)).toEqual({ token: `${id}.${secret}`, id });
    expect(linkToken('')).toBeNull();
    expect(linkToken(`#token=${id}`)).toBeNull();
    expect(linkToken(`#token=${id}.${secret}x`)).toBeNull();
    expect(linkToken(`#token=${id.toUpperCase()}.${secret}`)).toBeNull();
  });
});
