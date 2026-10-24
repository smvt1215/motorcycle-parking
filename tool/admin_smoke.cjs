// Run against an admin build configured with https://admin-smoke.supabase.co.
// Auth and data responses are intercepted; no real Google/Supabase account is used.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const root = path.resolve(__dirname, '..');
const output = path.join(root, 'artifacts/admin-smoke');
const build = path.join(root, 'build/admin');
const factor = {
  id: '11111111-1111-4111-8111-111111111111', friendly_name: '手機驗證器',
  factor_type: 'totp', status: 'verified',
  created_at: '2026-10-24T00:00:00Z', updated_at: '2026-10-24T00:00:00Z',
};

function session(role, aal, factors = [factor]) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const payload = { sub: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', aal, exp, app_metadata: { role } };
  const jwt = `${Buffer.from('{"alg":"HS256","typ":"JWT"}').toString('base64url')}.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.test-signature`;
  return {
    access_token: jwt, refresh_token: 'smoke-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp,
    user: { id: payload.sub, aud: 'authenticated', email: `${role}@example.test`, app_metadata: { role }, user_metadata: {}, created_at: '2026-10-24T00:00:00Z', factors },
  };
}

(async () => {
  assert((await fs.readFile(path.join(build, 'main.dart.js'), 'utf8')).includes('admin-smoke.supabase.co'), 'Build with the documented smoke Supabase URL before running this test');
  await fs.mkdir(output, { recursive: true });
  const headers = JSON.parse(await fs.readFile(path.join(root, 'firebase.json'), 'utf8')).hosting.headers[0].headers;
  const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json', '.ttf': 'font/ttf', '.otf': 'font/otf', '.svg': 'image/svg+xml', '.png': 'image/png' };
  const server = http.createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      const file = path.resolve(build, `.${pathname === '/' ? '/index.html' : pathname}`);
      if (!file.startsWith(build + path.sep)) { res.writeHead(403).end(); return; }
      const data = await fs.readFile(file);
      for (const { key, value } of headers) res.setHeader(key, value);
      res.setHeader('Content-Type', mime[path.extname(file)] || 'application/octet-stream');
      res.end(data);
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let browser;
  const results = [];
  try {
    browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
    for (const mobile of [false, true]) {
      for (const scenario of ['login', 'denied', 'mfa', 'shell']) {
        const name = `${scenario}-${mobile ? 'mobile-dark' : 'desktop'}`;
        const context = await browser.newContext({
          viewport: mobile ? { width: 390, height: 844 } : { width: 1440, height: 960 },
          colorScheme: mobile ? 'dark' : 'light', reducedMotion: 'reduce',
        });
        let current = scenario === 'login' ? null : session(scenario === 'denied' ? 'rider' : 'admin', scenario === 'mfa' ? 'aal1' : 'aal2');
        if (current) await context.addInitScript(value => {
          localStorage.setItem('sb-admin-smoke-auth-token', JSON.stringify(value));
        }, current);
        const errors = [];
        const requests = [];
        await context.route('https://admin-smoke.supabase.co/**', async route => {
          const url = new URL(route.request().url());
          requests.push(`${route.request().method()} ${url.pathname}`);
          const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-expose-headers': 'content-range' };
          if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
          if (url.pathname === '/auth/v1/authorize') {
            assert.equal(url.searchParams.get('provider'), 'google');
            assert.equal(new URL(url.searchParams.get('redirect_to')).origin, base);
            return route.fulfill({ contentType: 'text/html', body: '<html><body>Google OAuth smoke callback</body></html>' });
          }
          if (url.pathname === '/auth/v1/token') return route.fulfill({ json: current, headers: cors });
          if (url.pathname === '/auth/v1/logout') return route.fulfill({ status: 204, headers: cors });
          if (url.pathname === '/auth/v1/factors' && route.request().method() === 'POST') return route.fulfill({
            json: { id: '22222222-2222-4222-8222-222222222222', type: 'totp', totp: {
              qr_code: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="white"/><path d="M10 10h30v30H10zm50 0h30v30H60zM10 60h30v30H10zm40-10h15v15H50zm20 20h20v20H70z" fill="black"/></svg>',
              secret: 'JBSWY3DPEHPK3PXP', uri: 'otpauth://totp/smoke?secret=JBSWY3DPEHPK3PXP',
            } }, headers: cors,
          });
          if (url.pathname === '/auth/v1/factors/22222222-2222-4222-8222-222222222222' && route.request().method() === 'DELETE') return route.fulfill({ json: { id: '22222222-2222-4222-8222-222222222222' }, headers: cors });
          if (url.pathname.endsWith('/challenge')) return route.fulfill({ json: { id: 'smoke-challenge', expires_at: Math.floor(Date.now() / 1000) + 300 }, headers: cors });
          if (url.pathname.endsWith('/verify')) {
            current = session('admin', 'aal2');
            return route.fulfill({ json: current, headers: cors });
          }
          if (url.pathname === '/rest/v1/moderation_queue') {
            assert.equal(url.searchParams.get('status'), 'eq.pending');
            return route.fulfill({ body: '', headers: { ...cors, 'content-range': '0-6/7' } });
          }
          errors.push(`Unexpected API request: ${url.pathname}`);
          return route.fulfill({ status: 400, json: { message: 'Unexpected smoke request' }, headers: cors });
        });
        const page = await context.newPage();
        page.on('pageerror', error => errors.push(error.stack || error.message));
        page.on('requestfailed', request => errors.push(`${request.url()}: ${request.failure()?.errorText}`));
        page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
        const waitText = async text => {
          try {
            await page.getByText(text, { exact: true }).waitFor({ timeout: 15000 });
          } catch (error) {
            await page.screenshot({ path: path.join(output, `${name}-failure.png`) });
            await fs.writeFile(path.join(output, `${name}-failure.json`), JSON.stringify({ errors, requests, html: await page.content() }, null, 2));
            throw error;
          }
        };
        const enterText = async value => {
          // Flutter attaches editing listeners in the semantics update after focus.
          // Wait for that frame before dispatching input, as a real user would.
          await page.getByRole('textbox').last().click();
          await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
          const editor = page.getByRole('textbox').last();
          await editor.fill(value);
          await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
          await editor.press('Tab');
        };
        await page.goto(base, { waitUntil: 'networkidle' });
        await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached' });
        await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
        const heading = scenario === 'login' ? '登入管理介面' : scenario === 'denied' ? '這個帳號沒有管理權限' : scenario === 'mfa' ? '請先完成第二步驗證' : '待審回報';
        await waitText(heading);
        assert.equal(await page.title(), '停車指南管理');
        assert.match(await page.locator('meta[name=robots]').getAttribute('content'), /noindex/);
        if (scenario === 'shell') {
          await waitText('有 7 筆回報等待確認');
          await page.screenshot({ path: path.join(output, `${name}.png`) });
          for (const [label, title] of [['點位', '停車點位'], ['規則', '各縣市停車規則'], ['匯入', '匯入停車資料'], ['使用者', '使用者管理'], ['審核', '待審回報']]) {
            await page.getByRole('button', { name: label === '審核' ? /^審核/ : label, exact: true }).click();
            await waitText(title);
          }
        }
        if (scenario === 'denied' || scenario === 'login' || scenario === 'mfa') {
          assert(!requests.some(value => value.includes('/rest/v1/')), `${name} must not query admin data`);
        }
        await page.screenshot({ path: path.join(output, `${name}.png`) });
        if (scenario === 'mfa') {
          await enterText('123456');
          await page.getByRole('button', { name: '確認驗證碼', exact: true }).click();
          await waitText('待審回報');
        }
        if (scenario === 'shell') {
          await page.getByRole('button', { name: /帳號安全/ }).click();
          await waitText('管理驗證方式');
          await page.getByRole('button', { name: '登記另一個驗證方式', exact: true }).click();
          await enterText('備援驗證器');
          await page.getByRole('button', { name: '開始登記', exact: true }).click();
          await waitText('驗證新登記的方式');
          await page.getByRole('button', { name: '顯示密鑰', exact: true }).click();
          await page.getByRole('button', { name: '隱藏密鑰', exact: true }).click();
          await page.getByRole('button', { name: '取消這次登記', exact: true }).click();
          await waitText('已登記的驗證方式');
          await page.getByRole('button', { name: '登出', exact: true }).click();
          await waitText('登入管理介面');
          assert.equal(await page.evaluate(() => localStorage.getItem('sb-admin-smoke-auth-token')), null);
        }
        await page.keyboard.press('Tab');
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
        assert.deepEqual(errors, [], `${name} console errors`);
        if (scenario === 'login') {
          await page.getByRole('button', { name: /使用 Google 帳號登入/ }).click();
          await page.getByText('Google OAuth smoke callback', { exact: true }).waitFor();
        }
        results.push({ name, consoleErrors: errors.length });
        console.log(`Passed ${name}`);
        await context.close();
      }
    }
    await fs.writeFile(path.join(output, 'results.json'), JSON.stringify(results, null, 2));
    console.log(`Passed ${results.length} Chromium scenarios; screenshots: artifacts/admin-smoke/`);
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
