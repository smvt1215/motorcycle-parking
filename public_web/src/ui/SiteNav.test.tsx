import { act, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { vi } from 'vitest';
import { openSite } from '../test/site';

const nav = () => screen.getByRole('navigation', { name: '主要' });
const toggle = () => within(nav()).getByRole('button');
const menu = () => document.getElementById('site-menu')!;
const isOpen = () => menu().classList.contains('site-nav-links--open');
// jsdom applies the stylesheet but no media query: the page is phone-width and
// the closed list is out of the page; `hidden` reaches the links the bar shows from 680px.
const navLink = (name: string) => within(nav()).getByRole('link', { name, hidden: true });

async function openMenu() {
  const user = userEvent.setup();
  await user.click(toggle());
  expect(isOpen()).toBe(true);
  return user;
}

function expectClosedWithFocusBack() {
  expect(isOpen()).toBe(false);
  expect(toggle()).toHaveAttribute('aria-expanded', 'false');
  expect(toggle()).toHaveTextContent('選單');
  expect(toggle()).toHaveFocus();
}

describe('the site navigation', () => {
  it.each(['/', '/roadmap', '/account-deletion', '/support', '/privacy', '/terms', '/nope'])(
    '%s has the one navigation and the one footer',
    (path) => {
      openSite(path, null);
      expect(
        within(nav())
          .getAllByRole('link', { hidden: true })
          .map((a) => [a.textContent, a.getAttribute('href')]),
      ).toEqual([
        ['機車停車指南', '/'],
        ['功能', '/#features'],
        ['規則', '/#rules'],
        ['接下來', '/roadmap'],
        ['聯絡我們', '/support'],
      ]);
      expect(screen.getAllByRole('banner')).toHaveLength(1);
      const footer = screen.getByRole('contentinfo');
      expect(footer).toHaveTextContent('小哲資訊工作室（H.C. CHEN）');
      expect(
        within(footer)
          .getAllByRole('link')
          .map((a) => [a.textContent, a.getAttribute('href')]),
      ).toEqual([
        ['隱私權政策', '/privacy'],
        ['服務條款', '/terms'],
        ['接下來', '/roadmap'],
        ['聯絡我們', '/support'],
        ['刪除帳號', '/account-deletion'],
      ]);
    },
  );

  it('marks 接下來 as the current page on the roadmap only', () => {
    openSite('/roadmap', null);
    expect(navLink('接下來')).toHaveAttribute('aria-current', 'page');
    expect(navLink('功能')).not.toHaveAttribute('aria-current');
  });

  it('leaves 接下來 unmarked elsewhere', () => {
    openSite('/', null);
    expect(navLink('接下來')).not.toHaveAttribute('aria-current');
  });

  it('keeps a page’s own action, under the navigation', () => {
    openSite('/account-deletion', null);
    const banner = screen.getByRole('banner');
    expect(within(banner).getByRole('link', { name: '沒辦法登入？' })).toHaveAttribute(
      'href',
      '/support?kind=account_deletion',
    );
    expect(within(nav()).queryByRole('link', { name: '沒辦法登入？' })).toBeNull();
  });
});

describe('the menu below 680px', () => {
  it('starts closed and names its list', () => {
    openSite('/', null);
    expect(isOpen()).toBe(false);
    expect(toggle()).toHaveAttribute('aria-expanded', 'false');
    expect(toggle()).toHaveAttribute('aria-controls', 'site-menu');
    expect(toggle()).toHaveTextContent('選單');
    // Out of the page, so Tab cannot land on a link nobody can see.
    expect(within(nav()).getAllByRole('link')).toHaveLength(1);
  });

  it('opens, and says it can close', async () => {
    openSite('/', null);
    await openMenu();
    expect(toggle()).toHaveAttribute('aria-expanded', 'true');
    expect(toggle()).toHaveTextContent('關閉');
    expect(within(nav()).getAllByRole('link')).toHaveLength(5);
  });

  it('closes on a second press', async () => {
    openSite('/', null);
    const user = await openMenu();
    await user.click(toggle());
    expectClosedWithFocusBack();
  });

  it('closes on Esc, with the focus back on the button', async () => {
    openSite('/', null);
    const user = await openMenu();
    within(menu()).getAllByRole('link')[1]!.focus();
    await user.keyboard('{Escape}');
    expectClosedWithFocusBack();
  });

  it('closes on a press outside it', async () => {
    openSite('/', null);
    const user = await openMenu();
    await user.click(document.querySelector('.site-menu-scrim')!);
    expectClosedWithFocusBack();
    expect(document.querySelector('.site-menu-scrim')).toBeNull();
  });

  it('closes on a link within the page and goes to the section', async () => {
    const scrollIntoView = vi.mocked(Element.prototype.scrollIntoView);
    scrollIntoView.mockClear();
    const { router } = openSite('/', null);
    const user = await openMenu();
    await user.click(within(menu()).getByRole('link', { name: '規則' }));
    expect(router.state.location.hash).toBe('#rules');
    expect(scrollIntoView.mock.contexts).toEqual([document.getElementById('rules')]);
    expectClosedWithFocusBack();
  });

  it('closes on a link to another page, with the focus on that page’s button', async () => {
    const { router } = openSite('/', null);
    const user = await openMenu();
    await user.click(within(menu()).getByRole('link', { name: '接下來' }));
    expect(router.state.location.pathname).toBe('/roadmap');
    expect(screen.getByRole('heading', { level: 1, name: '接下來' })).toBeInTheDocument();
    expectClosedWithFocusBack();
  });

  it('does not take the focus when the bar’s links are used directly', async () => {
    openSite('/', null);
    await userEvent.setup().click(navLink('接下來'));
    expect(toggle()).not.toHaveFocus();
  });
});

describe('links to the home page’s sections', () => {
  const scrollIntoView = vi.mocked(Element.prototype.scrollIntoView);
  beforeEach(() => scrollIntoView.mockClear());

  it('功能 leads back from another page to its section', async () => {
    const { router } = openSite('/roadmap', null);
    await userEvent.setup().click(navLink('功能'));
    expect(router.state.location.pathname).toBe('/');
    expect(router.state.location.hash).toBe('#features');
    expect(scrollIntoView.mock.contexts).toEqual([document.getElementById('features')]);
  });

  it('goes to the section again when the same link is followed again', async () => {
    openSite('/', null);
    const user = userEvent.setup();
    await user.click(navLink('規則'));
    await user.click(navLink('規則'));
    expect(scrollIntoView).toHaveBeenCalledTimes(2);
  });

  it('does not break on an address that is not a section', async () => {
    const { router } = openSite('/', null);
    await act(() => router.navigate('/#%E4%'));
    expect(screen.getByRole('heading', { level: 1 })).toBeInTheDocument();
    expect(scrollIntoView).not.toHaveBeenCalled();
  });
});
