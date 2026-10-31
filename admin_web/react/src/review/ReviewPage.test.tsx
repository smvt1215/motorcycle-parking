import { act, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { renderApp } from '../test/renderApp';
import { fixtureSource } from './fixtureSource';
import { UNDO_MS } from './reviewSlice';

const NOW = Date.parse('2026-10-31T10:00:00Z');

function setup(path = '/review') {
  const source = fixtureSource({ now: NOW });
  const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });
  const app = renderApp(path, { source });
  return { source, user, ...app };
}

// Flows start on a report's URL: entering through /review's redirect under
// fake timers lets user-event outrun React's commit of controlled values.
const FIRST = '/review/r-ximen';

const detailTitle = async () => (await screen.findByRole('article')).querySelector('h2')?.textContent;

describe('ReviewPage', () => {
  beforeEach(() => vi.useFakeTimers({ shouldAdvanceTime: true }));
  afterEach(() => vi.useRealTimers());

  it('says nothing is connected when there is no data source', () => {
    renderApp('/review');
    expect(screen.getByRole('region', { name: '這一頁還沒接上資料' })).toHaveTextContent('admin_v1');
  });

  it('opens the oldest report and marks it in the queue', async () => {
    const { router } = setup();
    expect(await detailTitle()).toBe('西門町峨眉立體停車場');
    expect(router.state.location.pathname).toBe('/review/r-ximen');
    const queue = screen.getByRole('list', { name: '待審回報' });
    expect(within(queue).getAllByRole('button')[0]).toHaveAttribute('aria-current', 'true');
    expect(screen.getByText('示範資料，不會寫入伺服器')).toBeInTheDocument();
  });

  it('draws the eligibility change as plates: current → proposed', async () => {
    setup('/review/r-fuxing');
    const panel = await screen.findByRole('region', { name: '資格變更' });
    expect(within(panel).getByRole('img', { name: '目前不可停' })).toBeInTheDocument();
    expect(within(panel).getByRole('img', { name: '建議改為可停' })).toBeInTheDocument();
    expect(within(panel).getByText('維持可停')).toBeInTheDocument();
    // Community spot, heavy changes: the official-only rule is spelled out.
    expect(panel).toHaveTextContent('重機資格只採官方說法');
  });

  it('folds unchanged fields until asked', async () => {
    const { user } = setup('/review/r-fuxing');
    const diff = await screen.findByRole('region', { name: '其他欄位差異' });
    expect(within(diff).getAllByRole('row')).toHaveLength(2); // header + 格位類型
    expect(within(diff).getByText('已修改')).toBeInTheDocument();
    await user.click(within(diff).getByRole('button', { name: /顯示沒有修改的/ }));
    expect(within(diff).getAllByRole('row').length).toBeGreaterThan(2);
  });

  it('filters by type through the URL', async () => {
    const { user, router } = setup(FIRST);
    await detailTitle();
    await user.click(
      within(screen.getByRole('group', { name: '依類型篩選' })).getByRole('button', { name: /^位置/ }),
    );
    expect(router.state.location.search).toBe('?kind=location');
    const queue = screen.getByRole('list', { name: '待審回報' });
    expect(within(queue).getAllByRole('listitem')).toHaveLength(1);
    await user.click(within(queue).getByRole('button'));
    expect(router.state.location.pathname).toBe('/review/r-cks');
    expect(screen.getByRole('article')).toHaveTextContent('建議移動');
  });

  it('A applies, moves on, and can be undone within 5 seconds', async () => {
    const { user, source, router } = setup(FIRST);
    expect(await detailTitle()).toBe('西門町峨眉立體停車場');
    await user.keyboard('a');
    expect(router.state.location.pathname).toBe('/review/r-fuxing-2');
    const undo = screen.getByRole('status');
    expect(undo).toHaveTextContent('已套用「西門町峨眉立體停車場」');
    await user.click(within(undo).getByRole('button', { name: '復原' }));
    expect(router.state.location.pathname).toBe('/review/r-ximen');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS * 2));
    expect(source.resolved).toEqual([]);
  });

  it('writes after 5 seconds with the note', async () => {
    const { user, source } = setup(FIRST);
    await detailTitle();
    await user.type(screen.getByRole('textbox', { name: /處理說明/ }), '已比對停管處公告');
    await user.click(screen.getByRole('button', { name: /套用建議/ }));
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toEqual([
      {
        reportId: 'r-ximen',
        decision: 'accepted',
        patch: { scooter_allowed: true },
        edited: false,
        note: '已比對停管處公告',
        force: false,
      },
    ]);
    expect(screen.queryByText('西門町峨眉立體停車場')).not.toBeInTheDocument();
  });

  it('typing a note never triggers a shortcut', async () => {
    const { user, router } = setup(FIRST);
    await detailTitle();
    await user.type(screen.getByRole('textbox', { name: /處理說明/ }), 'aj');
    expect(router.state.location.pathname).toBe('/review/r-ximen');
  });

  it('J skips without writing', async () => {
    const { user, source, router } = setup(FIRST);
    await detailTitle();
    await user.keyboard('j');
    expect(router.state.location.pathname).toBe('/review/r-fuxing-2');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toEqual([]);
  });

  it('a failed write comes back flagged, with retry', async () => {
    const { user, source } = setup(FIRST);
    await detailTitle();
    source.failNextResolve('network');
    await user.keyboard('a');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    const queue = screen.getByRole('list', { name: '待審回報' });
    const failed = within(queue).getByText('沒有套用，打開處理');
    await user.click(failed);
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('沒有套用：連不上伺服器');
    await user.click(within(alert).getByRole('button', { name: '再試一次' }));
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved.map((r) => r.reportId)).toEqual(['r-ximen']);
  });

  it('a version conflict forces only after reloading', async () => {
    const { user, source } = setup(FIRST);
    await detailTitle();
    source.failNextResolve('stale');
    await user.keyboard('a');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    await user.click(within(screen.getByRole('list', { name: '待審回報' })).getByText('沒有套用，打開處理'));
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('儲存前，這個點位已被修改');
    const force = within(alert).getByRole('button', { name: '仍然套用' });
    expect(force).toBeDisabled();
    await user.click(within(alert).getByRole('button', { name: '重新讀取最新資料' }));
    await vi.waitFor(() => expect(force).toBeEnabled());
    await user.click(force);
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toMatchObject([{ reportId: 'r-ximen', force: true }]);
  });

  it('a phone opening a report whose queue fails sees the error, retry and a way back', async () => {
    // Below 680px the queue (and its error) is hidden while a report is open.
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query.includes('max-width: 679.98px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }));
    try {
      const failing = fixtureSource({ now: NOW });
      failing.loadQueue = () => Promise.reject(new Error('offline'));
      renderApp(FIRST, { source: failing });
      // The queue's own alert is also in the DOM (CSS hides it on a phone); take the detail's.
      const back = await screen.findByRole('link', { name: '回到清單' });
      expect(back).toHaveAttribute('href', '/review');
      const alert = back.closest('[role="alert"]') as HTMLElement;
      expect(alert).toHaveTextContent('讀取失敗');
      expect(within(alert).getByRole('button', { name: '重試' })).toBeInTheDocument();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('still warns before closing the tab after leaving the review page (Codex review, PR #214)', async () => {
    const { user, router } = setup(FIRST);
    await detailTitle();
    await user.keyboard('a');
    await act(() => router.navigate('/spots'));
    const leaving = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(leaving);
    expect(leaving.defaultPrevented).toBe(true);

    // Once written, closing is fine again.
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    const later = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(later);
    expect(later.defaultPrevented).toBe(false);
  });

  it('a phone back on the list can still undo (Codex review, PR #214)', async () => {
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query.includes('max-width: 679.98px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }));
    try {
      const { user, source, router } = setup(FIRST);
      await detailTitle();
      await user.keyboard('a');
      await user.click(screen.getByRole('link', { name: '返回審核清單' }));
      expect(router.state.location.pathname).toBe('/review');
      const queue = screen.getByRole('region', { name: '待審佇列' });
      const undo = within(queue).getByRole('status');
      expect(undo).toHaveTextContent('已套用「西門町峨眉立體停車場」');
      await user.click(within(undo).getByRole('button', { name: '復原' }));
      expect(router.state.location.pathname).toBe('/review/r-ximen');
      await act(() => vi.advanceTimersByTimeAsync(UNDO_MS * 2));
      expect(source.resolved).toEqual([]);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('R opens 駁回原因; a digit picks it and Enter rejects without touching the spot', async () => {
    const { user, source, router } = setup('/review/r-fuxing');
    await detailTitle();
    await user.keyboard('r');
    const panel = screen.getByRole('region', { name: '駁回原因' });
    // Reasons are a real radio group; nothing is chosen yet.
    expect(within(panel).getAllByRole('radio')).toHaveLength(6);
    await user.keyboard('{Enter}');
    expect(within(panel).getByText('選一個駁回原因才能送出。')).toBeInTheDocument();
    await user.keyboard('3');
    expect(within(panel).getByRole('radio', { name: /資訊不足/ })).toBeChecked();
    await user.keyboard('{Enter}');
    expect(router.state.location.pathname).not.toBe('/review/r-fuxing');
    expect(screen.getByRole('status')).toHaveTextContent('已駁回「復興南路一段 107 巷路邊機車格」');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toEqual([
      { reportId: 'r-fuxing', decision: 'rejected', resolutionKind: 'insufficient', note: '' },
    ]);
  });

  it('其他原因 needs a written reason before rejecting', async () => {
    const { user, source } = setup('/review/r-fuxing');
    await detailTitle();
    await user.click(screen.getByRole('button', { name: /駁回/ }));
    await user.click(screen.getByRole('radio', { name: /其他原因/ }));
    expect(screen.getByText('選了「其他原因」，寫下為什麼駁回才能送出。')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /確定駁回/ }));
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toEqual([]);
    await user.type(screen.getByRole('textbox', { name: /處理說明/ }), 'x');
    await user.click(screen.getByRole('button', { name: /確定駁回/ }));
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toMatchObject([{ decision: 'rejected', resolutionKind: 'other', note: 'x' }]);
  });

  it('Esc closes the reject panel and keeps the report', async () => {
    const { user, router } = setup('/review/r-fuxing');
    await detailTitle();
    await user.keyboard('r');
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('region', { name: '駁回原因' })).not.toBeInTheDocument();
    expect(router.state.location.pathname).toBe('/review/r-fuxing');
    expect(screen.getByRole('button', { name: /套用建議/ })).toBeInTheDocument();
  });

  it('E edits the values to apply; Ctrl+Enter writes the edited patch', async () => {
    const { user, source } = setup('/review/r-fuxing');
    await detailTitle();
    await user.keyboard('e');
    const plates = screen.getByRole('region', { name: '資格' });
    // The rider suggested 可停; the reviewer decides 不可停.
    await user.click(within(plates).getByRole('radio', { name: /不可停/ }));
    const type = screen.getByRole('combobox', { name: '格位類型' });
    expect(type).toHaveValue('heavyOnly');
    expect(screen.getByText('騎士建議：重機專用格')).toBeInTheDocument();
    expect(screen.getByRole('toolbar', { name: '修改後套用' })).toHaveTextContent('你改了騎士建議的 1 處');
    await user.keyboard('{Control>}{Enter}{/Control}');
    expect(screen.getByRole('status')).toHaveTextContent('已套用修改「復興南路一段 107 巷路邊機車格」');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toEqual([
      {
        reportId: 'r-fuxing',
        decision: 'accepted',
        patch: { space_type: 'heavyOnly' },
        edited: true,
        note: '',
        force: false,
      },
    ]);
  });

  it('refuses to save an edit that changes nothing', async () => {
    const { user, source } = setup('/review/r-fuxing');
    await detailTitle();
    await user.keyboard('e');
    await user.click(
      within(screen.getByRole('region', { name: '資格' })).getByRole('radio', { name: /不可停/ }),
    );
    await user.selectOptions(screen.getByRole('combobox', { name: '格位類型' }), 'freeMotorcycle');
    await user.click(screen.getByRole('button', { name: /儲存並套用/ }));
    expect(screen.getByRole('alert')).toHaveTextContent('沒有要寫入的修改');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toEqual([]);
  });

  it('shows 全部處理完了 when the queue empties', async () => {
    const { user, source } = setup(FIRST);
    await detailTitle();
    for (let i = 0; i < 7; i += 1) await user.keyboard('a');
    await act(() => vi.advanceTimersByTimeAsync(UNDO_MS));
    expect(source.resolved).toHaveLength(7);
    const done = await screen.findByRole('region', { name: '審核佇列沒有待審' });
    expect(done).toHaveTextContent('全部處理完了');
    expect(done).toHaveTextContent('這次處理了 7 筆');
  });
});
