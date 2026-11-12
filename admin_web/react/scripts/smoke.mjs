// RWD smoke for the React admin. Needs `npm run build:fixture` first: it
// serves dist-fixture/ (sample data, never shipped) with an SPA fallback,
// checks every page at the target widths (rwd rule: 320 / 390 / iPhone 16
// Pro 402 / two-pane 680–1040 / iPad Air 820 & 1180 / 13" 1024 / desktop),
// runs a few real-browser interactions, and saves screenshots.
import { createServer } from 'node:http';
import { mkdir, readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist-fixture');
const output = join(root, 'artifacts', 'smoke');

const VIEWPORTS = [
  { name: 'phone-320', width: 320, height: 640, phone: true },
  { name: 'phone-390', width: 390, height: 844, phone: true },
  { name: 'iphone16pro-402', width: 402, height: 874, phone: true },
  { name: 'two-pane-700', width: 700, height: 900, phone: false },
  { name: 'ipad-air-820', width: 820, height: 1180, phone: false },
  { name: 'ipad-13-1024', width: 1024, height: 1366, phone: false },
  { name: 'ipad-air-land-1180', width: 1180, height: 820, phone: false },
  { name: 'desktop-1440', width: 1440, height: 960, phone: false },
];
const PAGES = [
  '/review',
  '/review/r-fuxing',
  '/review/r-daan',
  '/review/r-cks?kind=location',
  '/pending',
  '/pending?tab=waiting',
  '/pending?scenario=many',
  '/pending?scenario=list-failed',
  '/pending?scenario=empty',
  '/pending/630f13c7-0000-4000-8000-000000000002',
  '/pending/8f21c04a-0000-4000-8000-000000000003',
  '/pending/4b08f6c2-0000-4000-8000-000000000006',
  '/pending/72d1bb21-0000-4000-8000-000000000008',
  '/pending/61a2d7e0-0000-4000-8000-000000000001',
  '/pending/7a000000-0000-4000-8000-000000000000?scenario=many',
  '/pending/79000000-0000-4000-8000-000000000000?scenario=many',
  '/pending/7d000000-0000-4000-8000-000000000000?scenario=many',
  '/pending/7e000000-0000-4000-8000-000000000000?scenario=many',
  '/spots',
  '/more',
  '/design',
  '/import',
  '/nope',
];

/** Tabs a page shows: none on a phone's report or case detail, else 4 on phones and 6 wider. */
const expectedTabs = (viewport, path) =>
  viewport.phone ? (/^\/(review|pending)\/[^/?]+/.test(path) ? 0 : 4) : 6;

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };

const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(
    /^(\.\.[/\\])+/,
    '',
  );
  const file = join(dist, path);
  try {
    const body = await readFile(file.startsWith(dist) && extname(file) ? file : join(dist, 'index.html'));
    res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'text/html' });
    res.end(body);
  } catch {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(await readFile(join(dist, 'index.html')));
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;

await mkdir(output, { recursive: true });
const browser = await chromium.launch();
const failures = [];

async function open(page, path) {
  await page.goto(`${base}${path}`);
  await page.waitForSelector('nav[aria-label="管理功能"]', { state: 'attached' });
  // The fixture answers after 400 ms; wait for the page's own content.
  await page.waitForSelector('main h1, main h2, main [role="article"]', { state: 'attached' });
  if (/^\/review\/[^/?]+/.test(path)) {
    // A report's URL: its detail, not just the queue, must be on screen
    // before keys are pressed.
    await page.waitForSelector('.review-detail, .review-done', { state: 'attached' });
  } else if (path.startsWith('/review')) {
    await page.waitForSelector('.queue__list, .review-detail, .review-done', { state: 'attached' });
  } else if (/^\/pending\/[^/?]+/.test(path)) {
    // A case's URL: its own content, not just the list next to it.
    await page.waitForSelector('article.case, .pending-pane .pending-state', { state: 'attached' });
  } else if (path.startsWith('/pending')) {
    // Past the skeleton: rows, an empty state or a failure.
    await page.waitForSelector('.pending-rows, .pending-state', { state: 'attached' });
    await page.waitForSelector('.pending-skeleton', { state: 'detached' });
  }
}

for (const viewport of VIEWPORTS) {
  const page = await browser.newPage({ viewport: { width: viewport.width, height: viewport.height } });
  // Fonts come from Google; the smoke checks layout, not the network.
  await page.route(/fonts\.(googleapis|gstatic)\.com/, (route) => route.abort());
  for (const path of PAGES) {
    await open(page, path);
    const result = await page.evaluate(() => {
      const nav = document.querySelector('nav[aria-label="管理功能"]');
      const visible = [...nav.querySelectorAll('a')].filter((a) => a.getClientRects().length > 0);
      const small = visible
        .map((a) => a.getBoundingClientRect())
        .filter((r) => r.height < 48 || r.width < 48)
        .map((r) => `${Math.round(r.width)}×${Math.round(r.height)}`);
      const buttons = [...document.querySelectorAll('main button, main a.btn')]
        .filter((b) => b.getClientRects().length > 0)
        .map((b) => [b.textContent.trim(), b.getBoundingClientRect()])
        .filter(([, r]) => r.height < 48)
        .map(([name, r]) => `${name} ${Math.round(r.height)}`);
      const current = visible
        .filter((a) => a.getAttribute('aria-current') === 'page')
        .map((a) => a.textContent);
      return {
        overflow: document.documentElement.scrollWidth - window.innerWidth,
        tabs: visible.length,
        small,
        buttons,
        current,
      };
    });
    const where = `${viewport.name} ${path}`;
    const tabs = expectedTabs(viewport, path);
    if (result.overflow > 0) failures.push(`${where}: scrolls sideways by ${result.overflow}px`);
    if (result.tabs !== tabs) failures.push(`${where}: ${result.tabs} tabs, want ${tabs}`);
    if (result.small.length) failures.push(`${where}: nav targets under 48px: ${result.small.join(', ')}`);
    if (result.buttons.length) failures.push(`${where}: buttons under 48px: ${result.buttons.join(', ')}`);
    if (
      tabs > 0 &&
      ['/review', '/pending', '/spots', '/import'].includes(path) &&
      result.current.length !== 1
    ) {
      failures.push(`${where}: ${result.current.length} current tabs (${result.current.join(', ')})`);
    }
    await page.screenshot({
      path: join(output, `${viewport.name}${path.replace(/[/?=]/g, '_')}.png`),
      fullPage: true,
    });
  }

  // Real-browser interactions: Chinese text in a controlled textarea, A, undo.
  await open(page, '/review/r-ximen');
  const note = page.getByRole('textbox', { name: /處理說明/ });
  await note.fill('');
  await note.pressSequentially('已比對停管處公告');
  const typed = await note.inputValue();
  if (typed !== '已比對停管處公告') failures.push(`${viewport.name}: note kept 「${typed}」`);
  await page.locator('body').click({ position: { x: 1, y: 1 } });
  await page.keyboard.press('a');
  await page.waitForURL(/\/review\/r-fuxing-2/);
  const undo = page.getByRole('status').filter({ hasText: '秒內可復原' });
  if (!(await undo.isVisible())) failures.push(`${viewport.name}: no undo notice after A`);
  await page.screenshot({ path: join(output, `${viewport.name}_review_after-apply.png`), fullPage: true });
  await undo.getByRole('button', { name: '復原' }).click();
  await page.waitForURL(/\/review\/r-ximen/);
  if ((await note.inputValue()) !== '已比對停管處公告') failures.push(`${viewport.name}: note lost on undo`);

  // 駁回 (ReviewReject boards): inline panel, or a bottom sheet on phones.
  const sideways = () => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  await open(page, '/review/r-fuxing');
  // Keys go to the detail once its toolbar (and its shortcut listener) is up.
  await page.getByRole('toolbar', { name: '處理這筆回報' }).waitFor();
  await page.locator('body').click({ position: { x: 1, y: 1 } });
  await page.keyboard.press('r');
  await page.getByRole('radio', { name: /其他原因/ }).waitFor({ state: 'attached' });
  await page.keyboard.press('6');
  if ((await sideways()) > 0) failures.push(`${viewport.name}: reject panel scrolls sideways`);
  await page.screenshot({
    path: join(output, `${viewport.name}_review_reject.png`),
    fullPage: !viewport.phone,
  });
  await page.keyboard.press('Escape');

  // 修改後套用 (ReviewEdit boards).
  await page.keyboard.press('e');
  const type = page.getByRole('combobox', { name: '格位類型' });
  await type.waitFor();
  await page.getByRole('region', { name: '資格' }).getByRole('radio', { name: '不可停' }).check();
  if ((await sideways()) > 0) failures.push(`${viewport.name}: edit form scrolls sideways`);
  const small = await page.evaluate(() =>
    [...document.querySelectorAll('.edit-field__value input, .edit-field__value select, .plate-pick__option')]
      .map((el) => el.getBoundingClientRect().height)
      .filter((h) => h < 48),
  );
  if (small.length) failures.push(`${viewport.name}: edit controls under 48px: ${small.join(', ')}`);
  await page.screenshot({ path: join(output, `${viewport.name}_review_edit.png`), fullPage: true });
  await page.keyboard.press('Escape');

  // 待處理: rows at least 48px, a row opens only the right pane, pagination.
  await open(page, '/pending?scenario=many');
  await page.getByRole('button', { name: '載入更多' }).click();
  await page.waitForFunction(() => document.querySelectorAll('.pending-row').length > 50);
  const shortRows = await page.evaluate(
    () =>
      [...document.querySelectorAll('.pending-row')].filter((row) => row.getBoundingClientRect().height < 48)
        .length,
  );
  if (shortRows) failures.push(`${viewport.name}: ${shortRows} pending rows under 48px`);
  if ((await sideways()) > 0) failures.push(`${viewport.name}: pending list scrolls sideways`);
  await page.screenshot({ path: join(output, `${viewport.name}_pending_more.png`), fullPage: true });

  await open(page, '/pending');
  await page.locator('.pending-row').first().click();
  await page.waitForURL(/\/pending\/61a2d7e0/);
  await page.getByRole('article', { name: '案件內容' }).waitFor();
  const listShown = await page.locator('.pending-list').isVisible();
  if (listShown === viewport.phone) failures.push(`${viewport.name}: list shown=${listShown} on a case`);
  if (viewport.phone) {
    await page.getByRole('link', { name: /返回待處理/ }).click();
    await page.waitForURL(/\/pending$/);
  }

  // 寄送失敗: 再寄一次 only once the server has stopped retrying (#447).
  for (const [id, retrying] of [
    ['79000000', true],
    ['7a000000', false],
  ]) {
    await open(page, `/pending/${id}-0000-4000-8000-000000000000?scenario=many`);
    await page.getByRole('button', { name: '結案' }).waitFor();
    const resend = await page.getByRole('button', { name: '再寄一次' }).count();
    const notice = await page.getByText('系統正在自動重試').count();
    if (resend !== (retrying ? 0 : 1) || notice !== (retrying ? 1 : 0)) {
      failures.push(`${viewport.name} ${id}: 再寄一次 ${resend}, retry notice ${notice}`);
    }
    if (retrying) {
      // The status line wraps inside its bubble, never past it.
      const line = page.getByText(/15 到 30 分鐘內會自動再試/);
      const spill = await line.evaluate((el) => {
        const bubble = el.closest('.case-message').getBoundingClientRect();
        const box = el.getBoundingClientRect();
        return Math.max(0, box.right - bubble.right, bubble.left - box.left, el.scrollWidth - el.clientWidth);
      });
      if (spill > 0) failures.push(`${viewport.name} ${id}: retry line spills by ${spill}px`);
    }
  }

  // 案件處理: send, the countdown, cancel, and the reply comes back.
  await open(page, '/pending/630f13c7-0000-4000-8000-000000000002');
  await page.getByRole('textbox', { name: '回覆' }).fill('已更正收費，謝謝回報。');
  await page.getByRole('button', { name: '寄出回覆' }).click();
  await page.waitForURL(/\/pending\/8f21c04a/);
  await page.locator('.dock-bar', { hasText: '秒後寄出' }).waitFor();
  await page.waitForFunction(() => document.activeElement?.classList.contains('case-head__title'));
  await page.screenshot({
    path: join(output, `${viewport.name}_pending_countdown.png`),
    fullPage: !viewport.phone,
  });
  if ((await sideways()) > 0) failures.push(`${viewport.name}: countdown scrolls sideways`);
  await page.getByRole('button', { name: /取消寄出/ }).click();
  await page.getByText('已取消寄出', { exact: true }).waitFor();
  await page.getByRole('button', { name: '打開案件' }).click();
  await page.waitForURL(/\/pending\/630f13c7/);
  await page.getByRole('textbox', { name: '回覆' }).waitFor();
  const restored = await page.getByRole('textbox', { name: '回覆' }).inputValue();
  if (restored !== '已更正收費，謝謝回報。')
    failures.push(`${viewport.name}: reply not restored: 「${restored}」`);

  // 檢舉的處理面板: in the case on wide screens, a sheet on phones.
  await open(page, '/pending/8f21c04a-0000-4000-8000-000000000003');
  await page.getByRole('button', { name: '檢舉成立' }).click();
  await page.getByRole('heading', { name: '檢舉成立', level: 2 }).waitFor();
  if ((await sideways()) > 0) failures.push(`${viewport.name}: report panel scrolls sideways`);
  await page.screenshot({
    path: join(output, `${viewport.name}_pending_keep.png`),
    fullPage: !viewport.phone,
  });
  await page.getByRole('button', { name: '返回' }).click();

  // 別人已處理：stays on the case with the reply intact.
  await open(page, '/pending/5d19a0b3-0000-4000-8000-000000000004?scenario=stale-admin');
  await page.getByRole('textbox', { name: '回覆' }).fill('沒寄出');
  await page.getByRole('button', { name: '寄出回覆' }).click();
  await page.getByText('這筆已由其他管理員處理').waitFor();
  await page.screenshot({ path: join(output, `${viewport.name}_pending_stale.png`), fullPage: true });

  if (viewport.phone) {
    // 手機開鍵盤 (TimedPhoneReply): pretend the on-screen keyboard took 300px.
    await open(page, '/pending/630f13c7-0000-4000-8000-000000000002');
    await page.getByRole('textbox', { name: '回覆' }).focus();
    await page.evaluate(() => {
      Object.defineProperty(window.visualViewport, 'height', {
        configurable: true,
        get: () => window.innerHeight - 300,
      });
      window.visualViewport.dispatchEvent(new Event('resize'));
    });
    await page.waitForFunction(() => document.querySelector('.pending--keyboard'));
    const bar = await page.locator('.case__actions').boundingBox();
    const keyboardTop = viewport.height - 300;
    if (Math.abs(bar.y + bar.height - keyboardTop) > 2) {
      failures.push(`${viewport.name}: action bar at ${bar.y + bar.height}, keyboard top ${keyboardTop}`);
    }
    const box = await page.getByRole('textbox', { name: '回覆' }).boundingBox();
    if (box.y + box.height > bar.y + 1) {
      failures.push(`${viewport.name}: the reply box is under the action bar`);
    }
    const header = await page.locator('.case-bar').boundingBox();
    if (header.height !== 48)
      failures.push(`${viewport.name}: top bar is ${header.height}px with the keyboard open`);
    await page.screenshot({ path: join(output, `${viewport.name}_pending_keyboard.png`) });
  }

  // Sign-in steps come before the shell, at every width.
  for (const mode of ['signedOut', 'denied', 'mfa', 'enroll', 'unavailable']) {
    await page.goto(`${base}/pending?auth=${mode}`);
    await page.waitForSelector('.auth-panel h1');
    await page.waitForFunction(() => !document.querySelector('.auth-panel [role="status"]'));
    if ((await sideways()) > 0) failures.push(`${viewport.name} auth=${mode}: scrolls sideways`);
    const smallAuth = await page.evaluate(() =>
      [...document.querySelectorAll('.auth-page button, .auth-page input, .auth-page select')]
        .map((el) => el.getBoundingClientRect().height)
        .filter((h) => h < 48),
    );
    if (smallAuth.length) failures.push(`${viewport.name} auth=${mode}: controls under 48px`);
    if (await page.locator('nav[aria-label="管理功能"]').count()) {
      failures.push(`${viewport.name} auth=${mode}: the admin shell is showing`);
    }
    await page.screenshot({ path: join(output, `${viewport.name}_auth_${mode}.png`), fullPage: true });
  }

  if (viewport.phone) {
    // The phone list expands a row in place before opening the detail.
    await open(page, '/review');
    await page.getByRole('list', { name: '待審回報' }).getByRole('button').first().click();
    await page.getByRole('link', { name: '看完整差異' }).waitFor();
    await page.screenshot({ path: join(output, `${viewport.name}_review_expanded.png`), fullPage: true });
  }
  await page.close();
}

await browser.close();
server.close();

if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
console.log(`smoke ok: ${VIEWPORTS.length} viewports × ${PAGES.length} pages + interactions → ${output}`);
