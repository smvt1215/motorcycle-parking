import { render, screen, within } from '@testing-library/react';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { routes } from '../App';
import * as c from '../content';

function open(path: string) {
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  render(<RouterProvider router={router} />);
  return router;
}

describe('/account-deletion', () => {
  it('names the app and the developer (Google Play asks for both)', () => {
    open('/account-deletion');
    expect(screen.getByRole('heading', { level: 1, name: '刪除你的帳號' })).toBeInTheDocument();
    expect(screen.getByText(c.appName)).toBeInTheDocument();
    expect(screen.getByText(c.developer)).toBeInTheDocument();
  });

  it('lists what is deleted, what is kept and for how long', () => {
    open('/account-deletion');
    const deleted = screen.getByRole('region', { name: c.deletedHeading });
    expect(
      within(deleted)
        .getAllByRole('listitem')
        .map((li) => li.textContent),
    ).toEqual([...c.deleted]);
    const kept = screen.getByRole('region', { name: c.keptHeading });
    expect(
      within(kept)
        .getAllByRole('listitem')
        .map((li) => li.textContent),
    ).toEqual([...c.kept]);
    expect(screen.getByRole('region', { name: c.retentionHeading })).toHaveTextContent('180 天');
    expect(screen.getByRole('region', { name: c.hashHeading })).toHaveTextContent('180 天後刪除');
  });

  it('shows the cooling-off as a sequence ending in deletion', () => {
    open('/account-deletion');
    const steps = within(screen.getByRole('region', { name: c.coolingOffHeading })).getAllByRole('listitem');
    expect(steps.map((s) => s.querySelector('.lane-when')?.textContent)).toEqual([
      '送出當下',
      '7 天內',
      '7 天後',
    ]);
  });

  it('offers sign-in once, and the support form for people who cannot', () => {
    open('/account-deletion');
    expect(screen.getAllByRole('button', { name: '使用 Google 登入' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: '使用 Apple 登入' })).toHaveLength(1);
    const cannot = screen.getByRole('region', { name: c.cannotSignInHeading });
    expect(within(cannot).getByRole('link', { name: c.supportFormLink })).toHaveAttribute('href', '/support');
    expect(cannot).toHaveTextContent('那個信箱收不到信的話，就無法用這個方式刪除');
  });

  it('links the policies and the support form in the footer, never a mailbox (#295)', () => {
    open('/account-deletion');
    const footer = screen.getByRole('contentinfo');
    expect(within(footer).getByRole('link', { name: '隱私權政策' })).toHaveAttribute('href', '/privacy');
    expect(within(footer).getByRole('link', { name: '聯絡我們' })).toHaveAttribute('href', '/support');
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });
});

describe('other paths', () => {
  it('/ goes to the deletion page', () => {
    const router = open('/');
    expect(router.state.location.pathname).toBe('/account-deletion');
  });

  it('an unknown path says so and leads back', () => {
    open('/nope');
    expect(screen.getByRole('heading', { name: '找不到這個頁面' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '前往刪除帳號說明' })).toHaveAttribute(
      'href',
      '/account-deletion',
    );
  });
});
