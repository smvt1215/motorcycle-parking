import { act, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Provider } from 'react-redux';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TimedCase, TimedCaseCounts } from '../api/v1/admin_v1.generated';
import type { PostgrestConnection } from '../api/v1/base';
import { DataConnectionContext } from '../app/connection';
import { routes } from '../app/routes';
import { makeStore } from '../app/store';

const row = (id: string, extra: Partial<TimedCase> = {}): TimedCase => ({
  id,
  type: 'support',
  kind: 'general',
  state: 'awaiting_admin',
  due_at: '2099-01-02T16:00:00Z',
  bucket: 'later',
  rank: 2,
  version: null,
  last_activity_at: '2026-11-01T00:00:00Z',
  suspicious: false,
  report_count: null,
  hidden_parts: null,
  spot_id: null,
  pending_action: null,
  has_exchange: false,
  ...extra,
});

const COUNTS: TimedCaseCounts = {
  all: 2,
  overdue: 0,
  today: 0,
  later: 2,
  waiting: 1,
  send_failed: 0,
  by_kind: { support: 2 },
  as_of: '2026-11-09T00:00:00Z',
};

type Reply = { status?: number; body: unknown };

function backend(handlers: { list: (body: Record<string, unknown>) => Reply; counts: () => Reply }) {
  const calls: Record<string, unknown>[] = [];
  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
    let reply: Reply;
    if (url.endsWith('/rpc/timed_cases')) {
      calls.push(body);
      reply = handlers.list(body);
    } else if (url.endsWith('/rpc/case_actions')) {
      reply = { body: [] };
    } else {
      reply = handlers.counts();
    }
    return new Response(JSON.stringify(reply.body), { status: reply.status ?? 200 });
  });
  const postgrest: PostgrestConnection = {
    url: 'https://example.invalid',
    anonKey: 'anon',
    accessToken: () => 'token',
    fetch: fetcher as unknown as typeof fetch,
  };
  return { postgrest, calls };
}

function renderPending(postgrest: PostgrestConnection, path = '/pending') {
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  render(
    <DataConnectionContext.Provider value="live">
      <Provider store={makeStore({ postgrest })}>
        <RouterProvider router={router} />
      </Provider>
    </DataConnectionContext.Provider>,
  );
  return router;
}

const filter = (name: RegExp) =>
  within(screen.getByRole('group', { name: '篩選' })).getByRole('button', { name });
const nav = () => screen.getByRole('navigation', { name: '管理功能' });

describe('待處理清單', () => {
  beforeEach(() => vi.useRealTimers());

  it('lists cases with deadlines and tab counts, never free text', async () => {
    const { postgrest } = backend({
      list: () => ({ body: { items: [row('61a2d7e0-1')], next_cursor: null } }),
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    expect(await screen.findByText('一般問題')).toBeInTheDocument();
    expect(screen.getByText('S-61A2D7E0')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: /之後/ })).toBeInTheDocument();
    await waitFor(() => expect(filter(/全部/)).toHaveTextContent('全部 2'));
    expect(filter(/內容檢舉/)).toHaveTextContent('內容檢舉 0');
    expect(filter(/等對方/)).toHaveTextContent('等對方 1');
    expect(within(nav()).getByLabelText('2 筆待處理')).toBeInTheDocument();
  });

  it('asks the server per tab', async () => {
    const { postgrest, calls } = backend({
      list: () => ({ body: { items: [row('a')], next_cursor: null } }),
      counts: () => ({ body: COUNTS }),
    });
    const router = renderPending(postgrest);
    await screen.findByText('一般問題');
    await userEvent.click(filter(/等對方/));
    await waitFor(() => expect(calls.at(-1)).toMatchObject({ p_kind: 'all', p_bucket: 'waiting' }));
    expect(router.state.location.search).toBe('?tab=waiting');
    await userEvent.click(filter(/客服/));
    await waitFor(() => expect(calls.at(-1)).toMatchObject({ p_kind: 'support', p_bucket: 'all' }));
  });

  it('never shows the previous tab under a tab that failed', async () => {
    const { postgrest } = backend({
      list: (body) =>
        body.p_bucket === 'waiting'
          ? { status: 500, body: { code: 'XX000', message: 'internal', details: null } }
          : { body: { items: [row('a')], next_cursor: null } },
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    await screen.findByText('一般問題');
    await userEvent.click(filter(/等對方/));
    expect(await screen.findByText('讀不到待處理清單')).toBeInTheDocument();
    expect(screen.queryByText('一般問題')).not.toBeInTheDocument();
  });

  it('reads the list again when Taiwan passes midnight', async () => {
    // 23:59:30 on 11/09 in Taiwan.
    vi.useFakeTimers({ now: Date.parse('2026-11-09T15:59:30Z'), shouldAdvanceTime: true });
    const { postgrest, calls } = backend({
      list: () => ({ body: { items: [row('a')], next_cursor: null } }),
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    await screen.findByText('一般問題');
    expect(calls).toHaveLength(1);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(61_000);
    });
    await waitFor(() => expect(calls).toHaveLength(2));
    vi.useRealTimers();
  });

  it('reads a tab again when returning to it', async () => {
    const { postgrest, calls } = backend({
      list: () => ({ body: { items: [row('a')], next_cursor: null } }),
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    await screen.findByText('一般問題');
    await userEvent.click(filter(/客服/));
    await waitFor(() => expect(calls).toHaveLength(2));
    await userEvent.click(filter(/全部/));
    await waitFor(() => expect(calls).toHaveLength(3));
    expect(calls.at(-1)).toMatchObject({ p_kind: 'all', p_bucket: 'all' });
  });

  it('does not present an empty result that failed to refresh as current', async () => {
    vi.useFakeTimers({ now: Date.parse('2026-11-09T15:59:30Z'), shouldAdvanceTime: true });
    let healthy = true;
    const { postgrest } = backend({
      list: () =>
        healthy
          ? { body: { items: [], next_cursor: null } }
          : { status: 500, body: { code: 'XX000', message: 'internal', details: null } },
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    await screen.findByText('現在沒有待處理的案件。');
    healthy = false;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(61_000);
    });
    expect(await screen.findByText('讀不到待處理清單')).toBeInTheDocument();
    expect(screen.queryByText('現在沒有待處理的案件。')).not.toBeInTheDocument();
    vi.useRealTimers();
  });

  it('shows 未知, not 0, when the counts fail', async () => {
    const { postgrest } = backend({
      list: () => ({ body: { items: [row('a')], next_cursor: null } }),
      counts: () => ({ status: 500, body: { code: 'XX000', message: 'internal', details: null } }),
    });
    renderPending(postgrest);
    await waitFor(() => expect(filter(/全部/)).toHaveTextContent('全部 未知'));
    expect(within(nav()).getByRole('img', { name: '待處理數量未知' })).toHaveTextContent('?');
  });

  it('does not read a failed list as an empty one, and retries', async () => {
    let healthy = false;
    const { postgrest } = backend({
      list: () =>
        healthy
          ? { body: { items: [row('a')], next_cursor: null } }
          : { status: 500, body: { code: 'XX000', message: 'internal', details: null } },
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    expect(await screen.findByText('讀不到待處理清單')).toBeInTheDocument();
    expect(screen.queryByText('現在沒有待處理的案件。')).not.toBeInTheDocument();
    healthy = true;
    await userEvent.click(screen.getByRole('button', { name: '重試' }));
    expect(await screen.findByText('一般問題')).toBeInTheDocument();
  });

  it('offers the waiting cases when nothing needs action', async () => {
    const { postgrest } = backend({
      list: () => ({ body: { items: [], next_cursor: null } }),
      counts: () => ({ body: { ...COUNTS, all: 0, later: 0, waiting: 3, by_kind: {} } }),
    });
    renderPending(postgrest);
    expect(await screen.findByText('現在沒有待處理的案件。')).toBeInTheDocument();
    await userEvent.click(await screen.findByRole('button', { name: '看等對方的案件' }));
    expect(await screen.findByText('沒有在等對方的案件。')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: '看全部' }));
    expect(await screen.findByText('現在沒有待處理的案件。')).toBeInTheDocument();
  });

  it('loads the next page with the server cursor', async () => {
    const cursor = { rank: 2, due_at: '2099-01-02T16:00:00Z', id: 'a' };
    const { postgrest, calls } = backend({
      list: (body) =>
        body.p_cursor
          ? { body: { items: [row('b', { kind: 'complaint' })], next_cursor: null } }
          : { body: { items: [row('a')], next_cursor: cursor } },
      counts: () => ({ body: COUNTS }),
    });
    renderPending(postgrest);
    await screen.findByText('一般問題');
    expect(screen.getByRole('heading', { name: /之後 1\+/ })).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: '載入更多' }));
    expect(await screen.findByText('檢舉與申訴')).toBeInTheDocument();
    expect(calls.at(-1)).toMatchObject({ p_cursor: cursor });
    expect(screen.getByRole('heading', { name: /之後 2$/ })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '載入更多' })).not.toBeInTheDocument();
  });

  it('asks for the second factor when the server requires it', async () => {
    const { postgrest } = backend({
      list: () => ({ status: 403, body: { code: 'PT403', message: 'auth.aal2_required', details: null } }),
      counts: () => ({ status: 403, body: { code: 'PT403', message: 'auth.aal2_required', details: null } }),
    });
    renderPending(postgrest);
    expect(await screen.findByText('請重新完成第二步驗證')).toBeInTheDocument();
  });

  it('goes back to the case the sign-in started from', async () => {
    sessionStorage.setItem('motopark-admin-return-path', '/pending/a?tab=support');
    const { postgrest } = backend({
      list: () => ({ body: { items: [row('a')], next_cursor: null } }),
      counts: () => ({ body: COUNTS }),
    });
    const router = renderPending(postgrest);
    await waitFor(() => expect(router.state.location.pathname).toBe('/pending/a'));
    expect(router.state.location.search).toBe('?tab=support');
    expect(sessionStorage.getItem('motopark-admin-return-path')).toBeNull();
  });

  it('marks the opened case and keeps the filter in its address', async () => {
    const { postgrest } = backend({
      list: () => ({ body: { items: [row('a')], next_cursor: null } }),
      counts: () => ({ body: COUNTS }),
    });
    const router = renderPending(postgrest, '/pending?tab=support');
    const link = await screen.findByRole('link', { name: /一般問題/ });
    await userEvent.click(link);
    expect(router.state.location.pathname).toBe('/pending/a');
    expect(router.state.location.search).toBe('?tab=support');
    expect(await screen.findByRole('link', { name: /一般問題/ })).toHaveAttribute('aria-current', 'true');
    expect(await screen.findByRole('status', { name: '正在讀取案件' })).toBeInTheDocument();
  });
});
