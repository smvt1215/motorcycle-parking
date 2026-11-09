// RWD smoke for the public pages. Needs `npm run build:smoke` first: a build
// pointed at a backend that does not exist, served from dist-smoke/ with an
// SPA fallback. Each screen of the deletion flow and the support pages is opened at the target
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
  // The home page's own edges (the bento's columns, the bar against the menu).
  { name: 'edge-680', width: 680, height: 900, only: 'site' },
  { name: 'tablet-820', width: 820, height: 1180, only: 'site' },
  { name: 'edge-1040', width: 1040, height: 800, only: 'site' },
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

const supportId = '1a2b3c4d-0000-4000-8000-000000000001';
const linkToken = `${supportId}.${'A'.repeat(42)}w`;
const caseLink = `/support/case#token=${linkToken}`;
const deletionForm = '/support?kind=account_deletion';
const confirmAnswer = (result, scheduledAt = null) => ({
  body: {
    result,
    kind: 'account_deletion',
    submitted_at: '2026-11-06T07:05:00Z',
    contact_email: 'r***@e***.com',
    scheduled_at: scheduledAt,
  },
});

const privacyAnswer = (result) => ({
  body: {
    result,
    kind: 'privacy',
    privacy_right: 'copy',
    subject: '想取得我的資料副本',
    message: `想取得帳號的全部資料。\n${'很長的一段沒有空白的文字'.repeat(12)}`,
    submitted_at: '2026-11-06T07:05:00Z',
    contact_email: 'r***@e***.com',
    scheduled_at: null,
  },
});
const caseAnswer = (overrides = {}) => ({
  body: {
    result: 'ok',
    code: 'S-1A2B3C4D',
    kind: 'general',
    status: 'open',
    submitted_at: '2026-11-08T06:02:00Z',
    can_reply: true,
    messages: [
      {
        direction: 'in',
        body: '收藏的停車點換手機後不見了，要怎麼找回來？\n第二行<b>不是標記</b>',
        created_at: '2026-11-08T06:02:00Z',
      },
      {
        direction: 'out',
        body: `收藏會跟著帳號同步，請確認新手機是用同一個帳號登入。${'x'.repeat(300)}`,
        created_at: '2026-11-09T02:30:00Z',
      },
    ],
    ...overrides,
  },
});

/**
 * Each screen: whether it is signed in, the API's answers, what to click to
 * get there, and the heading that proves it arrived.
 */
const SCREENS = [
  { name: 'home', group: 'site', path: '/', signedIn: false, heading: '騎到之前' },
  {
    name: 'home-reduced-motion',
    group: 'site',
    path: '/',
    signedIn: false,
    reducedMotion: 'reduce',
    heading: '騎到之前',
  },
  { name: 'roadmap', group: 'site', path: '/roadmap', signedIn: false, heading: '接下來' },
  {
    name: 'menu',
    group: 'site',
    path: '/',
    signedIn: false,
    menu: true,
    steps: ['openMenu'],
    heading: '騎到之前',
  },
  { name: 'explanation', signedIn: false, heading: '刪除你的帳號' },
  { name: 'privacy', path: '/privacy', signedIn: false, heading: '隱私權政策' },
  { name: 'terms', path: '/terms', signedIn: false, heading: '服務條款' },
  {
    name: 'signin-checking',
    signedIn: false,
    signIn: { kind: 'hold' },
    steps: ['signIn'],
    heading: '刪除你的帳號',
  },
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
  // The support form and its one-time links (no sign-in; the smoke build's
  // App Check token is fixed, and the Edge Functions answer from page.route).
  { name: 'support-form', signedIn: false, path: '/support', heading: '聯絡我們', visible: '送出' },
  {
    name: 'support-privacy',
    signedIn: false,
    path: '/support?kind=privacy',
    heading: '聯絡我們',
    visible: '查閱我的資料',
  },
  {
    name: 'support-privacy-errors',
    signedIn: false,
    path: '/support?kind=privacy',
    steps: ['submitCase'],
    heading: '聯絡我們',
    visible: '請選擇要做什麼',
  },
  {
    name: 'support-case-received',
    signedIn: false,
    path: '/support',
    functions: { 'support-request': { body: { received: true, id: supportId } } },
    steps: ['fillCase', 'submitCase'],
    heading: '已收到你的一般問題，案件編號 S-1A2B3C4D',
  },
  {
    name: 'support-privacy-received',
    signedIn: false,
    path: '/support?kind=privacy',
    functions: { 'support-request': { body: { received: true, id: supportId } } },
    steps: ['fillPrivacy', 'submitCase'],
    heading: '已收到請求，編號 S-1A2B3C4D',
  },
  {
    name: 'support-case-rate-limited',
    signedIn: false,
    path: '/support',
    functions: { 'support-request': { status: 429, body: { error: 'support.rate_limited' } } },
    steps: ['fillCase', 'submitCase'],
    heading: '聯絡我們',
    visible: '送出太多次了',
  },
  {
    name: 'support-deletion',
    signedIn: false,
    path: deletionForm,
    heading: '聯絡我們',
    visible: '用登入 email 申請刪除',
  },
  {
    name: 'support-errors',
    signedIn: false,
    path: deletionForm,
    steps: ['submit'],
    heading: '聯絡我們',
    visible: '請填寫聯絡用 email',
  },
  {
    name: 'support-received',
    signedIn: false,
    path: deletionForm,
    functions: { 'support-request': { body: { received: true, id: supportId } } },
    steps: ['fillForm', 'submit'],
    heading: '已收到申請，編號 S-1A2B3C4D',
  },
  {
    name: 'support-rate-limited',
    signedIn: false,
    path: deletionForm,
    functions: { 'support-request': { status: 429, body: { error: 'support.rate_limited' } } },
    steps: ['fillForm', 'submit'],
    heading: '聯絡我們',
    visible: '送出太多次了',
  },
  {
    name: 'support-app-check',
    signedIn: false,
    path: deletionForm,
    functions: { 'support-request': { status: 401, body: { error: 'app_check.required' } } },
    steps: ['fillForm', 'submit'],
    heading: '聯絡我們',
    visible: '沒辦法確認是真人送出',
  },
  {
    name: 'support-network',
    signedIn: false,
    path: deletionForm,
    functions: { 'support-request': 'abort' },
    steps: ['fillForm', 'submit'],
    heading: '聯絡我們',
    visible: '網路連線有問題，申請沒有送出。',
  },
  {
    name: 'verify',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: { 'support-confirm': [confirmAnswer('pending')] },
    heading: '是你申請刪除帳號的嗎？',
  },
  {
    name: 'verify-requested',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: {
      'support-confirm': [
        confirmAnswer('pending'),
        confirmAnswer('deletion_requested', '2026-11-13T07:05:00Z'),
      ],
    },
    steps: ['confirmLink'],
    heading: '已申請刪除帳號',
  },
  {
    name: 'verify-denied',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: { 'support-confirm': [confirmAnswer('pending'), confirmAnswer('denied')] },
    steps: ['denyLink'],
    heading: '已作廢這次申請',
  },
  {
    name: 'verify-invalid',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: { 'support-confirm': [{ status: 400, body: { error: 'support.link_invalid' } }] },
    heading: '連結無效',
  },
  {
    name: 'verify-privacy',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: { 'support-confirm': [privacyAnswer('pending')] },
    heading: '是你提出個資權利請求的嗎？',
  },
  {
    name: 'verify-privacy-verified',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: { 'support-confirm': [privacyAnswer('pending'), privacyAnswer('verified')] },
    steps: ['confirmPrivacy'],
    heading: '已確認個資權利請求',
  },
  {
    name: 'verify-privacy-denied',
    signedIn: false,
    path: `/support/verify#token=${linkToken}`,
    functions: { 'support-confirm': [privacyAnswer('pending'), privacyAnswer('denied')] },
    steps: ['denyLink'],
    heading: '已作廢這次請求',
  },
  {
    name: 'case',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': [caseAnswer()] },
    heading: '一般問題',
    visible: '送出回覆',
  },
  {
    name: 'case-reply-sent',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': [caseAnswer(), { body: { result: 'received', reopened: true } }] },
    steps: ['fillReply', 'sendReply'],
    heading: '一般問題',
    visible: '這個案件已重新開啟。',
  },
  {
    name: 'case-closed',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': [caseAnswer({ status: 'done', can_reply: false })] },
    heading: '一般問題',
    visible: '這個案件已結案',
  },
  {
    name: 'case-link-used',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': [caseAnswer({ can_reply: false })] },
    heading: '一般問題',
    visible: '這個連結沒辦法再回覆',
  },
  {
    name: 'case-rate-limited',
    signedIn: false,
    path: caseLink,
    functions: {
      'support-case': [caseAnswer(), { status: 429, body: { error: 'support.rate_limited' } }],
    },
    steps: ['fillReply', 'sendReply'],
    heading: '一般問題',
    visible: '回覆次數已達上限',
  },
  {
    name: 'case-reply-network',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': [caseAnswer(), 'abort'] },
    steps: ['fillReply', 'sendReply'],
    heading: '一般問題',
    visible: '網路連線有問題，回覆沒有送出。',
  },
  {
    name: 'case-invalid',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': [{ status: 400, body: { error: 'support.link_invalid' } }] },
    heading: '連結無效',
  },
  {
    name: 'case-failed',
    signedIn: false,
    path: caseLink,
    functions: { 'support-case': ['abort'] },
    heading: '沒有送出',
  },
  {
    name: 'cancel-link',
    signedIn: false,
    path: `/support/cancel#token=${linkToken}`,
    functions: { 'support-confirm': [{ body: { result: 'pending', scheduled_at: '2026-11-13T07:05:00Z' } }] },
    heading: '要取消刪除帳號嗎？',
  },
  {
    name: 'cancel-link-done',
    signedIn: false,
    path: `/support/cancel#token=${linkToken}`,
    functions: {
      'support-confirm': [
        { body: { result: 'pending', scheduled_at: '2026-11-13T07:05:00Z' } },
        { body: { result: 'cancelled', scheduled_at: null } },
      ],
    },
    steps: ['cancelLink'],
    heading: '已取消刪除帳號',
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
    if (viewport.only && screen.group !== viewport.only) continue;
    // The menu exists below 680px; from there the links are in the bar.
    if (screen.menu && viewport.width >= 680) continue;
    const context = await browser.newContext({
      viewport,
      locale: 'zh-TW',
      reducedMotion: screen.reducedMotion ?? 'no-preference',
    });
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
    // The support Edge Functions: a list of answers is used in turn (the last repeats).
    const used = {};
    await page.route('**/functions/v1/*', (route) => {
      if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 200, body: 'ok' });
      const fn = new URL(route.request().url()).pathname.split('/').pop();
      const listed = screen.functions?.[fn];
      const list = Array.isArray(listed) ? listed : [listed];
      const answer = list[Math.min(used[fn] ?? 0, list.length - 1)];
      used[fn] = (used[fn] ?? 0) + 1;
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
        if (step === 'openMenu') {
          await page.getByRole('button', { name: '選單' }).click();
          const rows = await page
            .locator('#site-menu a')
            .evaluateAll((links) => links.map((link) => link.getBoundingClientRect().height));
          if (rows.some((row) => row < 52)) failures.push(`${viewport.name}/menu: rows ${rows.join(', ')}`);
        }
        if (step === 'check') await page.getByRole('checkbox').check();
        if (step === 'delete') await page.getByRole('button', { name: '刪除帳號' }).click();
        if (step === 'cancelDeletion') await page.getByRole('button', { name: /取消刪除/ }).click();
        if (step === 'signIn') await page.getByRole('button', { name: '使用 Google 登入' }).click();
        if (step === 'fillForm') {
          await page.getByLabel(/帳號的登入 email/).fill('rider.old@gmail.com');
          await page.getByRole('radio', { name: 'Google' }).check();
          await page.getByLabel(/聯絡用 email/).fill('me@example.com');
          await page.getByLabel(/為什麼沒辦法登入/).fill('換了手機，忘記當初用哪個帳號登入');
        }
        if (step === 'submit') await page.getByRole('button', { name: '寄確認信' }).click();
        if (step === 'fillCase' || step === 'fillPrivacy') {
          await page.getByLabel(/聯絡用 email/).fill('me@example.com');
          await page.getByLabel(/主旨/).fill('收藏不見了');
          await page.getByLabel(/內容/).fill('換手機後收藏的停車點不見了');
        }
        if (step === 'fillPrivacy') {
          await page.getByLabel(/帳號的登入 email/).fill('rider.old@gmail.com');
          await page.getByRole('radio', { name: '取得資料副本' }).check();
        }
        if (step === 'submitCase') await page.getByRole('button', { name: '送出', exact: true }).click();
        if (step === 'confirmPrivacy') await page.getByRole('button', { name: '是我，確認這筆請求' }).click();
        if (step === 'fillReply') await page.getByLabel(/回覆/).fill('已經確認過了，還是找不到');
        if (step === 'sendReply') await page.getByRole('button', { name: '送出回覆' }).click();
        if (step === 'confirmLink') await page.getByRole('button', { name: '是我，申請刪除帳號' }).click();
        if (step === 'denyLink') await page.getByRole('button', { name: '不是我申請的' }).click();
        if (step === 'cancelLink') await page.getByRole('button', { name: '取消刪除' }).click();
      }
      await page.getByRole('heading', { level: 1, name: screen.heading }).waitFor({ timeout: 5000 });
      if (screen.visible) await page.getByText(screen.visible).first().waitFor({ timeout: 5000 });
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
console.log(`smoke ok: ${VIEWPORTS.length} widths, ${SCREENS.length} screens → ${output}`);
