export const cities = [
  'Taipei',
  'NewTaipei',
  'Taoyuan',
  'Taichung',
  'Tainan',
  'Kaohsiung',
  'Keelung',
  'Hsinchu',
  'HsinchuCounty',
  'MiaoliCounty',
  'ChanghuaCounty',
  'NantouCounty',
  'YunlinCounty',
  'Chiayi',
  'ChiayiCounty',
  'PingtungCounty',
  'YilanCounty',
  'HualienCounty',
  'TaitungCounty',
  'KinmenCounty',
  'PenghuCounty',
  'LienchiangCounty',
] as const;
export const cityNames: Record<string, string> = {
  Taipei: '臺北市',
  NewTaipei: '新北市',
  Taoyuan: '桃園市',
  Taichung: '臺中市',
  Tainan: '臺南市',
  Kaohsiung: '高雄市',
  Keelung: '基隆市',
  Hsinchu: '新竹市',
  HsinchuCounty: '新竹縣',
  MiaoliCounty: '苗栗縣',
  ChanghuaCounty: '彰化縣',
  NantouCounty: '南投縣',
  YunlinCounty: '雲林縣',
  Chiayi: '嘉義市',
  ChiayiCounty: '嘉義縣',
  PingtungCounty: '屏東縣',
  YilanCounty: '宜蘭縣',
  HualienCounty: '花蓮縣',
  TaitungCounty: '臺東縣',
  KinmenCounty: '金門縣',
  PenghuCounty: '澎湖縣',
  LienchiangCounty: '連江縣',
};
let token: { value: string; expires: number } | undefined;
let tokenRequest: Promise<string> | undefined;
export async function accessToken(): Promise<string> {
  if (token && token.expires > Date.now() + 60_000) return token.value;
  if (tokenRequest) return tokenRequest;
  tokenRequest = (async () => {
    const id = Deno.env.get('TDX_CLIENT_ID'),
      secret = Deno.env.get('TDX_CLIENT_SECRET');
    if (!id || !secret) throw new Error('TDX credentials missing');
    const res = await fetch(
      'https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'client_credentials',
          client_id: id,
          client_secret: secret,
        }),
        signal: AbortSignal.timeout(20_000),
      },
    );
    if (!res.ok) throw new Error(`TDX auth failed (${res.status})`);
    const j = await res.json();
    token = {
      value: j.access_token,
      expires: Date.now() + Number(j.expires_in) * 1000,
    };
    return token.value;
  })();
  try {
    return await tokenRequest;
  } finally {
    tokenRequest = undefined;
  }
}
export type Row = Record<string, unknown>;
export async function fetchRows(city: string, kind: string): Promise<Row[]> {
  if (!cities.includes(city as typeof cities[number])) {
    throw new Error('unsupported city');
  }
  const bearer = await accessToken();
  const result: Row[] = [];
  for (let skip = 0; skip < 100_000; skip += 1000) {
    const url = new URL(
      `https://tdx.transportdata.tw/api/basic/v1/Parking/${kind}/City/${city}`,
    );
    url.searchParams.set('$format', 'JSON');
    url.searchParams.set('$top', '1000');
    url.searchParams.set('$skip', String(skip));
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${bearer}` },
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new Error(`TDX ${kind} failed (${res.status})`);
    const rows = await res.json() as Row[];
    if (!Array.isArray(rows)) throw new Error('invalid TDX response');
    result.push(...rows);
    if (rows.length < 1000) return result;
  }
  throw new Error('TDX pagination limit exceeded');
}
