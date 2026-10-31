import { useAppDispatch, useAppSelector } from '../app/hooks';
import { vehicleChanged } from '../app/prefsSlice';
import { Button, Chip, ModifiedTag, Segmented, SourceTag, StatusTag } from '../ui/controls';
import { PLATE_STATUSES, STATUS_LABEL, VEHICLE_LABEL, VEHICLES, type Vehicle } from '../ui/eligibility';
import { LineIcon } from '../ui/icons';
import { MapMarker, MARKER_LABEL, MARKER_STATES } from '../ui/MapMarker';
import { PlateStack } from '../ui/PlateStack';
import { Page } from './Page';
import './DesignPage.css';

const SWATCHES = [
  ['rail-black', '壓印黑', '導覽欄、文字、選取框'],
  ['aluminium', '鋁板灰', '頁面底色'],
  ['plate-white', '牌面白', '欄位與面板'],
  ['action-blue', '操作藍', '只給按得下去的東西'],
  ['reflective-yellow', '反光黃', '已修改的欄位'],
  ['destructive', '刪除紅', '駁回、刪除、停權'],
] as const;

const STATUS_NOTE: Partial<Record<(typeof PLATE_STATUSES)[number], string>> = {
  notStated: '只用於官方點：官方資料沒寫',
  legacyUnknown: '只有虛線、沒有問號；編輯時必須改選',
};

/** Living version of the canvas board 「設計基礎」 (Tokens.dc.html). */
export function DesignPage() {
  const vehicle = useAppSelector((state) => state.prefs.vehicle);
  const dispatch = useAppDispatch();

  return (
    <Page title="管理站設計基礎">
      <div className="design-grid">
        <section className="panel design-card" aria-labelledby="design-colors">
          <h2 id="design-colors" className="t-title">
            色彩
          </h2>
          {SWATCHES.map(([token, name, use]) => (
            <div key={token} className="swatch">
              <i style={{ background: `var(--color-${token})` }} aria-hidden="true" />
              <span>
                {name} <span className="num">{token}</span>
                <small className="t-caption">{use}</small>
              </span>
            </div>
          ))}
          <p className="t-caption">車牌的綠、白、紅、黃只出現在車牌本身，沿用 App 的 platesOf。</p>
        </section>

        <section className="panel design-card" aria-labelledby="design-plates">
          <h2 id="design-plates" className="t-title">
            車牌與資格（App 的疊牌）
          </h2>
          <div className="table-scroll">
            <table className="legend-table">
              <thead>
                <tr>
                  <th scope="col">資格</th>
                  {VEHICLES.map((v) => (
                    <th key={v} scope="col">
                      {VEHICLE_LABEL[v]}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {PLATE_STATUSES.map((status) => (
                  <tr key={status}>
                    <th scope="row">
                      {STATUS_LABEL[status]}
                      {STATUS_NOTE[status] && <small className="t-caption">{STATUS_NOTE[status]}</small>}
                    </th>
                    {VEHICLES.map((v) => (
                      <td key={v}>
                        <PlateStack vehicle={v} status={status} />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="t-caption">左普通機車、右大型重機，順序固定；形狀與文字一起表達狀態，不只靠顏色。</p>
        </section>

        <section className="panel design-card" aria-labelledby="design-type">
          <h2 id="design-type" className="t-title">
            字體：三級字級
          </h2>
          <p className="t-headline">頁名與點位名 28</p>
          <p>內文、欄位、按鈕 15，Noto Sans TC</p>
          <p className="t-caption">說明與時間 13</p>
          <p className="num-figure design-row">
            <span>12</span>
            <span>38 m</span>
            <span>10/31 09:12</span>
          </p>
          <p className="t-caption">
            數字、計數、座標用 Barlow Condensed 等寬數字。層級靠字重（400／700／900）與反白。
          </p>
        </section>

        <section className="panel design-card design-card--wide" aria-labelledby="design-controls">
          <h2 id="design-controls" className="t-title">
            按鈕、篩選與標記
          </h2>
          <div className="design-row">
            <Button variant="primary" shortcut="A">
              套用建議
            </Button>
            <Button shortcut="E">修改後套用</Button>
            <Button variant="destructive" shortcut="R">
              駁回
            </Button>
            <Button variant="quiet" shortcut="J">
              跳過
            </Button>
          </div>
          <div className="design-row">
            <ModifiedTag />
            <StatusTag kind="open">正常開放</StatusTag>
            <StatusTag kind="closed">施工中，到 11/14</StatusTag>
            <StatusTag kind="closed">暫時封閉</StatusTag>
            <StatusTag kind="deleted">已刪除，13 天後永久刪除</StatusTag>
            <SourceTag source="community" />
            <SourceTag source="official" />
          </div>
          <div className="design-row">
            <Chip selected count={12}>
              待審
            </Chip>
            <Chip selected={false} count={4}>
              已刪除
            </Chip>
            <Chip kind="toggle" selected>
              官方點
            </Chip>
            <Chip kind="toggle" selected={false}>
              衛星
            </Chip>
          </div>
          <p className="t-caption">
            按鈕 48 px 高、篩選 44 px 高；焦點框 3 px 操作藍；刪除一律保留 14 天，期間可復原。
          </p>
        </section>

        <section className="panel design-card" aria-labelledby="design-markers">
          <h2 id="design-markers" className="t-title">
            地圖標記（App A0）
          </h2>
          <ul className="marker-list">
            {MARKER_STATES.map((state) => (
              <li key={state}>
                <MapMarker state={state} />
                {MARKER_LABEL[state]}
              </li>
            ))}
            <li>
              <MapMarker state="allowed" shared />
              普大共用格
            </li>
            <li>
              <MapMarker state="allowed" selected />
              選取中
            </li>
          </ul>
        </section>

        <section className="panel design-card design-card--wide" aria-labelledby="design-vehicle">
          <h2 id="design-vehicle" className="t-title">
            車種切換
          </h2>
          <Segmented<Vehicle>
            label="車種"
            value={vehicle}
            onChange={(next) => dispatch(vehicleChanged(next))}
            options={VEHICLES.map((v) => ({
              value: v,
              label: VEHICLE_LABEL[v],
              leading: <PlateStack vehicle={v} status="allowed" label={VEHICLE_LABEL[v]} />,
            }))}
          />
          <div className="design-row">
            <PlateStack vehicle={vehicle} status="denied" size="large" label="目前不可停" />
            <LineIcon name="arrow" size={24} strokeWidth={2} className="muted" />
            <PlateStack vehicle={vehicle} status="allowed" size="large" label="建議改為可停" />
            <span className="t-title">建議改為可停</span>
          </div>
        </section>
      </div>
    </Page>
  );
}
