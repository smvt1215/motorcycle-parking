# 管理站（React + Redux Toolkit）

Flutter 管理站（`lib/admin/`）的改寫版本，依 [`../DESIGN.md`](../DESIGN.md)（設計稿畫布 Version 49）實作。計畫見 #195 的 P7 與 [`docs/ADMIN_WEB.md`](../../docs/ADMIN_WEB.md)。

目前有：

- 前端基礎層：設計 token、疊牌、地圖標記、基本元件、導覽外框與 `/design` 樣式頁。
- 審核頁：佇列、類型篩選、詳情（資格車牌、差異表、騎士說明、處理說明、脈絡）、套用建議（A）、修改後套用（E）、駁回（R）、跳過（J）、處理完自動跳下一筆、5 秒內可復原，以及載入、空、失敗、版本衝突狀態。
  - 駁回：六種原因必選（`1`–`6` 直接選、Enter 確定、Esc 取消），「其他原因」要寫處理說明；手機是底部 sheet。點位不會改變。
  - 修改後套用：車牌選可停或不可停，其他欄位在「套用值」欄編輯，每格下方寫騎士原本的建議；Ctrl Enter 儲存並套用、Esc 取消。只寫入和目前點位不同的欄位；沒有不同就不能儲存。

- 待處理（#295 第一層）：唯讀清單、分頁與計數、期限分組、keyset 分頁，載入、失敗、空清單與離線狀態。案件內容（回覆、結案、檢舉處理、倒數）在第二層。

正式建置只有「待處理」接上真實資料：部署在既有 admin Hosting 的 `/pending`，和 Flutter 管理站並存，導覽的其他項目整頁換到 Flutter。登入走 Supabase（Google ＋ AAL2），沒有管理權限或第二步驗證就不會顯示內容，也不會向 `admin_v1` 取資料。工作階段存在自己的 `motopark-admin-react-auth`，不用 Flutter 管理站的 `sb-<ref>-auth-token`：兩個 client 之間沒有共用的鎖，各自更新同一顆會輪替的 refresh token，可能觸發重複使用偵測，讓兩邊一起被登出。代價是第一次進 `/pending` 要再登入一次。

開發時用 `--mode fixture` 載入記憶體內的示範資料（`src/review/fixtureSource.ts`、`src/pending/fixture.ts`），審核頁會標示「示範資料，不會寫入伺服器」。fixture 可用 `?scenario=`（`empty`、`waiting-empty`、`list-failed`、`counts-failed`、`second-factor`、`many`）與 `?auth=`（`signedOut`、`denied`、`mfa`、`enroll`、`unavailable`）切換狀態。

## 指令

需要 Node 24。

```sh
npm ci
npm run dev                 # 開發伺服器（要連資料需設 VITE_SUPABASE_URL、VITE_SUPABASE_ANON_KEY）
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
- 分頁數：手機 4 個（手機的審核與案件詳情 0 個），其他 6 個。
- 導覽、按鈕與篩選的觸控目標至少 48px。
- 每頁只有一個目前分頁。
- 實際操作：輸入中文處理說明、按 A 套用後跳下一筆並出現復原、按復原回到原本那筆且說明還在；手機清單列就地展開；待處理載入更多、開案件與返回清單；登入與第二步驗證各狀態不會顯示管理外框。

CI 會確認 `dist/` 裡沒有示範資料（`MOTOPARK_ADMIN_FIXTURE_DATA` 標記與示範點位名稱）。

## 統一 API（#195）

`src/api/v1/` 是打 Supabase 統一 API 的 RTK Query 用戶端：

- `base.ts`：兩個 base（`api_v1`、`admin_v1`），自動帶 `apikey`、登入 token 與 `Content-Profile`，並把錯誤轉成 `{status, code, message, details}`。連線設定由 `makeStore({ postgrest })` 注入；沒有連線時一律回 `client.not_connected`。
- `*.generated.ts`：`npm run codegen` 由 `supabase/api/v1/<schema>.json` 產生，不要手改；CI 會重新產生並比對。讀取類 API 要在 `scripts/codegen.mjs` 的 `READS` 列為 query。

目前審核頁仍走 `src/review/source.ts` 的資料來源介面；`admin_v1` 有了審核相關 API 後再改接。

## 目錄

| 路徑                    | 內容                                                                                                        |
| ----------------------- | ----------------------------------------------------------------------------------------------------------- |
| `src/design/tokens.css` | DESIGN.md frontmatter 的 token；名稱一一對應（`colors.x` → `--color-x`）。改 token 時先改 DESIGN.md         |
| `src/ui/`               | 疊牌 `PlateStack`／`EligibilityPair`、A0 `MapMarker`、按鈕、篩選 chip、分段控制、狀態標籤、空狀態           |
| `src/shell/`            | 導覽外框：≥1040px 96px 導覽欄、680–1039px 上方分頁、<680px 頂欄＋底部分頁（規則、匯入、使用者收在「更多」） |
| `src/auth/`             | Supabase 登入與第二步驗證：gateway 介面、狀態機（照 Flutter `admin_controller.dart`）、登入閘門             |
| `src/pending/`          | 待處理：清單、分頁、計數、分組規則與 fixture；`/pending/:caseId` 的案件內容由第二層接上                     |
| `src/app/`              | Redux store、RTK Query `adminApi`（資料來源由 store 的 extra 參數注入）、路由                               |
| `src/review/`           | 審核頁：資料模型（照 Flutter `review_models.dart`）、資料來源介面、示範資料、延後送出與復原、元件           |
| `src/pages/`            | 其他功能頁與 `/design` 樣式頁                                                                               |

## 審核頁的資料規則

- 「套用建議」延後 5 秒才送出；期間按「復原」直接取消，不需要伺服器支援撤銷（Flutter 版同樣是延後送出）。關閉分頁前若還有沒送出的處理，瀏覽器會先詢問。
- 送出的欄位只限這個點位接受的欄位（社群點用 `status`、官方點用 `hidden` 隱藏）。
- 含費率、停放條件、暫時封閉、分區或路邊分段的建議，這裡**不套用**：Flutter 版送出前會把費率依車種與現有費率合併並重算收費文字，原樣送出可能清掉另一種車的費率。這部分等 #195 的共用核心接上後再開放。
- 寫入失敗時，那筆回到佇列並標示「沒有套用」，處理說明保留；版本衝突時要先重新讀取最新資料，才能選「仍然套用」。

## 待處理的資料規則

- 伺服器排程，前端只跟著：`actionsSlice` 記下動作的本機到期時間（`run_at` 用導覽計數的 `as_of` 換算伺服器時鐘差），`useActionWatcher` 到期後問 `case_actions` 結果。每筆獨立，互不影響，不會因滑鼠或焦點暫停。
- `cancel_case_action` 回傳不含內文：取消後的草稿是前端自己留的（`actionTracked` 的 `draft: 'take'`）。stale／failed 的草稿優先用記憶體裡的，重新整理後才用 `case_actions` 的 payload。
- 草稿放在 Redux（不放在頁面）：切換案件保留、`auth.aal2_required` 重新驗證後還在。只有換人登入或登出才清掉。
- 案件頁的版本與檢舉期限來自 `admin_v1.timed_case`（清單列的資料），不靠清單目前載入的那幾頁，深連結才打得開。登入 redirect 固定回 `/pending`，深連結先存 sessionStorage（`auth/returnPath.ts`）。
- 回覆寄送失敗但還沒試滿 5 次（`delivery_status='failed'` 且 `attempts` 未滿 `DELIVERY_MAX_ATTEMPTS`）：伺服器會自動再試，案件頁寫「還沒寄出，系統已試了 N 次，約 15 分鐘後會自動再試。」並顯示「系統正在自動重試」，處理列不放「再寄一次」（手動重送會把次數歸零，#447）。期間每 60 秒讀一次；寄到或 5 次都失敗時重新讀清單列，失敗就換成紅色的「回覆沒有寄出」與「再寄一次」。
- 別人已處理：伺服器回 `case.stale`，不執行、不跳下一筆、草稿不動。點位被改時先「重新讀取最新資料」，才能「仍然套用」。
- 手機鍵盤用 `visualViewport` 量（`useKeyboardInset`）：動作列貼著鍵盤、頂欄收成 48px，只在文字欄位有焦點時生效，縮放不會誤判。

## 規則

- 只用 DESIGN.md 的 token；車牌的綠、白、紅、黃只出現在車牌上，操作藍只給按得下去的東西，反光黃只表示「已修改」。
- 資格永遠成對顯示：普通機車在左、大型重機在右，`aria-label` 寫出完整狀態。
- 正式建置不放示範資料；示範資料只在 `--mode fixture` 出現，並標明是示範資料。
- 不要把 App 的 IconScout 重機圖示放進這裡。
