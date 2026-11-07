import { act, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { vi } from 'vitest';
import { dateLabel, privacy, reviewNotice, sectionId, sections } from '../legal/policies';
import { openSite } from '../test/site';

function open() {
  return openSite('/privacy', null);
}

describe('/privacy', () => {
  it('shows the title, version, dates and the review notice', () => {
    open();
    expect(screen.getByRole('heading', { level: 1, name: '隱私權政策' })).toBeInTheDocument();
    expect(screen.getByText(privacy.version)).toBeInTheDocument();
    expect(screen.getAllByText(dateLabel(privacy.effective)).length).toBeGreaterThan(0);
    expect(screen.getByRole('note')).toHaveTextContent(reviewNotice);
  });

  it('names who collects and how to reach them', () => {
    open();
    const main = screen.getByRole('main');
    expect(main).toHaveTextContent('小哲資訊工作室（負責人：H.C. CHEN）');
    expect(main).toHaveTextContent('ops@motoparking.smvtstudio.com');
  });

  it('lists every section, and each contents link reaches its heading', () => {
    open();
    const titles = sections(privacy.markdown);
    expect(titles).toHaveLength(14);
    expect(titles[0]).toBe('重點摘要');
    titles.forEach((title, index) => {
      const heading = screen.getByRole('heading', { level: 2, name: title });
      expect(heading).toHaveAttribute('id', sectionId(index));
    });
    const nav = screen.getAllByRole('navigation', { name: '目錄' })[0]!;
    expect(within(nav).getAllByRole('link')).toHaveLength(titles.length);
    expect(within(nav).getAllByRole('link')[1]).toHaveAttribute('href', `#${sectionId(1)}`);
  });

  it('renders the tables', () => {
    open();
    expect(screen.getAllByRole('table').length).toBe(2);
    expect(screen.getByRole('cell', { name: '不登入也能用' })).toBeInTheDocument();
  });

  it('keeps addresses as text and links the site within the app (#295)', () => {
    open();
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
    const support = screen.getAllByRole('link', {
      name: 'https://motoparking.smvtstudio.com/support',
    })[0];
    expect(support).toHaveAttribute('href', '/support');
  });

  it('ends a bare address at the address, not in the Chinese after it', () => {
    open();
    const bare = screen.getAllByRole('link').filter((a) => a.textContent?.startsWith('https://'));
    expect(bare.length).toBeGreaterThan(3);
    bare.forEach((a) => expect(a.textContent).toMatch(/^https:\/\/[a-z0-9./-]+$/));
  });

  it('keeps the header to the brand; deletion is in the footer and in 「你的權利」', () => {
    open();
    expect(within(screen.getByRole('banner')).getAllByRole('link')).toHaveLength(1);
    const footer = screen.getByRole('contentinfo');
    expect(within(footer).getByRole('link', { name: '隱私權政策' })).toHaveAttribute('aria-current', 'page');
    expect(within(footer).getByRole('link', { name: '刪除帳號' })).toHaveAttribute(
      'href',
      '/account-deletion',
    );
    const inText = screen.getByRole('link', {
      name: 'https://motoparking.smvtstudio.com/account-deletion',
    });
    expect(inText).toHaveAttribute('href', '/account-deletion');
  });
});

describe('arriving at the policy', () => {
  it('opens at its top from another page, and a section link keeps its place', async () => {
    const scrollTo = vi.mocked(window.scrollTo);
    const { router } = openSite('/account-deletion', null);
    scrollTo.mockClear();
    await userEvent.click(within(screen.getByRole('contentinfo')).getByRole('link', { name: '隱私權政策' }));
    expect(screen.getByRole('heading', { level: 1, name: '隱私權政策' })).toBeInTheDocument();
    expect(scrollTo).toHaveBeenCalledWith(0, 0);

    scrollTo.mockClear();
    await act(() => router.navigate('/privacy#section-3'));
    expect(scrollTo).not.toHaveBeenCalled();
  });
});

describe('the published text', () => {
  it('carries no draft marks or internal references', () => {
    for (const mark of ['待確認', '待專業人士審閱', '起草', 'Q275', '依據']) {
      expect(privacy.markdown).not.toContain(mark);
    }
    expect(privacy.markdown).not.toMatch(/#\d{2,}/);
  });

  it('says what the mail service handles, and when Apple is not revoked', () => {
    expect(privacy.markdown).toContain('寄到帳號登入 email 的確認信、刪除帳號通知與取消連結');
    expect(privacy.markdown).toContain('透過客服表單申請時，我們無法代為撤銷');
  });

  it('keeps the decisions: no postal address, no push, no OpenStreetMap', () => {
    expect(privacy.markdown).not.toContain('地址：');
    expect(privacy.markdown).not.toContain('推播 token');
    expect(privacy.markdown).not.toContain('OpenStreetMap');
    expect(privacy.markdown).toContain('至少 7 天');
    expect(privacy.markdown).toContain('日本東京（AWS ap-northeast-1）');
  });
});
