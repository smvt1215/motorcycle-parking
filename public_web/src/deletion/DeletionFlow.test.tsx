import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, vi } from 'vitest';
import { apiError, fakeAuth, noRequest, openSite, pendingUntil, rider, stubApi } from '../test/site';
import * as t from './text';

// 2026-11-12T02:00Z is 10:00 on 12 November in Taiwan.
const scheduled = '2026-11-12T02:00:00Z';

afterEach(() => vi.unstubAllGlobals());

/** Lets pending API calls (thunk, token, fetch) run to the end. */
async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 50));
}

async function heading(name: string) {
  return screen.findByRole('heading', { level: 1, name });
}

describe('signed out', () => {
  it('signs in with the provider they pick, and the flow takes over', async () => {
    const auth = fakeAuth();
    stubApi({ account_deletion_status: { body: noRequest } });
    openSite('/account-deletion', auth);
    auth.next = { kind: 'signedIn', user: { ...rider, provider: 'apple' } };
    await userEvent.click(screen.getByRole('button', { name: '使用 Apple 登入' }));
    expect(auth.signIn).toHaveBeenCalledWith('apple');
    await heading(t.confirmTitle);
    expect(screen.getByText('以 Apple 登入：rider@gmail.com')).toBeInTheDocument();
  });

  it('offers no sign-in when the build has none', () => {
    openSite('/account-deletion', null);
    expect(screen.queryByRole('button', { name: '使用 Google 登入' })).toBeNull();
    expect(screen.getByRole('link', { name: '填寫客服表單' })).toBeInTheDocument();
  });

  it('an identity the App has never seen: nothing to delete, nothing created', async () => {
    const auth = fakeAuth();
    const calls = stubApi({});
    openSite('/account-deletion', auth);
    auth.next = { kind: 'noAccount', email: 'new@gmail.com' };
    await userEvent.click(screen.getByRole('button', { name: '使用 Google 登入' }));
    await heading(t.noAccountTitle);
    expect(screen.getByText(t.noAccountBody('new@gmail.com'))).toBeInTheDocument();
    expect(screen.getByText(t.noAccountHint('google'))).toBeInTheDocument();
    expect(screen.getByRole('link', { name: t.noAccountSupport })).toHaveAttribute('href', '/support');
    expect(calls).toEqual([]);
    await userEvent.click(screen.getByRole('button', { name: t.noAccountRetry }));
    expect(await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' })).toBeInTheDocument();
  });

  it('says so when the sign-in did not finish, and leads back', async () => {
    const auth = fakeAuth();
    openSite('/account-deletion', auth);
    await userEvent.click(screen.getByRole('button', { name: '使用 Google 登入' }));
    await heading(t.signInIncompleteTitle);
    expect(screen.getByText(t.signInIncompleteBody)).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: t.signInRetry }));
    expect(await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' })).toBeInTheDocument();
  });
});

describe('confirming the request (PhoneConfirm)', () => {
  it('shows the account and holds the button until the box is ticked', async () => {
    const calls = stubApi({ account_deletion_status: { body: noRequest } });
    openSite('/account-deletion', fakeAuth(rider));
    await heading(t.confirmTitle);
    expect(screen.getByText('以 Google 登入：rider@gmail.com')).toBeInTheDocument();
    t.confirmPoints.forEach((point) => expect(screen.getByText(point)).toBeInTheDocument());

    const action = screen.getByRole('button', { name: t.confirmAction });
    expect(action).toHaveAttribute('aria-disabled', 'true');
    expect(action).toHaveAccessibleDescription(t.confirmCheckHint);
    await userEvent.click(action);
    // Let a wrongly sent request reach fetch before checking it did not.
    await settle();
    expect(calls.map((c) => c.fn)).toEqual(['account_deletion_status']);
    expect(screen.getByRole('heading', { level: 1, name: t.confirmTitle })).toBeInTheDocument();
    expect(calls[0]!.token).toBe('Bearer token-u-1');
  });

  it('sends the request from the web and shows the date it runs', async () => {
    const auth = fakeAuth(rider);
    const calls = stubApi({
      account_deletion_status: { body: noRequest },
      request_account_deletion: { body: pendingUntil(scheduled) },
    });
    openSite('/account-deletion', auth);
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('checkbox', { name: t.confirmCheck }));
    await userEvent.click(screen.getByRole('button', { name: t.confirmAction }));

    await heading(t.requestedTitle);
    expect(calls.find((c) => c.fn === 'request_account_deletion')!.body).toEqual({ p_source: 'web' });
    expect(screen.getByText('帳號預計於 11 月 12 日後刪除。')).toBeInTheDocument();
    t.requestedRows.forEach((row) => expect(screen.getByText(row)).toBeInTheDocument());

    await userEvent.click(screen.getByRole('button', { name: t.requestedDone }));
    expect(auth.signOut).toHaveBeenCalled();
    expect(await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' })).toBeInTheDocument();
  });

  it('cancel signs out without asking the API anything else', async () => {
    const auth = fakeAuth(rider);
    const calls = stubApi({ account_deletion_status: { body: noRequest } });
    openSite('/account-deletion', auth);
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('button', { name: t.confirmCancel }));
    await settle();
    expect(auth.signOut).toHaveBeenCalled();
    expect(calls.map((c) => c.fn)).toEqual(['account_deletion_status']);
  });

  async function staleSignIn(
    auth: ReturnType<typeof fakeAuth>,
    after: object = { body: pendingUntil(scheduled) },
  ) {
    const calls = stubApi({
      account_deletion_status: { body: noRequest },
      request_account_deletion: [apiError(401, 'auth.recent_sign_in_required'), after as never],
    });
    openSite('/account-deletion', auth);
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('checkbox', { name: t.confirmCheck }));
    await userEvent.click(screen.getByRole('button', { name: t.confirmAction }));
    await heading(t.reauthTitle);
    expect(screen.getByText(t.reauthFootnote)).toBeInTheDocument();
    return calls;
  }

  it('a stale sign-in asks to sign in again as this account, then sends straight away', async () => {
    const auth = fakeAuth(rider);
    const calls = await staleSignIn(auth);
    auth.next = { kind: 'signedIn', user: rider };
    await userEvent.click(screen.getByRole('button', { name: '使用 Google 登入' }));
    expect(auth.signIn).toHaveBeenCalledWith('google', { reauthFor: rider });
    await heading(t.requestedTitle);
    expect(calls.filter((c) => c.fn === 'request_account_deletion')).toHaveLength(2);
  });

  it('signing in again as another identity sends nothing and keeps the account', async () => {
    const auth = fakeAuth(rider);
    const calls = await staleSignIn(auth);
    auth.next = { kind: 'wrongAccount', email: 'other@gmail.com' };
    await userEvent.click(screen.getByRole('button', { name: '使用 Google 登入' }));
    await heading(t.wrongAccountTitle);
    expect(screen.getByText(t.wrongAccountBody('o••••@gmail.com'))).toBeInTheDocument();
    expect(auth.signOut).not.toHaveBeenCalled();
    expect(calls.filter((c) => c.fn === 'request_account_deletion')).toHaveLength(1);
    await userEvent.click(screen.getByRole('button', { name: t.ok }));
    await heading(t.confirmTitle);
  });

  it('a re-sign-in that did not finish can be tried again', async () => {
    const auth = fakeAuth(rider);
    await staleSignIn(auth);
    await userEvent.click(screen.getByRole('button', { name: '使用 Google 登入' }));
    await heading(t.signInIncompleteTitle);
    await userEvent.click(screen.getByRole('button', { name: t.signInRetry }));
    await heading(t.reauthTitle);
  });

  it('a lost connection says nothing was sent and retries', async () => {
    const calls = stubApi({
      account_deletion_status: { body: noRequest },
      request_account_deletion: ['network', { body: pendingUntil(scheduled) }],
    });
    openSite('/account-deletion', fakeAuth(rider));
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('checkbox', { name: t.confirmCheck }));
    await userEvent.click(screen.getByRole('button', { name: t.confirmAction }));
    await heading(t.networkFailedTitle);
    await userEvent.click(screen.getByRole('button', { name: t.networkRetry }));
    await heading(t.requestedTitle);
    expect(calls.filter((c) => c.fn === 'request_account_deletion')).toHaveLength(2);
  });

  it('an administrator is told why, and is not offered the request', async () => {
    stubApi({
      account_deletion_status: {
        body: {
          ...noRequest,
          can_self_delete: false,
          cannot_self_delete_reason: 'account.admin_cannot_self_delete',
        },
      },
    });
    openSite('/account-deletion', fakeAuth(rider));
    await heading(t.adminCannotDeleteTitle);
    expect(screen.queryByRole('button', { name: t.confirmAction })).toBeNull();
  });
});

describe('other answers to the request', () => {
  async function send(answer: Parameters<typeof stubApi>[0][string]) {
    stubApi({ account_deletion_status: { body: noRequest }, request_account_deletion: answer });
    openSite('/account-deletion', fakeAuth(rider));
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('checkbox', { name: t.confirmCheck }));
    await userEvent.click(screen.getByRole('button', { name: t.confirmAction }));
  }

  it('an administrator found only at sending is told why', async () => {
    await send(apiError(403, 'account.admin_cannot_self_delete'));
    await heading(t.adminCannotDeleteTitle);
  });

  it('anything else is a plain error, not a retry that cannot help', async () => {
    await send(apiError(400, 'request.invalid'));
    await heading(t.genericErrorTitle);
    expect(screen.queryByRole('button', { name: t.networkRetry })).toBeNull();
  });

  it('a session that ended before sending signs the page out', async () => {
    const auth = fakeAuth(rider);
    stubApi({
      account_deletion_status: { body: noRequest },
      request_account_deletion: apiError(401, 'auth.sign_in_required'),
    });
    openSite('/account-deletion', auth);
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('checkbox', { name: t.confirmCheck }));
    await userEvent.click(screen.getByRole('button', { name: t.confirmAction }));
    await waitFor(() => expect(auth.signOut).toHaveBeenCalled());
  });

  it('「登入以取消刪除」 goes straight to the cooling-off choice while signed in', async () => {
    const auth = fakeAuth(rider);
    stubApi({
      account_deletion_status: [{ body: noRequest }, { body: pendingUntil(scheduled) }],
      request_account_deletion: { body: pendingUntil(scheduled) },
    });
    openSite('/account-deletion', auth);
    await heading(t.confirmTitle);
    await userEvent.click(screen.getByRole('checkbox', { name: t.confirmCheck }));
    await userEvent.click(screen.getByRole('button', { name: t.confirmAction }));
    await heading(t.requestedTitle);
    await userEvent.click(screen.getByRole('button', { name: t.requestedSignIn }));
    await heading(t.pendingTitle);
    expect(auth.signOut).not.toHaveBeenCalled();
    expect(auth.signIn).not.toHaveBeenCalled();
  });
});

describe('signed in during the cooling-off (PhonePending)', () => {
  it('asks for a choice, with no way around it', async () => {
    stubApi({ account_deletion_status: { body: pendingUntil(scheduled) } });
    openSite('/account-deletion', fakeAuth(rider));
    const title = await heading(t.pendingTitle);
    await waitFor(() => expect(title).toHaveFocus());
    expect(screen.getByRole('button', { name: /取消刪除/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /繼續刪除/ })).toHaveTextContent(
      '維持申請並登出，11 月 12 日後刪除。',
    );
    expect(screen.getByText(t.pendingFootnote)).toBeInTheDocument();
  });

  it('cancelling restores the account', async () => {
    const auth = fakeAuth(rider);
    const calls = stubApi({
      account_deletion_status: { body: pendingUntil(scheduled) },
      cancel_account_deletion: { body: noRequest },
    });
    openSite('/account-deletion', auth);
    await heading(t.pendingTitle);
    await userEvent.click(screen.getByRole('button', { name: /取消刪除/ }));
    await heading(t.cancelledTitle);
    expect(calls.map((c) => c.fn)).toContain('cancel_account_deletion');
    await userEvent.click(screen.getByRole('button', { name: t.dismiss }));
    expect(auth.signOut).toHaveBeenCalled();
  });

  it('once the deletion has started it cannot be cancelled', async () => {
    stubApi({
      account_deletion_status: { body: pendingUntil(scheduled) },
      cancel_account_deletion: apiError(409, 'account.deletion_in_progress'),
    });
    openSite('/account-deletion', fakeAuth(rider));
    await heading(t.pendingTitle);
    await userEvent.click(screen.getByRole('button', { name: /取消刪除/ }));
    await heading(t.inProgressTitle);
    expect(screen.getByText(t.inProgressBody)).toBeInTheDocument();
  });

  it('continuing keeps the request, signs out and says when it runs', async () => {
    const auth = fakeAuth(rider);
    const calls = stubApi({ account_deletion_status: { body: pendingUntil(scheduled) } });
    openSite('/account-deletion', auth);
    await heading(t.pendingTitle);
    await userEvent.click(screen.getByRole('button', { name: /繼續刪除/ }));
    await heading(t.continuedTitle);
    expect(auth.signOut).toHaveBeenCalled();
    expect(screen.getByText('帳號預計於 11 月 12 日後刪除。')).toBeInTheDocument();
    expect(calls.map((c) => c.fn)).toEqual(['account_deletion_status']);
    await userEvent.click(screen.getByRole('button', { name: t.dismiss }));
    const page = await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' });
    expect(
      within(page.closest('main')!).getByRole('button', { name: '使用 Google 登入' }),
    ).toBeInTheDocument();
  });
});

describe('the session', () => {
  it('ended elsewhere: back to signed out', async () => {
    const auth = fakeAuth(rider);
    stubApi({ account_deletion_status: apiError(401, 'auth.sign_in_required') });
    openSite('/account-deletion', auth);
    await waitFor(() => expect(auth.signOut).toHaveBeenCalled());
    expect(await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' })).toBeInTheDocument();
  });
});
