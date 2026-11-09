import { act, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { vi } from 'vitest';
import { dateLabel, privacy, sectionId, sections, terms } from '../legal/policies';
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
    expect(screen.getByRole('note')).toHaveTextContent(privacy.notice);
  });

  it('names who collects and how to reach them', () => {
    open();
    const main = screen.getByRole('main');
    expect(main).toHaveTextContent('小哲資訊工作室（負責人：H.C. CHEN）');
    expect(main).toHaveTextContent('support@motoparking.smvtstudio.com');
    expect(main).not.toHaveTextContent('ops@');
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

describe('/terms', () => {
  it('uses the policy layout with its own notice, version and footer mark', () => {
    openSite('/terms', null);
    expect(screen.getByRole('heading', { level: 1, name: '服務條款' })).toBeInTheDocument();
    expect(screen.getByText(terms.version)).toBeInTheDocument();
    expect(screen.getByRole('note').textContent).toBe(terms.notice);
    const footer = screen.getByRole('contentinfo');
    expect(within(footer).getByRole('link', { name: '服務條款' })).toHaveAttribute('aria-current', 'page');
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('lists all twelve articles and links the privacy policy inside the site', () => {
    openSite('/terms', null);
    const titles = sections(terms.markdown);
    expect(titles).toHaveLength(12);
    expect(titles[1]).toContain('停車判斷僅供參考');
    expect(within(screen.getByRole('main')).getByRole('link', { name: '隱私權政策' })).toHaveAttribute(
      'href',
      '/privacy',
    );
  });

  it('carries no draft marks or internal references, and the decisions hold', () => {
    // 「待確認」 appears once, as the App's label for community spots.
    expect(terms.markdown.split('待確認')).toHaveLength(2);
    for (const mark of ['待專業人士', '待律師', '起草', 'Q275', '顯示名稱', '.md']) {
      expect(terms.markdown).not.toContain(mark);
    }
    expect(terms.markdown).not.toMatch(/#\d{2,}/);
    expect(terms.markdown).toContain('至少 7 天');
    expect(terms.markdown).toContain('停權期間仍可登入、管理和刪除帳號');
    expect(terms.markdown).toContain('你可以在停車點詳情檢舉不當內容');
    expect(terms.markdown).toContain('類型選「檢舉與申訴」');
    expect(terms.markdown).not.toContain('ops@');
    expect(terms.markdown).toContain('臺灣臺北地方法院');
    expect(terms.markdown).toContain('前兩項不適用');
    expect(terms.markdown).not.toContain('新臺幣');
    expect(terms.markdown).not.toContain('地址：');
  });

  it('states the data sources in article 5, the anchor the App links to', () => {
    // lib/core/policy_links.dart links here: moving the article moves the App's link.
    expect(sectionId(sections(terms.markdown).indexOf('第 5 條　資料來源與智慧財產權'))).toBe('section-5');
    openSite('/terms', null);
    const article = screen.getByRole('heading', { level: 2, name: /^第 5 條/ });
    expect(article).toHaveAttribute('id', 'section-5');
    expect(terms.markdown).toContain(
      '政府開放資料、交通部運輸資料流通服務平臺（TDX）、各縣市政府資料，以及社群協力資料',
    );
    expect(terms.markdown).toContain('社群協力資料經核驗後只收錄事實');
    expect(terms.markdown).toContain('官方點與社群點在 App 中分開標示');
    expect(
      within(screen.getByRole('main')).getByRole('link', { name: '政府資料開放授權條款－第 1 版' }),
    ).toHaveAttribute('href', 'https://data.gov.tw/license');
    expect(terms.markdown).not.toContain('詳見 App');
  });

  it('leaves out what is not confirmed for publication', () => {
    for (const mark of ['OpenStreetMap', 'IconScout', '著作權法', 'spot_details', 'docs/', '草稿']) {
      expect(terms.markdown).not.toContain(mark);
    }
    expect(terms.markdown).not.toMatch(/data\.gov\.tw\/dataset/);
  });
});

describe('arriving at the policy', () => {
  it('goes to the linked section when the page opens on one', () => {
    const scrollIntoView = vi.mocked(Element.prototype.scrollIntoView);
    scrollIntoView.mockClear();
    openSite('/terms#section-5', null);
    expect(scrollIntoView).toHaveBeenCalledOnce();
    expect(scrollIntoView.mock.contexts[0]).toBe(document.getElementById('section-5'));
  });

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

  it('says support@ takes mail as a case, and that mail does not prove who owns an account', () => {
    expect(privacy.markdown).toContain('來信會登錄為客服案件');
    expect(privacy.markdown).toContain('寄信無法確認你是帳號本人，請用客服表單申請');
    expect(privacy.markdown).not.toContain('不收信');
  });

  it('says what the mail service handles, and when Apple is not revoked', () => {
    expect(privacy.markdown).toContain('寄到帳號登入 email 的確認信、刪除帳號通知與取消連結');
    expect(privacy.markdown).toContain('透過客服表單申請時，我們無法代為撤銷');
  });

  it('says what stays for a suspended account, without calling it anonymous', () => {
    const sentence =
      '如果帳號刪除時仍在停權中，我們會保留一組無法直接辨識你的雜湊值和停權到期日，直到停權結束（無限期停權最多保留 180 天），只用來在同一個 Google 或 Apple 帳號重新登入時維持停權。';
    expect(privacy.markdown).toContain(sentence);
    expect(sentence).not.toContain('匿名');
    expect(privacy.markdown).toContain('保留到停權結束；無限期停權最多 180 天');
  });

  it('keeps the decisions: no postal address, no push, no OpenStreetMap', () => {
    expect(privacy.markdown).not.toContain('地址：');
    expect(privacy.markdown).not.toContain('推播 token');
    expect(privacy.markdown).not.toContain('OpenStreetMap');
    expect(privacy.markdown).toContain('至少 7 天');
    expect(privacy.markdown).toContain('日本東京（AWS ap-northeast-1）');
  });
});
