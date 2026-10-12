import {
  cities,
  fetchRows,
  type Row,
} from '../supabase/functions/_shared/tdx.ts';
import {
  count,
  validPosition,
} from '../supabase/functions/tdx-parking/normalize.ts';

if (!Deno.env.get('TDX_CLIENT_ID') || !Deno.env.get('TDX_CLIENT_SECRET')) {
  throw new Error(
    'Set TDX_CLIENT_ID and TDX_CLIENT_SECRET before the live audit.',
  );
}
const output = Deno.args[0] ?? 'docs/tdx-coverage.md';
const lines = [
  '# TDX 資料完整性稽核',
  `\n執行時間：${
    new Date().toISOString()
  }。僅記錄實際 API 回應；端點錯誤不視為零筆。`,
  '\n| 縣市 | 路外場數 | 有機車格 | 無效座標 | 機車即時／資料列 | 超過 5 分鐘 | 路邊路段 | 路邊機車資料列 | 狀態 |',
  '|---|---:|---:|---:|---:|---:|---:|---:|---|',
];
const samples: string[] = [];
const spaces = (row: Row): Row[] =>
  Array.isArray(row.Spaces) ? row.Spaces as Row[] : [];
const moto = (row: Row) => spaces(row).some((s) => Number(s.SpaceType) === 2);
for (const city of cities) {
  const kinds = [
    'OffStreet/CarPark',
    'OffStreet/ParkingSpace',
    'OffStreet/ParkingAvailability',
    'OnStreet/ParkingSegment',
    'OnStreet/ParkingSpace',
    'OnStreet/ParkingAvailability',
  ];
  const data: (Row[] | null)[] = [];
  const errors: string[] = [];
  // Sequential requests keep the audit gentle on TDX quotas.
  for (const kind of kinds) {
    try {
      data.push(await fetchRows(city, kind));
    } catch (error) {
      data.push(null);
      errors.push(error instanceof Error ? error.message : 'request failed');
    }
  }
  const [parks, totals, live, segments, roadSpaces, roadLive] = data;
  const invalid = parks?.filter((r) => {
    const p = r.CarParkPosition as Row | undefined;
    return !validPosition(p?.PositionLat, p?.PositionLon);
  }).length;
  const availability = live?.filter((r) =>
    spaces(r).some((s) =>
      Number(s.SpaceType) === 2 && count(s.AvailableSpaces) !== null
    )
  );
  const stale = availability?.filter((r) => {
    const time = Date.parse(String(r.DataCollectTime ?? r.UpdateTime ?? ''));
    return !Number.isFinite(time) || Date.now() - time > 300_000;
  }).length;
  const show = (n: number | undefined) =>
    n === undefined ? '未取得' : String(n);
  lines.push(
    `| ${city} | ${show(parks?.length)} | ${
      show(totals?.filter(moto).length)
    } | ${show(invalid)} | ${show(availability?.length)} / ${
      show(live?.length)
    } | ${show(stale)} | ${show(segments?.length)} | ${
      show(roadSpaces?.filter(moto).length)
    } / ${show(roadLive?.filter(moto).length)} | ${
      errors.join('; ') || '回應成功'
    } |`,
  );
  if (
    ['Taipei', 'NewTaipei', 'Taichung', 'Kaohsiung', 'TaitungCounty'].includes(
      city,
    )
  ) {
    const ids = new Set(totals?.filter(moto).map((r) => r.CarParkID));
    const park = parks?.find((r) => ids.has(r.CarParkID));
    if (park) {
      samples.push(
        `- ${city}：${
          JSON.stringify({ id: park.CarParkID, name: park.CarParkName })
        }。縣市資料交叉核對尚待人工完成。`,
      );
    }
  }
}
lines.push(
  '\n## 縣市資料交叉核對',
  ...samples,
  '\n抽樣尚未等同交叉核對。須核對官方總格數、座標與資料日期後，才決定各縣市 adapter 的採用範圍。',
);
await Deno.writeTextFile(output, lines.join('\n') + '\n');
console.log(`Wrote live audit: ${output}`);
