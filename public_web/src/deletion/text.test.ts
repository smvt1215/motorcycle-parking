import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import * as t from './text';

// The App's words for the same flow (tests run from public_web/).
const dart = readFileSync(resolve(process.cwd(), '../lib/domain/account_deletion_display.dart'), 'utf8');

function dartString(name: string): string {
  const match = dart.match(new RegExp(`const ${name} =\\s*'([^']*)';`));
  if (!match?.[1]) throw new Error(`${name} not found in account_deletion_display.dart`);
  return match[1];
}

function dartList(name: string): string[] {
  const match = dart.match(new RegExp(`const ${name} = \\[([\\s\\S]*?)\\];`));
  if (!match?.[1]) throw new Error(`${name} not found in account_deletion_display.dart`);
  return [...match[1].matchAll(/'([^']*)'/g)].map((m) => m[1]!);
}

/** Web constant → the App's, where both say the same thing. */
const SAME: [string, string][] = [
  [t.confirmTitle, 'deletionConfirmTitle'],
  [t.confirmBody, 'deletionConfirmBody'],
  [t.confirmCancel, 'deletionConfirmCancel'],
  [t.confirmAction, 'deletionConfirmAction'],
  [t.sending, 'deletionSending'],
  [t.reauthNote, 'deletionReauthNote'],
  [t.reauthTitle, 'reauthTitle'],
  [t.reauthBody, 'reauthBody'],
  [t.reauthBodyApple, 'reauthBodyApple'],
  [t.reauthFootnote, 'reauthFootnote'],
  [t.reauthCancel, 'reauthCancel'],
  [t.adminCannotDeleteTitle, 'adminCannotDeleteTitle'],
  [t.adminCannotDeleteBody, 'adminCannotDeleteBody'],
  [t.networkFailedTitle, 'networkFailedTitle'],
  [t.networkFailedBody, 'networkFailedBody'],
  [t.networkRetry, 'networkRetry'],
  [t.signInIncompleteBody, 'reauthIncomplete'],
  [t.genericErrorTitle, 'genericErrorTitle'],
  [t.genericErrorBody, 'genericErrorBody'],
  [t.ok, 'dialogOk'],
  [t.requestedTitle, 'requestedTitle'],
  [t.requestedDone, 'requestedDone'],
  [t.requestedSignIn, 'requestedSignIn'],
  [t.appleRevokeFailedTitle, 'appleRevokeFailedTitle'],
  [t.appleRevokeFailedBody, 'appleRevokeFailedBody'],
  [t.pendingTitle, 'pendingTitle'],
  [t.pendingBody, 'pendingBody'],
  [t.pendingCancel, 'pendingCancel'],
  [t.pendingCancelDetail, 'pendingCancelDetail'],
  [t.pendingContinue, 'pendingContinue'],
  [t.cancelledTitle, 'cancelledBannerTitle'],
  [t.cancelledBody, 'cancelledBannerBody'],
  [t.continuedTitle, 'continuedTitle'],
  [t.dismiss, 'bannerDismiss'],
  [t.inProgressTitle, 'inProgressTitle'],
  [t.inProgressBody, 'inProgressBody'],
];

describe('the web flow says what the App says', () => {
  it.each(SAME)('%s', (web, name) => {
    expect(web).toBe(dartString(name));
  });

  it('lists the same rows after the request', () => {
    expect([...t.requestedRows]).toEqual(dartList('requestedRows'));
  });

  it('words the date lines the same way', () => {
    expect(dart).toContain("'帳號預計於 ${deletionDateLabel(scheduledAt)}後刪除。'");
    expect(t.scheduledLine('11 月 12 日')).toBe('帳號預計於 11 月 12 日後刪除。');
    expect(dart).toContain("'維持申請並登出，${deletionDateLabel(scheduledAt)}後刪除。'");
    expect(t.pendingContinueDetail('11 月 12 日')).toBe('維持申請並登出，11 月 12 日後刪除。');
  });

  it("adds to the App's Apple note when the rider has only just signed in here", () => {
    expect(t.reauthNoteApple).toBe(`如果不是剛才在這個頁面登入，${dartString('deletionReauthNoteApple')}`);
  });

  it('only the footnote of the choice differs: there is no App to go on to', () => {
    expect(dartString('pendingFootnote')).toBe('要先選一個，才能繼續使用 App。');
    expect(t.pendingFootnote).toBe('要先選一個，才能繼續。');
  });
});
