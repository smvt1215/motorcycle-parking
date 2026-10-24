# Web 管理介面 — 開發計畫

> 狀態：UI 原型已確認（2026-10-24），尚未實作。取代 [PLAN.md](PLAN.md)「社群回報機制 › 5. 管理」原本「第一版用 Supabase Dashboard」的做法；實作完成前仍以 Dashboard 操作。最後更新：2026-10-24

## 背景
目前審核與資料維護都在 Supabase Dashboard 完成，有幾個問題：

| 問題 | 原因 |
|---|---|
| 審核時看不到目前值與建議值的差異 | `moderation_queue` 只有 `source_id`、`reason`；App 把結構化建議組成文字（`lib/features/report/spot_suggestions.dart` 的 `reason()`） |
| 採納建議不會改到點位 | 要另外到 Table Editor 改 `community_spots`／`official_heavy_spots`，再回頭填 `resolved_at`，兩步不在同一個 transaction |
| 規則改版容易漏 | `city_rules` 要手動調高 `version`、確認 `restriction`，並同步 `assets/rules/parking_rules.json` |
| 沒有操作紀錄 | 以 service role 在 Dashboard 操作，不知道誰改了什麼 |
| 匯入要貼 SQL | `tool/import_mymaps.py` 產出的 `official.sql`／`import.sql` 要在 SQL Editor 執行 |

`city_rules` 已有 `app_metadata.role='admin'` 的寫入 policy（`202610110001_init.sql`），管理者角色從這裡延伸。

## 決策
以下四項已於 2026-10-24 確認：

| 項目 | 採用 | 理由 |
|---|---|---|
| 前端 | Flutter Web，獨立入口 `lib/main_admin.dart`，程式放 `lib/admin/` | 沿用 `lib/models/parking.dart`、`lib/domain/eligibility.dart`、Supabase client 與 `google_maps_flutter` web；App 的 `main.dart` 不 import admin，不會打包進 App |
| 託管 | Firebase Hosting，staging／production 各一個 site | 已有 Firebase 專案與 GitHub OIDC |
| 角色 | 第一版只有 `admin` | 目前一人維護；權限判斷集中在 `is_admin()`，之後可擴充審核者角色 |
| 驗證 | Google 登入後強制第二步驗證（`aal2`），使用 Supabase Auth 內建的多種方式 | 管理者能改公開資料，需比一般回報更強的驗證 |

第二步驗證的做法：
- Supabase Auth MFA 目前只支援驗證器 App（TOTP）與手機簡訊驗證碼，每個帳號最多登記 10 個驗證方式，沒有復原碼（2026-10-24 查官方文件，未支援 passkey／WebAuthn）。
- 管理者至少登記兩個驗證器 App（例如手機與密碼管理器）互為備援，並可再加手機簡訊。簡訊需在 Supabase 設定簡訊供應商（如 Twilio），依則計費。
- passkey 用在第一步：管理者的 Google 帳號以 passkey 登入。Supabase 日後支援 passkey 作為第二步驗證時，只需調整 `is_admin()` 與登入畫面。
- 所有驗證方式都遺失時，由專案擁有者以 Auth Admin API 的 `auth.admin.mfa.deleteFactor`（service role，在後端執行）移除該帳號的驗證方式後重新登記。

瀏覽器不放 service role key；所有寫入經 `security definer` 的 `admin_*` RPC，或需要 Auth Admin API 時經 Edge Function。

## UI（原型已確認）
互動原型：[停車指南審核桌](https://claude.ai/artifact/Wv8aqsr2KQrEN8WUgvu1Qz)（私人連結，需由擁有者分享）。共用規則：

- 頂部分頁：審核（含待審數）、點位、規則、匯入、使用者。登入後直接進審核佇列，不放統計卡片。
- 配色：路面灰 `#ECEEEF`、標線白 `#FFFFFF`、柏油 `#2A2E33`、停車標誌藍 `#1F5FA8`（主要動作）、黃牌黃 `#E3AE00`（有變更、待審）、紅線紅 `#C3362E`（駁回、隱藏）。停放資格沿用 App 的語意色與標記形狀。字體 Noto Sans TC，數字用等寬數字。
- 「有變更」一律以黃色斜角色帶標示（審核的建議值、表單中改過的欄位、未儲存提示）。
- 每個寫入動作完成後顯示提示並可復原；深淺色跟隨系統；手機寬度可用；觸控目標至少 44 px；鍵盤焦點可見。

### 審核
- 左側待審佇列，可依「停放資格／已不存在／點位資訊」篩選。
- 右側：點位名稱與來源、小地圖（點位與 15 m 去重範圍）、「欄位／目前／建議」差異表、騎士說明、處理說明（選填，寫入稽核紀錄）。
- 動作：套用建議、修改後套用（建議值變成可編輯）、駁回。處理完自動跳下一筆。

### 點位
- 全版地圖加停車點圖層：標記沿用 App 的顏色、形狀與選取外圈；車種切換；官方點／社群點／已隱藏三個圖層開關；衛星圖。
- 左側搜尋列與清單（名稱、地址、行政區；依來源與狀態篩選），可收起。點清單會移動地圖並開啟表單。
- 點標記或清單項目時，右側開啟編輯表單；「儲存並關閉」、「隱藏點位」或「恢復顯示」後關閉。有未儲存變更時，關閉前先確認。
- 表單分「基本資訊、可停車種、費率與說明、位置、來源」，驗證與資料庫約束一致（名稱、字數上限、緯度 20–27、經度 118–123）。
- 來源：
  - 官方點：資料來源從 22 個縣市政府選；官方資料網址（https）與生效日期必填；官方資料編號（`source_id`，唯讀）與授權說明。
  - 社群點：資料來源固定「社群回報整理」，顯示建立方式（騎士回報、Google 我的地圖匯入整理、管理者新增），皆唯讀。
  - 「改為官方點」：比對官方資料確認存在時使用；必須補官方來源，大型重機資格重設為「未確認」（只採官方明載）。
- 新增停車點：工具列「新增停車點」→ 選位置 → 依位置帶入縣市與行政區 → 選官方點或社群點 → 填表送出。

### 位置選擇（後台與 App 共用）
- 拖曳標記選位置，拖曳地圖空白處平移；調整時縮放到街道層級，虛線圈標出原位置。
- 搜尋門牌、路段、路口（「A 路與 B 路」、空格、`&` 都可）。門牌寫入「地址」；路段與路口寫入「路段」，並提醒路段只到中心點、路口只到交會點，需再拖曳對準。
- 提醒：距原位置的距離；超過 150 m 確認是否同一點；15 m 內有同類型的點可能重複；跨縣市時適用規則會改變。
- 套用後以國土測繪中心 `TownVillagePointQuery` 反查縣市與行政區（`tool/import_mymaps.py` 已使用）。
- 後台另有東南西北 1 m 微調鈕。App 另有「我的位置」（顯示 GPS 精準度，誤差大於 20 m 時提醒），標記觸控範圍 56×68 px，拖曳時浮起避開手指。
- 做成一個 Flutter 元件，用於：後台點位編輯與新增、App 新增停車點（長按或地圖中心只當起始位置）、App 修改建議新增「位置不正確」（送出座標後進審核；原本的「位置或其他備註」改為只寫其他備註）。
- 表單開啟時，以地圖 padding 或相機偏移讓標記停在表單旁可見處。

### 規則
- 左側列出各縣市 × 普通機車／大型重機，顯示版本與限制類型。
- 每種路邊格位設「可停／有條件／不開放」；路外停車場依場站資料判斷，不在規則設定。
- 限制類型：限試辦路段、限標示車格、規則未核實。路邊格位有條件但未選限制類型時擋下（對應 `city_rules_restriction_required`）。
- 開放行政區、可斜停兩格、費率說明、例外與注意事項、生效日期、公告網址。
- 預覽區以共用的 `eligibility()` 顯示發布後各格位的地圖標記；生效日未到、行政區清單都反映在預覽。
- 「發布第 N 版」由伺服器自動遞增版本；提醒 App 內建規則檔需在發版前更新。

## 後端變更
全部向下相容（依 [CICD.md](CICD.md)「資料庫 migration 規則」）：

1. `is_admin()`：JWT `app_metadata.role = 'admin'` 且 `aal = 'aal2'`；`city_rules` 的 `admin_rules` policy 改用它。
2. `moderation_queue` 新增欄位（可為 null 或有預設值）：`field`、`proposed jsonb`、`note`、`status`（`pending`／`accepted`／`rejected`）、`resolved_by`、`resolution_note`。
3. `submit-report` 與 App：`flag` 可附 `field`、`proposed`（含位置建議的 `lat`／`lng`）；`reason` 文字照送，供舊資料與舊版 App。
4. `admin_audit_log`：只能新增；記錄操作者、動作、目標、修改前後（jsonb）。
5. Admin RPC（皆先檢查 `is_admin()`，並在同一 transaction 寫稽核紀錄）：
   - `admin_resolve_report(id, decision, patch, note)`：依 `source_id` 前綴（`official:` 或社群點 uuid）更新對應資料表並結案。
   - `admin_upsert_spot`、`admin_set_spot_status`（隱藏／恢復）、`admin_promote_spot`（社群點改為官方點）。
   - `admin_upsert_city_rule`：伺服器遞增 `version`，檢查 `restriction`。
   - `admin_import_preview`／`admin_import_apply`：接收 `spots.json`，先試算差異再套用，取代 SQL Editor。
6. 停權使用者需 Auth Admin API：Edge Function `admin-users` 先驗證呼叫者為 admin 且 `aal2`，再用 service role 執行。
7. 地址定位：Edge Function 包裝定位服務，金鑰不進前端與 App，後台與 App 共用。Google Geocoding 支援路口查詢但另計費；TGOS／國土測繪中心的門牌與路口定位能力與申請條件，實作前查官方文件決定。
8. pgTAP：一般使用者被拒、admin 沒有 `aal2` 被拒、套用與結案同一 transaction、稽核紀錄不可修改。

## 階段
| 階段 | 範圍 | 完成條件 |
|---|---|---|
| P0 | staging 設定 admin 帳號、兩個以上驗證器 App 與（選用）簡訊供應商 | 能取得 `aal2` JWT |
| P1 後端基礎 | 後端變更 1、2、4、5（`admin_resolve_report`）與 pgTAP | `supabase test db` 通過 |
| P2 外殼 | `main_admin.dart`、登入、驗證方式登記與選擇（驗證器 App、簡訊）、go_router 版面、非 admin 拒絕畫面、Firebase Hosting（CSP、`X-Frame-Options: DENY`、`noindex`） | staging 可登入 |
| P3 審核佇列 | 篩選、差異表、小地圖、套用／修改後套用／駁回；App 改送結構化建議 | 不用 Dashboard 也能審核 |
| P4 點位 | 地圖圖層、清單、編輯表單、來源、改為官方點、新增停車點、位置選擇元件 | — |
| P5 規則 | 規則表單、預覽、版本遞增；`tool/export_rules.py` 從 DB 匯出規則避免與 `parking_rules.json` 不一致 | — |
| P6 匯入 | 上傳 `import_mymaps.py` 的 JSON → 差異試算 → 套用 | — |
| P7 使用者 | 檢視 `rate_limit_events`、停權（`admin-users`） | — |
| App | 位置選擇元件用於新增停車點與「位置不正確」建議 | 可與 P4 同步 |

## CI／CD
- `tool/ci_changes.py` 將 `lib/admin/` 歸入品質檢查與 admin web 建置（`flutter build web -t lib/main_admin.dart -o build/admin`），不觸發模擬器。
- `cd-staging.yml` 部署 admin 到 staging hosting；RC tag 部署 production。
- Maps Web 金鑰加入 admin 網域的 referrer 限制。

## 驗證
- pgTAP 涵蓋所有權限邊界。
- Widget test：佇列、差異表、表單驗證、位置選擇元件、非 admin 拒絕畫面。
- admin web 建置以 Chromium＋Playwright 做 smoke test。

## 不在範圍內
數據儀表板、多層級角色、即時車位與 TDX 即時層、照片審核（待 Storage 上傳上線後另行規劃）。
