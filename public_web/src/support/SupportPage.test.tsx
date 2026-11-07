import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, vi } from 'vitest';
import { openSite, stubFunctions, testSupport, type Answer } from '../test/site';
import * as t from './text';

afterEach(() => vi.unstubAllGlobals());

const id = '1a2b3c4d-0000-4000-8000-000000000001';
const received: Answer = { body: { received: true, id } };
const failure = (status: number, error: string): Answer => ({ status, body: { error } });

async function heading(name: string) {
  return screen.findByRole('heading', { level: 1, name });
}

const login = () => screen.getByLabelText(/帳號的登入 email/);
const contact = () => screen.getByLabelText(/聯絡用 email/);
const send = () => screen.getByRole('button', { name: t.submit });

async function fill({
  loginEmail = 'rider.old@gmail.com',
  contactEmail = 'me@example.com',
  provider,
  message,
}: {
  loginEmail?: string;
  contactEmail?: string;
  provider?: string;
  message?: string;
} = {}) {
  const user = userEvent.setup();
  if (loginEmail) await user.type(login(), loginEmail);
  if (contactEmail) await user.type(contact(), contactEmail);
  if (provider) await user.click(screen.getByRole('radio', { name: provider }));
  if (message) await user.type(screen.getByLabelText(/為什麼沒辦法登入/), message);
  return user;
}

describe('the support form', () => {
  it('shows the board, with the heading focused and no mail link', async () => {
    openSite('/support');
    const h1 = await heading(t.formTitle);
    expect(h1).toHaveFocus();
    expect(screen.getByText(t.formWarning)).toBeInTheDocument();
    expect(screen.getByRole('group', { name: t.providerLegend })).toBeInTheDocument();
    expect(screen.getAllByRole('radio')).toHaveLength(3);
    expect(screen.getAllByRole('radio').some((radio) => (radio as HTMLInputElement).checked)).toBe(false);
    expect(screen.getByRole('link', { name: '返回刪除帳號說明' })).toHaveAttribute(
      'href',
      '/account-deletion',
    );
    expect(screen.getByText(t.otherQuestions)).toBeInTheDocument();
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('checks both emails before sending anything', async () => {
    const calls = stubFunctions({});
    openSite('/support');
    await heading(t.formTitle);
    const user = userEvent.setup();
    await user.click(send());
    expect(login()).toHaveAttribute('aria-invalid', 'true');
    expect(contact()).toHaveAttribute('aria-invalid', 'true');
    expect(login()).toHaveAccessibleDescription(expect.stringContaining(t.loginMissing));
    expect(contact()).toHaveAccessibleDescription(expect.stringContaining(t.contactMissing));
    expect(login()).toHaveFocus();

    await user.type(login(), 'rider.old@');
    expect(login()).toHaveAccessibleDescription(expect.stringContaining(t.emailIncomplete));
    await user.type(login(), 'gmail.com');
    expect(login()).not.toHaveAttribute('aria-invalid');
    await user.click(send());
    expect(contact()).toHaveFocus();
    expect(calls).toHaveLength(0);
  });

  it.each([
    ['Google', 'google'],
    ['Apple', 'apple'],
    ['不記得', undefined],
    [undefined, undefined],
  ])('sends the request with %s as the sign-in', async (provider, hint) => {
    const calls = stubFunctions({ 'support-request': received });
    openSite('/support');
    await heading(t.formTitle);
    const user = await fill({
      loginEmail: ' Rider.Old@gmail.com ',
      provider,
      message: '換了手機',
    });
    await user.click(send());
    await heading(t.receivedTitle('S-1A2B3C4D'));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.headers.get('x-firebase-appcheck')).toBe('app-check-token');
    expect(calls[0]!.headers.get('apikey')).toBe('anon');
    const body = calls[0]!.body!;
    expect(body).toEqual({
      kind: 'account_deletion',
      login_email: 'Rider.Old@gmail.com',
      contact_email: 'me@example.com',
      message: '換了手機',
      ...(hint ? { account_hint: hint } : {}),
    });
  });

  it('shows the same receipt whatever the backend matched, with the heading focused', async () => {
    stubFunctions({ 'support-request': received });
    openSite('/support');
    await heading(t.formTitle);
    const user = await fill();
    await user.click(send());
    const h1 = await heading(t.receivedTitle('S-1A2B3C4D'));
    await waitFor(() => expect(h1).toHaveFocus());
    expect(screen.getByRole('status')).toHaveTextContent(t.receivedBody[0]);
    expect(screen.getByRole('status')).toHaveTextContent(t.receivedBody[1]);
    expect(screen.queryByRole('textbox')).toBeNull();
  });

  it.each([
    ['too many requests', failure(429, 'support.rate_limited'), t.rateLimitedTitle, t.rateLimitedBody],
    ['App Check refused', failure(401, 'app_check.required'), t.appCheckTitle, t.appCheckBody],
    ['no answer', 'network' as const, t.networkTitle, t.networkBody],
    ['the backend down', failure(503, 'server.unavailable'), t.unavailableTitle, t.unavailableBody],
    ['a refused body', failure(400, 'request.invalid'), t.unavailableTitle, t.unavailableBody],
    ['an odd answer', { body: {} }, t.unavailableTitle, t.unavailableBody],
  ])('keeps the form after %s and says so', async (_, answer, title, body) => {
    stubFunctions({ 'support-request': [answer, received] });
    openSite('/support');
    await heading(t.formTitle);
    const user = await fill({ message: '忘記帳號' });
    await user.click(send());
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(title);
    expect(alert).toHaveTextContent(body);
    expect(login()).toHaveValue('rider.old@gmail.com');
    expect(screen.getByLabelText(/為什麼沒辦法登入/)).toHaveValue('忘記帳號');
    // Sending again works and clears the alert.
    await user.click(send());
    await heading(t.receivedTitle('S-1A2B3C4D'));
  });

  it('says App Check failed when no token comes, without calling the backend', async () => {
    const calls = stubFunctions({ 'support-request': received });
    openSite(
      '/support',
      undefined,
      testSupport(() => Promise.reject(new Error('recaptcha'))),
    );
    await heading(t.formTitle);
    const user = await fill();
    await user.click(send());
    expect(await screen.findByRole('alert')).toHaveTextContent(t.appCheckTitle);
    expect(calls).toHaveLength(0);
  });

  it('says the network failed when App Check cannot start offline', async () => {
    const calls = stubFunctions({ 'support-request': received });
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
    openSite(
      '/support',
      undefined,
      testSupport(() => Promise.reject(new Error('offline'))),
    );
    await heading(t.formTitle);
    const user = await fill();
    await user.click(send());
    expect(await screen.findByRole('alert')).toHaveTextContent(t.networkBody);
    expect(calls).toHaveLength(0);
    vi.restoreAllMocks();
  });

  it('sends once while a request is on its way', async () => {
    let answer!: (response: Response) => void;
    const fetchStub = vi.fn(
      () =>
        new Promise<Response>((resolve) => {
          answer = resolve;
        }),
    );
    vi.stubGlobal('fetch', fetchStub);
    openSite('/support');
    await heading(t.formTitle);
    const user = await fill();
    await user.click(send());
    await waitFor(() => expect(fetchStub).toHaveBeenCalledTimes(1));
    expect(send()).toHaveAttribute('aria-disabled', 'true');
    await user.click(send());
    expect(fetchStub).toHaveBeenCalledTimes(1);
    answer(new Response(JSON.stringify({ received: true, id }), { status: 200 }));
    await heading(t.receivedTitle('S-1A2B3C4D'));
  });

  it('is not offered without App Check settings', async () => {
    openSite('/support', undefined, testSupport(null));
    await heading(t.formTitle);
    expect(screen.getByRole('status')).toHaveTextContent(t.formUnavailable);
    expect(screen.queryByRole('button', { name: t.submit })).toBeNull();
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('is not offered without a backend', async () => {
    openSite('/support', null, null);
    await heading(t.formTitle);
    expect(screen.getByRole('status')).toHaveTextContent(t.formUnavailable);
  });

  it('is where the deletion page sends riders who cannot sign in', async () => {
    openSite('/account-deletion', null);
    await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' });
    await userEvent.setup().click(screen.getByRole('link', { name: '填寫客服表單' }));
    await heading(t.formTitle);
  });
});
