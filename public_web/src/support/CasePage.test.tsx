import { act, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, vi } from 'vitest';
import { openSite, stubFunctions, type Answer } from '../test/site';
import * as t from './text';

afterEach(() => vi.unstubAllGlobals());

const id = '9f8e7d6c-0000-4000-8000-000000000002';
const token = `${id}.${'A'.repeat(42)}w`;
const path = `/support/case#token=${token}`;

const rider = { direction: 'in', body: '收藏不見了', created_at: '2026-11-08T06:02:00Z' };
const staff = { direction: 'out', body: '請確認帳號', created_at: '2026-11-09T02:30:00Z' };

function caseAnswer(overrides: Record<string, unknown> = {}): Answer {
  return {
    body: {
      result: 'ok',
      code: 'S-9F8E7D6C',
      kind: 'general',
      status: 'open',
      submitted_at: '2026-11-08T06:02:00Z',
      can_reply: true,
      messages: [rider, staff],
      ...overrides,
    },
  };
}
const received = (reopened: boolean): Answer => ({ body: { result: 'received', reopened } });
const failure = (status: number, error: string): Answer => ({ status, body: { error } });

async function heading(name: string) {
  return screen.findByRole('heading', { level: 1, name });
}
const box = () => screen.getByLabelText(/回覆/);
const send = () => screen.getByRole('button', { name: t.replySubmit });
const actions = (calls: { body: Record<string, unknown> | null }[]) => calls.map((c) => c.body!.action);

async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 50));
}

async function reply(text = '還是找不到') {
  const user = userEvent.setup();
  await user.type(box(), text);
  await user.click(send());
  return user;
}

describe('the case page', () => {
  it('shows the case on opening, changes nothing, and drops the token from the address', async () => {
    const calls = stubFunctions({ 'support-case': caseAnswer() });
    const { router } = openSite(path);
    const h1 = await heading('一般問題');
    await waitFor(() => expect(h1).toHaveFocus());
    expect(calls).toEqual([expect.objectContaining({ fn: 'support-case', body: { token, action: 'view' } })]);
    expect(calls[0]!.headers.get('x-firebase-appcheck')).toBeNull();
    expect(router.state.location.hash).toBe('');
    expect(router.state.location.pathname).toBe('/support/case');
    expect(router.state.historyAction).toBe('REPLACE');
    expect(document.querySelector('.support-case-facts')!.textContent).toBe(
      '案件編號 S-9F8E7D6C　處理中　11 月 8 日送出',
    );
    await settle();
    expect(calls).toHaveLength(1);
  });

  it('shows who said what and when, in Taiwan time', async () => {
    stubFunctions({ 'support-case': caseAnswer() });
    openSite(path);
    await heading('一般問題');
    const log = screen.getByRole('log', { name: t.threadLabel });
    expect(within(log).getByText('你｜11 月 8 日 14:02')).toBeInTheDocument();
    expect(within(log).getByText('收藏不見了')).toBeInTheDocument();
    expect(within(log).getByText('客服｜11 月 9 日 10:30')).toBeInTheDocument();
    expect(within(log).getByText('請確認帳號')).toBeInTheDocument();
  });

  it('shows a message as text: HTML stays text and line breaks stay', async () => {
    const html = '<img src=x onerror="alert(1)"><b>粗體</b>\n第二行';
    stubFunctions({
      'support-case': caseAnswer({ messages: [{ ...rider, body: html }] }),
    });
    openSite(path);
    await heading('一般問題');
    const log = screen.getByRole('log');
    expect(log.querySelector('img')).toBeNull();
    expect(log.querySelector('b')).toBeNull();
    const body = log.querySelector('.support-message-body')!;
    expect(body.textContent).toBe(html);
    expect(body).toHaveStyle({ whiteSpace: 'pre-wrap' });
  });

  it('leaves out an empty message', async () => {
    stubFunctions({ 'support-case': caseAnswer({ messages: [{ ...rider, body: ' ' }, staff] }) });
    openSite(path);
    await heading('一般問題');
    expect(screen.getByRole('log').children).toHaveLength(1);
  });

  it.each([
    ['open', '處理中'],
    ['done', '已結案'],
    ['rejected', '已結案'],
    ['voided', '已作廢'],
    ['expired', '已過期'],
    ['exception', '已結束'],
  ])('words %s plainly', async (status, words) => {
    stubFunctions({ 'support-case': caseAnswer({ status }) });
    openSite(path);
    await heading('一般問題');
    expect(screen.getByText(new RegExp(`\\s${words}\\s`))).toBeInTheDocument();
  });

  it.each([
    ['data_issue', '資料錯誤或侵權'],
    ['complaint', '檢舉與申訴'],
    ['privacy', '個資權利請求'],
    ['something_new', t.caseFallbackTitle],
  ])('names the kind %s', async (kind, name) => {
    stubFunctions({ 'support-case': caseAnswer({ kind }) });
    openSite(path);
    await heading(name);
  });

  it('sends the reply only from the button, and adds it to the thread', async () => {
    const calls = stubFunctions({ 'support-case': [caseAnswer(), received(false)] });
    openSite(path);
    await heading('一般問題');
    expect(box()).toHaveAttribute('maxlength', '4000');
    expect(box()).toHaveAccessibleDescription(`${t.replyNote}${t.replyHelp}`);
    const user = userEvent.setup();
    await user.type(box(), '  還是\n找不到  ');
    await settle();
    expect(actions(calls)).toEqual(['view']);
    await user.click(send());
    const status = await screen.findByRole('status');
    expect(status).toHaveTextContent(t.replySentTitle);
    expect(status).toHaveTextContent(t.replySentBody);
    expect(status).not.toHaveTextContent(t.replyReopened);
    expect(actions(calls)).toEqual(['view', 'reply']);
    expect(calls[1]!.body).toEqual({ token, action: 'reply', message: '還是\n找不到' });
    expect(box()).toHaveValue('');
    expect(screen.getByRole('log').children).toHaveLength(3);
    expect(screen.getByRole('log').lastElementChild!.textContent).toContain('還是\n找不到');
  });

  it('needs some text', async () => {
    const calls = stubFunctions({ 'support-case': caseAnswer() });
    openSite(path);
    await heading('一般問題');
    await userEvent.setup().click(send());
    expect(box()).toHaveAccessibleDescription(expect.stringContaining(t.replyMissing));
    expect(actions(calls)).toEqual(['view']);
  });

  it('says so when the reply opens the case again', async () => {
    stubFunctions({
      'support-case': [caseAnswer({ status: 'done' }), received(true)],
    });
    openSite(path);
    await heading('一般問題');
    expect(screen.getByText(/已結案/)).toBeInTheDocument();
    await reply();
    expect(await screen.findByRole('status')).toHaveTextContent(t.replyReopened);
    expect(screen.getByText(/處理中/)).toBeInTheDocument();
  });

  it('has no reply box when the case takes none: closed', async () => {
    stubFunctions({ 'support-case': caseAnswer({ status: 'done', can_reply: false }) });
    openSite(path);
    await heading('一般問題');
    expect(screen.queryByRole('textbox')).toBeNull();
    expect(screen.queryByRole('button', { name: t.replySubmit })).toBeNull();
    expect(screen.getByRole('heading', { level: 2, name: t.caseClosedTitle })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: t.caseRefill })).toHaveAttribute('href', '/support');
    expect(screen.getByRole('log')).toBeInTheDocument();
  });

  it('has no reply box when the link is used up on an open case', async () => {
    stubFunctions({ 'support-case': caseAnswer({ can_reply: false }) });
    openSite(path);
    await heading('一般問題');
    expect(screen.queryByRole('textbox')).toBeNull();
    expect(screen.getByRole('heading', { level: 2, name: t.linkUsedTitle })).toBeInTheDocument();
    expect(screen.getByText(t.linkUsedBody)).toBeInTheDocument();
  });

  it('says the case closed when the reply meets it, keeping the thread', async () => {
    stubFunctions({ 'support-case': [caseAnswer(), failure(409, 'support.case_closed')] });
    openSite(path);
    await heading('一般問題');
    await reply();
    expect(await screen.findByRole('heading', { level: 2, name: t.caseClosedTitle })).toBeInTheDocument();
    expect(screen.queryByRole('textbox')).toBeNull();
    expect(screen.getByRole('log')).toBeInTheDocument();
  });

  it('says the limit is reached, keeping the text', async () => {
    stubFunctions({ 'support-case': [caseAnswer(), failure(429, 'support.rate_limited')] });
    openSite(path);
    await heading('一般問題');
    await reply();
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(t.replyLimitTitle);
    expect(alert).toHaveTextContent(t.replyLimitBody);
    expect(box()).toHaveValue('還是找不到');
  });

  it.each([
    ['no answer', 'network' as const, t.replyNetworkBody],
    ['the backend down', failure(503, 'server.unavailable'), t.replyUnavailableBody],
    ['a refused body', failure(400, 'request.invalid'), t.replyUnavailableBody],
    ['an odd answer', { body: {} }, t.replyUnavailableBody],
  ])('keeps the text after %s, and sending again works', async (_, answer, body) => {
    const calls = stubFunctions({ 'support-case': [caseAnswer(), answer, received(false)] });
    openSite(path);
    await heading('一般問題');
    const user = await reply();
    expect(await screen.findByRole('alert')).toHaveTextContent(body);
    expect(box()).toHaveValue('還是找不到');
    await user.click(send());
    expect(await screen.findByRole('status')).toHaveTextContent(t.replySentTitle);
    expect(screen.queryByRole('alert')).toBeNull();
    expect(actions(calls)).toEqual(['view', 'reply', 'reply']);
  });

  it('sends once while a reply is on its way', async () => {
    const calls = stubFunctions({ 'support-case': caseAnswer() });
    openSite(path);
    await heading('一般問題');
    let answer!: (response: Response) => void;
    vi.stubGlobal(
      'fetch',
      vi.fn(() => new Promise<Response>((resolve) => (answer = resolve))),
    );
    const user = await reply();
    expect(send()).toHaveAttribute('aria-disabled', 'true');
    await user.click(send());
    expect(fetch).toHaveBeenCalledTimes(1);
    await act(async () =>
      answer(new Response(JSON.stringify({ result: 'received', reopened: false }), { status: 200 })),
    );
    expect(await screen.findByRole('status')).toHaveTextContent(t.replySentTitle);
    expect(calls).toHaveLength(1);
  });

  it('says the link is invalid for a bad token, with the way back to the form', async () => {
    stubFunctions({ 'support-case': failure(400, 'support.link_invalid') });
    const { router } = openSite(path);
    await heading(t.caseInvalidTitle);
    expect(screen.getByText(/連結可能已過期（30 天）/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: t.caseRefill })).toHaveAttribute('href', '/support');
    expect(router.state.location.hash).toBe('');
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('says the link is invalid when the reply meets a dead token', async () => {
    stubFunctions({ 'support-case': [caseAnswer(), failure(400, 'support.link_invalid')] });
    openSite(path);
    await heading('一般問題');
    await reply();
    await heading(t.caseInvalidTitle);
  });

  it.each([['/support/case'], ['/support/case#token=abc'], [`/support/case#token=${id}`]])(
    'sends nothing for %s',
    async (malformed) => {
      const calls = stubFunctions({ 'support-case': caseAnswer() });
      openSite(malformed);
      await heading(t.caseInvalidTitle);
      await settle();
      expect(calls).toHaveLength(0);
    },
  );

  it('retries the view after no answer, and after the backend failed', async () => {
    const calls = stubFunctions({
      'support-case': ['network', failure(503, 'server.unavailable'), caseAnswer()],
    });
    openSite(path);
    await heading(t.linkNetworkTitle);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: t.retry }));
    await heading(t.linkErrorTitle);
    await user.click(screen.getByRole('button', { name: t.retry }));
    await heading('一般問題');
    expect(actions(calls)).toEqual(['view', 'view', 'view']);
  });

  it.each([
    ['a result it does not know', { body: { result: 'something_new' } }],
    ['a thread it cannot read', caseAnswer({ messages: [{ direction: 'sideways', body: 'x' }] })],
    ['no thread', caseAnswer({ messages: null })],
  ])('treats %s as an error', async (_, answer) => {
    stubFunctions({ 'support-case': answer });
    openSite(path);
    await heading(t.linkErrorTitle);
  });

  it('cannot do anything without a backend', async () => {
    openSite(path, null, null);
    await heading(t.linkErrorTitle);
  });
});

describe('another case link in the same tab', () => {
  const other = `1a2b3c4d-0000-4000-8000-000000000003.${'B'.repeat(42)}w`;

  it('starts over with the new token, and a reply goes to the new case', async () => {
    const calls = stubFunctions({ 'support-case': caseAnswer() });
    const { router } = openSite(path);
    await heading('一般問題');
    await waitFor(() => expect(router.state.location.hash).toBe(''));
    const user = userEvent.setup();
    await user.type(box(), '第一個案件的草稿');

    await act(() => router.navigate(`/support/case#token=${other}`));
    await waitFor(() => expect(calls.at(-1)!.body).toEqual({ token: other, action: 'view' }));
    await waitFor(() => expect(router.state.location.hash).toBe(''));
    expect(await screen.findByText(/S-1A2B3C4D/)).toBeInTheDocument();
    expect(box()).toHaveValue('');

    await user.type(box(), '第二個');
    stubFunctions({ 'support-case': received(false) });
    await user.click(send());
    await screen.findByRole('status');
    expect(calls.filter((c) => c.body!.token === token)).toHaveLength(1);
  });

  it('dropping the token from the address does not reopen the link', async () => {
    const calls = stubFunctions({ 'support-case': caseAnswer() });
    openSite(path);
    await heading('一般問題');
    await settle();
    expect(calls).toHaveLength(1);
  });
});
