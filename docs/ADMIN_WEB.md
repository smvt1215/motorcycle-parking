# Web 管理介面 — 開發計畫

> 狀態：P1 後端與 P2 外殼已完成，P2 已於 2026-10-24 通過 staging 登入驗收（https://motopark-admin-staging.web.app ）。P3 審核佇列已實作，待 staging 部署後驗收；P4a-1（點位清單、編輯、隱藏、改為官方點）已合併；P4a-2（位置選擇元件、新增停車點）已實作；全點位地圖圖層在 P4a-3，結構化費率的管理站支援待 #68 合併後補上，地址搜尋在 P4b。P0 仍差第二個備援驗證器 App。取代 [PLAN.md](PLAN.md)「社群回報機制 › 5. 管理」原本「第一版用 Supabase Dashboard」的做法；P3 驗收前審核仍以 Dashboard 操作。最後更新：2026-10-25

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
- Supabase Auth MFA 目前只支援驗證器 App（TOTP）與手機簡訊驗證碼，每個帳號最多登記 10 個驗證方式，沒有復原碼（2026-10-24 查官方文件）。
- 管理者至少登記兩個驗證器 App（例如手機與密碼管理器）互為備援，並可再加手機簡訊。簡訊需在 Supabase 設定簡訊供應商（如 Twilio），依則計費。
- passkey 用在第一步：管理者的 Google 帳號以 passkey 登入。Supabase Auth 已有實驗性 passkey（WebAuthn）登入，但它是第一步登入方式，不是 MFA 驗證方式，官方文件也沒說它會產生 `aal2`；API 可能變動，且 passkey 綁定網域（RP ID），staging／production 要各自登記。因此不採用，等 Supabase 支援 passkey 作為第二步驗證或脫離實驗階段後再評估，屆時只需調整 `is_admin()` 與登入畫面。
- 所有驗證方式都遺失時，由專案擁有者以 Auth Admin API 的 `auth.admin.mfa.deleteFactor`（service role，在後端執行）移除該帳號的驗證方式後重新登記。

瀏覽器不放 service role key；所有寫入經 `security definer` 的 `admin_*` RPC，或需要 Auth Admin API 時經 Edge Function。

## UI（原型已確認）
互動原型：[停車指南審核桌](https://claude.ai/artifact/Wv8aqsr2KQrEN8WUgvu1Qz)（私人連結，需由擁有者分享）。共用規則：

- 頂部分頁：審核（含待審數）、點位、規則、匯入、使用者。登入後直接進審核佇列，不放統計卡片。
- 配色：路面灰 `#ECEEEF`、標線白 `#FFFFFF`、柏油 `#2A2E33`、停車標誌藍 `#1F5FA8`（主要動作）、黃牌黃 `#E3AE00`（有變更、待審）、紅線紅 `#C3362E`（駁回、隱藏）。停放資格、車種（車牌色）與格位類型（地面標線，含 #51 新增的 4 種格位）直接沿用 App 的元件與標記。字體 Noto Sans TC，數字用等寬數字。
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
  - 「改為官方點」：比對官方資料確認存在時使用；必須補官方來源（資料來源、https 官方資料網址、生效日期）。普通機車與大型重機資格都重設為「未確認」，除非管理者在同一次操作中依官方明載填入；社群填寫的資格不沿用（#59 之後官方點的「可停」會被完全採信）。社群點隱藏保留，未結回報改指向新官方點，稽核紀錄保存升級前完整快照。
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
   - `admin_upsert_spot`、`admin_set_spot_hidden`（隱藏／恢復，P3 已實作）、`admin_promote_spot`（社群點改為官方點），P4a-1 已實作；另有 `admin_spots` 合併搜尋兩張表。
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
| P3 審核佇列 | 篩選、差異表、小地圖、套用／修改後套用／駁回；App 改送結構化建議；採納前比對點位版本（[社群核實計畫](COMMUNITY_VERIFICATION_PLAN.md) §5.2） | 不用 Dashboard 也能審核；建議送出後點位已改版時，採納會提示衝突而不直接覆蓋（pgTAP 覆蓋） |
| P4 點位 | P4a-1：清單、編輯表單、來源、隱藏／恢復、改為官方點；P4a-2：位置選擇元件、新增停車點；P4a-3：全點位地圖圖層（沿用 App 標記）；P4b：門牌與路口搜尋（Google Geocoding 經 Edge Function，先實測路口） | — |
| P5 規則 | 規則表單、預覽、版本遞增；`tool/export_rules.py` 從 DB 匯出規則避免與 `parking_rules.json` 不一致 | — |
| P6 匯入 | 上傳 `import_mymaps.py` 的 JSON → 差異試算 → 套用；既有點位的費率文字轉為結構化 `fee`（[PLAN.md](PLAN.md)「費率結構」）：只轉換能確定的寫法，「請依現場公告」「未知」與混有汽車、月租、身障費率而無法確定者維持 null 或交人工判斷；差異試算分列可轉換／無法判斷／需人工確認，確認後才寫入；解析結果以 `lib/models/fee.dart` 或 DB 的 `valid_fee()` 驗證 | 轉換完成前不開放依價格篩選 |
| P7 使用者 | 檢視 `rate_limit_events`、停權（`admin-users`） | — |
| App | 位置選擇元件用於新增停車點與「位置不正確」建議 | 可與 P4 同步 |

### P2 實作與待驗收事項

- 獨立入口 `lib/main_admin.dart`，UI、登入狀態、Supabase 存取皆位於 `lib/admin/`。App 的 import graph 不會到達 admin；由工具測試持續檢查此邊界。沒有後端設定時只顯示登入服務未設定，不開放示範管理權限。
- Google OAuth 回到目前網站；非 admin 顯示拒絕原因與登出。admin 的 session 尚未通過第二步驗證時，先登記或選擇已登記的 TOTP／簡訊方式。TOTP 提供 QR code 與可顯示的手動密鑰，簡訊需主動傳送驗證碼；切換方式會清除前一個 challenge。中斷設定後可取消未完成的登記，再以原名稱重試；取消前重新確認仍未驗證。帳號安全頁可加登記備援方式，提醒至少兩個驗證器 App。
- 五個分頁先提供準備中／空狀態；只有 admin 且 `aal2` 才讀取 `moderation_queue` 中 `pending` 的精確筆數。失敗顯示未知與重試，不以零筆代替；失去權限或登出後清除管理資料。
- Noto Sans TC 位於 `web/admin/fonts/`，由 admin 入口載入，字型與授權不加入手機資產。深淺色跟隨系統、手機分頁可換行、按鈕至少 44 px、鍵盤焦點可見。
- `admin_web/` 提供管理站專用 metadata 與圖示；建置後執行 `python3 tool/prepare_admin_web.py`，只覆蓋 `build/admin`，不修改 App 的 `web/index.html` 或 `build/web`。

本機預覽與建置：

```bash
flutter run -d chrome -t lib/main_admin.dart --dart-define-from-file=config/staging.json
flutter build web -t lib/main_admin.dart -o build/admin --no-web-resources-cdn --no-wasm-dry-run --dart-define-from-file=config/staging.json
python3 tool/prepare_admin_web.py
```

`config/staging.json` 沿用 `SUPABASE_URL`、`SUPABASE_ANON_KEY`、`GOOGLE_MAPS_WEB_API_KEY`。admin 不使用手機的 `OAUTH_REDIRECT_URL`。Hosting 與擁有者設定見 [CICD.md](CICD.md#管理介面-staging-hosting)。

Chromium smoke test 使用虛構後端並攔截 Auth／資料回應，不代表真實 Google OAuth、TOTP 或簡訊供應商已驗收：

```bash
flutter build web -t lib/main_admin.dart -o build/admin --no-web-resources-cdn --no-wasm-dry-run --dart-define=SUPABASE_URL=https://admin-smoke.supabase.co --dart-define=SUPABASE_ANON_KEY=public-smoke-key
python3 tool/prepare_admin_web.py
# 已安裝 playwright 與 Chromium 時執行；也可用 PLAYWRIGHT_MODULE 指定套件位置。
node tool/admin_smoke.cjs
```

此測試套用 `firebase.json` 的回應標頭，檢查桌面淺色／手機深色的登入、拒絕、第二步驗證與分頁外殼、MFA 後進入管理頁、console error 與 metadata，截圖存於 `artifacts/admin-smoke/`（不進版控）。測試版本不可部署到 staging；CD 會使用 staging Environment 重新建置。

### P3 實作

- 路徑 `/review`、`/review/<回報 id>`、`/review/hidden`；程式位於 `lib/admin/review/`。佇列依建立時間由舊到新，最多 200 筆；篩選依 `field`／`proposed` 分為停放資格、已不存在、點位資訊，舊版 App 的回報以 `reason` 冒號前文字當標題。
- 版面：寬度 ≥ 1040 px 佇列 360 px＋詳情；680–1039 px 佇列 300 px；< 680 px 先列表、點選後進詳情（返回鍵顯示剩餘筆數），差異表改為每個欄位上下排列，動作列固定在底部。網址帶回報 id，重新整理或瀏覽器返回不會掉位置。
- 差異表只列 `admin_resolve_report` 可改的欄位，建議值以黃色斜角色帶標示；不在可改清單的建議另外列出，不會被默默略過。編輯值的驗證與資料表約束一致（名稱 1–100 字、收費 200 字、備註 500 字、緯度 20–27、經度 118–123、官方點大型重機只能可停或不可停）。
- 動作：有建議值時「套用建議」「修改後套用」；沒有建議值時「修改後套用」「結案不修改」；找不到點位只能「駁回」。處理說明寫入 `resolution_note` 與稽核紀錄。
- **駁回原因與風險等級**（遊戲化研究階段 0，`202610260020_review_resolution_kind.sql`）：按「駁回」後要先選原因才能「駁回這筆回報」。手機（< 680 px）用底部面板，較寬的畫面用對話框；選項可換行，每列至少 48 px。原因共 6 類：與現況不符、重複回報、資訊不足、已不適用、濫用、其他原因，存在 `resolution_kind`，提示列寫成「已駁回（原因）：點位」。`admin_resolve_report` 新增 `p_resolution_kind`：駁回沒帶原因就以 `22023` 拒絕；採納與「結案不修改」可以不帶。資料表另有 trigger，不論從 RPC、Dashboard 或 service role，只要把案件改成 `rejected` 都必須有原因。舊版管理站沒有這個參數，駁回會被拒絕、案件留在佇列，採納不受影響，所以 migration 與管理站要一起部署。處理說明只給管理員看，回報者只會看到依原因顯示的固定文案（我的貢獻）。佇列與詳情顯示伺服器推導的風險等級 `risk`（低／中／高，規則見 [研究文件 §6](CONTRIBUTION_TIERS_FEASIBILITY.md#6-資料模型與-api建議實作時再定版號)）。標示方式是路緣標線色條（白／黃／紅）加上訊號格圖示與文字，不只靠顏色；詳情另附一句判定理由。沒有風險資料的舊案件不顯示標示。
- **量測基線**：`admin_review_baseline(p_months)` 只給 admin（`aal2`）讀取，每月列出案件數、回報者人數、管理員結案時效中位數，以及依結案狀態、原因、風險的分布；欄位定義見 [研究文件 §2.4](CONTRIBUTION_TIERS_FEASIBILITY.md#24-量測基線階段-0)。目前只做資料層，不做儀表板。
- 復原：後端沒有重新開啟回報的 RPC，所以處理後先從佇列移除、6 秒後才寫入；提示列可「復原」。做下一個決定、重新載入或登出時立即寫入；關閉分頁則不寫入，回報留在佇列。寫入失敗會放回佇列；已由他人處理則移出並說明。
- 小地圖以 Maps JavaScript API 顯示點位與 15 m 去重範圍；載入失敗時顯示座標與重試，不阻擋審核。
- **官方點隱藏**（2026-10-24 確認）：騎士不能單方面下架官方資料，只有管理者審核「已不存在」時立即隱藏。`official_heavy_spots.hidden` 由 `official_read` 政策過濾，直接讀取、收藏驗證與兩個 viewport 函式都不再回傳；admin（`aal2`）另有讀取政策。匯入不寫 `hidden`，重新匯入不會讓隱藏的點重新出現。
- **已隱藏的點位**：列出隱藏的社群點與官方點，可逐筆「恢復顯示」（`admin_set_spot_hidden`，寫稽核紀錄，提示列可復原＝重新隱藏）。社群點恢復後回到「待確認」並清除「已不存在」票；P4 點位頁的已隱藏圖層沿用同一個 RPC。
- **版本衝突**（2026-10-24 併入 P3）：`moderation_queue` 入列時由 trigger 記下點位的 `base_updated_at` 與快照 `base_spot`（不改 `apply_report`，舊版 App 送的建議也有）。`admin_resolve_report` 採納時，只要這次寫入的欄位在送出後被改過，就以 `40001`（`spot changed since the report`）拒絕，點位與案件不變；只比對寫入的欄位，投票或其他欄位的變動不算衝突，避免管理者習慣性強制。後台把案件放回佇列並標示「資料已更新，需重新檢視」，差異表多一欄「送出時」，按「仍要套用」才以 `p_force` 寫入，稽核紀錄 `after.forced=true`。入列早於此功能的案件沒有快照，照常審核。
- `field` 改用穩定 key：`name`、`space_type`、`fee_note`、`eligibility`、`note`、`gone`，中文只做顯示；舊版 App 送的中文名稱仍可審核。`submit-report` 的白名單見 #61。
- App 的修改建議改送 `field`（上述 key）、`proposed`、`note`，`reason` 照送給舊伺服器與 Dashboard：格位類型、停放資格送選擇值；名稱與收費送填寫內容（未超過欄位上限時）；點位已不存在時社群點送 `status=hidden`、官方點送 `hidden=true`；「位置或其他備註」只送說明。

### P4a-1 實作

- 路徑 `/spots`、`/spots/<source id>`（官方點為 `official:<uuid>`）；程式位於 `lib/admin/spots/`。版面與審核頁相同：寬螢幕清單＋表單，< 680 px 先列表再表單，動作列依窗格寬度堆疊。
- `admin_spots(p_query, p_kind, p_state, p_limit)`：合併兩張表，依名稱、地址、路段、行政區、縣市搜尋（萬用字元視為一般文字），依來源與狀態篩選，最多 200 筆、最近更新優先。security invoker，仍由 RLS 決定可見範圍。
- `admin_upsert_spot(p_source_id, p_values, p_base_updated_at, p_note)`：只接受可編輯欄位（`source_id`、照片不在內）；社群點的 `status` 只能是待確認／已確認存在，隱藏走 `admin_set_spot_hidden`；官方點來源需 https。編輯必須帶開啟時的 `updated_at`，不一致以 `40001` 拒絕，不覆蓋他人的修改；表單保留修改並提示重新載入。也可新增（`p_source_id` 為 null、`kind` 指定社群或官方），供 P4a-2 使用。
- 表單只送出改過的欄位，並只驗證改過的欄位（與 RPC 一致），舊匯入資料的空欄位不會擋住無關的修改。改過的欄位以黃色斜角色帶「已修改」標示；有未儲存的修改時，切換點位或返回前先確認。
- 社群點的「存在狀態」註明「已確認存在」只代表點位存在，不代表停放資格已核實（社群核實計畫 R1）。管理者編輯寫稽核紀錄，不寫欄位核實表（社群計畫 P3 再決定）；但管理者設定或採納車種資格（`scooter_allowed`、`heavy_allowed`，或同時說明兩車種的 `parking_access`）時，資料庫 trigger 會記錄該車種的核驗時間（`scooter_verified_at`／`heavy_verified_at`，僅 aal2 管理者 JWT 會寫入），App 在 180 天內把該車種欄位當成可信資料判定可停／不可停。`admin_upsert_spot`／`admin_resolve_report` 收到這些欄位時，即使值與現值相同也算核驗（例如採納與現值相同的建議）。非管理者路徑改了該車種欄位、`parking_access`、格位類型、場站型式或座標，核驗即失效；管理者改格位類型、場站型式或座標而沒有同時送出該車種欄位，該車種核驗也失效。只改其他欄位不影響核驗。點位表單只送出改過的欄位，因此「可停車種」區塊另有「核驗目前車種」按鈕（社群點、無未儲存修改時可按）：以 `admin_upsert_spot` 原值重送已設定的車種旗標，並顯示各車種的核驗日期。

### P4a-2 實作

- 位置選擇元件 `lib/ui/location_picker.dart`（App 與管理站共用，App 由社群核實計畫 session 接入）：拖曳標記或點地圖選位置，顯示座標與距原位置的距離，可選 1 m 東西南北微調鈕，地圖可替換以利測試。位置邏輯在 `lib/domain/location_check.dart`（微調、距離、15 m 同類型重複、跨縣市），反查在 `lib/core/town_lookup.dart`（國土測繪中心 `TownVillagePointQuery`，免金鑰、允許 CORS；管理站 CSP 已加入 `https://api.nlsc.gov.tw`）。
- 點位表單的「位置」區塊改用元件：移動後 0.6 秒自動反查縣市與行政區並帶入，查詢 15 m 內同類型的可見點位提示可能重複，跨縣市時提醒規則會改變；移動超過 150 m 時，儲存前確認是否仍是同一點位。座標欄位仍可直接輸入。
- 新增停車點：清單「新增停車點」→ 選社群點或官方點 → `/spots/new?kind=` → 預設位置為上次開啟的點位（否則台北車站）→ 建立後開啟新點位。新表單在第一次按「建立停車點」後才顯示必填錯誤；新增的社群點由管理者帳號建立、狀態為待確認。
- 每個點位的表單從頂端開始（列表 key 依點位）；開啟、新增各自排序，不會讓搜尋中的清單誤判為過期。

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
