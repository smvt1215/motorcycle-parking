# 管理站（React + Redux Toolkit）

Flutter 管理站（`lib/admin/`）的改寫版本，依 [`../DESIGN.md`](../DESIGN.md)（設計稿畫布 Version 49）實作。計畫見 #195 的 P7 與 [`docs/ADMIN_WEB.md`](../../docs/ADMIN_WEB.md)。

目前有：

- 前端基礎層：設計 token、疊牌、地圖標記、基本元件、導覽外框與 `/design` 樣式頁。
- 審核頁：佇列、類型篩選、詳情（資格車牌、差異表、騎士說明、處理說明、脈絡）、套用建議（A）、修改後套用（E）、駁回（R）、跳過（J）、處理完自動跳下一筆、5 秒內可復原，以及載入、空、失敗、版本衝突狀態。
  - 駁回：六種原因必選（`1`–`6` 直接選、Enter 確定、Esc 取消），「其他原因」要寫處理說明；手機是底部 sheet。點位不會改變。
  - 修改後套用：車牌選可停或不可停，其他欄位在「套用值」欄編輯，每格下方寫騎士原本的建議；Ctrl Enter 儲存並套用、Esc 取消。只寫入和目前點位不同的欄位；沒有不同就不能儲存。

正式建置還沒有資料來源，各頁顯示「這一頁還沒接上資料」，等 `admin_v1`（#195）完成後再接上。開發時用 `--mode fixture` 載入記憶體內的示範資料（`src/review/fixtureSource.ts`），頁面會標示「示範資料，不會寫入伺服器」。

## 指令

需要 Node 24。

```sh
npm ci
npm run dev                 # 開發伺服器（沒有資料來源）
npm run dev -- --mode fixture  # 開發伺服器＋示範資料
npm test                    # Vitest（含 tokens.css 與 DESIGN.md 的比對）
npm run lint                # ESLint
npm run format:check        # Prettier
npm run build               # tsc -b ＋ Vite，輸出 dist/（不含示範資料）
npm run build:fixture       # 含示範資料，輸出 dist-fixture/（只供本機與 smoke）
npm run smoke               # 先 build:fixture；Chromium 檢查 RWD 與互動，截圖存到 artifacts/smoke/
```

`npm run smoke` 需要 Playwright 的 Chromium（`npx playwright install chromium-headless-shell`），只在本機跑，不在 CI 跑。它會在 320／390／402（iPhone 16 Pro）／700／820、1180（iPad Air）／1024（13 吋）／1440 寬度檢查：

- 不能橫向捲動。
- 分頁數：手機 4 個（手機的審核詳情 0 個），其他 5 個。
- 導覽與按鈕的觸控目標至少 44px。
- 每頁只有一個目前分頁。
- 實際操作：輸入中文處理說明、按 A 套用後跳下一筆並出現復原、按復原回到原本那筆且說明還在；手機清單列就地展開。

CI 會確認 `dist/` 裡沒有示範資料（`MOTOPARK_ADMIN_FIXTURE_DATA` 標記與示範點位名稱）。

## 目錄

| 路徑                    | 內容                                                                                                  |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| `src/design/tokens.css` | DESIGN.md frontmatter 的 token；名稱一一對應（`colors.x` → `--color-x`）。改 token 時先改 DESIGN.md   |
| `src/ui/`               | 疊牌 `PlateStack`／`EligibilityPair`、A0 `MapMarker`、按鈕、篩選 chip、分段控制、狀態標籤、空狀態     |
| `src/shell/`            | 導覽外框：≥1040px 96px 導覽欄、680–1039px 上方分頁、<680px 頂欄＋底部分頁（匯入、使用者收在「更多」） |
| `src/app/`              | Redux store、RTK Query `adminApi`（資料來源由 store 的 extra 參數注入）、路由                         |
| `src/review/`           | 審核頁：資料模型（照 Flutter `review_models.dart`）、資料來源介面、示範資料、延後送出與復原、元件     |
| `src/pages/`            | 其他功能頁與 `/design` 樣式頁                                                                         |

## 審核頁的資料規則

- 「套用建議」延後 5 秒才送出；期間按「復原」直接取消，不需要伺服器支援撤銷（Flutter 版同樣是延後送出）。關閉分頁前若還有沒送出的處理，瀏覽器會先詢問。
- 送出的欄位只限這個點位接受的欄位（社群點用 `status`、官方點用 `hidden` 隱藏）。
- 含費率、停放條件、暫時封閉、分區或路邊分段的建議，這裡**不套用**：Flutter 版送出前會把費率依車種與現有費率合併並重算收費文字，原樣送出可能清掉另一種車的費率。這部分等 #195 的共用核心接上後再開放。
- 寫入失敗時，那筆回到佇列並標示「沒有套用」，處理說明保留；版本衝突時要先重新讀取最新資料，才能選「仍然套用」。

## 規則

- 只用 DESIGN.md 的 token；車牌的綠、白、紅、黃只出現在車牌上，操作藍只給按得下去的東西，反光黃只表示「已修改」。
- 資格永遠成對顯示：普通機車在左、大型重機在右，`aria-label` 寫出完整狀態。
- 正式建置不放示範資料；示範資料只在 `--mode fixture` 出現，並標明是示範資料。
- 不要把 App 的 IconScout 重機圖示放進這裡。
