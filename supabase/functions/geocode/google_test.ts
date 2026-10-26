import { googleProvider, toCandidate } from './google.ts';
import { parseQuery, ProviderError } from './query.ts';

function assertEquals(actual: unknown, expected: unknown, message = '') {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

// Shapes as the API answered on 2026-10-25 (staging key, language=zh-TW).
const admin = (village: string, district: string, city: string) => [
  { long_name: village, types: ['administrative_area_level_3', 'political'] },
  { long_name: district, types: ['administrative_area_level_2', 'political'] },
  { long_name: city, types: ['administrative_area_level_1', 'political'] },
  { long_name: '台灣', types: ['country', 'political'] },
];
const center = (lat: number, lng: number) => ({
  location: { lat, lng },
  location_type: 'GEOMETRIC_CENTER',
});

Deno.test('門牌：縣市、行政區、路名與號，不含里與郵遞區號', () => {
  const c = toCandidate({
    formatted_address: '10041台灣臺北市中正區黎明里忠孝西路一段49號',
    types: ['premise', 'street_address'],
    address_components: [
      { long_name: '49號', types: ['street_number'] },
      { long_name: '忠孝西路一段', types: ['route'] },
      ...admin('黎明里', '中正區', '臺北市'),
    ],
    geometry: center(25.046396, 121.517641),
  }, parseQuery('臺北市中正區忠孝西路一段49號'));
  assertEquals(c, {
    kind: 'address',
    label: '臺北市中正區忠孝西路一段49號',
    lat: 25.046396,
    lng: 121.517641,
    precision: 'center',
  });
  const hsinchu = toCandidate({
    formatted_address: '302台灣新竹縣竹北市北崙里光明六路10號',
    types: ['premise', 'street_address'],
    address_components: [
      { long_name: '10', types: ['street_number'] },
      { long_name: '光明六路', types: ['route'] },
      ...admin('北崙里', '竹北市', '新竹縣'),
    ],
    geometry: {
      location: { lat: 24.8275, lng: 121.0133 },
      location_type: 'ROOFTOP',
    },
  }, parseQuery('新竹縣竹北市光明六路10號'));
  assertEquals([hsinchu?.label, hsinchu?.precision], [
    '新竹縣竹北市光明六路10號',
    'exact',
  ]);
});

Deno.test('路口：英文名稱改用騎士輸入的路名，縣市行政區另列', () => {
  const c = toCandidate({
    formatted_address:
      'Yongkang St & Section 2, Xinyi Rd, 福住里大安區臺北市台灣 106',
    types: ['intersection'],
    address_components: [
      {
        long_name: 'Yongkang Street & Section 2, Xinyi Road',
        types: ['intersection'],
      },
      ...admin('福住里', '大安區', '臺北市'),
    ],
    geometry: center(25.033641, 121.529972),
  }, parseQuery('台北市 永康街 & 信義路二段'));
  assertEquals([c?.kind, c?.label, c?.place, c?.precision], [
    'intersection',
    '永康街與信義路二段',
    '臺北市大安區',
    'center',
  ]);
});

Deno.test('行政區只依結果確認的名稱移除，不吞掉路名', () => {
  const c = toCandidate({
    types: ['intersection'],
    address_components: [
      { long_name: 'Zhenzhong Road & Xinsheng Road', types: ['intersection'] },
      ...admin('鎮中里', '前鎮區', '高雄市'),
    ],
    geometry: center(22.6, 120.32),
  }, parseQuery('高雄市前鎮區鎮中路與新生路'));
  assertEquals([c?.label, c?.place], ['鎮中路與新生路', '高雄市前鎮區']);
  // A district the result does not name stays in the label.
  const unnamed = toCandidate({
    types: ['intersection'],
    address_components: [
      { long_name: 'Zhenzhong Road & Xinsheng Road', types: ['intersection'] },
    ],
    geometry: center(22.6, 120.32),
  }, parseQuery('高雄市前鎮區鎮中路與新生路'));
  assertEquals([unnamed?.label, unnamed?.place], [
    '前鎮區鎮中路與新生路',
    '高雄市',
  ]);
});

Deno.test('不相交的兩條路：Google 回的巷口不是所問的路口', () => {
  const c = toCandidate({
    types: ['intersection'],
    address_components: [
      {
        long_name:
          "Lane 151, Section 4, Ren'ai Road & Section 4, Zhongxiao East Road",
        types: ['intersection'],
      },
      ...admin('建倫里', '大安區', '臺北市'),
    ],
    geometry: center(25.041376, 121.551807),
  }, parseQuery('忠孝東路四段與仁愛路四段'));
  assertEquals(c, null);
  const asked = toCandidate({
    types: ['intersection'],
    address_components: [
      {
        long_name: 'Yongkang Street & Lane 31, Yongkang Street',
        types: ['intersection'],
      },
      ...admin('福住里', '大安區', '臺北市'),
    ],
    geometry: center(25.031305, 121.529511),
  }, parseQuery('永康街31巷與永康街'));
  assertEquals(asked?.label, '永康街31巷與永康街');
});

Deno.test('路段：英文名稱改用輸入的路名；只是某條巷子時略過', () => {
  const road = toCandidate({
    formatted_address: 'Taiwan Blvd Sec 3',
    types: ['route'],
    address_components: [{
      long_name: 'Taiwan Boulevard Section 3',
      types: ['route'],
    }],
    geometry: center(24.167898, 120.641076),
  }, parseQuery('台中市西屯區臺灣大道三段'));
  // Without components naming the district, only the county is removed.
  assertEquals([road?.kind, road?.label, road?.place], [
    'road',
    '西屯區臺灣大道三段',
    '臺中市',
  ]);
  const lane = toCandidate({
    formatted_address: 'Lane 451, Section 6, Nanjingdong Road',
    types: ['route'],
    address_components: [{
      long_name: 'Lane 451, Section 6, Nanjingdong Road',
      types: ['route'],
    }],
    geometry: center(25.061627, 121.586783),
  }, parseQuery('南京東路'));
  assertEquals(lane, null);
  const roadForCrossing = toCandidate({
    types: ['route'],
    address_components: [{ long_name: 'Yongkang Street', types: ['route'] }],
    geometry: center(25.03, 121.53),
  }, parseQuery('永康街與不存在路'));
  assertEquals(roadForCrossing, null);
  const missingDoor = toCandidate({
    types: ['route'],
    address_components: [{ long_name: 'Some Road', types: ['route'] }],
    geometry: center(23, 120.17),
  }, parseQuery('不存在路99號'));
  assertEquals(missingDoor, null);
});

function fake(status: number, body: unknown, seen: string[] = []) {
  return ((url: string) => {
    seen.push(url);
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as unknown as typeof fetch;
}

Deno.test('請求帶語言、地區、國家限制與偏好範圍', async () => {
  const seen: string[] = [];
  const search = googleProvider(
    'k',
    fake(200, { status: 'ZERO_RESULTS' }, seen),
  );
  assertEquals(
    await search(parseQuery('中山北路與南京東路'), { lat: 25, lng: 121.5 }),
    [],
  );
  const url = new URL(seen[0]);
  assertEquals(url.searchParams.get('address'), '中山北路 & 南京東路');
  assertEquals(url.searchParams.get('language'), 'zh-TW');
  assertEquals(url.searchParams.get('components'), 'country:TW');
  assertEquals(url.searchParams.get('bounds'), '24.9,121.4|25.1,121.6');
});

Deno.test('配額用完與服務錯誤分開回報', async () => {
  const reason = async (status: number, body: unknown) => {
    try {
      await googleProvider('k', fake(status, body))(parseQuery('中山北路'));
      return 'none';
    } catch (e) {
      return e instanceof ProviderError ? e.reason : 'other';
    }
  };
  assertEquals(await reason(200, { status: 'OVER_QUERY_LIMIT' }), 'quota');
  assertEquals(await reason(200, { status: 'OVER_DAILY_LIMIT' }), 'quota');
  assertEquals(await reason(200, { status: 'REQUEST_DENIED' }), 'unavailable');
  assertEquals(await reason(500, {}), 'unavailable');
});
