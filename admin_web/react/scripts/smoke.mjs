// RWD smoke for the React admin: builds must exist (`npm run build`).
// Serves dist/ with an SPA fallback, then checks every page at the target
// widths (docs: rwd-required — 320 / 390 / iPhone 16 Pro 402 / two-pane
// 680–1040 / iPad Air 820 & 1180 / 13" 1024 / desktop) and saves screenshots.
import { createServer } from 'node:http';
import { mkdir, readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist');
const output = join(root, 'artifacts', 'smoke');

const VIEWPORTS = [
  { name: 'phone-320', width: 320, height: 640, tabs: 4 },
  { name: 'phone-390', width: 390, height: 844, tabs: 4 },
  { name: 'iphone16pro-402', width: 402, height: 874, tabs: 4 },
  { name: 'two-pane-700', width: 700, height: 900, tabs: 5 },
  { name: 'ipad-air-820', width: 820, height: 1180, tabs: 5 },
  { name: 'ipad-13-1024', width: 1024, height: 1366, tabs: 5 },
  { name: 'ipad-air-land-1180', width: 1180, height: 820, tabs: 5 },
  { name: 'desktop-1440', width: 1440, height: 960, tabs: 5 },
];
const PAGES = ['/review', '/spots', '/more', '/design', '/import', '/nope'];

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

for (const viewport of VIEWPORTS) {
  const page = await browser.newPage({ viewport: { width: viewport.width, height: viewport.height } });
  // Fonts come from Google; the smoke checks layout, not the network.
  await page.route(/fonts\.(googleapis|gstatic)\.com/, (route) => route.abort());
  for (const path of PAGES) {
    await page.goto(`${base}${path}`);
    await page.waitForSelector('nav[aria-label="管理功能"]');
    const result = await page.evaluate(() => {
      const nav = document.querySelector('nav[aria-label="管理功能"]');
      const visible = [...nav.querySelectorAll('a')].filter((a) => a.getClientRects().length > 0);
      const small = visible
        .map((a) => a.getBoundingClientRect())
        .filter((r) => r.height < 44 || r.width < 44)
        .map((r) => `${Math.round(r.width)}×${Math.round(r.height)}`);
      const buttons = [...document.querySelectorAll('main button, main a.btn')]
        .map((b) => b.getBoundingClientRect())
        .filter((r) => r.height < 44)
        .map((r) => Math.round(r.height));
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
    if (result.overflow > 0) failures.push(`${where}: scrolls sideways by ${result.overflow}px`);
    if (result.tabs !== viewport.tabs) failures.push(`${where}: ${result.tabs} tabs, want ${viewport.tabs}`);
    if (result.small.length) failures.push(`${where}: nav targets under 44px: ${result.small.join(', ')}`);
    if (result.buttons.length) failures.push(`${where}: buttons under 44px: ${result.buttons.join(', ')}`);
    if (['/review', '/spots', '/import'].includes(path) && result.current.length !== 1) {
      failures.push(`${where}: ${result.current.length} current tabs (${result.current.join(', ')})`);
    }
    await page.screenshot({
      path: join(output, `${viewport.name}${path.replaceAll('/', '_')}.png`),
      fullPage: true,
    });
  }
  await page.close();
}

await browser.close();
server.close();

if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
console.log(`smoke ok: ${VIEWPORTS.length} viewports × ${PAGES.length} pages → ${output}`);
