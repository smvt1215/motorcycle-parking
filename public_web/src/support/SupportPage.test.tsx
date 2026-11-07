import { act, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, vi } from 'vitest';
import { openSite, stubFunctions, testSupport, type Answer } from '../test/site';
import * as t from './text';

afterEach(() => vi.unstubAllGlobals());

const id = '1a2b3c4d-0000-4000-8000-000000000001';
const received: Answer = { body: { received: true, id } };
const failure = (status: number, error: string): Answer => ({ status, body: { error } });
const deletionPath = '/support?kind=account_deletion';

async function heading(name: string) {
  return screen.findByRole('heading', { level: 1, name });
}
const opened = () => heading(t.supportTitle);

const login = () => screen.getByLabelText(/帳號的登入 email/);
const contact = () => screen.getByLabelText(/聯絡用 email/);
const subject = () => screen.getByLabelText(/主旨/);
const content = () => screen.getByLabelText(/內容/);
const reason = () => screen.getByLabelText(/為什麼沒辦法登入/);
const kindRadio = (name: string) => screen.getByRole('radio', { name });
const send = () => screen.getByRole('button', { name: t.submit });
const sendCase = () => screen.getByRole('button', { name: t.caseSubmit });

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
  if (message) await user.type(reason(), message);
  return user;
}

async function fillCase() {
  const user = userEvent.setup();
  await user.type(contact(), 'me@example.com');
  await user.type(subject(), '收藏不見了');
  await user.type(content(), '換手機後不見了');
  return user;
}

describe('the kinds', () => {
  it('shows the board, with the heading focused, 一般問題 chosen and no mail link', async () => {
    openSite('/support');
    const h1 = await opened();
    expect(h1).toHaveFocus();
    expect(screen.getByText(t.supportIntro)).toBeInTheDocument();
    const kinds = screen.getByRole('group', { name: t.kindLegend });
    const radios = within(kinds).getAllByRole('radio');
    expect(radios).toHaveLength(5);
    expect(radios.map((radio) => (radio as HTMLInputElement).value)).toEqual(
      t.kindOptions.map((option) => option.value),
    );
    expect(kindRadio('一般問題')).toBeChecked();
    expect(kindRadio('一般問題')).toHaveAccessibleDescription('App 怎麼用、帳號或其他問題。');
    expect(screen.getByRole('heading', { level: 2, name: '一般問題' })).toBeInTheDocument();
    expect(sendCase()).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: '返回刪除帳號說明' })).toBeNull();
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('says no reply time and has no ops@ line', async () => {
    openSite('/support');
    await opened();
    expect(document.body).not.toHaveTextContent('工作天');
    expect(document.body).not.toHaveTextContent('ops@');
  });

  it('is operable from the keyboard', async () => {
    openSite('/support');
    await opened();
    const user = userEvent.setup();
    await user.click(kindRadio('一般問題'));
    await user.keyboard('{ArrowDown}');
    expect(kindRadio('資料錯誤或侵權')).toBeChecked();
    expect(kindRadio('資料錯誤或侵權')).toHaveFocus();
    expect(screen.getByRole('heading', { level: 2, name: '資料錯誤或侵權' })).toBeInTheDocument();
  });

  it.each([
    ['data_issue', '資料錯誤或侵權'],
    ['complaint', '檢舉與申訴'],
    ['privacy', '個資權利請求'],
    ['account_deletion', '刪除帳號'],
  ])('opens with %s chosen from the address', async (kind, name) => {
    openSite(`/support?kind=${kind}`);
    await opened();
    expect(kindRadio(name)).toBeChecked();
  });

  it('ignores a kind it does not know', async () => {
    openSite('/support?kind=nonsense');
    await opened();
    expect(kindRadio('一般問題')).toBeChecked();
  });

  it('follows a link to the page: the footer goes back to 一般問題, keeping the text', async () => {
    openSite(deletionPath);
    await opened();
    const user = userEvent.setup();
    await user.type(contact(), 'me@example.com');
    await user.click(screen.getByRole('link', { name: '聯絡我們' }));
    await waitFor(() => expect(kindRadio('一般問題')).toBeChecked());
    expect(contact()).toHaveValue('me@example.com');
  });

  it('keeps what was typed where the next kind has the field', async () => {
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(kindRadio('個資權利請求'));
    expect(contact()).toHaveValue('me@example.com');
    expect(subject()).toHaveValue('收藏不見了');
    expect(content()).toHaveValue('換手機後不見了');
    await user.type(login(), 'rider@gmail.com');
    await user.click(screen.getByRole('radio', { name: '查閱我的資料' }));

    await user.click(kindRadio('刪除帳號'));
    expect(login()).toHaveValue('rider@gmail.com');
    expect(contact()).toHaveValue('me@example.com');
    expect(reason()).toHaveValue('換手機後不見了');
    expect(screen.queryByLabelText(/主旨/)).toBeNull();

    await user.click(kindRadio('檢舉與申訴'));
    expect(subject()).toHaveValue('收藏不見了');
    expect(screen.queryByLabelText(/帳號的登入 email/)).toBeNull();

    await user.click(kindRadio('個資權利請求'));
    expect(login()).toHaveValue('rider@gmail.com');
    expect(screen.getByRole('radio', { name: '查閱我的資料' })).toBeChecked();
  });

  it('starts the next kind without errors or the last failure', async () => {
    stubFunctions({ 'support-request': failure(429, 'support.rate_limited') });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(sendCase());
    await screen.findByRole('alert');
    await user.click(kindRadio('個資權利請求'));
    expect(screen.queryByRole('alert')).toBeNull();
    expect(login()).not.toHaveAttribute('aria-invalid');
  });

  it('is not offered without App Check settings', async () => {
    openSite('/support', undefined, testSupport(null));
    await opened();
    expect(screen.getByRole('status')).toHaveTextContent(t.formUnavailable);
    expect(screen.queryByRole('radio')).toBeNull();
    expect(screen.queryByRole('button', { name: t.caseSubmit })).toBeNull();
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('is not offered without a backend', async () => {
    openSite('/support', null, null);
    await opened();
    expect(screen.getByRole('status')).toHaveTextContent(t.formUnavailable);
  });
});

describe('the general kinds', () => {
  it.each([
    ['一般問題', 'general'],
    ['資料錯誤或侵權', 'data_issue'],
    ['檢舉與申訴', 'complaint'],
  ])('sends %s with its fields only', async (name, kind) => {
    const calls = stubFunctions({ 'support-request': received });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(kindRadio(name));
    await user.click(sendCase());
    await heading(t.caseReceivedTitle(name, 'S-1A2B3C4D'));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.headers.get('x-firebase-appcheck')).toBe('app-check-token');
    expect(calls[0]!.body).toEqual({
      kind,
      contact_email: 'me@example.com',
      subject: '收藏不見了',
      message: '換手機後不見了',
    });
  });

  it('needs the contact email, the subject and the text', async () => {
    const calls = stubFunctions({});
    openSite('/support');
    await opened();
    const user = userEvent.setup();
    await user.click(sendCase());
    expect(contact()).toHaveAccessibleDescription(expect.stringContaining(t.contactMissing));
    expect(subject()).toHaveAccessibleDescription(expect.stringContaining(t.subjectMissing));
    expect(content()).toHaveAccessibleDescription(expect.stringContaining(t.contentMissing));
    expect(contact()).toHaveFocus();

    await user.type(contact(), 'me@example.com');
    await user.click(sendCase());
    expect(subject()).toHaveFocus();
    await user.type(subject(), '   ');
    await user.click(sendCase());
    expect(subject()).toHaveAttribute('aria-invalid', 'true');

    await user.type(subject(), '問題');
    await user.click(sendCase());
    expect(content()).toHaveFocus();
    expect(content()).toHaveAttribute('aria-invalid', 'true');
    expect(calls).toHaveLength(0);
  });

  it('shows what the board says about each field', async () => {
    openSite('/support');
    await opened();
    expect(contact()).toHaveAccessibleDescription(`${t.caseContactNote}${t.caseContactHelp}`);
    expect(subject()).toHaveAccessibleDescription(t.subjectNote);
    expect(content()).toHaveAccessibleDescription(`${t.contentNote}${t.contentHelp}`);
    expect(subject()).toHaveAttribute('maxlength', '120');
    expect(content()).toHaveAttribute('maxlength', '4000');
  });

  it('says the reply comes by email and the mail has the case link', async () => {
    stubFunctions({ 'support-request': received });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(sendCase());
    const h1 = await heading('已收到你的一般問題，案件編號 S-1A2B3C4D');
    await waitFor(() => expect(h1).toHaveFocus());
    const status = screen.getByRole('status');
    expect(status).toHaveTextContent(t.caseReceivedBody[0]);
    expect(status).toHaveTextContent(t.caseReceivedBody[1]);
    expect(document.body).not.toHaveTextContent('工作天');
  });

  it('opens the form again, emptied, from the footer after a receipt', async () => {
    stubFunctions({ 'support-request': received });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(sendCase());
    await heading('已收到你的一般問題，案件編號 S-1A2B3C4D');
    await user.click(screen.getByRole('link', { name: '聯絡我們' }));
    await opened();
    expect(contact()).toHaveValue('');
  });

  it('gives the limits of a kind without a login email', async () => {
    stubFunctions({ 'support-request': [failure(429, 'support.rate_limited'), received] });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(sendCase());
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(t.rateLimitedTitle);
    expect(alert).toHaveTextContent(t.caseRateLimitedBody);
    expect(alert).not.toHaveTextContent('登入 email');
    expect(subject()).toHaveValue('收藏不見了');
  });

  it.each([
    ['App Check refused', failure(401, 'app_check.required'), t.appCheckTitle, t.appCheckBody],
    ['no answer', 'network' as const, t.networkTitle, t.networkBody],
    ['the backend down', failure(503, 'server.unavailable'), t.unavailableTitle, t.unavailableBody],
  ])('keeps the form after %s and says so', async (_, answer, title, body) => {
    stubFunctions({ 'support-request': [answer, received] });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(sendCase());
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(title);
    expect(alert).toHaveTextContent(body);
    expect(content()).toHaveValue('換手機後不見了');
    await user.click(sendCase());
    await heading('已收到你的一般問題，案件編號 S-1A2B3C4D');
  });
});

describe('a privacy request', () => {
  it('has the board fields above the text, and says the answer goes to the login email', async () => {
    openSite('/support?kind=privacy');
    await opened();
    expect(login()).toHaveAccessibleDescription(`${t.privacyLoginNote}${t.privacyLoginHelp}`);
    const rights = screen.getByRole('group', { name: t.privacyRightLegend });
    expect(within(rights).getAllByRole('radio')).toHaveLength(3);
    // Only the login email hears back, so the contact email promises no reply.
    expect(contact()).toHaveAccessibleDescription(`${t.contactRequired}${t.contactHelp}`);
    expect(document.body).not.toHaveTextContent(t.caseContactHelp);
    expect(login().compareDocumentPosition(content()) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('needs the login email and the right', async () => {
    const calls = stubFunctions({ 'support-request': received });
    openSite('/support?kind=privacy');
    await opened();
    const user = await fillCase();
    await user.click(sendCase());
    expect(login()).toHaveFocus();
    expect(login()).toHaveAccessibleDescription(expect.stringContaining(t.loginMissing));
    await user.type(login(), 'rider@gmail.com');
    await user.click(sendCase());
    expect(screen.getByRole('radio', { name: '查閱我的資料' })).toHaveFocus();
    expect(screen.getByRole('group', { name: t.privacyRightLegend })).toHaveAccessibleDescription(
      t.privacyRightMissing,
    );
    expect(calls).toHaveLength(0);
  });

  it.each([
    ['查閱我的資料', 'access'],
    ['更正我的資料', 'correction'],
    ['取得資料副本', 'copy'],
  ])('sends %s', async (name, right) => {
    const calls = stubFunctions({ 'support-request': received });
    openSite('/support?kind=privacy');
    await opened();
    const user = await fillCase();
    await user.type(login(), 'rider@gmail.com');
    await user.click(screen.getByRole('radio', { name }));
    await user.click(sendCase());
    await heading(t.privacyReceivedTitle('S-1A2B3C4D'));
    expect(calls[0]!.body).toEqual({
      kind: 'privacy',
      contact_email: 'me@example.com',
      login_email: 'rider@gmail.com',
      privacy_right: right,
      subject: '收藏不見了',
      message: '換手機後不見了',
    });
    expect(screen.getByRole('status')).toHaveTextContent(t.privacyReceivedBody[0]);
  });

  it('gives the limits with the login email', async () => {
    stubFunctions({ 'support-request': failure(429, 'support.rate_limited') });
    openSite('/support?kind=privacy');
    await opened();
    const user = await fillCase();
    await user.type(login(), 'rider@gmail.com');
    await user.click(screen.getByRole('radio', { name: '取得資料副本' }));
    await user.click(sendCase());
    expect(await screen.findByRole('alert')).toHaveTextContent(t.rateLimitedBody);
  });
});

describe('the deletion kind', () => {
  it('shows the approved form, with the way back to the explanation', async () => {
    openSite(deletionPath);
    await opened();
    expect(screen.getByRole('heading', { level: 2, name: t.formTitle })).toBeInTheDocument();
    expect(screen.getByText(t.formWarning)).toBeInTheDocument();
    expect(screen.getByRole('group', { name: t.providerLegend })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '返回刪除帳號說明' })).toHaveAttribute(
      'href',
      '/account-deletion',
    );
    expect(screen.queryByLabelText(/主旨/)).toBeNull();
  });

  it('checks both emails before sending anything', async () => {
    const calls = stubFunctions({});
    openSite(deletionPath);
    await opened();
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
    openSite(deletionPath);
    await opened();
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
    expect(calls[0]!.body).toEqual({
      kind: 'account_deletion',
      login_email: 'Rider.Old@gmail.com',
      contact_email: 'me@example.com',
      message: '換了手機',
      ...(hint ? { account_hint: hint } : {}),
    });
  });

  it('sends no subject typed for another kind', async () => {
    const calls = stubFunctions({ 'support-request': received });
    openSite('/support');
    await opened();
    const user = await fillCase();
    await user.click(kindRadio('刪除帳號'));
    await user.type(login(), 'rider@gmail.com');
    await user.click(send());
    await heading(t.receivedTitle('S-1A2B3C4D'));
    expect(calls[0]!.body).not.toHaveProperty('subject');
  });

  it('asks to shorten text longer than the deletion form takes', async () => {
    const calls = stubFunctions({ 'support-request': received });
    openSite('/support');
    await opened();
    const user = userEvent.setup();
    await user.click(content());
    await user.paste('長'.repeat(1001));
    await user.click(kindRadio('刪除帳號'));
    await user.type(login(), 'rider@gmail.com');
    await user.type(contact(), 'me@example.com');
    await user.click(send());
    expect(reason()).toHaveFocus();
    expect(reason()).toHaveAccessibleDescription(t.messageTooLong);
    expect(calls).toHaveLength(0);
  });

  it('shows the same receipt whatever the backend matched, with the heading focused', async () => {
    stubFunctions({ 'support-request': received });
    openSite(deletionPath);
    await opened();
    const user = await fill();
    await user.click(send());
    const h1 = await heading(t.receivedTitle('S-1A2B3C4D'));
    await waitFor(() => expect(h1).toHaveFocus());
    expect(screen.getByRole('status')).toHaveTextContent(t.receivedBody[0]);
    expect(screen.getByRole('status')).toHaveTextContent(t.receivedBody[1]);
    expect(screen.queryByRole('textbox')).toBeNull();
    expect(screen.getByRole('link', { name: '返回刪除帳號說明' })).toBeInTheDocument();
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
    openSite(deletionPath);
    await opened();
    const user = await fill({ message: '忘記帳號' });
    await user.click(send());
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(title);
    expect(alert).toHaveTextContent(body);
    expect(login()).toHaveValue('rider.old@gmail.com');
    expect(reason()).toHaveValue('忘記帳號');
    // Sending again works and clears the alert.
    await user.click(send());
    await heading(t.receivedTitle('S-1A2B3C4D'));
  });

  it('says App Check failed when no token comes, without calling the backend', async () => {
    const calls = stubFunctions({ 'support-request': received });
    openSite(
      deletionPath,
      undefined,
      testSupport(() => Promise.reject(new Error('recaptcha'))),
    );
    await opened();
    const user = await fill();
    await user.click(send());
    expect(await screen.findByRole('alert')).toHaveTextContent(t.appCheckTitle);
    expect(calls).toHaveLength(0);
  });

  it('says the network failed when App Check cannot start offline', async () => {
    const calls = stubFunctions({ 'support-request': received });
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
    openSite(
      deletionPath,
      undefined,
      testSupport(() => Promise.reject(new Error('offline'))),
    );
    await opened();
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
    openSite(deletionPath);
    await opened();
    const user = await fill();
    await user.click(send());
    await waitFor(() => expect(fetchStub).toHaveBeenCalledTimes(1));
    expect(send()).toHaveAttribute('aria-disabled', 'true');
    await user.click(send());
    expect(fetchStub).toHaveBeenCalledTimes(1);
    await act(async () => answer(new Response(JSON.stringify({ received: true, id }), { status: 200 })));
    await heading(t.receivedTitle('S-1A2B3C4D'));
  });

  it('is where the deletion page sends riders who cannot sign in, with 刪除帳號 chosen', async () => {
    openSite('/account-deletion', null);
    await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' });
    await userEvent.setup().click(screen.getByRole('link', { name: '填寫客服表單' }));
    await opened();
    expect(kindRadio('刪除帳號')).toBeChecked();
  });

  it('is where the header link of the deletion page goes too', async () => {
    openSite('/account-deletion', null);
    await screen.findByRole('heading', { level: 1, name: '刪除你的帳號' });
    await userEvent.setup().click(screen.getByRole('link', { name: '沒辦法登入？' }));
    await opened();
    expect(kindRadio('刪除帳號')).toBeChecked();
  });
});
