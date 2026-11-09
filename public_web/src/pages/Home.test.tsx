import { screen, within } from '@testing-library/react';
import { openSite } from '../test/site';

describe('/', () => {
  it('is the home page, not a redirect to the deletion page', () => {
    const { router } = openSite('/', null);
    expect(router.state.location.pathname).toBe('/');
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('騎到之前，先知道這裡能不能停。');
  });

  it('has the sections the navigation and the first button lead to', () => {
    openSite('/', null);
    for (const id of ['features', 'rules', 'how']) {
      expect(document.getElementById(id)).not.toBeNull();
    }
    expect(screen.getByRole('link', { name: '看看怎麼用' })).toHaveAttribute('href', '/#how');
    expect(screen.getByRole('link', { name: '看接下來的計畫' })).toHaveAttribute('href', '/roadmap');
  });

  it('says the stores are still to come, and links to neither', () => {
    openSite('/', null);
    expect(screen.getByText('即將在 App Store 與 Google Play 推出')).toBeInTheDocument();
    for (const link of screen.getAllByRole('link')) {
      expect(link.getAttribute('href')).toMatch(/^\//);
    }
  });

  it('says reports are reviewed, without saying by whom', () => {
    openSite('/', null);
    const main = screen.getByRole('main');
    expect(main).toHaveTextContent('回報經審核後公開');
    expect(main).not.toHaveTextContent('管理員');
  });

  it('keeps the pictures to drawn ones', () => {
    openSite('/', null);
    expect(document.querySelector('img')).toBeNull();
  });
});

describe('/roadmap', () => {
  it('lists the three stages in order, each with its items', () => {
    openSite('/roadmap', null);
    expect(screen.getByRole('heading', { level: 1, name: '接下來' })).toBeInTheDocument();
    const headings = screen.getAllByRole('heading', { level: 2 });
    expect(headings.map((h) => h.textContent)).toEqual(['正在做', '接下來', '之後']);
    const counts = headings.map((h) => within(h.closest('section')!).getAllByRole('listitem').length);
    expect(counts).toEqual([4, 5, 2]);
  });
});
