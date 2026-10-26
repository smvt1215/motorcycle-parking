import { type Caller, type Deps, handle, LimitReached } from './handler.ts';
import {
  cacheKey,
  type Candidate,
  parseQuery,
  ProviderError,
  readRequest,
  shape,
} from './query.ts';

Deno.test('「與」、& 與兩個路名之間的空格都是路口', () => {
  for (
    const q of [
      '忠孝東路四段與敦化南路',
      '忠孝東路四段 & 敦化南路',
      '忠孝東路四段＆敦化南路一段',
      '忠孝東路四段 敦化南路',
      '忠孝東路四段與敦化南路口',
    ]
  ) {
    const p = parseQuery(q);
    assertEquals(p.kind, 'intersection', q);
    if (p.kind === 'intersection') {
      assertEquals(p.roads[0], '忠孝東路四段', q);
      assertEquals(p.text.includes(' & '), true, q);
    }
  }
});

Deno.test('門牌、路段與帶空格的地址不是路口', () => {
  for (
    const q of [
      '臺北市中正區忠孝西路一段49號',
      '台北市 忠孝西路一段49號',
      '忠孝東路 4段',
      '和平東路二段',
      '忠孝西路一段49號 & 重慶南路',
      '台北市 中正區 重慶南路',
    ]
  ) {
    assertEquals(parseQuery(q).kind, 'text', q);
  }
});

Deno.test('全形字轉半形、空白合併', () => {
  assertEquals(parseQuery('　忠孝西路一段４９號  ').text, '忠孝西路一段49號');
});

Deno.test('快取鍵只含查詢與約 5 km 的偏好位置', () => {
  const q = parseQuery('中山北路與南京東路');
  assertEquals(
    cacheKey(q, { lat: 25.0521, lng: 121.5201 }),
    cacheKey(q, { lat: 25.0539, lng: 121.5188 }),
  );
  assertEquals(cacheKey(q), 'intersection|中山北路 & 南京東路|-');
});

Deno.test('請求檢查：字數與座標', () => {
  assertEquals(readRequest({ query: 'a' }), 'invalid_query');
  assertEquals(readRequest({ query: 'x'.repeat(101) }), 'invalid_query');
  assertEquals(readRequest({ query: ['中山北路'] }), 'invalid_query');
  assertEquals(
    readRequest({ query: '中山北路', near: { lat: '25', lng: 121 } }),
    'invalid_query',
  );
  const ok = readRequest({ query: '中山北路', near: { lat: 25, lng: 121.5 } });
  assertEquals(typeof ok === 'object' && ok.near, { lat: 25, lng: 121.5 });
});

const at = (label: string, lat = 25.05, lng = 121.52): Candidate => ({
  kind: 'address',
  label,
  lat,
  lng,
  precision: 'exact',
});

Deno.test('候選：去掉台灣以外、重複與空白，最多 5 筆', () => {
  const out = shape([
    at('那霸', 26.2, 127.68),
    at('A'),
    at('A'),
    at('  '),
    at('B', 25.06),
    at('C', 25.07),
    at('D', 25.08),
    at('E', 25.09),
    at('F', 25.1),
  ]);
  assertEquals(out.map((c) => c.label), ['A', 'B', 'C', 'D', 'E']);
});

const rider: Caller = { id: 'u1', admin: false };
function deps(over: Partial<Deps> = {}): Deps & { stored: string[] } {
  const stored: string[] = [];
  return {
    stored,
    caller: (token) => Promise.resolve(token === 'good' ? rider : null),
    begin: () => Promise.resolve(null),
    store: (key) => {
      stored.push(key);
      return Promise.resolve();
    },
    provider: () => Promise.resolve([at('臺北市中正區忠孝西路一段49號')]),
    ...over,
  };
}
const post = (body: unknown, token = 'good') =>
  new Request('http://local/geocode', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
async function call(d: Deps, req: Request) {
  const res = await handle(req, d);
  return { status: res.status, body: await res.json() };
}

Deno.test('查到後回傳候選並寫入快取', async () => {
  const d = deps();
  const r = await call(d, post({ query: '忠孝西路一段49號' }));
  assertEquals(r.status, 200);
  assertEquals(r.body.kind, 'text');
  assertEquals(r.body.candidates[0].label, '臺北市中正區忠孝西路一段49號');
  assertEquals(d.stored, ['text|忠孝西路一段49號|-']);
});

Deno.test('快取命中不呼叫定位服務', async () => {
  let called = false;
  const d = deps({
    begin: () => Promise.resolve([at('快取')]),
    provider: () => {
      called = true;
      return Promise.resolve([]);
    },
  });
  const r = await call(d, post({ query: '中山北路與南京東路' }));
  assertEquals([r.body.kind, r.body.candidates[0].label], [
    'intersection',
    '快取',
  ]);
  assertEquals(called, false);
});

Deno.test('錯誤代碼', async () => {
  const cases: [Deps, Request, number, string][] = [
    [deps(), post({ query: '中山北路' }, 'bad'), 401, 'sign_in_required'],
    [
      deps({ provider: null }),
      post({ query: '中山北路' }),
      503,
      'not_configured',
    ],
    [deps(), post({ query: '' }), 400, 'invalid_query'],
    [
      deps({ begin: () => Promise.reject(new LimitReached()) }),
      post({ query: '中山北路' }),
      429,
      'daily_limit',
    ],
    [
      deps({ provider: () => Promise.reject(new ProviderError('quota')) }),
      post({ query: '中山北路' }),
      503,
      'service_limit',
    ],
    [
      deps({
        provider: () => Promise.reject(new ProviderError('unavailable')),
      }),
      post({ query: '中山北路' }),
      502,
      'unavailable',
    ],
    [
      deps({ caller: () => Promise.reject(new Error('auth down')) }),
      post({ query: '中山北路' }),
      503,
      'unavailable',
    ],
  ];
  for (const [d, req, status, error] of cases) {
    const r = await call(d, req);
    assertEquals([r.status, r.body.error], [status, error], error);
  }
  const noAuth = await handle(
    new Request('http://local/geocode', { method: 'POST', body: '{}' }),
    deps(),
  );
  assertEquals(noAuth.status, 401);
});

Deno.test('快取寫入失敗仍回傳結果', async () => {
  const d = deps({ store: () => Promise.reject(new Error('db down')) });
  const r = await call(d, post({ query: '中山北路' }));
  assertEquals(r.status, 200);
});

// Structural equality through JSON is enough for these plain values.
function assertEquals(actual: unknown, expected: unknown, message = '') {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}
