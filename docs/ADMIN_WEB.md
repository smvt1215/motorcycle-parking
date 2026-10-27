# Web 管理介面 — 開發計畫

> 狀態：P1 後端與 P2 外殼已完成，P2 已於 2026-10-24 通過 staging 登入驗收（https://motopark-admin-staging.web.app ）。P3 審核佇列已合併（#62；#77 補上入口指引、位置與場站欄位），待 staging 部署後驗收；P4a-1（點位清單、編輯、隱藏、改為官方點，#67）與 P4a-2（位置選擇元件、新增停車點，#76）已合併，管理員核驗車種欄位（#84）已合併；點位表單與審核頁的結構化費率已實作（`202610260010`）；P4a-3（全點位地圖圖層）已實作；P4b 地址搜尋（Google Geocoding 經 Edge Function `geocode`）已實作，待 staging 部署後驗收；App 的新增停車點與「位置不正確」建議已接入位置選擇元件（見「App 位置選擇實作」）。P5 規則頁已實作（見「P5 實作」）。P6 匯入與費率轉換已實作（見「P6 實作」），待 staging 部署後驗收；P7 使用者頁（搜尋、回報額度、停權、清除公開名稱）已實作（見「P7 實作」）。P0 仍差第二個備援驗證器 App。取代 [PLAN.md](PLAN.md)「社群回報機制 › 5. 管理」原本「第一版用 Supabase Dashboard」的做法；P3 驗收前審核仍以 Dashboard 操作。最後更新：2026-10-26

## 背景
目前審核與資料維護都在 Supabase Dashboard 完成，有幾個問題：

| 問題 | 原因 |
|---|---|
| 審核時看不到目前值與建議值的差異 | `moderation_queue` 只有 `source_id`、`reason`；App 把結構化建議組成文字（`lib/features/report/spot_suggestions.dart` 的 `reason()`） |
| 採納建議不會改到點位 | 要另外到 Table Editor 改 `community_spots`／`official_heavy_spots`，再回頭填 `resolved_at`，兩步不在同一個 transaction |
| 規則改版容易漏 | `city_rules` 要手動調高 `version`、確認 `restriction`，並同步 `assets/rules/parking_rules.json`（P5 起由管理站發布與 `tool/export_rules.py` 處理） |
| 沒有操作紀錄 | 以 service role 在 Dashboard 操作，不知道誰改了什麼 |
| 匯入要貼 SQL | `tool/import_mymaps.py` 產出的 `official.sql`／`import.sql` 要在 SQL Editor 執行（SQL 輸出已於 2026-10-26 停用，#117；工具只產生匯入頁用的 JSON） |

`city_rules` 原有 `app_metadata.role='admin'` 的寫入 policy（`202610110001_init.sql`），管理者角色從這裡延伸；P5 起改為只能經 `admin_upsert_city_rule` 寫入。

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
- 搜尋門牌、路段、路口（「A 路與 B 路」、兩個路名之間的空格、`&` 都可）。門牌寫入「地址」；路段與路口寫入「路段」，並提醒路段只到中心點、路口只到交會點，需再拖曳對準（P4b，見下方「P4b 實作」）。
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
   - `admin_clear_contributor_name(spot_id, note)`：清除社群點公開的回報者名稱並寫稽核紀錄（#81 已實作，後台 UI 尚未接入）。
   - `admin_upsert_city_rule`：伺服器遞增 `version`，檢查 `restriction`；發布前把現列複製到 `city_rules_history`（P5 已實作）。
   - `admin_import_preview`／`admin_import_apply`：接收 `spots.json`，先試算差異再套用，取代 SQL Editor（P6 已實作，見下方「P6 實作」）。
   - `admin_fee_backlog`／`admin_convert_fees`：列出尚無結構化費率的點位，寫入管理者確認的費率（P6）。
6. 停權使用者需 Auth Admin API：Edge Function `admin-users` 先驗證呼叫者為 admin 且 `aal2`，再用 service role 執行（P7 已實作，見下方「P7 實作」）。
7. 地址定位：Edge Function `geocode` 包裝 Google Geocoding API，金鑰只在 function secret `GOOGLE_GEOCODING_API_KEY`，不進前端與 App，後台與 App 共用。2026-10-25 比較後決定（見「P4b 實作」）。
8. pgTAP：一般使用者被拒、admin 沒有 `aal2` 被拒、套用與結案同一 transaction、稽核紀錄不可修改。

## 階段
| 階段 | 範圍 | 完成條件 |
|---|---|---|
| P0 | staging 設定 admin 帳號、兩個以上驗證器 App 與（選用）簡訊供應商 | 能取得 `aal2` JWT |
| P1 後端基礎 | 後端變更 1、2、4、5（`admin_resolve_report`）與 pgTAP | `supabase test db` 通過 |
| P2 外殼 | `main_admin.dart`、登入、驗證方式登記與選擇（驗證器 App、簡訊）、go_router 版面、非 admin 拒絕畫面、Firebase Hosting（CSP、`X-Frame-Options: DENY`、`noindex`） | staging 可登入 |
| P3 審核佇列 | 篩選、差異表、小地圖、套用／修改後套用／駁回；App 改送結構化建議；採納前比對點位版本（[社群核實計畫](COMMUNITY_VERIFICATION_PLAN.md) §5.2） | 不用 Dashboard 也能審核；建議送出後點位已改版時，採納會提示衝突而不直接覆蓋（pgTAP 覆蓋） |
| P4 點位 | P4a-1：清單、編輯表單、來源、隱藏／恢復、改為官方點；P4a-2：位置選擇元件、新增停車點；P4a-3：全點位地圖圖層（沿用 App 標記，已實作）；P4b：門牌與路口搜尋（Google Geocoding 經 Edge Function `geocode`，已實測路口） | — |
| P5 規則 | 規則表單、預覽、版本遞增、`city_rules_history`；`tool/export_rules.py` 從 DB 匯出規則避免與 `parking_rules.json` 不一致 | 已實作，見「P5 實作」 |
| P6 匯入 | 上傳 `import_mymaps.py` 的 JSON → 差異試算 → 套用；既有點位的費率文字轉為結構化 `fee`（[PLAN.md](PLAN.md)「費率結構」）：只轉換能確定的寫法，「請依現場公告」「未知」與混有汽車、月租、身障費率而無法確定者維持 null 或交人工判斷；差異試算分列可轉換／無法判斷／需人工確認，確認後才寫入；解析結果以 `lib/models/fee.dart` 或 DB 的 `valid_fee()` 驗證 | 轉換完成前不開放依價格篩選 |
| P7 使用者 | 檢視 `rate_limit_events`、停權（`admin-users`）、清除點位上的公開名稱；等級、點數、角色撤銷與抽查佇列屬遊戲化階段 1 以後（[研究文件 §4](CONTRIBUTION_TIERS_FEASIBILITY.md)） | — |
| App | 位置選擇元件用於新增停車點與「位置不正確」建議（已實作，見「App 位置選擇實作」） | 可與 P4 同步 |

遊戲化接軌（已規劃、未實作，2026-10-26）：多層級角色、P5 規則草稿與影響分析、P6 覆蓋層試算、P7 等級／點數／角色撤銷、指標頁、B 類「已預審」佇列、抽查佇列，依[研究文件 §9](CONTRIBUTION_TIERS_FEASIBILITY.md#9-分階段與依賴每階段以指標驗收) 的階段實作與驗收；範圍見下方「遊戲化接軌」。

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
- **駁回原因與風險等級**（遊戲化研究階段 0，`202610260020_review_resolution_kind.sql`）：按「駁回」後要先選原因才能「駁回這筆回報」。手機（< 680 px）用底部面板，較寬的畫面用對話框；選項可換行，每列至少 48 px。原因共 6 類：與現況不符、重複回報、資訊不足、已不適用、濫用、其他原因，存在 `resolution_kind`，提示列寫成「已駁回（原因）：點位」。`admin_resolve_report` 新增 `p_resolution_kind`：駁回沒帶原因就以 `22023` 拒絕；採納與「結案不修改」可以不帶；選「其他原因」時處理說明必填，面板內會出現說明欄，RPC 也會擋下空白說明。資料表另有 trigger，不論從 RPC、Dashboard 或 service role，只要把案件改成 `rejected` 都必須有原因。舊版管理站沒有這個參數，駁回會被拒絕、案件留在佇列，採納不受影響，所以 migration 與管理站要一起部署。處理說明只給管理員看，回報者只會看到依原因顯示的固定文案（我的貢獻）。佇列與詳情顯示伺服器推導的風險等級 `risk`（低／中／高，規則見 [研究文件 §6](CONTRIBUTION_TIERS_FEASIBILITY.md#6-資料模型與-api建議實作時再定版號)）。標示方式是路緣標線色條（白／黃／紅）加上訊號格圖示與文字，不只靠顏色；詳情另附一句判定理由。沒有風險資料的舊案件不顯示標示。
- **量測基線**：`admin_review_baseline(p_months)` 只給 admin（`aal2`）讀取，每月列出案件數、回報者人數、管理員結案時效中位數，以及依結案狀態、原因、風險的分布；欄位定義見 [研究文件 §2.4](CONTRIBUTION_TIERS_FEASIBILITY.md#24-量測基線階段-0)。目前只做資料層，不做儀表板。
- 復原：後端沒有重新開啟回報的 RPC，所以處理後先從佇列移除、6 秒後才寫入；提示列可「復原」。做下一個決定、重新載入或登出時立即寫入；關閉分頁則不寫入，回報留在佇列。寫入失敗會放回佇列；已由他人處理則移出並說明。
- 小地圖以 Maps JavaScript API 顯示點位與 15 m 去重範圍；載入失敗時顯示座標與重試，不阻擋審核。
- **官方點隱藏**（2026-10-24 確認）：騎士不能單方面下架官方資料，只有管理者審核「已不存在」時立即隱藏。`official_heavy_spots.hidden` 由 `official_read` 政策過濾，直接讀取、收藏驗證與兩個 viewport 函式都不再回傳；admin（`aal2`）另有讀取政策。匯入不寫 `hidden`，重新匯入不會讓隱藏的點重新出現。
- **已隱藏的點位**：列出隱藏的社群點與官方點，可逐筆「恢復顯示」（`admin_set_spot_hidden`，寫稽核紀錄，提示列可復原＝重新隱藏）。社群點恢復後回到「待確認」並清除「已不存在」票；P4 點位頁的已隱藏圖層沿用同一個 RPC。
- **版本衝突**（2026-10-24 併入 P3）：`moderation_queue` 入列時由 trigger 記下點位的 `base_updated_at` 與快照 `base_spot`（不改 `apply_report`，舊版 App 送的建議也有）。`admin_resolve_report` 採納時，只要這次寫入的欄位在送出後被改過，就以 `40001`（`spot changed since the report`）拒絕，點位與案件不變；只比對寫入的欄位，投票或其他欄位的變動不算衝突，避免管理者習慣性強制。後台把案件放回佇列並標示「資料已更新，需重新檢視」，差異表多一欄「送出時」，按「仍要套用」才以 `p_force` 寫入，稽核紀錄 `after.forced=true`。入列早於此功能的案件沒有快照，照常審核。
- `field` 改用穩定 key：`name`、`space_type`、`fee_note`、`eligibility`、`note`、`gone`，#75 再加入 `guide`（入口與停車指引），中文只做顯示；舊版 App 送的中文名稱仍可審核。`submit-report` 的白名單見 #61。App 的「停車點位置」建議送 `location`（`proposed` 含 `lat`、`lng`，反查成功時另含 `city`、`district`），`submit-report` 白名單已加入，審核頁辨識為「位置不正確」，可審核欄位加入縣市與行政區（文字，30 字，縣市不可空白）；位置建議沒附縣市時（反查失敗或舊版 App）審核頁提醒管理者確認是否跨縣市，需要時「修改後套用」加入縣市與行政區。
- App 的修改建議改送 `field`（上述 key）、`proposed`、`note`，`reason` 照送給舊伺服器與 Dashboard：格位類型、停放資格送選擇值；名稱與收費送填寫內容（未超過欄位上限時，收費自 #72 起另送結構化 `fee`）；「這裡已經不能停車」先選原因，只有格線已撤除、改為其他用途兩種永久原因才附隱藏建議（社群點 `status=hidden`、官方點 `hidden=true`），施工、暫時封閉與其他原因只送說明（#75）；原本的「位置或其他備註」拆成「入口與停車指引」（`guide`，只送有變更的 `entrance_note`、`parking_guide`）與「其他備註」（`note`，只送說明）。
- 審核頁（#77）：可審核欄位加入場站型式、車種開放（選項）與入口說明、停放方式（文字，500 字）；沒附建議值的「已不存在」回報不預設隱藏，「修改後套用」從點位目前的顯示狀態開始，由管理者決定是否隱藏。
- 審核頁的費率：可審核欄位加入 `fee`。App 送來的 `fee` 整筆合規才列入修改內容（`Fee.tryParse`），否則另列為無法套用；差異表以費率內容比較並顯示費率文字。「修改後套用」以共用 `FeeEditor` 編輯（任何寬度都佔滿整列），金額填完後收費資訊自動改為 `feeNoteOf(fee)`。點位已有結構化費率時，只改收費資訊的建議無法直接套用（App 顯示的是費率），需在「修改後套用」加入「費率」修改。伺服器端 `admin_resolve_report`（`202610260010`）同樣檢查：patch 動到 `fee` 或 `fee_note` 時，寫入後的 `fee_note` 必須等於 `fee_note_of(fee)`，否則以 `22023` 拒絕；檢查在版本衝突之後，強制套用也不略過；沒有 `fee` 的點位照舊。

### P4a-1 實作

- 路徑 `/spots`、`/spots/<source id>`（官方點為 `official:<uuid>`）；程式位於 `lib/admin/spots/`。版面與審核頁相同：寬螢幕清單＋表單，< 680 px 先列表再表單，動作列依窗格寬度堆疊。
- `admin_spots(p_query, p_kind, p_state, p_limit)`：合併兩張表，依名稱、地址、路段、行政區、縣市搜尋（萬用字元視為一般文字），依來源與狀態篩選，最多 200 筆、最近更新優先。security invoker，仍由 RLS 決定可見範圍。
- `admin_upsert_spot(p_source_id, p_values, p_base_updated_at, p_note)`：只接受可編輯欄位（`source_id`、照片不在內）；社群點的 `status` 只能是待確認／已確認存在，隱藏走 `admin_set_spot_hidden`；官方點來源需 https。編輯必須帶開啟時的 `updated_at`，不一致以 `40001` 拒絕，不覆蓋他人的修改；表單保留修改並提示重新載入。也可新增（`p_source_id` 為 null、`kind` 指定社群或官方），供 P4a-2 使用。
- 表單只送出改過的欄位，並只驗證改過的欄位（與 RPC 一致），舊匯入資料的空欄位不會擋住無關的修改。改過的欄位以黃色斜角色帶「已修改」標示；有未儲存的修改時，切換點位或返回前先確認。
- 社群點的「存在狀態」註明「已確認存在」只代表點位存在，不代表停放資格已核實（社群核實計畫 R1）。管理者編輯寫稽核紀錄，不寫欄位核實表（社群計畫 P3 再決定）；但管理者設定或採納車種資格（`scooter_allowed`、`heavy_allowed`，或同時說明兩車種的 `parking_access`）時，資料庫 trigger 會記錄該車種的核驗時間（`scooter_verified_at`／`heavy_verified_at`，僅 aal2 管理者 JWT 會寫入），App 在 180 天內把該車種欄位當成可信資料判定可停／不可停。`admin_upsert_spot`／`admin_resolve_report` 收到這些欄位時，即使值與現值相同也算核驗（例如採納與現值相同的建議）。非管理者路徑改了該車種欄位、`parking_access`、格位類型、場站型式或座標，核驗即失效；管理者改格位類型、場站型式或座標而沒有同時送出該車種欄位，該車種核驗也失效。只改其他欄位不影響核驗。點位表單只送出改過的欄位，因此「可停車種」區塊另有「核驗目前車種」按鈕（社群點、無未儲存修改時可按）：以 `admin_upsert_spot` 原值重送已設定的車種旗標，並顯示各車種的核驗日期。

- **結構化費率**（`202610260010`）：`admin_spot_fields` 加入 `fee`（社群點與官方點）；`admin_upsert_spot` 以 `valid_fee()` 驗證 `fee`（錯誤為 `invalid fee`），並在這次寫入有 `fee` 或 `fee_note` 時，要求寫入後的 `fee_note` 等於 `fee_note_of(fee)`（與 `lib/models/fee.dart` 的 `feeNoteOf` 相同寫法，pgTAP 與 Dart 測試固定同一組句子），沒有 `fee` 的舊資料文字仍可自由修改。表單「費率與說明」使用共用 `FeeEditor`（一次展開一個車種；C3 起含汽車、依時段不同、比照其他車種與三態選項），下方「App 顯示的費率」用 App 同一個收費公告牌 `FeeBoard`（柏油色字、白底，深色模式仍為白底）顯示，由費率產生、不能直接輸入；費率未填完或沒有結構化費率時仍顯示文字公告牌；所有車種都改回「未確認」時清除 `fee`，說明文字恢復可編輯（原本沒有 `fee` 時還原原文，原本有則改為「請依現場公告」）。只有 `fee_note` 的舊資料顯示提示、各車種保持未確認，不從文字猜價格。費率與文字只送改過的欄位，稽核紀錄的 before／after 含 `fee`。分區 `parking_zones` 不在管理站可編輯欄位（其 `fee` 由 `valid_zone_fees` 把關）。

### P4a-2 實作

- 位置選擇元件 `lib/ui/location_picker.dart`（App 與管理站共用）：拖曳標記或點地圖選位置，顯示座標與距原位置的距離，可選 1 m 東西南北微調鈕，地圖可替換以利測試。位置邏輯在 `lib/domain/location_check.dart`（微調、距離、15 m 同類型重複、跨縣市），反查在 `lib/core/town_lookup.dart`（國土測繪中心 `TownVillagePointQuery`，免金鑰、允許 CORS；管理站 CSP 已加入 `https://api.nlsc.gov.tw`）。
- 點位表單的「位置」區塊改用元件：移動後 0.6 秒自動反查縣市與行政區並帶入，查詢 15 m 內同類型的可見點位提示可能重複，跨縣市時提醒規則會改變；移動超過 150 m 時，儲存前確認是否仍是同一點位。座標欄位仍可直接輸入。
- 新增停車點：清單「新增停車點」→ 選社群點或官方點 → `/spots/new?kind=` → 預設位置為上次開啟的點位（否則台北車站）→ 建立後開啟新點位。新表單在第一次按「建立停車點」後才顯示必填錯誤；新增的社群點由管理者帳號建立、狀態為待確認。
- 每個點位的表單從頂端開始（列表 key 依點位）；開啟、新增各自排序，不會讓搜尋中的清單誤判為過期。

### App 位置選擇實作

- 元件新增 App 用的選項：`touchMarker` 以 Flutter 繪製的標記取代地圖原生標記，觸控範圍 56×68 px，拖曳時標記尖端浮在手指上方 24 px，地面以小圈標出實際落點；標記用 eager recognizer 取得手勢，拖曳標記不會捲動表單也不會平移地圖，拖曳空白處照常平移，點地圖也能移動標記。位置換算以 Web Mercator（每圖磚 256 邏輯像素，Google Maps 與 flutter_map 相同）由相機中心與縮放算出，因此 App 的選位地圖關閉旋轉與傾斜。Google Maps 在表單中以 `EagerGestureRecognizer` 保留地圖上的拖曳（iOS、Android 相同），沒有 Maps 金鑰時改用與主地圖相同的 OpenStreetMap 預覽（`osmLocationMap`）。
- `onLocate`：「移到我的位置」讀取裝置定位（`AppStore.currentFix`，不移動主地圖），顯示「GPS 精準度約 ±N m」，誤差大於 20 m 時提醒拖曳對準；標記被移開後不再顯示精準度。定位未開啟或未授權時沿用既有的設定對話框。
- `onSearch`：P4b 門牌、路段與路口搜尋（見「P4b 實作」），回傳選到的結果後移動標記；沒有提供時不顯示入口。
- 提醒分三種語氣並都附圖示：資訊（所在縣市）、注意（條件琥珀：GPS 誤差、15 m 內同類型的點、跨縣市規則改變、查不到縣市）、錯誤（紅色：標記超出臺灣範圍等擋住送出的問題）。
- 新增停車點：表單最上方「位置」區塊，長按點或地圖中心只當起始位置；開啟時與每次移動後 0.6 秒以 `AppStore.townAt`（國土測繪中心）反查，縣市與行政區帶入並送出 `district`；反查得到的縣市與原本帶入的不同時提醒「適用 X 的停車規則」，並依新縣市重新帶入未手動修改的可停車種；查不到時保留附近點位帶入的縣市請騎士確認。15 m 內同類型的點提示改到該點提出修改建議。地圖高度為螢幕高的 34%（200–300 px），320 px 寬與鍵盤彈出時表單仍可捲動。
- 修改建議「停車點位置」（`field=location`）：從點位目前位置開始，空心小圈標出原位置，未移動 1 m 以上不能送出；變更卡片列出移動方向與距離、跨縣市時列出縣市變化；超過 150 m 送出前確認是否仍是同一個點。`proposed` 含 `lat`、`lng`（7 位小數），反查成功時一併送 `city`、`district`（2026-10-26 使用者決定），跨縣市移動採納後點位改用新縣市的規則；反查失敗時只送座標，由審核頁提醒管理者確認。TDX 點位沒有可修改的資料列，只送說明。說明欄選填，另寫入 `note`。
- `submit-report` 白名單加入 `location`，`field=location` 的 `proposed` 必須有 `lat`、`lng`，只能另帶 `city`（1–30 字）、`district`（0–30 字），範圍沿用緯度 20–27、經度 118–123；任何建議的 `city`、`district` 都不能沒有座標單獨出現。`admin_resolve_report`（最新定義在 `202610260020`）本來就能套用 `lat`、`lng`，`location` geography 是產生欄位會一起更新，不需要 migration；`moderation_risk` 依移動距離把位置建議分級（150 m 內中、以上高）；pgTAP 已涵蓋採納位置建議，包括跨縣市時縣市與行政區一併更新。

### P4a-3 實作

- 點位頁改為全版地圖：地圖沿用 App 的 `GoogleParkingMap`（標記顏色、形狀、角落格位徽章、選取外圈與群聚），另加衛星圖（`MapType.hybrid`，保留路名）與淡化參數；程式位於 `lib/admin/spots/spot_map.dart`。`/spots` 與 `/spots/<id>` 共用同一個頁面，開關表單時地圖保留相機與已載入的點。
- 車種切換（普通機車／大型重機）以 App 的 `eligibility()` 與規則（資料庫 `city_rules`，讀取失敗時用內建規則檔）重算標記。
- 圖層：官方點、社群點、已隱藏三個開關互相獨立；已隱藏圖層包含兩種來源的隱藏點，以半透明標記顯示。資料來自 `admin_viewport_spots(south, west, north, east, p_community, p_official, p_hidden)`（migration `202610260220`）：只限 `is_admin()`，security invoker；範圍限制與 App 相同（每邊最多 0.5 度，超過時提示放大），每個圖層最多 501 筆，超過 500 筆時提示只顯示一部分。官方點含尚未生效的點，狀態與 App 相同視為已確認。App 的 viewport 函式不變。
- 開表單：點標記開啟表單，地圖只平移不改縮放；點清單或由網址開啟則移到街道層級（zoom 18）。Maps JavaScript API 不會依地圖 padding 移動相機（`google_maps_flutter_web` 只在 `fitBounds` 使用 padding），所以改以相機偏移：目標點往東移（表單寬 − 清單寬）／2 px，讓標記停在兩個面板之間（`lib/domain/map_camera.dart` 的 `shiftCenter`）。表單中拖曳位置時選取標記跟著移動；儲存、核驗、隱藏／恢復、改為官方點、新增後重新載入地圖上的點。
- 版面（斷點同審核頁）：
  - ≥ 1040 px：左側清單 380 px、右側表單 480 px，皆疊在地圖上；清單可收起。
  - 680–1039 px：清單 300 px；開表單時清單讓位（表單寬為視窗 56%，360–440 px），可再叫出；表單開著時叫出或收起清單，相機會依新的面板寬度重新偏移（只平移不改縮放），選取的標記不會被清單蓋住；地圖控制放不下時只留清單開關。
  - < 680 px：頂端「地圖／清單」切換，預設地圖；點標記或清單項目後表單佔滿畫面，返回鍵回到原本的地圖或清單。地圖一直保留在下層，返回後相機不變；被覆蓋時不查詢。
- 疊在地圖上的面板與控制在 web 以 `PointerInterceptor` 擋住地圖的指標事件。控制按鈕至少 48 px。

### P4b 實作

**服務選擇（2026-10-25 使用者拍板）**

| | Google Geocoding | TGOS | 國土測繪中心（NLSC） |
|---|---|---|---|
| 門牌 | 支援 | `QueryAddr` | 門牌 API（需申請） |
| 路段 | 支援，回路段中心 | 道路定位（點＋範圍） | 路名清單 |
| 路口 | 支援，含小路口（實測） | 路口定位 `roadcross` | 未標示 |
| 申請與費用 | 每月免費 10,000 次，超過 US$5／1000 | 金鑰免費；全國門牌地址定位需公司或機關＋公文 | 民營須統一編號、審查、繳費，最低 NT$4,000／月 |
| 從 Edge Function 呼叫 | 可（API 限制） | 不可：金鑰綁 Domain／IP，Edge Function 沒有固定對外 IP | 不可：同樣綁 URL／IP |

OpenStreetMap Nominatim 免金鑰，但實測台灣門牌與路口都查不到，不採用。

**設定**
- staging 金鑰「Motopark staging geocoding」只開 Geocoding API；Geocoding 每日配額硬上限 300 次（約每月 9,000，留在免費額度內），另設帳單預算警示。production 需另建金鑰與配額。
- Supabase secret `GOOGLE_GEOCODING_API_KEY`；未設定時 function 回 `not_configured`，畫面提示直接拖曳標記。
- 條款（Google Maps Platform Service Specific Terms §6）：結果只能配 Google 地圖（App 與管理站都是）；跨使用者共用的經緯度快取最多 30 天。

**Edge Function `geocode`**（`supabase/functions/geocode/`）
- `POST {query, near?: {lat, lng}}` → `{kind, candidates: [{kind, label, place?, lat, lng, precision}]}`。`kind` 為 `address`（門牌）、`road`（路段）、`intersection`（路口）、`area`（其他區域）；`precision` 為 `exact`、`interpolated`、`center`、`approximate`。最多 5 筆，只留台灣範圍（緯度 20–27、經度 118–123）。
- 查詢：全形轉半形、合併空白；「與」、`&`、`/` 或兩個路名之間的空格視為路口（「和」不算，避免和平東路），去掉結尾「路口」；含「號」的不當路口。送 Google 時加 `language=zh-TW`、`region=tw`、`components=country:TW`，並以地圖位置約 10 km 為偏好範圍（不是限制）。
- 名稱（實測）：Google 的路名與路口常回英文，所以路口與路段的 `label` 用騎士輸入的路名（去掉開頭的縣市；行政區只在 Google 結果列出該名稱時才去掉，例如「前鎮區鎮中路」不會被當成「前鎮區鎮」＋「中路」），縣市與行政區另放 `place`；門牌由縣市、行政區、路名、號組成，不含里與郵遞區號；「台」改「臺」。問兩條不相交的路時 Google 會回某條巷子與另一條路的交會點，或問不存在的門牌時只回英文路名，這些都略過，畫面顯示找不到。
- 呼叫者：App 需 Google／Apple 登入（匿名拒絕），管理站以 admin＋aal2 身分。每人每台北日 30 次、管理者 200 次（含快取命中），超過回 429 `daily_limit`；Google 配額用完回 503 `service_limit`。其他錯誤：`sign_in_required`、`invalid_query`（2–100 字）、`unavailable`。
- migration `202610260230_geocode.sql`：`geocode_events`（只計數，不混用回報的 `rate_limit_events`）、`geocode_cache`（以查詢＋約 5 km 偏好位置為鍵，30 天內才使用，寫入時刪除過期資料與 30 天前的計數），兩者只有 service role 可用。

**畫面**（`lib/ui/address_search_field.dart`，由位置選擇元件的 `onSearch` 入口「搜尋門牌、路段或路口」開啟）
- 手機以底部面板、寬度 ≥ 600 px 以對話框開啟搜尋欄與「搜尋地址」；按鈕或鍵盤搜尋鍵才送出，不在輸入時查詢，以免消耗次數。窄於約 360 px 或放大字級時按鈕移到欄位下方；鍵盤彈出時面板內容上移。
- 結果每列有圖示與文字說明類型（門牌、路段只到中心點、路口只到交會點、推估位置），列高至少 56 px。點一筆後關閉搜尋、移動標記、寫入對應欄位；入口下方說明「已移到…，並填入『路段』。路口只定位到兩條路的交會點，請把標記拖到實際停車位置。」，標記移開後不再顯示。
- 找不到時提示門牌寫到「號」、路口寫兩條路名，或直接拖曳；網路錯誤可「重新搜尋」；次數用完說明明天恢復。
- 管理站點位表單：門牌寫入「地址」、路段與路口寫入「路段」，以既有的「已修改」標示；全版地圖的相機移到結果（搜尋可能跳到很遠的地方）。App 的新增停車點與「位置不正確」建議以 `ParkingRepository.searchAddress` 搜尋，App 表單沒有地址欄位，只移動標記。

### P5 實作

- 路徑 `/rules`、`/rules/<縣市>/<scooter|heavy>`；程式位於 `lib/admin/rules/`。版面與點位頁相同：寬螢幕清單＋編輯區，< 680 px 先列表再編輯。編輯區寬度 ≥ 900 px 時預覽放在表單右側，較窄時接在表單下方。
- 清單列出全國與 22 縣市 × 普通機車／大型重機（車牌色區分車種），顯示目前版本與限制類型，沒有規則的顯示「尚無規則」，可直接建立第 1 版。版本和 App 內建 `assets/rules/parking_rules.json` 不同的規則標「App 內建尚未更新」，清單上方提示發版前執行 `tool/export_rules.py`。
- 路邊格位：普通機車設收費機車格、免費機車格、汽車格；大型重機另加重機專用格（普通機車一律不可停重機專用格，不提供設定）。每種格位選「可停／有條件／不開放」，可另填「只在這些行政區」（寫入 `district_space_types`，清單外行政區的該格位顯示不可停；普通機車的汽車格也適用，`eligibility()` 把列在 `district_space_types` 的汽車格視為城市規則開放）。路外停車場、身障、電動、彈性共用格不在規則設定；既有規則中這些表單不顯示的種類（例如 `conditional_space_types` 的 `offStreet`）發布時原樣保留，新規則比照內建規則把 `offStreet` 列為有條件，讓還讀規則判斷停車場的舊版 App 行為不變。
- 有條件的格位才顯示「限制類型」（限試辦路段 `pilot_area`、限標示車格 `signage`、規則未核實 `unverified`）；沒選時發布會被擋下，沒有有條件格位時不送限制類型。App 沒有 `pilot_area` 的列舉值，會顯示為一般的「有條件」。
- 其他欄位：公告的開放行政區（`districts`，清單外顯示待確認）、可斜停兩格、費率說明（1–200 字）、例外與注意事項（1–500 字；規則沒有結構化的時段與截止日，平日／假日、時段或試辦截止日寫在這裡）、生效日期（YYYY-MM-DD，不存在的日期會擋下）、公告網址（https）。改過的欄位以黃色斜角色帶「已修改」標示；有未發布的修改時，換規則前先確認。
- 預覽：以共用的 `eligibility()` 對每種路邊格位與限時停車格（比照收費格）判斷官方點，顯示 App 地圖標記（`SpotMarker`）、狀態與說明。生效日在未來時可切換「今天／生效後」；規則有列行政區時可切換點位所在的行政區、其他行政區、行政區不明。
- 「發布第 N 版」先確認，提醒 App 內建規則檔不會跟著改變；成功後提示列可「復原」，做法是再發布一版恢復原內容（版本仍遞增，歷史保留）。開啟後他人已發布時以 `40001` 拒絕，保留修改並提示重新載入。發布進行中不能重新載入規則，以免發布結果被丟棄。
- `admin_upsert_city_rule(p_city, p_vehicle, p_values, p_base_version, p_note)`（`202610260240`）：`is_admin()`；縣市限全國與 22 縣市；只接受規則欄位（`version` 由伺服器遞增）；格位種類限原本五種（#51 前的 App 讀不懂其他種類）；同一種類不可同時可停與有條件；有條件路邊格位必須有限制類型（`23514`），有限制類型必須有有條件路邊格位；內容與目前版本相同時拒絕。`p_base_version` 必須等於目前版本（新規則為 null），否則 `40001`。同一 transaction 內把被取代的列寫入 `city_rules_history`、寫稽核紀錄（完整修改前後列與發布說明）。
- `city_rules_history`（`city`、`vehicle`、`version`、`row jsonb`、`replaced_at`、`replaced_by`；`(city, vehicle, version)` 唯一）：只由 RPC 寫入、不可修改或刪除，僅 admin（`aal2`）可讀；供法規預審引擎（[CONTRIBUTION_TIERS_FEASIBILITY.md](CONTRIBUTION_TIERS_FEASIBILITY.md) §5.7、§10 第 16 點，2026-10-25 決定採歷史表）還原「當時版本說什麼」。
- **直接寫入已收回**（2026-10-26 使用者決定）：同一 migration 移除 `city_rules` 的 `admin_rules` 寫入 policy，並收回 `authenticated` 的 insert／update／delete；admin 只能經規則頁（`admin_upsert_city_rule`）改規則，每次修改都有版本、稽核與歷史。所有人照舊可讀。緊急時仍可用 service role（Dashboard SQL），但不會留稽核與歷史，也不遞增版本，事後應補發一版。
- `tool/export_rules.py`：以 anon key 讀 `city_rules`（`SUPABASE_URL`／`SUPABASE_ANON_KEY` 環境變數，或 `--config`，預設 `config/staging.json`），依內建檔的格式與順序寫回 `assets/rules/parking_rules.json`（新規則依縣市順序附在後面，空的 `district_space_types` 與 null 的 `restriction` 不寫入）。內建檔有但資料庫沒有、或內建版本較新時停止並說明，需先修正資料庫。`--check` 只比對、不寫入（不一致時結束碼 1），`--input` 可改讀匯出的列。App 發版前執行：

```bash
python3 tool/export_rules.py --check || python3 tool/export_rules.py
```

### P6 實作

- 路徑 `/imports`（匯入檔案）與 `/imports/fees`（費率轉換）；程式位於 `lib/admin/import/`，migration `202610260250_admin_import.sql`。
- **匯入**：選擇 `tool/import_mymaps.py` 產生的 `spots.json`（官方點 `data/imports/official/spots.json` 或社群點 `data/imports/google-mymaps/spots.json`），檔案只在瀏覽器讀取，按下「匯入」才寫入。網站先以費率解析（見下）為能確定的點位補上 `fee`，再分批（每批 500 筆）呼叫 `admin_import_preview` 試算，每筆標示：新增、更新、有管理員修改、不變、已存在（社群點）、無法匯入（id、來源、名稱、座標、https 來源或費率格式不符，附原因）。
  - 官方點以 id 更新，`hidden` 與既有點的 `effective_date` 不會改變；新官方點使用頁面上的生效日期。社群點只新增不存在的點（`source='import'`、`status='pending'`，擁有者沿用既有匯入點的帳號），已存在的點交給騎士回報與投票，不再更新。
  - 匯入頁是寫入資料庫的唯一途徑：`tool/import_mymaps.py` 原本的 `official.sql`／`import.sql` 輸出（`--sql-owner`）已於 2026-10-26 停用（#117），因為 `official.sql` 會覆寫除 `hidden`、`effective_date` 外的全部官方欄位，與本頁保留管理員修改的做法衝突。工具改以匯入頁的檢查（`admin_import_plan` 的 id、來源、名稱、座標、縣市、https 來源與欄位型別規則）驗證產出的 JSON，有任何一筆會被匯入頁拒絕時結束碼為 1 並列出原因。
  - **不默默覆寫管理員的修改**：某欄位最近一次改變它的稽核紀錄是管理員寫入（點位頁修改、採納回報、管理員新增、改為官方點、費率轉換），且目前值仍是那次寫入的值時，該欄位視為管理員修改。匯入值不同時列為「有管理員修改」，差異表顯示修改日期與來源，預設「保留管理員修改」，逐欄切換為「以匯入值覆寫」才會寫入；其餘欄位照常更新。匯入寫入記為 `import_spot`，之後的匯入不把匯入值當成管理員修改。
  - 檔案沒有 `fee` 且收費資訊與資料庫相同時，保留資料庫已有的結構化費率。
  - 套用時以試算時的 `updated_at` 檢查，試算後被改過的點位略過並提示重新試算；每筆各自寫入，被資料表約束拒絕的點位列出原因，不影響其他點位。結果顯示新增、更新與未寫入的筆數及原因，並重新試算。
  - 匯入不會讓管理員核驗車種的 trigger（P4a-1）把匯入新增的社群點當成管理員核驗。
  - 覆蓋層（[CONTRIBUTION_TIERS_FEASIBILITY.md](CONTRIBUTION_TIERS_FEASIBILITY.md) §5.6）尚未建立：管理員保留的值仍存在 `official_heavy_spots`，以稽核紀錄辨識；覆蓋層上線後，差異試算改為列出受影響的覆蓋層。`vehicle_source` 旗標（同文件 §0 第 9 點）也尚未加入匯入。
- **費率轉換**：`admin_fee_backlog` 列出 `fee` 為 null 的點位（兩張表，含已隱藏），網站以 `lib/admin/import/fee_reading.dart` 依收費資訊的寫法分組解析，分列：
  - 可轉換：官方資料明確寫出的機車費率（略過汽車、月租、季租、身障費率；「小型車（含大型重型機車）」是公告寫明的大型重機費率）；社群整理的「X（大型重機比照機車費率）」只轉成機車費率 X；重機專用格上未註明依據的金額只屬於大型重機。預設勾選。
  - **大型重機費率不回退**：沒有大型重機費率時維持未確認，不自動比照機車或汽車；只有公告明定比照時才用 `same_as_scooter`／`same_as_car`。社群整理的「比照機車／比照汽車費率」「停汽車區」是車友回報，不是公告，所以大型重機一律不自動轉換，「比照汽車費率」「停汽車區」的金額只列為需人工確認的建議值。
  - **現有費率格式無法表達的寫法一律不轉換**，交人工確認並說明原因：以倍率計算（臺北路外試辦機車區為機車費率 2 倍）、首段 0 元（臺北限時重機格首 20 分鐘 0 元，不等於免費）、機車的免費時段（入場前 30 分鐘免費）、依平日／假日或日夜時段而不同、收費上限或計次的重設時間不是每日 0 時（以凌晨 2 時為基準、隔日 3 時另計、入場 24 小時）。
  - **保守通則**：金額之外只要還有其他金額、日期或時段限定詞（平日、假日、週末、夜間、尖峰、x 點至 y 點等）、優惠或條件詞（折抵、憑證、限定對象等），就交人工；官方資料的限定詞與同一車種的相鄰片段一起判斷，社群整理的寫法在整段文字內判斷。只有入口位置、需按鈴等非計費備註可以略過。
  - 需人工確認的其他原因：未註明車種、依區域或牌色而不同、「計時 X 元」沒有計費單位、另列「重型機車」、「另訂費率」、混有拖吊保管費等。能讀出建議值的可勾選採用；沒有建議值的列出點位連結，到點位頁逐筆設定（點位頁的結構化費率欄位由管理站結構化費率 PR 提供）。
  - 無法判斷：「請依現場公告」「未知」、只有汽車或月租費率，維持未確認（null），不需處理。
  - 「寫入 N 筆費率」才呼叫 `admin_convert_fees`：只寫 `fee`（以 `valid_fee()` 驗證），`fee_note` 保留原文（含月租、入口等補充，供重新匯入比對）；App 有 `fee` 時先顯示 `fee`。點位表單的「`fee_note` 須為 `fee` 的文字」檢查（`202610260010`）只在之後的編輯動到費率或收費資訊時套用，屆時兩者一起改；收費資訊在讀取後被改過或已有費率的點位略過。每筆寫入稽核紀錄 `convert_fee`，之後匯入視為管理員修改。
  - 以 2026-10-25 的匯入檔試算：官方點 1,497 筆中可轉換 646、需人工確認 260、無法判斷 591；社群點 630 筆中可轉換 140、需人工確認 296、無法判斷 194。轉換規則的單元測試使用 staging 的實際寫法（`test/admin/fee_reading_test.dart`）。
- **依價格篩選不在本階段開放**：等 staging 與 production 的轉換與人工確認完成後另行處理。
- 版面：< 680 px 差異表每個欄位上下排列（欄位名稱、目前、匯入、保留／覆寫開關），操作列固定在底部並上下堆疊；寬螢幕為「欄位／目前／匯入」三欄。狀態同時以圖示與文字表示，匯入會寫入的值以黃色斜角色帶標示，保留的匯入值以刪除線與「不匯入」標示。

### P7 實作

- 路徑 `/users`、`/users/<使用者 id>`；程式位於 `lib/admin/users/`。版面與點位頁相同：寬螢幕清單＋詳情，< 680 px 先列表再詳情。
- **搜尋**（`admin_users(p_query, p_limit)`，security definer，先檢查 `is_admin()`）：完整的使用者 id、完整 email（不分大小寫精確比對）或顯示名稱的一部分（萬用字元視為一般文字）；空白時列出最近 30 天有回報的帳號，最近回報的在前，最多 100 筆。顯示名稱沿用 `contributor_display_name()`。
- **email 遮蔽**（2026-10-25 確認）：只顯示部分字元（如 `sm***@gmail.com`），遮蔽在資料庫函式內完成，完整 email 不經 API 或畫面；需要找特定騎士時以完整 email 精確搜尋。
- **詳情**（`admin_user_detail(p_user)`）：今天的回報次數與每日上限（`apply_report` 的 10 次／帳號，UTC 日界＝台灣時間早上 8 點），近 7／30 天次數、網路位置數、近 30 天同網路位置的其他帳號數；最近 30 筆回報時間只附 6 碼網路代號（`ip_hash` 前綴，只能分辨是否同一網路，完整雜湊不離開資料庫）。回報統計：新增的社群點（含已隱藏）、仍在／已不存在投票、修改建議依狀態。另列此帳號新增的社群點與 App 上顯示的公開名稱，以及停權紀錄。這些是 P7 自己的查詢，不依賴 ④a 的 `admin_review_baseline`。
- **停權／解除停權**：Edge Function `admin-users`（`verify_jwt = false`，函式自行驗證）。`getUser` 確認 session 仍有效、未被停權，且帳號目前的 `app_metadata.role` 是 admin；`getClaims` 驗證 token 簽章並讀 `aal`，必須是 `aal2`（與 `is_admin()` 相同）。之後以 service role 呼叫 Auth Admin API `updateUserById(id, { ban_duration })`：7 天＝`168h`、30 天＝`720h`、直到解除＝`876000h`，解除為 `none`。不能停權自己或其他管理者。原因必填（1–500 字）。Auth 會拒絕被停權帳號的登入、token 更新與 `/user`，因此 `submit-report` 的 `getUser` 立即擋下回報與投票。
- **稽核**：停權變更後由 Edge Function 呼叫 `admin_record_user_ban`（只授權 service role）寫入 `admin_audit_log`（`target_table='auth.users'`，前後的 `banned_until`、期間、原因）。Auth API 與資料庫無法同一 transaction：稽核寫入失敗時函式把停權狀態還原（原本有停權則還原剩餘時數，無條件進位到小時）並回錯誤；還原前重新讀取帳號，若停權狀態已不是本次寫入的值（另一位管理者同時變更），保留較新的變更、不還原。
- **清除公開名稱**：詳情先列最新 50 個社群點，「載入更早的點位」以 `admin_user_spots(p_user, p_offset)` 分頁（依建立時間，清除名稱不會改變順序）；逐點以 `admin_clear_contributor_name`（#81）清除，原因選填、寫入稽核紀錄；清除後即使改名也不再顯示。停權後背景重新讀取停權紀錄時，若期間又有停權或清除操作，舊的讀取結果會被捨棄，不覆蓋較新的畫面狀態。
- 測試：pgTAP `admin_users_test.sql`（一般使用者、無 `aal2` 的 admin、anon 被拒；搜尋與遮蔽；統計；只有 service role 能寫停權紀錄、稽核不可修改）；deno `admin-users/handler_test.ts`（非 admin、無 `aal2`、無 token 被拒且不呼叫 Auth；停權與解除寫稽核；稽核失敗還原；輸入驗證；不能停權自己或管理者）；widget test `test/admin/users_test.dart`。

### C6b 點位表單計費規則與審核頁（stack C）

依停放條件與費率畫布（AdminSpotForm、AdminReviewDiff、AdminSharedPlan）與設計文件 §2.6、§8.4，migration `202610270090_admin_spot_plans.sql`：

- **讀取**：點位表單與審核頁改用 `admin_spot_rows(p_source_ids)`（管理員限定、最多 200 筆）讀完整欄位，包含 `fee_plans`、`fee_plan`、`fee_source_text`、`parking_zones`。`community_spots` 的欄位授權不變（規則名稱只給管理員看）。
- **路外點位（`space_type = offStreet`）的費率改由計費規則管理**：
  - 「計費規則」列出每條規則的名稱與 App 句子；新增、改名、改費率在對話框用共用 FeeEditor（手機全螢幕）。名稱空白時依車種與收費方式命名（同 `fee_plan_name()`）；最多 12 條、名稱 1–20 字且不重複。
  - 仍被全場費率或分區引用的規則，刪除鈕停用並寫「N 個分區在用，先改掉引用」（決定 51）；伺服器回 `23503 fee plan in use` 時依 `detail` 顯示同一句。
  - 「全場費率套用」選一條規則或不套用；改選時一併送 `fee` 與它的句子。只改規則內容時不送全場 `fee`／`fee_note`，由 `fee_plans_sync()` 同步（避免被當成不認得規則的寫入而移除未使用的規則）。
  - 「區域與格位」：同名同 `area` 的分區合成一張區域卡；每種格位可選格位（機車格／重機格／汽車格）、用途（普大共用、汽機共用）、收費格／免費格、兩個車種的可停三段按鈕，以及計費規則（一併帶上規則的費率）。分區條件一律寫 `allow`，`access` 由 `legacyAccess()` 推導（決定 32），推導不出時不能儲存並說明原因。依據（公告網址、生效日、到期日）寫在區域卡，套用到卡內每種格位；既有的限時、共用時段照原樣保留。另有「分區資料已涵蓋全場」（`zones_complete`）。
  - 路邊點位維持單一 FeeEditor，規則由觸發器自動管理。
- **原始公告文字**：`fee_source_text` 有值時在費率區唯讀顯示，App 不顯示（設計 §7 第 12 項）。
- **比照來源沒有費率**（#155 第 13 項）：`Fee.followGap` 由 FeeEditor、點位表單 `validateSpotField` 與審核頁 `validatePatch` 共用，汽車未確認時大型重機比照汽車不能儲存或套用。
- **審核頁**：
  - 費率差異逐車種列出合併後的結果：「維持目前」、新費率＋「有變更」、「改成未確認」＋「會清除」，狀態用文字與底線表示，不只靠顏色。
  - 顯示預檢標記 `risk_flags`（#158）與附上的公告連結 `evidence_url`；`stored_pair_hold` 的規則寫明「建議只改費率（或條件），和點位目前的條件（或費率）不一致」，提醒一併確認（#155 第 19、20 項）。
  - 全場費率引用的規則也被分區使用時，套用前詢問「只改全場費率」（預設，另開一條規則，名稱可改）或「改這條規則」（全部跟著改），確認鈕寫明套用到哪裡。`admin_resolve_report` 因此接受 `fee_plans`／`fee_plan`；這兩個鍵是管理員推導的值，不參與 `base_spot` 衝突檢查。

### C6b 暫時封閉與地圖上限（#116、#133）

依暫時封閉畫布（Main、ClosureDetail，決定 41）與 C6 畫布 ClosureAdmin、MapLimit，migration `202610270091_spot_closures.sql`：

- **資料**：兩張點位表加 `closure`：`{reason: works|closed, since, until?, basis?}`（`valid_closure()`）。沒有 `until` 時 `since` 後 7 天到期；`closure_state()` 依臺灣日期回 `active`／`expired`。`public_spots`（v3／v2／原版 viewport 同步帶出）、`official_viewport_spots_v3` 與 `admin_spot_rows()` 帶 `closure` 與 `closure_state`，App 與管理站讀伺服器的判斷。到期後點位照常顯示並請車友確認，不刪除點位。
- **App 回報**：「這裡已經不能停車」的原因改成膠囊（選中只換底色與框線、不加勾勾、寬度不變）；施工中與暫時封閉改問「預計什麼時候恢復？」（不知道／有寫日期＋日期選擇器），取代 40 字自由文字，送 `proposed.closure = {reason, until?}`（`validate.ts` 與預檢 `gone_with_changes` 允許）。
- **App 詳情**：到期前「施工中／暫時封閉，暫時不能停」與預計恢復日期或「恢復時間未知」；過期後「原定…恢復・現場是否已恢復，還沒有人確認」與「已經可以停」（送 `field: reopened`、`proposed.closure = null`）／「還是不能停」（開啟「這裡已經不能停車」）。
- **管理站**：點位表單「暫時無法停車」區：原因（沒有／施工中／暫時封閉）、預計恢復日期（選填，可清除）、到期說明、依據、生效中／待確認標籤；過期時「延長到…」與「標記已恢復」。審核頁新增「暫時無法停車」欄位：騎士的建議套用時開始日為回報日（臺灣時間）、依據為「車友回報，附「說明」」，可在修改後套用調整；`admin_upsert_spot`、`admin_resolve_report` 接受 `closure`。
- **全站選項膠囊**：`OptionPill` 取代規則頁行政區預覽、App 共用時段的 ChoiceChip，FeeEditor 的收費方式膠囊也改用它（選中不再加粗字，寬度不變）。駁回原因維持附說明的單選清單。
- **地圖上限（#133）**：`admin_viewport_spots_v2()` 以單一 jsonb 回傳 `{rows, counts, truncated}`，不受 API `max_rows` 截斷；全部最多 1,000 筆、每層最多 500 筆，依社群點、官方點、已隱藏的順序填入。截斷時地圖顯示「這個範圍的點位太多，只顯示 1,000 個」、各圖層數量（未全部載入時寫「已顯示／總數」，一筆都沒載入寫「未載入」）與「放大地圖或關掉一個圖層」。後端尚未更新時退回舊 RPC，回 1,000 列也視為截斷。

## CI／CD
- `tool/ci_changes.py` 將 `lib/admin/` 歸入品質檢查與 admin web 建置（`flutter build web -t lib/main_admin.dart -o build/admin`），不觸發模擬器。
- `cd-staging.yml` 部署 admin 到 staging hosting；RC tag 部署 production。
- Maps Web 金鑰加入 admin 網域的 referrer 限制。

## 驗證
- pgTAP 涵蓋所有權限邊界。
- Widget test：佇列、差異表、表單驗證、位置選擇元件、非 admin 拒絕畫面。
- admin web 建置以 Chromium＋Playwright 做 smoke test。

## 遊戲化接軌

> 狀態：**已規劃、未實作。** 2026-10-26 使用者決定現在修訂本文件（[研究文件](CONTRIBUTION_TIERS_FEASIBILITY.md) §10 第 8 點），把遊戲化研究需要的管理站功能列為已規劃。本節只新增規劃，不改上方 P0–P7 已實作或實作中的描述；各項依研究文件 §9 的階段實作，屆時再寫成各自的「實作」小節。

| 項目 | 範圍 | 依據 | 研究階段 |
|---|---|---|---|
| 多層級角色 | 社群等級 L0–L4 加管理員。L0–L2 由每日 job 依 `contributor_standing` 自動計算；L3 `verifier`、L4 `guardian` 寫入 `app_metadata.role`，伺服器端另以 standing 二次檢查。管理員在管理站確認 L4（L3 滿 90 天且準確率達標）、撤銷角色、凍結。既有 `admin_*` RPC 仍只認 `is_admin()`；L3／L4 的能力走各自的 RPC（`confirm_evidence`、`guardian_resolve_dispute`），不取得管理權限。L4 的爭議初審在 App 內的審核任務進行，管理站維持只給 MFA（`aal2`）管理員（2026-10-26 決定） | [研究文件 §5.2](CONTRIBUTION_TIERS_FEASIBILITY.md#52-信任等級)、§6（`admin_set_role`） | 階段 1（L0–L2）、階段 2（L3、L4） |
| P5 規則頁：草稿與影響分析 | 貼入公告（網址、文字或 PDF）→ LLM 輔助產生結構化草稿，每個欄位旁標出原文片段，沒有原文片段的欄位不可確認；一致性檢查；影響分析列出套用後 `EligibilityStatus` 會改變的點位數（依型式與車種的 before／after）、與新規則衝突的官方明載值、會自動結案的 A 類案件；管理員逐欄確認後才發布。另列規則複查任務（矛盾觀察聚合） | [研究文件 §5.7](CONTRIBUTION_TIERS_FEASIBILITY.md#57-法規預審引擎) 第 2 面向、§10 第 11、13 點 | 階段 2 |
| P6 匯入：覆蓋層試算 | 差異試算除官方值差異外，另列「有覆蓋層的欄位」；先以覆蓋層保存的官方值快照比對，只有官方欄位確實變動時才判斷「官方新值是否與社群值一致」：一致 → 覆蓋層 `confirmed_by_official`；不一致 → `superseded` 並產生重新核實任務；官方值未變動時覆蓋層維持 `active`；由管理員一次確認。匯入只更新官方欄位，保留 `hidden` 與覆蓋層；並寫入 `vehicle_source` 旗標 | [研究文件 §5.6](CONTRIBUTION_TIERS_FEASIBILITY.md#56-官方點的資料修改核實模式決定) 第 3、7 點、§0 第 9 點 | 階段 1 |
| P7 使用者頁：等級、點數、角色 | 詳情加等級、點數（`point_ledger` 明細）、準確率、翻案與濫用紀錄、凍結期限；角色授予（L4 確認）與撤銷、標記濫用（回 L0 並凍結 180 天），皆寫稽核 | [研究文件 §5.2](CONTRIBUTION_TIERS_FEASIBILITY.md#52-信任等級)、§5.3、§7 | 階段 1（等級、點數）、階段 2（角色） |
| 指標頁 | 研究文件 §2.1 全部指標：社群結案率、管理員逐案結案率、B 類預審率與否決率（> 20% 警示）、A 類引擎一致率、預檢誤攔率、翻案率、抽查不合格率、審核時效、審核者覆蓋；各類別閘門狀態與一鍵關閉。資料層沿用 `admin_review_baseline` | [研究文件 §2.1](CONTRIBUTION_TIERS_FEASIBILITY.md#21-指標)、§2.4 | 階段 3 |
| B 類「已預審」佇列 | 審核頁新增分頁：社群已達預審門檻的 B 類案件（已不存在、型式跨路外／路邊、位置移動 > 150 m、合併重複點、改為官方點），顯示參與票數、照片與已套用的安全中間狀態（例如 `reported_gone`），管理員一鍵確認或否決；否決時參與者扣分 | [研究文件 §5.1](CONTRIBUTION_TIERS_FEASIBILITY.md#51-社群審核流程與共識規則) B 類列、§0 第 3、6 點 | 階段 2 |
| 抽查佇列 | 每月隨機抽查社群結案案件：起始 5%，翻案率穩定後 2%，案件少時每月至少 30 件；不合格即翻案（`admin_reverse_decision`），結果寫 `audit_samples` | [研究文件 §5.4](CONTRIBUTION_TIERS_FEASIBILITY.md#54-防刷與品質控制)、§5.5、§10 第 6 點 | 階段 2 |

審核頁另依研究文件 §7 規劃「社群結案」「爭議」（L4 初審後仍無法定案、送管理員終審者）「禁區」分頁，與上表的「已預審」「抽查」一起實作；黃金任務題庫由管理員維護（§10 第 4 點），管理介面隨階段 1 規劃。

## 不在範圍內
即時車位與 TDX 即時層、照片審核（待 Storage 上傳上線後另行規劃）。數據儀表板與多層級角色原列於此，2026-10-26 起改為已規劃，見「遊戲化接軌」（指標頁、多層級角色）。
