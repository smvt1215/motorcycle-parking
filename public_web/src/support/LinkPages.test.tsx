import { act, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, vi } from 'vitest';
import { openSite, stubFunctions, type Answer } from '../test/site';
import * as t from './text';

afterEach(() => vi.unstubAllGlobals());

const id = '9f8e7d6c-0000-4000-8000-000000000002';
const token = `${id}.${'A'.repeat(42)}w`;
const code = 'S-9F8E7D6C';
// 2026-11-06T07:05Z is 15:05 on 6 November in Taiwan; 2026-11-13T07:05Z is 13 November.
const submitted = '2026-11-06T07:05:00Z';
const scheduled = '2026-11-13T07:05:00Z';

const linkInvalid: Answer = { status: 400, body: { error: 'support.link_invalid' } };
const down: Answer = { status: 503, body: { error: 'server.unavailable' } };

function confirmAnswer(result: string, scheduledAt: string | null = null): Answer {
  return {
    body: { result, submitted_at: submitted, contact_email: 'r***@e***.com', scheduled_at: scheduledAt },
  };
}
function cancelAnswer(result: string, scheduledAt: string | null = null): Answer {
  return { body: { result, scheduled_at: scheduledAt } };
}

async function heading(name: string) {
  return screen.findByRole('heading', { level: 1, name });
}

/** Lets pending calls run to the end. */
async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 50));
}

describe('the confirmation link', () => {
  it('shows the request on opening, changes nothing, and drops the token from the address', async () => {
    const calls = stubFunctions({ 'support-confirm': confirmAnswer('pending') });
    const { router } = openSite(`/support/verify#token=${token}`);
    const h1 = await heading(t.verifyTitle);
    await waitFor(() => expect(h1).toHaveFocus());
    expect(calls).toEqual([
      expect.objectContaining({ fn: 'support-confirm', body: { link: 'confirm', token, action: 'view' } }),
    ]);
    expect(calls[0]!.headers.get('x-firebase-appcheck')).toBeNull();
    expect(router.state.location.hash).toBe('');
    expect(router.state.location.pathname).toBe('/support/verify');
    expect(router.state.historyAction).toBe('REPLACE');
    const rows = document.querySelector('dl')!;
    expect(rows).toHaveTextContent(`${t.codeLabel}${code}`);
    expect(rows).toHaveTextContent(`${t.submittedAtLabel}11 月 6 日 15:05`);
    expect(rows).toHaveTextContent(`${t.contactEmailLabel}r***@e***.com`);
    expect(rows).toHaveTextContent(`${t.accountLabel}${t.accountValue}`);
    expect(screen.getByRole('button', { name: t.verifyConfirm })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: t.verifyDeny })).toBeInTheDocument();
    await settle();
    expect(calls).toHaveLength(1);
  });

  it('asks for the deletion only from the button', async () => {
    const calls = stubFunctions({
      'support-confirm': [confirmAnswer('pending'), confirmAnswer('deletion_requested', scheduled)],
    });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    expect(calls.map((call) => call.body!.action)).toEqual(['view']);
    await userEvent.setup().click(screen.getByRole('button', { name: t.verifyConfirm }));
    const h1 = await heading(t.requestedTitle);
    await waitFor(() => expect(h1).toHaveFocus());
    expect(calls.map((call) => call.body!.action)).toEqual(['view', 'confirm']);
    expect(calls[1]!.body!.token).toBe(token);
    expect(screen.getByText(t.requestedBody('11 月 13 日'))).toBeInTheDocument();
    expect(screen.getByText(t.requestedCancel)).toBeInTheDocument();
    expect(screen.getByText(t.requestedApple)).toBeInTheDocument();
  });

  it('voids the request from 「不是我申請的」', async () => {
    const calls = stubFunctions({ 'support-confirm': [confirmAnswer('pending'), confirmAnswer('denied')] });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    await userEvent.setup().click(screen.getByRole('button', { name: t.verifyDeny }));
    await heading(t.deniedTitle);
    expect(screen.getByText(t.deniedBody)).toBeInTheDocument();
    expect(calls.map((call) => call.body!.action)).toEqual(['view', 'deny']);
  });

  it.each([
    ['resolved', null, t.resolvedTitle, t.resolvedBody],
    ['account_deletion_pending', scheduled, t.alreadyPendingTitle, t.alreadyPendingBody('11 月 13 日')],
    ['account_deleting', null, t.deletingTitle, t.deletingBody],
    ['unavailable', null, t.adminTitle, t.adminBody],
  ])('says %s when the link opens, without the buttons', async (result, at, title, body) => {
    stubFunctions({ 'support-confirm': confirmAnswer(result, at) });
    openSite(`/support/verify#token=${token}`);
    await heading(title);
    expect(screen.getByText(body)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: t.verifyConfirm })).toBeNull();
  });

  it.each([
    ['account_deletion_pending', scheduled, t.alreadyPendingTitle],
    ['account_deleting', null, t.deletingTitle],
    ['unavailable', null, t.adminTitle],
  ])('says %s when the confirmation meets it', async (result, at, title) => {
    stubFunctions({ 'support-confirm': [confirmAnswer('pending'), confirmAnswer(result, at)] });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    await userEvent.setup().click(screen.getByRole('button', { name: t.verifyConfirm }));
    await heading(title);
  });

  it('says the link is invalid for an expired or used token, with the way back to the form', async () => {
    stubFunctions({ 'support-confirm': linkInvalid });
    const { router } = openSite(`/support/verify#token=${token}`);
    await heading(t.verifyInvalidTitle);
    expect(screen.getByText(t.verifyInvalidBody)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: t.refillForm })).toHaveAttribute('href', '/support');
    expect(router.state.location.hash).toBe('');
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('never shows the deletion page for a privacy request link', async () => {
    stubFunctions({
      'support-confirm': {
        body: { result: 'pending', kind: 'privacy', submitted_at: submitted, contact_email: 'r***@e***.com' },
      },
    });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyInvalidTitle);
    expect(screen.queryByRole('heading', { level: 1, name: t.verifyTitle })).toBeNull();
  });

  it('says the link is invalid when a used token meets the confirmation', async () => {
    stubFunctions({ 'support-confirm': [confirmAnswer('pending'), linkInvalid] });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    await userEvent.setup().click(screen.getByRole('button', { name: t.verifyConfirm }));
    await heading(t.verifyInvalidTitle);
  });

  it.each([['/support/verify'], ['/support/verify#token=abc'], [`/support/verify#token=${id}`]])(
    'sends nothing for %s',
    async (path) => {
      const calls = stubFunctions({ 'support-confirm': confirmAnswer('pending') });
      openSite(path);
      await heading(t.verifyInvalidTitle);
      await settle();
      expect(calls).toHaveLength(0);
    },
  );

  it('retries the same action after no answer', async () => {
    const calls = stubFunctions({
      'support-confirm': [
        confirmAnswer('pending'),
        'network',
        confirmAnswer('deletion_requested', scheduled),
      ],
    });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: t.verifyConfirm }));
    await heading(t.linkNetworkTitle);
    expect(screen.getByRole('alert')).toHaveTextContent(t.linkNetworkBody);
    await user.click(screen.getByRole('button', { name: t.retry }));
    await heading(t.requestedTitle);
    expect(calls.map((call) => call.body!.action)).toEqual(['view', 'confirm', 'confirm']);
  });

  it('says something went wrong when the backend is down', async () => {
    stubFunctions({ 'support-confirm': [down, confirmAnswer('pending')] });
    openSite(`/support/verify#token=${token}`);
    await heading(t.linkErrorTitle);
    await userEvent.setup().click(screen.getByRole('button', { name: t.retry }));
    await heading(t.verifyTitle);
  });

  it('treats an answer it does not know as an error', async () => {
    stubFunctions({ 'support-confirm': confirmAnswer('something_new') });
    openSite(`/support/verify#token=${token}`);
    await heading(t.linkErrorTitle);
  });

  it('cannot do anything without a backend', async () => {
    openSite(`/support/verify#token=${token}`, null, null);
    await heading(t.linkErrorTitle);
  });
});

describe('another link in the same tab', () => {
  const other = `1a2b3c4d-0000-4000-8000-000000000003.${'B'.repeat(42)}w`;

  it('starts over with the new token, and actions go to the new request', async () => {
    const calls = stubFunctions({ 'support-confirm': confirmAnswer('pending') });
    const { router } = openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    await waitFor(() => expect(router.state.location.hash).toBe(''));

    await act(() => router.navigate(`/support/verify#token=${other}`));
    await waitFor(() =>
      expect(calls.at(-1)!.body).toEqual({ link: 'confirm', token: other, action: 'view' }),
    );
    await waitFor(() => expect(router.state.location.hash).toBe(''));
    await heading(t.verifyTitle);
    expect(screen.getByText('S-1A2B3C4D')).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: t.verifyConfirm }));
    await waitFor(() =>
      expect(calls.at(-1)!.body).toEqual({ link: 'confirm', token: other, action: 'confirm' }),
    );
    expect(calls.filter((c) => (c.body as { token: string }).token === token)).toHaveLength(1);
  });

  it('dropping the token from the address does not reopen the link', async () => {
    const calls = stubFunctions({ 'support-confirm': confirmAnswer('pending') });
    openSite(`/support/verify#token=${token}`);
    await heading(t.verifyTitle);
    await settle();
    expect(calls).toHaveLength(1);
  });
});

describe('the cancel link', () => {
  it('shows the deletion time on opening, changes nothing, and drops the token from the address', async () => {
    const calls = stubFunctions({ 'support-confirm': cancelAnswer('pending', scheduled) });
    const { router } = openSite(`/support/cancel#token=${token}`);
    const h1 = await heading(t.cancelTitle);
    await waitFor(() => expect(h1).toHaveFocus());
    expect(calls).toEqual([
      expect.objectContaining({ fn: 'support-confirm', body: { link: 'cancel', token, action: 'view' } }),
    ]);
    expect(router.state.location.hash).toBe('');
    const rows = document.querySelector('dl')!;
    expect(rows).toHaveTextContent(`${t.codeLabel}${code}`);
    expect(rows).toHaveTextContent(`${t.scheduledLabel}11 月 13 日後`);
    expect(screen.getByText(t.cancelKeepNote)).toBeInTheDocument();
    await settle();
    expect(calls).toHaveLength(1);
  });

  it('cancels only from the button', async () => {
    const calls = stubFunctions({
      'support-confirm': [cancelAnswer('pending', scheduled), cancelAnswer('cancelled')],
    });
    openSite(`/support/cancel#token=${token}`);
    await heading(t.cancelTitle);
    await userEvent.setup().click(screen.getByRole('button', { name: t.cancelButton }));
    await heading(t.cancelledTitle);
    expect(screen.getByRole('status')).toHaveTextContent(t.cancelledBody);
    expect(calls.map((call) => call.body!.action)).toEqual(['view', 'cancel']);
  });

  it.each([
    ['not_pending', t.notPendingTitle, t.notPendingBody],
    ['account_deleting', t.deletingTitle, t.deletingBody],
  ])('says %s', async (result, title, body) => {
    stubFunctions({ 'support-confirm': cancelAnswer(result) });
    openSite(`/support/cancel#token=${token}`);
    await heading(title);
    expect(screen.getByText(body)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: t.cancelButton })).toBeNull();
  });

  it('says the link is invalid for an expired or used token', async () => {
    stubFunctions({ 'support-confirm': linkInvalid });
    openSite(`/support/cancel#token=${token}`);
    await heading(t.cancelInvalidTitle);
    expect(screen.getByText(t.cancelInvalidBody)).toBeInTheDocument();
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('says the deletion is under way when the cancel meets it', async () => {
    stubFunctions({
      'support-confirm': [cancelAnswer('pending', scheduled), cancelAnswer('account_deleting')],
    });
    openSite(`/support/cancel#token=${token}`);
    await heading(t.cancelTitle);
    await userEvent.setup().click(screen.getByRole('button', { name: t.cancelButton }));
    await heading(t.deletingTitle);
  });

  it('sends nothing without a token', async () => {
    const calls = stubFunctions({ 'support-confirm': cancelAnswer('pending', scheduled) });
    openSite('/support/cancel');
    await heading(t.cancelInvalidTitle);
    await settle();
    expect(calls).toHaveLength(0);
  });

  it('retries the cancel after no answer', async () => {
    const calls = stubFunctions({
      'support-confirm': [cancelAnswer('pending', scheduled), 'network', cancelAnswer('cancelled')],
    });
    openSite(`/support/cancel#token=${token}`);
    await heading(t.cancelTitle);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: t.cancelButton }));
    await heading(t.linkNetworkTitle);
    await user.click(screen.getByRole('button', { name: t.retry }));
    await heading(t.cancelledTitle);
    expect(calls.map((call) => call.body!.action)).toEqual(['view', 'cancel', 'cancel']);
  });
});
