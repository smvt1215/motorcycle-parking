import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Provider } from 'react-redux';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  CaseAction,
  ContentReport,
  SupportRequestDetail,
  TimedCase,
  TimedCaseCounts,
} from '../api/v1/admin_v1.generated';
import type { PostgrestConnection } from '../api/v1/base';
import { DataConnectionContext } from '../app/connection';
import { routes } from '../app/routes';
import { makeStore } from '../app/store';
import { actionSettled, actionsReset, pendingActionsSlice, SLOW_AFTER_MS } from './actionsSlice';
import { describeAction } from './caseCopy';

const UUID = (n: number) => `0000000${n}-0000-4000-8000-000000000000`;

const row = (n: number, extra: Partial<TimedCase> = {}): TimedCase => ({
  id: UUID(n),
  type: 'support',
  kind: 'general',
  state: 'awaiting_admin',
  due_at: '2099-01-02T16:00:00Z',
  bucket: 'later',
  rank: 2,
  version: '2026-11-09T01:00:00.123456+00:00',
  last_activity_at: '2026-11-01T00:00:00Z',
  suspicious: false,
  report_count: null,
  hidden_parts: null,
  spot_id: null,
  pending_action: null,
  has_exchange: false,
  ...extra,
});

const reportRow = (n: number, extra: Partial<TimedCase> = {}) =>
  row(n, {
    type: 'report',
    kind: 'spot_name',
    state: 'held',
    report_count: 2,
    hidden_parts: ['spot_name'],
    spot_id: 'spot-1',
    ...extra,
  });

const supportDetail = (item: TimedCase): SupportRequestDetail =>
  ({
    request: {
      id: item.id,
      kind: item.kind,
      contact_email: 'rider@example.com',
      account_hint: '',
      message: '原始',
      status: 'open',
      created_at: '2026-11-03T01:41:00Z',
      notified_at: null,
      resolved_at: null,
      resolution_note: '',
      deletion_requested: false,
      login_email: null,
      account_matched: false,
      matched_user: null,
      email_confirmed_at: null,
      exception: null,
      deletion_notified_at: null,
      cancelled_at: null,
      superseded_by: null,
      source: 'web',
      subject: '',
      privacy_right: null,
      due_at: item.due_at,
      reply_to: item.state === 'system' ? null : 'rider@example.com',
      can_reply: item.state !== 'system',
      message_count: 0,
      last_message_at: null,
      awaiting_admin: true,
      suspicious: false,
      reopened_at: null,
      related_to: null,
    },
    messages: [
      {
        id: item.id,
        direction: 'in',
        channel: 'web',
        body: '原始內容文字',
        created_at: '2026-11-03T01:41:00Z',
        author: null,
        from_email: null,
        suspicious: false,
        spf: null,
        dkim: null,
        dmarc: null,
        attachments: [],
        to_email: null,
        delivery_status: null,
        attempts: 0,
        sent_at: null,
        send_error: null,
      },
    ],
  }) as SupportRequestDetail;

const reportDetail = (item: TimedCase): ContentReport => ({
  id: item.id,
  status: 'pending',
  spot_id: 'spot-1',
  target: item.kind as ContentReport['target'],
  created_at: '2026-11-03T01:41:00Z',
  spot_updated_at: item.version,
  spot_deleted: item.state === 'spot_deleted',
  content_held: (item.hidden_parts ?? []) as ContentReport['content_held'],
  snapshot: { name: '舊名' },
  current: { name: '新名' },
  editable_fields: ['name', 'note', 'entrance_note', 'parking_guide', 'special_rules'],
  reports: [
    {
      id: 'r1',
      created_at: '2026-11-03T01:41:00Z',
      note: '不舒服',
      held: true,
      risk_flags: [],
      same_network: false,
    },
    {
      id: 'r2',
      created_at: '2026-11-03T02:41:00Z',
      note: '',
      held: false,
      risk_flags: [],
      same_network: true,
    },
  ],
});

const COUNTS: TimedCaseCounts = {
  all: 3,
  overdue: 0,
  today: 0,
  later: 3,
  waiting: 0,
  send_failed: 0,
  by_kind: {},
  as_of: new Date().toISOString(),
};

type Reply = { status?: number; body: unknown };

interface Setup {
  items: TimedCase[];
  actions?: Record<string, CaseAction[]>;
  schedule?: (body: Record<string, unknown>) => Reply;
  cancel?: () => Reply;
  retry?: () => Reply;
}

const receipt = (id: string, seconds = 5) => ({
  body: {
    action_id: id,
    run_at: new Date(Date.now() + seconds * 1000).toISOString(),
    irreversible: seconds === 10,
    duplicate: false,
  },
});

function backend(setup: Setup) {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  let actionSeq = 0;
  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input).replace(/.*\/rpc\//, '');
    const body = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
    calls.push({ url, body });
    let reply: Reply;
    switch (url) {
      case 'timed_cases':
        reply = { body: { items: setup.items, next_cursor: null } };
        break;
      case 'timed_case_counts':
        reply = { body: { ...COUNTS, as_of: new Date().toISOString() } };
        break;
      case 'timed_case': {
        const item = setup.items.find((i) => i.id === body.p_id);
        reply = item
          ? { body: item }
          : { status: 404, body: { code: 'PT404', message: 'case.not_found', details: null } };
        break;
      }
      case 'support_request':
        reply = { body: supportDetail(setup.items.find((i) => i.id === body.p_id)!) };
        break;
      case 'content_report':
        reply = { body: reportDetail(setup.items.find((i) => i.id === body.p_id)!) };
        break;
      case 'case_actions':
        reply = { body: setup.actions?.[String(body.p_case)] ?? [] };
        break;
      case 'schedule_case_action':
        reply = setup.schedule?.(body) ?? receipt(`action-${++actionSeq}`);
        break;
      case 'cancel_case_action':
        reply = setup.cancel?.() ?? { body: { cancelled: true } };
        break;
      case 'retry_case_action':
        reply = setup.retry?.() ?? {
          body: { action_id: 'retry-1', run_at: new Date(Date.now() + 5000).toISOString() },
        };
        break;
      default:
        reply = { status: 500, body: {} };
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

function open(postgrest: PostgrestConnection, path: string) {
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  const store = makeStore({ postgrest });
  render(
    <DataConnectionContext.Provider value="live">
      <Provider store={store}>
        <RouterProvider router={router} />
      </Provider>
    </DataConnectionContext.Provider>,
  );
  return { router, store };
}

let user: ReturnType<typeof userEvent.setup>;

const tick = async (ms: number) => {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
};

const dock = () => screen.getByRole('group', { name: '等待中的處理' });

/** The box of the case now open: the previous case's is read-only while counting. */
async function typeReply(text: string) {
  const box = await waitFor(() => {
    const field = screen.getByRole('textbox', { name: '回覆' });
    expect(field).not.toHaveAttribute('readonly');
    return field;
  });
  await user.type(box, text);
  return box;
}

const sendReply = () => user.click(screen.getByRole('button', { name: '寄出回覆' }));

describe('案件詳情的處理', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime.bind(vi) });
  });
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('shows the exchange and where a reply goes', async () => {
    const { postgrest } = backend({ items: [row(1)] });
    open(postgrest, `/pending/${UUID(1)}`);
    expect(await screen.findByText('原始內容文字')).toBeInTheDocument();
    expect(screen.getByText('對方的原始內容（客服表單）')).toBeInTheDocument();
    expect(screen.getByText(/會寄到 rider@example.com/)).toBeInTheDocument();
  });

  it('schedules with the case version and moves to the next case, focusing its title', async () => {
    const { postgrest, calls } = backend({ items: [row(1), row(2, { kind: 'complaint' })] });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('已更正');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(2)}`));
    const schedule = calls.find((c) => c.url === 'schedule_case_action');
    expect(schedule?.body).toMatchObject({
      p_case: UUID(1),
      p_action: 'reply',
      p_payload: { body: '已更正' },
      p_expected_version: '2026-11-09T01:00:00.123456+00:00',
    });
    const title = await screen.findByRole('heading', { name: '檢舉與申訴' });
    await waitFor(() => expect(title).toHaveFocus());
    expect(within(dock()).getByText(/秒後寄出/)).toBeInTheDocument();
  });

  it('reads the start of a countdown once, not every second', async () => {
    const { postgrest } = backend({ items: [row(1), row(2)] });
    open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('嗨');
    await sendReply();
    const live = await waitFor(() => {
      const region = screen.getAllByRole('status').find((s) => s.textContent?.includes('按 Z 取消'));
      if (!region) throw new Error('no announcement');
      return region;
    });
    const first = live.textContent;
    await tick(2000);
    expect(live.textContent).toBe(first);
  });

  it('counts each action on its own and folds the extra lines', async () => {
    let id = 0;
    const { postgrest } = backend({
      items: [row(1), row(2), row(3), row(4)],
      // Long enough that nothing finishes while the test types.
      schedule: () => receipt(`action-${++id}`, 30),
    });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('一');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(2)}`));
    await tick(2000);
    await typeReply('二');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(3)}`));
    await typeReply('三');
    await sendReply();

    await waitFor(() => expect(within(dock()).getByText('還有 1 筆等待中')).toBeInTheDocument());
    await user.click(within(dock()).getByRole('button', { name: '還有 1 筆等待中' }));
    const seconds = within(dock())
      .getAllByText(/秒後寄出/)
      .map((el) => Number.parseInt(el.textContent ?? '', 10));
    expect(seconds).toHaveLength(3);
    // The action sent earlier kept its own, earlier deadline.
    expect(seconds[0]).toBeLessThanOrEqual(28);
    expect(seconds[1]).toBeGreaterThanOrEqual(29);
    expect(seconds[2]).toBeGreaterThanOrEqual(29);
  });

  it('Z cancels the newest action, but not while typing', async () => {
    let id = 0;
    const { postgrest, calls } = backend({
      items: [row(1), row(2), row(3)],
      schedule: () => receipt(`action-${++id}`, 30),
    });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('一');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(2)}`));
    const nextBox = await typeReply('z');
    expect(nextBox).toHaveValue('z');
    expect(calls.filter((c) => c.url === 'cancel_case_action')).toHaveLength(0);

    await sendReply();
    await waitFor(() => expect(within(dock()).getAllByText(/秒後寄出/)).toHaveLength(2));
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(3)}`));
    await user.keyboard('z');
    await waitFor(() => expect(calls.filter((c) => c.url === 'cancel_case_action')).toHaveLength(1));
    expect(calls.find((c) => c.url === 'cancel_case_action')?.body).toEqual({ p_action_id: 'action-2' });
  });

  it('puts the reply back when cancelled', async () => {
    const { postgrest } = backend({ items: [row(1), row(2)] });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('要寄出的內容');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(2)}`));
    await user.click(within(dock()).getByRole('button', { name: /取消寄出/ }));
    expect(await within(dock()).findByText('已取消寄出')).toBeInTheDocument();
    await user.click(within(dock()).getByRole('button', { name: '打開案件' }));
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(1)}`));
    expect(await screen.findByRole('textbox', { name: '回覆' })).toHaveValue('要寄出的內容');
  });

  it('says it was too late, and keeps no draft, when the server already started', async () => {
    const { postgrest } = backend({
      items: [row(1), row(2)],
      cancel: () => ({ status: 409, body: { code: 'PT409', message: 'case_action.started', details: null } }),
    });
    const { router, store } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('內容');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(2)}`));
    await user.click(within(dock()).getByRole('button', { name: /取消寄出/ }));
    expect(await within(dock()).findByText('來不及取消')).toBeInTheDocument();
    expect(store.getState().pendingActions.drafts[UUID(1)]).toBeUndefined();
  });

  it('ignores a cancel answer that lands after the action finished', () => {
    const slice = pendingActionsSlice;
    const base = slice.reducer(
      undefined,
      slice.actions.actionTracked({
        id: 'a',
        caseId: 'c',
        action: 'reply',
        labels: describeAction({ action: 'reply', item: row(1) }),
        deadline: 1000,
        irreversible: false,
        draft: { reply: '內文' },
        now: 0,
      }),
    );
    const done = slice.reducer(base, actionSettled({ id: 'a', outcome: 'done', now: 2000 }));
    const after = slice.reducer(done, actionSettled({ id: 'a', outcome: 'cancelled', now: 2100 }));
    expect(after.actions[0]?.phase).toBe('done');
    expect(after.drafts).toEqual({});
  });

  it('lets the server restore the draft once it stops following a slow action', () => {
    const slice = pendingActionsSlice;
    const base = slice.reducer(
      undefined,
      slice.actions.actionTracked({
        id: 'a',
        caseId: 'c',
        action: 'reply',
        labels: describeAction({ action: 'reply', item: row(1) }),
        deadline: 1000,
        irreversible: false,
        draft: { reply: '內文' },
        now: 0,
      }),
    );
    const sending = slice.reducer(base, slice.actions.ticked(1000));
    const slow = slice.reducer(sending, slice.actions.ticked(1000 + SLOW_AFTER_MS));
    expect(slow.actions[0]?.phase).toBe('slow');
    expect(slow.seen).toEqual([]);
  });

  it('keeps the draft and stays put when someone else handled the case', async () => {
    const stale = {
      status: 409,
      body: { code: 'PT409', message: 'case.stale', details: '{"by":"other_admin"}' },
    };
    const { postgrest } = backend({ items: [row(1), row(2)], schedule: () => stale });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    const box = await typeReply('沒寄出的內容');
    await sendReply();
    expect(await screen.findByText('這筆已由其他管理員處理')).toBeInTheDocument();
    expect(router.state.location.pathname).toBe(`/pending/${UUID(1)}`);
    expect(box).toHaveValue('沒寄出的內容');
    expect(screen.getByRole('button', { name: '重新讀取' })).toBeInTheDocument();
  });

  it('restores the draft when the server finds the case changed at run time', async () => {
    const actions: Record<string, CaseAction[]> = {};
    const { postgrest } = backend({ items: [row(1), row(2)], actions });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('倒數時有變動');
    await sendReply();
    await waitFor(() => expect(router.state.location.pathname).toBe(`/pending/${UUID(2)}`));
    actions[UUID(1)] = [
      {
        id: 'action-1',
        case_type: 'support',
        case_id: UUID(1),
        action: 'reply',
        status: 'stale',
        run_at: new Date().toISOString(),
        irreversible: false,
        attempts: 1,
        error: null,
        actor: 'me',
        expected_version: null,
        payload: { body: '倒數時有變動' },
        created_at: new Date().toISOString(),
        started_at: null,
        finished_at: null,
        message_id: null,
        delivery_status: null,
        send_error: null,
        address_editable: false,
      },
    ];
    await tick(7000);
    expect(await within(dock()).findByText('這筆案件有新的變動')).toBeInTheDocument();
    await user.click(within(dock()).getByRole('button', { name: '打開案件' }));
    expect(await screen.findByRole('textbox', { name: '回覆' })).toHaveValue('倒數時有變動');
  });

  it('keeps each case its own draft when switching', async () => {
    const { postgrest } = backend({ items: [row(1), row(2, { kind: 'complaint' })] });
    const { router } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('第一筆');
    await act(async () => {
      await router.navigate(`/pending/${UUID(2)}`);
    });
    await typeReply('第二筆');
    await act(async () => {
      await router.navigate(`/pending/${UUID(1)}`);
    });
    expect(await screen.findByRole('textbox', { name: '回覆' })).toHaveValue('第一筆');
  });

  it('asks for the second factor and keeps the draft', async () => {
    const { postgrest } = backend({
      items: [row(1)],
      schedule: () => ({
        status: 403,
        body: { code: 'PT403', message: 'auth.aal2_required', details: null },
      }),
    });
    const { store } = open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('要保留');
    await sendReply();
    expect(await screen.findByText('請重新完成第二步驗證')).toBeInTheDocument();
    expect(store.getState().pendingActions.drafts[UUID(1)]?.reply).toBe('要保留');
    // Only someone else signing in drops it.
    store.dispatch(actionsReset());
    expect(store.getState().pendingActions.drafts).toEqual({});
  });

  it('marks a case that no longer exists as handled', async () => {
    const { postgrest } = backend({ items: [] });
    open(postgrest, `/pending/${UUID(9)}`);
    expect(await screen.findByText('這筆案件已經處理完')).toBeInTheDocument();
  });

  it('offers 再寄一次 for a reply the mail service gave up on', async () => {
    const failed: CaseAction = {
      id: 'failed-1',
      case_type: 'support',
      case_id: UUID(1),
      action: 'reply',
      status: 'done',
      run_at: new Date().toISOString(),
      irreversible: false,
      attempts: 1,
      error: null,
      actor: 'me',
      expected_version: null,
      payload: {},
      created_at: new Date().toISOString(),
      started_at: null,
      finished_at: null,
      message_id: 'm1',
      delivery_status: 'failed',
      send_error: null,
      address_editable: false,
    };
    const { postgrest, calls } = backend({
      items: [row(1, { state: 'send_failed', rank: 0 }), row(2)],
      actions: { [UUID(1)]: [failed] },
    });
    open(postgrest, `/pending/${UUID(1)}`);
    await user.click(await screen.findByRole('button', { name: '再寄一次' }));
    await waitFor(() =>
      expect(calls.find((c) => c.url === 'retry_case_action')?.body).toEqual({ p_action_id: 'failed-1' }),
    );
    expect(await within(dock()).findByText(/秒後寄出/)).toBeInTheDocument();
  });

  it('asks before closing with an unsent reply', async () => {
    const { postgrest, calls } = backend({ items: [row(1), row(2)] });
    open(postgrest, `/pending/${UUID(1)}`);
    await typeReply('沒寄的');
    await user.click(screen.getByRole('button', { name: '結案' }));
    expect(await screen.findByRole('heading', { name: '回覆還沒寄出' })).toHaveFocus();
    await user.click(screen.getByRole('button', { name: '不寄出，直接結案' }));
    await user.click(await screen.findByRole('radio', { name: /已處理/ }));
    await user.click(screen.getByRole('button', { name: '確定結案' }));
    await waitFor(() =>
      expect(calls.find((c) => c.url === 'schedule_case_action')?.body).toMatchObject({
        p_action: 'resolve_support',
        p_payload: { status: 'done', note: '' },
      }),
    );
  });

  describe('內容檢舉', () => {
    it('has three actions, and shows what changed since the report', async () => {
      const { postgrest } = backend({ items: [reportRow(1)] });
      open(postgrest, `/pending/${UUID(1)}`);
      expect(await screen.findByRole('button', { name: '改內容' })).toBeInTheDocument();
      expect(screen.getByText('檢舉後已改')).toBeInTheDocument();
      expect(screen.getByText('App 目前顯示')).toBeInTheDocument();
    });

    it('rider names cannot be edited', async () => {
      const { postgrest } = backend({
        items: [reportRow(1, { kind: 'rider_name', hidden_parts: ['rider_name'] })],
      });
      open(postgrest, `/pending/${UUID(1)}`);
      await screen.findByRole('button', { name: '檢舉成立' });
      expect(screen.queryByRole('button', { name: '改內容' })).not.toBeInTheDocument();
    });

    it('requires a new name, waits 10 seconds, and says it cannot be undone', async () => {
      const { postgrest, calls } = backend({
        items: [reportRow(1), row(2)],
        schedule: () => receipt('keep-1', 10),
      });
      open(postgrest, `/pending/${UUID(1)}`);
      await user.click(await screen.findByRole('button', { name: '檢舉成立' }));
      expect(screen.getByText('按下後有 10 秒可以取消，之後不能復原。')).toBeInTheDocument();
      await user.click(screen.getByRole('button', { name: '換掉停車點名稱' }));
      expect(await screen.findByText(/請填新的名稱/)).toBeInTheDocument();
      await user.type(screen.getByRole('textbox', { name: '新的停車點名稱' }), '好名字');
      await user.click(screen.getByRole('button', { name: '換掉停車點名稱' }));
      await waitFor(() =>
        expect(calls.find((c) => c.url === 'schedule_case_action')?.body).toMatchObject({
          p_action: 'report_keep',
          p_payload: { patch: { name: '好名字' } },
        }),
      );
      expect(await within(dock()).findByText(/秒後換掉停車點名稱/)).toBeInTheDocument();
    });

    it('sends only changed fields when editing', async () => {
      const { postgrest, calls } = backend({ items: [reportRow(1), row(2)] });
      open(postgrest, `/pending/${UUID(1)}`);
      await user.click(await screen.findByRole('button', { name: '改內容' }));
      const name = screen.getByRole('textbox', { name: '停車點名稱' });
      await user.clear(name);
      await user.type(name, '改好');
      await user.click(screen.getByRole('button', { name: '儲存並放回' }));
      await waitFor(() =>
        expect(calls.find((c) => c.url === 'schedule_case_action')?.body).toMatchObject({
          p_action: 'report_edit',
          p_payload: { patch: { name: '改好' } },
        }),
      );
    });

    it('needs a written reason for 其他原因', async () => {
      const { postgrest, calls } = backend({ items: [reportRow(1), row(2)] });
      open(postgrest, `/pending/${UUID(1)}`);
      await user.click(await screen.findByRole('button', { name: '檢舉不成立' }));
      await user.click(screen.getByRole('radio', { name: /其他原因/ }));
      await user.click(screen.getByRole('button', { name: '放回 App' }));
      expect(await screen.findByText(/要寫下原因才能送出/)).toBeInTheDocument();
      expect(calls.some((c) => c.url === 'schedule_case_action')).toBe(false);
    });
  });

  describe('手機', () => {
    let restoreViewport: () => void;

    beforeEach(() => {
      const listeners: Record<string, (() => void)[]> = {};
      const viewport = {
        height: 844,
        offsetTop: 0,
        addEventListener: (type: string, fn: () => void) => {
          (listeners[type] ??= []).push(fn);
        },
        removeEventListener: () => undefined,
        fire: (height: number) => {
          viewport.height = height;
          listeners.resize?.forEach((fn) => fn());
        },
      };
      Object.defineProperty(window, 'matchMedia', {
        configurable: true,
        value: () => ({
          matches: true,
          addEventListener: () => undefined,
          removeEventListener: () => undefined,
        }),
      });
      Object.defineProperty(window, 'innerHeight', { configurable: true, value: 844 });
      Object.defineProperty(window, 'visualViewport', { configurable: true, value: viewport });
      restoreViewport = () => {
        Object.defineProperty(window, 'visualViewport', { configurable: true, value: undefined });
        Object.defineProperty(window, 'matchMedia', { configurable: true, value: undefined });
      };
    });
    afterEach(() => restoreViewport());

    it('rides the action bar on the keyboard while typing', async () => {
      const { postgrest } = backend({ items: [row(1)] });
      open(postgrest, `/pending/${UUID(1)}`);
      const box = await screen.findByRole('textbox', { name: '回覆' });
      await user.click(box);
      act(() => {
        (window.visualViewport as unknown as { fire: (h: number) => void }).fire(544);
      });
      const pending = document.querySelector<HTMLElement>('.pending');
      await waitFor(() => expect(pending).toHaveClass('pending--keyboard'));
      expect(pending?.style.getPropertyValue('--kb')).toBe('300px');
    });

    it('opens panels as a sheet with focus on the title', async () => {
      const { postgrest } = backend({ items: [reportRow(1)] });
      open(postgrest, `/pending/${UUID(1)}`);
      const button = await screen.findByRole('button', { name: '檢舉成立' });
      await user.click(button);
      const dialog = screen.getByRole('dialog', { name: '檢舉成立' });
      expect(within(dialog).getByRole('heading', { name: '檢舉成立' })).toHaveFocus();
      await user.click(within(dialog).getByRole('button', { name: '返回' }));
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
      expect(button).toHaveFocus();
    });
  });
});
