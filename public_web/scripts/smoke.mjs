// RWD smoke for the public pages. Needs `npm run build:smoke` first: a build
// pointed at a backend that does not exist, served from dist-smoke/ with an
// SPA fallback. Each screen of the deletion flow is opened at the target
// widths (rwd rule: phone, 680–1040, desktop, past 1440), signed in with the
// smoke build's fake sign-in and API answers from page.route; the page must not
// scroll sideways, and a screenshot is saved for review.
import { createServer } from 'node:http';
import { mkdir, readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist-smoke');
const output = join(root, 'artifacts', 'smoke');

const VIEWPORTS = [
  { name: 'phone-320', width: 320, height: 640 },
  { name: 'phone-390', width: 390, height: 844 },
  { name: 'two-pane-700', width: 700, height: 900 },
  { name: 'ipad-1024', width: 1024, height: 1366 },
  { name: 'desktop-1440', width: 1440, height: 960 },
  { name: 'wide-1920', width: 1920, height: 1080 },
];

const none = {
  status: 'none',
  requested_at: null,
  scheduled_at: null,
  can_self_delete: true,
  cannot_self_delete_reason: null,
};
const pending = {
  ...none,
  status: 'pending',
  requested_at: '2026-11-05T02:00:00Z',
  scheduled_at: '2026-11-12T02:00:00Z',
};
const error = (status, message) => ({
  status,
  body: { code: `PT${status}`, message, details: null, hint: null },
});

/**
 * Each screen: whether it is signed in, the API's answers, what to click to
 * get there, and the heading that proves it arrived.
 */
const SCREENS = [
  { name: 'explanation', signedIn: false, heading: '刪除你的帳號' },
  { name: 'privacy', path: '/privacy', signedIn: false, heading: '隱私權政策' },
  {
    name: 'no-account',
    signedIn: false,
    signIn: { kind: 'noAccount', email: 'new.rider@gmail.com' },
    steps: ['signIn'],
    heading: '這個帳號沒有用過 App',
  },
  {
    name: 'confirm',
    signedIn: true,
    api: { account_deletion_status: { body: none } },
    heading: '要刪除帳號嗎？',
  },
  {
    name: 'requested',
    signedIn: true,
    api: { account_deletion_status: { body: none }, request_account_deletion: { body: pending } },
    steps: ['check', 'delete'],
    heading: '已申請刪除帳號',
  },
  {
    name: 'reauth',
    signedIn: true,
    api: {
      account_deletion_status: { body: none },
      request_account_deletion: error(401, 'auth.recent_sign_in_required'),
    },
    steps: ['check', 'delete'],
    heading: '再登入一次',
  },
  {
    name: 'rate-limited',
    signedIn: false,
    signIn: { kind: 'rateLimited' },
    steps: ['signIn'],
    heading: '暫時無法登入',
  },
  {
    name: 'requested-apple-not-revoked',
    signedIn: true,
    user: 'apple',
    appleRevoke: { kind: 'notRevoked' },
    api: { account_deletion_status: { body: none }, request_account_deletion: { body: pending } },
    steps: ['check', 'delete'],
    heading: '已申請刪除帳號',
    visible: 'Apple 登入授權沒有撤銷',
  },
  {
    name: 'reauth-apple',
    signedIn: true,
    user: 'apple',
    appleRevoke: { kind: 'signInNeeded' },
    api: { account_deletion_status: { body: none } },
    steps: ['check', 'delete'],
    heading: '再登入一次',
  },
  {
    name: 'pending',
    signedIn: true,
    api: { account_deletion_status: { body: pending } },
    heading: '帳號正在等待刪除',
  },
  {
    name: 'cancelled',
    signedIn: true,
    api: { account_deletion_status: { body: pending }, cancel_account_deletion: { body: none } },
    steps: ['cancelDeletion'],
    heading: '已取消刪除帳號',
  },
  {
    name: 'network',
    signedIn: true,
    api: { account_deletion_status: { body: none }, request_account_deletion: 'abort' },
    steps: ['check', 'delete'],
    heading: '沒有送出',
  },
  {
    name: 'admin',
    signedIn: true,
    api: {
      account_deletion_status: {
        body: {
          ...none,
          can_self_delete: false,
          cannot_self_delete_reason: 'account.admin_cannot_self_delete',
        },
      },
    },
    heading: '管理員帳號無法自行刪除',
  },
];

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

const rider = { id: 'u-smoke', email: 'rider@gmail.com', provider: 'google' };
const appleRider = { id: 'u-smoke-apple', email: 'abc123@privaterelay.appleid.com', provider: 'apple' };

await mkdir(output, { recursive: true });
const browser = await chromium.launch();
const failures = [];
for (const viewport of VIEWPORTS) {
  for (const screen of SCREENS) {
    const context = await browser.newContext({ viewport, locale: 'zh-TW' });
    // The smoke build signs in with src/smoke/smokeAuth.ts, which reads these.
    await context.addInitScript(
      ([user, signIn, appleRevoke]) => {
        if (user) localStorage.setItem('motopark-smoke-user', user);
        if (signIn) localStorage.setItem('motopark-smoke-sign-in', signIn);
        if (appleRevoke) localStorage.setItem('motopark-smoke-apple-revoke', appleRevoke);
      },
      [
        screen.signedIn ? JSON.stringify(screen.user === 'apple' ? appleRider : rider) : null,
        screen.signIn ? JSON.stringify(screen.signIn) : null,
        screen.appleRevoke ? JSON.stringify(screen.appleRevoke) : null,
      ],
    );
    const page = await context.newPage();
    await page.route('**/rest/v1/rpc/*', (route) => {
      const fn = new URL(route.request().url()).pathname.split('/').pop();
      const answer = screen.api?.[fn];
      if (answer === 'abort') return route.abort('internetdisconnected');
      if (!answer) return route.fulfill({ status: 500, body: '{}' });
      return route.fulfill({
        status: answer.status ?? 200,
        contentType: 'application/json',
        body: JSON.stringify(answer.body),
      });
    });
    const label = `${viewport.name}/${screen.name}`;
    try {
      await page.goto(`${base}${screen.path ?? '/account-deletion'}`);
      for (const step of screen.steps ?? []) {
        if (step === 'check') await page.getByRole('checkbox').check();
        if (step === 'delete') await page.getByRole('button', { name: '刪除帳號' }).click();
        if (step === 'cancelDeletion') await page.getByRole('button', { name: /取消刪除/ }).click();
        if (step === 'signIn') await page.getByRole('button', { name: '使用 Google 登入' }).click();
      }
      await page.getByRole('heading', { level: 1, name: screen.heading }).waitFor({ timeout: 5000 });
      if (screen.visible) await page.getByText(screen.visible).waitFor({ timeout: 5000 });
      const overflow = await page.evaluate(
        () => globalThis.document.documentElement.scrollWidth - globalThis.innerWidth,
      );
      if (overflow > 0) failures.push(`${label}: scrolls sideways by ${overflow}px`);
      await page.screenshot({ path: join(output, `${viewport.name}-${screen.name}.png`), fullPage: true });
    } catch (failure) {
      failures.push(`${label}: ${failure instanceof Error ? failure.message.split('\n')[0] : failure}`);
    }
    await context.close();
  }
}
await browser.close();
server.close();

if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
console.log(`smoke ok: ${VIEWPORTS.length} widths × ${SCREENS.length} screens → ${output}`);
