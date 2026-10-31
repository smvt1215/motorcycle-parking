import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Provider } from 'react-redux';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { routes } from '../app/routes';
import { makeStore } from '../app/store';

function renderAt(path: string) {
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  render(
    <Provider store={makeStore()}>
      <RouterProvider router={router} />
    </Provider>,
  );
  return router;
}

const nav = () => screen.getByRole('navigation', { name: '管理功能' });

describe('AppShell', () => {
  it('opens on 審核', () => {
    const router = renderAt('/');
    expect(router.state.location.pathname).toBe('/review');
    expect(screen.getByRole('heading', { level: 1, name: '審核' })).toBeInTheDocument();
    expect(within(nav()).getByRole('link', { name: '審核' })).toHaveAttribute('aria-current', 'page');
  });

  it('lists the sections in canvas order, plus 更多 for phones', () => {
    renderAt('/review');
    const names = within(nav())
      .getAllByRole('link', { hidden: true })
      .map((link) => link.textContent);
    expect(names).toEqual(['審核', '點位', '規則', '匯入', '使用者', '更多']);
  });

  it('keeps 更多 current on the pages it leads to', async () => {
    renderAt('/more');
    const more = screen.getByRole('list', { name: '其他功能' });
    await userEvent.click(within(more).getByRole('link', { name: '匯入' }));
    expect(screen.getByRole('heading', { level: 1, name: '匯入' })).toBeInTheDocument();
    // 更多 is display:none outside phone widths, which jsdom always reports.
    expect(nav().querySelector('a[href="/more"]')).toHaveAttribute('aria-current', 'page');
    expect(within(nav()).getByRole('link', { name: '匯入' })).toHaveAttribute('aria-current', 'page');
    expect(within(nav()).getByRole('link', { name: '審核' })).not.toHaveAttribute('aria-current');
  });

  it('says a section is not connected instead of showing sample data', () => {
    renderAt('/spots');
    expect(screen.getByRole('region', { name: '這一頁還沒接上資料' })).toHaveTextContent('admin_v1');
  });

  it('shows a way back from an unknown address', () => {
    renderAt('/nope');
    expect(screen.getByRole('link', { name: '回到審核' })).toHaveAttribute('href', '/review');
  });
});

describe('DesignPage', () => {
  it('switches every sample plate with the 車種 control', async () => {
    renderAt('/design');
    const group = screen.getByRole('group', { name: '車種' });
    const heavy = within(group).getByRole('button', { name: /大型重機/ });
    expect(heavy).toHaveAttribute('aria-pressed', 'false');
    await userEvent.click(heavy);
    expect(heavy).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('img', { name: '建議改為可停' })).toHaveClass('plate-stack--heavy');
  });
});
