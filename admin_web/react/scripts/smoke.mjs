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
  '/spots',
  '/more',
  '/design',
  '/import',
  '/nope',
];

/** Tabs a page shows: none on a phone's report detail, else 4 on phones and 5 wider. */
const expectedTabs = (viewport, path) => (viewport.phone ? (/^\/review\/[^/?]+/.test(path) ? 0 : 4) : 5);

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
  if (path.startsWith('/review')) {
    await page.waitForSelector('.queue__list, .review-detail, .review-done', { state: 'attached' });
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
        .filter((r) => r.height < 44 || r.width < 44)
        .map((r) => `${Math.round(r.width)}×${Math.round(r.height)}`);
      const buttons = [...document.querySelectorAll('main button, main a.btn')]
        .filter((b) => b.getClientRects().length > 0)
        .map((b) => [b.textContent.trim(), b.getBoundingClientRect()])
        .filter(([, r]) => r.height < 44)
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
    if (result.small.length) failures.push(`${where}: nav targets under 44px: ${result.small.join(', ')}`);
    if (result.buttons.length) failures.push(`${where}: buttons under 44px: ${result.buttons.join(', ')}`);
    if (tabs > 0 && ['/review', '/spots', '/import'].includes(path) && result.current.length !== 1) {
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
