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

const communityId = '33333333-3333-4333-8333-333333333333';
const officialId = '44444444-4444-4444-8444-444444444444';
const reports = [
  { id: '55555555-5555-4555-8555-555555555551', source_id: communityId, reason: '格位類型：建議「重機專用格」', field: 'space_type', proposed: { space_type: 'heavyOnly' }, note: '現場已改漆重機專用格標線，地面有「大型重機」字樣。', created_at: '2026-10-24T06:00:00Z', base_spot: { space_type: 'freeMotorcycle' } },
  { id: '55555555-5555-4555-8555-555555555552', source_id: `official:${officialId}`, reason: '機車停放資格：建議「普通機車可停 · 大型重機不可停」', field: 'eligibility', proposed: { heavy_allowed: false }, note: '', created_at: '2026-10-24T07:00:00Z' },
  { id: '55555555-5555-4555-8555-555555555553', source_id: `official:${officialId}`, reason: '點位已不存在：入口封閉', field: 'gone', proposed: { hidden: true }, note: '入口已封閉施工，現場無法進入。', created_at: '2026-10-24T08:00:00Z' },
];
const spot = { lat: 25.0581, lng: 121.5226, city: '臺北市', district: '中山區', fee_note: '每小時 20 元', note: '', scooter_allowed: true, heavy_allowed: null, source_name: '', updated_at: '2026-10-23T00:00:00Z',
  address: '', road_segment: '', entrance_note: '', parking_guide: '', special_rules: '', facility_type: null, parking_access: null, scooter_total: null };
const communitySpot = { ...spot, id: communityId, name: '中山北路二段路邊機車格', space_type: 'paidMotorcycle', status: 'pending' };
const officialSpot = { ...spot, id: officialId, name: '新北市政府行政大樓地下停車場', city: '新北市', district: '板橋區', lat: 25.0124, lng: 121.4651, space_type: 'offStreet', heavy_allowed: true, source_name: '新北市政府', hidden: false,
  address: '新北市板橋區中山路一段 161 號', facility_type: 'underground', parking_access: 'scooterHeavy', source_url: 'https://example.test/notice', source_id: 'ntpc-001', effective_date: '2026-01-01', license_note: '' };
const riderId = '77777777-7777-4777-8777-777777777777';
const rider = { id: riderId, display_name: '夜騎小哲', email_masked: 'ri***@example.test', providers: ['google'], is_admin: false,
  created_at: '2026-09-01T00:00:00Z', last_sign_in_at: '2026-10-24T01:00:00Z', banned_until: null, deleted: false, reports_30d: 12, last_report_at: '2026-10-24T02:00:00Z' };
const riderDetail = banned => ({
  user: { ...rider, banned_until: banned },
  limits: { today: 3, daily_limit: 10, last_7d: 9, last_30d: 12, networks_30d: 2, shared_accounts_30d: 1 },
  events: [{ created_at: '2026-10-24T02:00:00Z', network: 'a1b2c3' }, { created_at: '2026-10-23T02:00:00Z', network: 'd4e5f6' }],
  reports: { spots: 2, spots_hidden: 1, votes_still_there: 5, votes_gone: 1, flags_pending: 1, flags_accepted: 2, flags_rejected: 3, flags_closed: 0 },
  spots: [{ id: communityId, name: '中山北路二段路邊機車格', city: '臺北市', district: '中山區', status: 'confirmed', contributor_name: '夜騎小哲', name_cleared: false }],
  history: banned ? [{ action: 'ban_user', note: '短時間內大量重複回報', created_at: '2026-10-25T00:00:00Z', banned_until: banned }] : [],
});
const hiddenSpot = { ...spot, id: '66666666-6666-4666-8666-666666666666', name: '三重正義北路機車格', city: '新北市', district: '三重區', space_type: 'freeMotorcycle', status: 'hidden' };

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
      for (const scenario of ['login', 'denied', 'mfa', 'unfinished', 'shell']) {
        const name = `${scenario}-${mobile ? 'mobile-dark' : 'desktop'}`;
        const context = await browser.newContext({
          viewport: mobile ? { width: 390, height: 844 } : { width: 1440, height: 960 },
          colorScheme: mobile ? 'dark' : 'light', reducedMotion: 'reduce',
          // A shell locale such as C.UTF-8 gives Chromium an invalid language tag.
          locale: 'zh-TW',
        });
        let current = scenario === 'login' ? null : session(scenario === 'denied' ? 'rider' : 'admin', scenario === 'mfa' || scenario === 'unfinished' ? 'aal1' : 'aal2', scenario === 'unfinished' ? [{ ...factor, status: 'unverified' }] : [factor]);
        if (current) await context.addInitScript(value => {
          localStorage.setItem('sb-admin-smoke-auth-token', JSON.stringify(value));
        }, current);
        const errors = [];
        const requests = [];
        let conflicts = 0;
        let riderBan = null;
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
          if (url.pathname.startsWith('/auth/v1/factors/') && route.request().method() === 'DELETE') {
            const id = url.pathname.split('/').at(-1);
            current.user.factors = current.user.factors.filter(value => value.id !== id);
            return route.fulfill({ json: { id }, headers: cors });
          }
          if (url.pathname.endsWith('/challenge')) return route.fulfill({ json: { id: 'smoke-challenge', expires_at: Math.floor(Date.now() / 1000) + 300 }, headers: cors });
          if (url.pathname.endsWith('/verify')) {
            current = session('admin', 'aal2');
            return route.fulfill({ json: current, headers: cors });
          }
          if (url.pathname === '/rest/v1/moderation_queue') {
            assert.equal(url.searchParams.get('status'), 'eq.pending');
            if (url.searchParams.get('select')?.includes('source_id')) return route.fulfill({ json: reports, headers: cors });
            return route.fulfill({ body: '', headers: { ...cors, 'content-range': '0-2/3' } });
          }
          if (url.pathname === '/rest/v1/community_spots') {
            if ((route.request().headers().accept || '').includes('vnd.pgrst.object')) return route.fulfill({ json: communitySpot, headers: cors });
            return route.fulfill({ json: url.searchParams.get('status') === 'eq.hidden' ? [hiddenSpot] : [communitySpot], headers: cors });
          }
          if (url.pathname === '/rest/v1/official_heavy_spots') {
            // maybeSingle() asks for one object instead of an array.
            if ((route.request().headers().accept || '').includes('vnd.pgrst.object')) return route.fulfill({ json: officialSpot, headers: cors });
            return route.fulfill({ json: url.searchParams.get('hidden') === 'eq.true' ? [] : [officialSpot], headers: cors });
          }
          if (url.pathname === '/rest/v1/rpc/admin_spots') {
            return route.fulfill({ json: [communitySpot, officialSpot].map(spot => ({
              source_id: spot === officialSpot ? `official:${spot.id}` : spot.id, kind: spot === officialSpot ? 'official' : 'community',
              name: spot.name, city: spot.city, district: spot.district, address: spot.address, space_type: spot.space_type,
              state: spot === officialSpot ? 'visible' : spot.status, lat: spot.lat, lng: spot.lng, updated_at: spot.updated_at,
            })), headers: cors });
          }
          if (url.pathname === '/rest/v1/rpc/admin_upsert_spot') {
            // Verifying the stored vehicle access restates it unchanged.
            const { p_source_id: sourceId, p_values: values, p_note: note } = route.request().postDataJSON();
            assert.equal(sourceId, communityId);
            assert.deepEqual(values, { scooter_allowed: true });
            assert.equal(note, '核驗目前車種');
            return route.fulfill({ json: { ...communitySpot, ...values, scooter_verified_at: '2026-10-25T01:19:36Z', updated_at: '2026-10-25T01:19:36Z' }, headers: cors });
          }
          if (url.pathname === '/rest/v1/rpc/admin_resolve_report' && !route.request().postDataJSON().p_force) {
            // The spot changed after the report: the admin must review and force.
            conflicts++;
            return route.fulfill({ status: 400, json: { code: '40001', message: 'spot changed since the report' }, headers: cors });
          }
          if (url.pathname === '/rest/v1/rpc/admin_resolve_report' || url.pathname === '/rest/v1/rpc/admin_set_spot_hidden') {
            return route.fulfill({ json: {}, headers: cors });
          }
          if (url.pathname === '/rest/v1/rpc/admin_users') return route.fulfill({ json: [{ ...rider, banned_until: riderBan }], headers: cors });
          if (url.pathname === '/rest/v1/rpc/admin_user_detail') {
            assert.equal(route.request().postDataJSON().p_user, riderId);
            return route.fulfill({ json: riderDetail(riderBan), headers: cors });
          }
          if (url.pathname === '/functions/v1/admin-users') {
            const body = route.request().postDataJSON();
            assert.deepEqual(body, { action: 'ban', user_id: riderId, duration: '7d', reason: '短時間內大量重複回報' });
            riderBan = '2026-11-01T00:00:00Z';
            return route.fulfill({ json: { user_id: riderId, banned_until: riderBan }, headers: cors });
          }
          errors.push(`Unexpected API request: ${url.pathname}`);
          return route.fulfill({ status: 400, json: { message: 'Unexpected smoke request' }, headers: cors });
        });
        // The land-survey reverse lookup the location picker calls.
        await context.route('https://api.nlsc.gov.tw/**', route => route.fulfill({
          contentType: 'application/xml; charset=utf-8',
          headers: { 'access-control-allow-origin': '*' },
          body: '<?xml version="1.0" encoding="UTF-8"?><townVillageItem><ctyName>臺北市</ctyName><townName>中山區</townName></townVillageItem>',
        }));
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
        const heading = scenario === 'login' ? '登入管理介面' : scenario === 'denied' ? '這個帳號沒有管理權限' : scenario === 'mfa' || scenario === 'unfinished' ? '請先完成第二步驗證' : '待審回報';
        await waitText(heading);
        assert.equal(await page.title(), '停車指南管理');
        assert.match(await page.locator('meta[name=robots]').getAttribute('content'), /noindex/);
        if (scenario === 'shell') {
          if (mobile) {
            await page.getByRole('button', { name: /^格位類型/ }).waitFor({ timeout: 15000 });
            await page.screenshot({ path: path.join(output, `${name}-queue.png`) });
            await page.getByRole('button', { name: /^格位類型/ }).click();
          }
          await waitText('格位類型的修改建議');
          await waitText('建議變更');
          await page.screenshot({ path: path.join(output, `${name}-review.png`), fullPage: true });
          await page.getByRole('button', { name: '修改後套用', exact: true }).click();
          await waitText('套用修改');
          await page.screenshot({ path: path.join(output, `${name}-edit.png`) });
          await page.getByRole('button', { name: '取消修改', exact: true }).click();
          await page.getByRole('button', { name: '套用建議', exact: true }).click();
          await waitText('已套用建議：中山北路二段路邊機車格');
          await waitText('機車停放資格的修改建議');
          await page.screenshot({ path: path.join(output, `${name}-next.png`) });
          await page.getByRole('button', { name: '復原', exact: true }).click();
          await waitText('格位類型的修改建議');
          if (mobile) await page.getByRole('button', { name: /^返回佇列/ }).click();
          await page.getByRole('button', { name: '已隱藏的點位', exact: true }).click();
          await page.getByRole('button', { name: '恢復顯示', exact: true }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-hidden.png`) });
          await page.getByRole('button', { name: '返回待審回報', exact: true }).click();
          if (mobile) await page.getByRole('button', { name: /^格位類型/ }).click();
          await page.getByRole('button', { name: '套用建議', exact: true }).click();
          await waitText('機車停放資格的修改建議');
          // Past the undo window the write is sent and refused as a conflict.
          if (mobile) await page.getByRole('button', { name: /^返回佇列/ }).click({ delay: 6500 });
          else await page.waitForTimeout(6500);
          await page.getByRole('button', { name: /^格位類型/ }).click();
          await page.getByRole('button', { name: '仍要套用建議', exact: true }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-conflict.png`) });
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${name} conflict view scrolls sideways`);
          await page.getByRole('button', { name: '仍要套用建議', exact: true }).click();
          await waitText('已套用建議：中山北路二段路邊機車格');
          if (mobile) await page.getByRole('button', { name: /^返回佇列/ }).click();
          // Spots page: list, then the official spot's form.
          await page.getByRole('button', { name: '點位', exact: true }).click();
          await page.getByRole('button', { name: /^新北市政府行政大樓地下停車場/ }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-spots.png`) });
          await page.getByRole('button', { name: /^新北市政府行政大樓地下停車場/ }).click();
          await waitText('官方點（新北市政府）');
          await page.screenshot({ path: path.join(output, `${name}-spot-form.png`) });
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${name} spot form scrolls sideways`);
          // A community spot: verify its stored vehicle access as it is.
          if (mobile) await page.getByRole('button', { name: '返回點位清單', exact: true }).click();
          await page.getByRole('button', { name: /^中山北路二段路邊機車格/ }).click();
          await waitText('社群點（社群回報整理）');
          const verify = page.getByRole('button', { name: '核驗目前車種' });
          const box = page.viewportSize();
          // Flutter draws on a canvas: wheel until the button clears the
          // fixed header and the bottom action bar.
          const inView = async () => {
            const at = (await verify.count()) ? await verify.boundingBox() : null;
            return at && at.y > box.height * 0.25 && at.y + at.height < box.height - 180;
          };
          const reachVerify = async () => {
            await page.mouse.move(box.width * (mobile ? 0.5 : 0.65), box.height * 0.5);
            for (let i = 0; i < 40 && !(await inView()); i++) {
              await page.mouse.wheel(0, 120);
              await page.waitForTimeout(100);
            }
            assert.ok(await inView(), `${name} vehicle verification button is reachable`);
          };
          await reachVerify();
          await page.screenshot({ path: path.join(output, `${name}-spot-verify.png`) });
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${name} vehicle verification scrolls sideways`);
          const verified = page.waitForResponse(response => response.url().endsWith('/rpc/admin_upsert_spot'));
          await verify.click();
          await verified;
          // The reloaded form starts at the top again.
          await page.waitForTimeout(500);
          await reachVerify();
          await page.getByRole('group', { name: /普通機車核驗\s+已核驗（2026-10-25）/ }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-spot-verified.png`) });
          // New spot: kind, then a form whose county follows the position.
          if (mobile) {
            const back = page.getByRole('button', { name: '返回點位清單', exact: true });
            for (let i = 0; i < 40 && !(await back.count()); i++) await page.mouse.wheel(0, -200);
            await page.waitForTimeout(300);
            await back.click();
          }
          await page.getByRole('button', { name: '新增停車點', exact: true }).click();
          await page.getByRole('button', { name: /現場確認、尚無官方資料的停車點/ }).click();
          await waitText('新增社群點');
          await page.getByRole('button', { name: '建立停車點', exact: true }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-spot-new.png`) });
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${name} new spot form scrolls sideways`);
          // Scroll the form down to the picker and its notes.
          const viewport = page.viewportSize();
          await page.mouse.move(viewport.width * (mobile ? 0.5 : 0.65), viewport.height * 0.5);
          for (let i = 0; i < 12; i++) await page.mouse.wheel(0, 150);
          await page.waitForTimeout(500);
          await page.screenshot({ path: path.join(output, `${name}-spot-location.png`) });
          // Users page: find a rider, see the quota, ban with a reason.
          await page.getByRole('button', { name: '使用者', exact: true }).click();
          await page.getByRole('button', { name: /^夜騎小哲/ }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-users.png`) });
          await page.getByRole('button', { name: /^夜騎小哲/ }).click();
          await page.getByRole('button', { name: '停權帳號', exact: true }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-user.png`) });
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${name} user page scrolls sideways`);
          await page.getByRole('button', { name: '停權帳號', exact: true }).click();
          await page.getByRole('button', { name: '直到解除', exact: true }).waitFor({ timeout: 15000 });
          await enterText('短時間內大量重複回報');
          await page.screenshot({ path: path.join(output, `${name}-user-ban.png`) });
          const banned = page.waitForResponse(response => response.url().endsWith('/functions/v1/admin-users'));
          await page.getByRole('button', { name: '停權帳號', exact: true }).last().click();
          await banned;
          await page.getByRole('button', { name: '解除停權', exact: true }).waitFor({ timeout: 15000 });
          await page.screenshot({ path: path.join(output, `${name}-user-banned.png`) });
          await page.getByRole('button', { name: '審核', exact: false }).first().click();
          await page.screenshot({ path: path.join(output, `${name}.png`) });
          for (const [label, title] of [['點位', '停車點位'], ['規則', '各縣市停車規則'], ['匯入', '匯入停車資料'], ['使用者', '使用者管理'], ['審核', '待審回報']]) {
            await page.getByRole('button', { name: label === '審核' ? /^審核/ : label, exact: true }).click();
            await waitText(title);
          }
        }
        if (scenario !== 'shell') {
          assert(!requests.some(value => value.includes('/rest/v1/')), `${name} must not query admin data`);
        }
        await page.screenshot({ path: path.join(output, `${name}.png`) });
        if (scenario === 'unfinished') {
          await waitText('未完成的登記');
          await page.getByRole('button', { name: '取消登記', exact: true }).click();
          await page.getByText('未完成的登記', { exact: true }).waitFor({ state: 'hidden' });
          await enterText('手機驗證器');
          await page.getByRole('button', { name: '開始登記', exact: true }).click();
          await waitText('驗證新登記的方式');
        }
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
          // A hovered tooltip may repeat its text in the accessible name.
          await page.getByRole('button', { name: /^顯示密鑰/ }).click();
          await page.getByRole('button', { name: /^隱藏密鑰/ }).click();
          await page.getByRole('button', { name: '取消這次登記', exact: true }).click();
          await waitText('已登記的驗證方式');
          await page.getByRole('button', { name: '登出', exact: true }).click();
          await waitText('登入管理介面');
          assert.equal(await page.evaluate(() => localStorage.getItem('sb-admin-smoke-auth-token')), null);
        }
        await page.keyboard.press('Tab');
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
        // Chromium logs each refused write; only the mocked conflicts may appear.
        const unexpected = errors.filter(e => !e.includes('status of 400'));
        assert.deepEqual(unexpected, [], `${name} console errors`);
        assert.equal(errors.length - unexpected.length, conflicts, `${name} 400 responses`);
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
