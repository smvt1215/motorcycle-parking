# 機車停車指南 APP（普通機車 + 大型重機）— 實作計畫

> 狀態：MVP 實作與 UI 驗證中。本階段只提供靜態點（官方點＋社群點），不串接即時車位。CI（含 Android／iOS 模擬器與 CodeQL）已運作；staging 後端已部署到 Supabase 官方託管（2026-10-21，停車點資料待匯入），手機測試版建置待設定 Maps 金鑰與簽章。Google Maps Platform 已啟用，API Key 尚未設定。最後更新：2026-10-21

## 背景
目標是做一個台灣用的機車停車指南 APP，同時服務「普通機車」與「大型重機（黃牌/紅牌）」騎士。
重機停車規定各縣市差異大且正在快速變動（例：台北市 2026/10/6 起開放約 6.3 萬個路邊收費機車格給重機、可斜停兩格、每次 40 元；新北、桃園、台中、高雄各有不同做法），騎士跨縣市容易誤觸規定，找車位也困難。
專案已建立 Flutter MVP、本機 Supabase schema 與測試；目前持續依參考介面調整並接入 Google Maps。

已確認的決策：
- 平台：**Flutter**（iOS / Android，另可建 Web 方便測試）
- 資料：**各縣市政府開放資料與 TDX（靜態匯入）＋社群回報**；Google 我的地圖「Alan大重停車記事」經官方核驗後匯入
- 後端：**Supabase 官方託管**（Postgres + PostGIS、Auth、Edge Function `submit-report` 處理社群寫入）。2026-10-21 評估 GCP 自架後決定採官方託管：官方託管只在 AWS，初期成本約每月 0–25 美元，自架約 40–150 美元且需自行維運。
- 地圖：**Google Maps + 官方 `google_maps_flutter`**，支援 Android、iOS 與 Web；本機尚未設定金鑰或離線測試時保留 OpenStreetMap 預覽底圖。停車資料來源為官方靜態點與社群回報。
- UI：**雙平台自適應**，iOS 依 Liquid Glass（HIG，iOS 26/27）、Android 依 Material 3 Expressive；iOS 關鍵導覽元件嵌入原生 Liquid Glass 元件（見「UI 設計規範」）
- 第一版功能：地圖找附近停車位、停車規則指南、記住我停哪裡、使用者回報/收藏停車點

## 架構總覽
```
Flutter App ──► Supabase Postgres（官方點 official_heavy_spots／社群點 community_spots，RPC 依地圖範圍讀取）
     │
     └────────► Supabase Edge Function `submit-report`（社群寫入）
（2026-10-17 起移除 TDX 即時層；TDX 只在 `tool/import_mymaps.py` 用於靜態核驗與補入。原架構：）
Flutter App ──► Supabase Edge Function `tdx-parking` ──► TDX API（金鑰只存在伺服器）
     │
     └────────► Supabase Postgres（community_spots / spot_votes / favorites / city_rules，RLS 保護）
本機：停車紀錄（隱私，不上傳）、車種設定
```
未設定 Supabase 時（`--dart-define` 未給），App 自動改用內建範例資料，方便開發與測試。

## Google Maps 底圖切換（2026-10-11 更新）

### 已確認範圍
- 使用者已啟用 Google Maps Platform，目前尚未建立或提供本機 API Key 設定。
- 更換地圖底圖、相機操作與群聚標記；沿用目前的浮動搜尋框、下拉停車點選單、車種與格位篩選、探索／個人中心／貢獻三個分頁。
- 地圖拖曳或縮放結束後，依可見範圍查詢停車資料；搜尋只比對目前範圍的停車點，空白或只有空白字元不能送出。
- 詳情抽屜使用根 Navigator，覆蓋分頁與其他控制元件。全高下拉先停在半高；從半高再次下拉關閉。修改建議面板疊在詳情之上。
- 深淺色隨系統切換。Google Maps 淺色沿用預設底圖，深色使用本機樣式；停車資格仍以顏色加形狀區分。
- 第一版沿用 TDX／社群搜尋，Google Maps 供應底圖。Google Places 地點搜尋、評論、照片與內建逐向導航未納入此次切換。

### 搜尋目前行為
- 單一浮動搜尋框搭配下拉結果，不另開搜尋頁。
- 提示「搜尋此範圍停車點」，比對目前範圍停車點的名稱、縣市、行政區與備註；拖曳地圖後，結果跟著新範圍更新。
- 搜尋結果與地圖共用格位、隱藏不可停條件；下拉列顯示結果數及是否已篩選。無結果時可直接清除篩選。結果列以與地圖相同的狀態標記開頭，副標顯示縣市行政區、可停狀態、格位類型及非預設的費率說明，並依可停 → 有條件 → 不可停排序（同級維持原順序）。
- 篩選列依序為「車種／地圖怎麼看（圖示鈕）／全部格位（選單）／隱藏不可停」，格位選單明確區分路邊收費機車格、免費機車格、重機專用格、汽車格、路外停車場；選中後顯示名稱，提供清除篩選，保留車種偏好。本階段只提供靜態點，不提供「有剩餘車位」篩選。「隱藏不可停」依目前車種排除判定為不可停的點，保留有條件的點；待確認點同樣依其判定處理。社群回報本身不會讓點位變成不可停，待確認點只會因法規（例如普通機車遇重機專用格、格位不在該縣市開放類型）判定為不可停，此時一併隱藏。篩選列一次建構全部按鈕並可橫向捲動。
- 「地圖怎麼看」圖例（參考 [重機能停哪?](https://findparkinglot.github.io/) 的圖例說明）以實際標記元件呈現可停／有條件／不可停／待確認四種狀態，形狀與顏色雙重編碼，並說明群聚數字與長按回報；車種選單沿用同一份圖例。Flutter 與 Google 底圖標記共用同一組顏色與圖示定義。
- 搜尋列右側提供搜尋按鈕，取代與個人中心重複的設定入口。空白時按鈕停用；純空格仍可清除。Enter 或搜尋按鈕只有唯一結果時開啟詳情，多筆時維持下拉選擇，不擅自開啟第一筆。
- 搜尋列與篩選高度依系統字級調整，下拉結果可捲動並避開鍵盤。
- 空白或純空白字元不能送出；選取停車點後移動地圖並開啟最上層詳情抽屜，關閉詳情不自動重開下拉選單。
- 地址／地標定位尚未接入。Google 底圖切換本身不會自動提供 Google Places 搜尋；若加入此流程，需啟用並設定對應服務及另行驗證。

### 平台與金鑰設定
- 官方 Flutter 套件採 `google_maps_flutter` 2.18.2；iOS 採 `google_maps_flutter_ios_sdk9` 2.19.0，保留 iOS 15 下限。
- Android 啟用 Maps SDK for Android，金鑰限制為 App 的 package name 與簽章 SHA-1。
- iOS 啟用 Maps SDK for iOS，金鑰限制為 App 的 bundle identifier。
- Web 啟用 Maps JavaScript API，金鑰限制為允許的網站來源；本機測試列入 `http://localhost:3000/*` 與 `http://127.0.0.1:3000/*`。
- 三個平台分別建立金鑰，填入不進版控的 `config/maps.local.json`；範本為 `config/maps.local.example.json`。只需先填目前要驗證的平台。
- `tool/configure_maps.py` 產生不進版控的 Android、iOS 與 Dart 設定；Web 在需要 Google Maps 時才載入 SDK。設定工具不輸出金鑰。
- 未設定對應平台金鑰時沿用 OpenStreetMap 預覽；Google SDK 載入失敗時顯示重試，避免將失敗的 Google 地圖誤呈現為成功載入。
- Google Maps 的標誌與版權由 SDK 顯示，控制元件需避開其位置；設定頁提供授權資訊入口。

### 成本與驗證
- 一般手機 Maps SDK 地圖載入目前有不限量免費額度；Web Dynamic Maps 每月 10,000 次免費，超過依用量計費。Places、Routes 等其他服務各有自己的計費，不包含在此次底圖切換中。以 [官方價格](https://developers.google.com/maps/billing-and-pricing/pricing) 為準。
- 已通過：Flutter 程式分析、24 項 Flutter 測試（含 Google 相機範圍與標記的模擬平台測試），以及 3 項金鑰設定工具測試。Web 搜尋／抽屜／深淺色預覽另做瀏覽器驗證；模擬平台測試不代表實際 Google 圖資已載入。
- Web 建置與 Chromium 預覽已通過：使用未設定金鑰的 OpenStreetMap 預覽，驗證空白搜尋、下拉選取、詳情及修改建議疊放、拖曳更新範圍、三分頁與系統深淺色，未出現瀏覽器錯誤。此結果不涵蓋 Google HTML 地圖的實際事件疊放。
- Web 必須處理原生 HTML 地圖的事件攔截，確認浮動搜尋、按鈕、分頁和最上層抽屜可操作，開啟面板時底圖不接收拖曳。
- 實際 Google 圖資載入、API Key 限制與帳單設定需在填入有效金鑰後驗證；Android／iOS 原生疊放另由模擬器或實機驗證。未完成的項目不得標示已通過。

官方文件：[Flutter 平台設定](https://developers.google.com/maps/flutter-package/config)、[套件與平台支援](https://pub.dev/packages/google_maps_flutter)、[Web 事件處理](https://pub.dev/packages/google_maps_flutter_web)。

## 本機開發環境（Supabase local）
開發時在自己的電腦用 Supabase CLI 的本機堆疊（Docker）跑完整後端，不必連雲端專案；staging 與 production 仍用雲端（見 [CICD.md](CICD.md)）。

| 環境 | 後端 | 用途 |
|---|---|---|
| demo | 無（App 內建範例資料） | 只做 UI、沒有 Docker 時 |
| **local** | `supabase start`（本機 Docker） | 日常開發：schema、RLS、Edge Function、社群回報流程 |
| staging | Supabase 雲端 staging 專案 | 合併到 `main` 後自動部署，測試機安裝的 APK／IPA 連這裡 |
| production | Supabase 雲端 production 專案 | 正式版 |

### 工具與啟動
- 需要 Docker（Docker Desktop、OrbStack 或 Colima 皆可）與 Supabase CLI；CLI 版本固定，和 CI 使用同一版，升級時兩邊一起改。
- `supabase/config.toml`（`supabase init` 產生）納入版本控管，只影響本機堆疊，不會套用到雲端專案。
- `supabase start` 啟動 Postgres（含 PostGIS）、Auth、PostgREST、Storage、Studio 等；預設位址：API `http://127.0.0.1:54321`、資料庫 `54322`、Studio `http://127.0.0.1:54323`、測試信箱 `54324`。`supabase status` 顯示本機 URL 與 anon key。
- `supabase stop` 保留資料；`supabase stop --no-backup` 連資料一起清除。

### Schema 開發流程
1. `supabase migration new <名稱>` 建立 migration，寫 SQL。
2. `supabase db reset`：清空本機資料庫、從零套用全部 migration、再執行 `supabase/seed.sql`（等同 CI 的「可從零重建」檢查）。
3. `supabase test db` 執行 pgTAP 測試（與 CI 相同）。
- 在 Studio 介面改表時，要用 `supabase db diff -f <名稱>` 轉成 migration 檔，不能只改本機資料庫；migration 規則（向下相容、只能往前）見 [CICD.md](CICD.md)「資料庫 migration 規則」。

### 種子資料 `supabase/seed.sql`
- 只用於本機與 CI；`supabase db push` 預設不執行 seed，staging／production 不會被寫入測試資料。
- 內容：
  - 台北周邊的 `community_spots`，涵蓋各種格位類型與「待確認／已確認／隱藏待審／資訊可能過時」狀態，以及對應的 `spot_votes`。
  - `city_rules`（與 `assets/rules/parking_rules.json` 相同的初始規則）。
  - 測試帳號：合格帳號、建立未滿 7 天的新帳號、匿名帳號、管理者，供 pgTAP 與 Edge Function 測試模擬多人確認、加權計分與限流。
- 範例停車點與 `lib/data/demo_data.dart` 使用同一份來源（例如 `tool/` 下的 JSON，以腳本產生 `seed.sql` 與 demo 資料），避免兩邊不一致。

### Auth（本機）
- `config.toml` 開啟匿名登入；CAPTCHA 在本機關閉（staging／production 在 Supabase Dashboard 開啟 Turnstile）。
- **Google 登入**：本機使用另一組開發用 Google OAuth client（redirect URI 為 `http://127.0.0.1:54321/auth/v1/callback`），client secret 放 **repo 根目錄**的 `.env`（不進版控，根目錄附 `.env.example`），`config.toml` 以 `env()` 引用；Supabase CLI 的 `env()` 讀取專案根目錄（`supabase/` 的上一層）的 `.env`，不是 `supabase/.env`（[說明](https://supabase.com/docs/guides/local-development/managing-config#using-secrets-inside-configtoml)）。
  - OAuth 完成後，瀏覽器會被導向 `127.0.0.1:54321` 的 callback，再回到 App 的 deep link（`config.toml` 的 `additional_redirect_urls` 要列入 App 的 callback scheme）。在手機上 `127.0.0.1` 指的是手機本身，所以裝置必須能以 `127.0.0.1:54321` 連到電腦：
    - iOS 模擬器、Web：與電腦共用網路，直接可用。
    - Android 模擬器與 USB 連接的 Android 實機：`adb reverse tcp:54321 tcp:54321`，讓裝置上的 `127.0.0.1:54321` 轉到電腦。
    - iPhone 實機：沒有對應的轉接方式，Google 也不接受區網 IP 的明文 HTTP redirect；iPhone 實機的 Google 登入改在 staging 測試（真的需要本機測試時，用 HTTPS tunnel 並把 redirect URI 與 `config.toml` 改成 tunnel 網址）。
- **Apple 登入**需要 HTTPS 網域，本機不設定，只在 staging 驗證。
- 需要多個帳號的情境（兩位合格使用者確認、新帳號權重低、每帳號／每 IP 限流）以 pgTAP 與 Edge Function 測試搭配 seed 帳號覆蓋，不靠手動登入多個帳號。

### Edge Function（本機）
- `supabase functions serve`：本機執行全部 Edge Function，修改後自動重載。
- 本機 secrets 放 `supabase/functions/.env`（不進版控，附 `.env.example`）。
- ~~**TDX 範例模式**~~（2026-10-17 隨 TDX 即時層移除）：本機 `.env` 設 `TDX_MODE=fixture` 時，`tdx-parking` 改回傳 `supabase/functions/tdx-parking/fixtures/` 的 TDX 範例回應，沒有 TDX 金鑰或網路被擋時也能開發。只有明確設定這個值才會啟用；其他環境缺少 TDX 金鑰時直接回報錯誤，不會悄悄改用範例資料。
- 限流依 IP 計算，本機所有請求來自同一個 IP；手動測試達到上限時以 `supabase db reset` 重置。

### App 連本機後端
- 以 `--dart-define-from-file=config/local.json` 帶入 `SUPABASE_URL`／`SUPABASE_ANON_KEY`；repo 只放 `config/local.example.json`，實際檔案不進版控。
- 位址依執行環境而不同：
  - iOS 模擬器、Web（`flutter run -d chrome`）：`http://127.0.0.1:54321`
  - Android 模擬器、USB 連接的 Android 實機：先執行 `adb reverse tcp:54321 tcp:54321`，再用 `http://127.0.0.1:54321`（與 Google 登入的 callback 一致）；不需要登入時也可用模擬器的 `http://10.0.2.2:54321`
  - iPhone 實機：電腦的區網 IP（同一個 Wi-Fi，電腦防火牆放行 54321）；Google 登入見上方「Auth（本機）」的限制
- 本機後端是明文 HTTP，**只在 Debug 建置允許**：
  - Android：`network_security_config` 只放在 `debug` source set。
  - iOS：只在 Debug 設定的 Info.plist 加 ATS 例外（`NSAllowsLocalNetworking`）；實機連區網需要 `NSLocalNetworkUsageDescription`（iOS 14 起的區域網路權限）。實作時確認實際需要的鍵值。
  - staging／release 建置不含這些例外。
- 此開發環境已啟動 Docker 與本機 Supabase，資料庫及 Edge Function 可在本機驗證；CI 仍需獨立確認能從零建立堆疊。

## 專案結構（Flutter 專案放 repo 根目錄）
```
pubspec.yaml
lib/
  main.dart, app.dart                 # go_router（底部分頁：探索／個人中心／貢獻；規則與收藏由個人中心進入）
  ui/theme/                           # 設計 token（色彩、字級、圓角、間距）、Material 與 Cupertino 主題
  ui/adaptive/                        # 自適應元件層：依平台與 iOS 版本選擇實作（見「UI 設計規範」）
  core/config.dart                    # SUPABASE_URL / SUPABASE_ANON_KEY（--dart-define）
  core/geo.dart                       # 距離計算、bbox
  models/                             # vehicle_type, parking_spot, city_rule, parked_record
  domain/eligibility.dart             # 判斷某車位是否適合目前車種（純函式，單元測試重點）
  data/
    tdx_repository.dart               # 呼叫 Edge Function，取得正規化後的 ParkingSpot
    community_repository.dart         # 社群回報 CRUD、投票、nearby RPC
    rules_repository.dart             # 內建 JSON + Supabase city_rules 遠端覆蓋（取版本較新者）
    favorites_repository.dart
    parked_repository.dart            # 本機 shared_preferences
    demo_data.dart                    # 無後端時的範例資料
  features/
    map/        # 地圖、群聚標記、篩選（車種、空間類型、隱藏不可停）、車位詳情 bottom sheet、導航
    rules/      # 依縣市 × 車種顯示規則、生效日期、來源連結、免責聲明
    my_parking/ # 一鍵記錄位置/備註/樓層、計時提醒（本機通知）、導航回車旁
    favorites/  # 收藏清單
    report/     # 新增停車點、修改建議（含點位已不存在）
assets/rules/parking_rules.json       # 內建縣市規則（含 sourceUrl、effectiveDate）
config/local.example.json             # 本機後端的 --dart-define-from-file 範本（實際 local.json 不進版控）
config/maps.local.example.json        # Android／iOS／Web 地圖金鑰範本（實際金鑰不進版控）
tool/configure_maps.py                # 產生原生與 Dart 地圖設定，不輸出金鑰
.env.example                          # 本機 config.toml 以 env() 引用的 secrets 範本（例如開發用 Google OAuth secret；實際 .env 不進版控）
supabase/
  config.toml                         # 本機堆疊設定（匿名登入、本機 Google OAuth、關閉 CAPTCHA），只影響本機
  seed.sql                            # 本機與 CI 用的種子資料（不推到雲端）
  migrations/0001_init.sql            # 資料表、PostGIS、RLS、nearby_spots RPC、每日回報上限 trigger
  functions/submit-report/            # Deno：社群寫入（驗證、限流、IP 雜湊）
  functions/.env.example              # 本機 Edge Function secrets 範本
tool/import_mymaps.py                 # Google 我的地圖匯入、官方資料（含 TDX 靜態）核驗與正規化，輸出 data/imports/
test/                                 # eligibility、rules 解析、匯入資料、車種切換 widget test、雙平台 golden 截圖測試
.github/workflows/                    # ci.yml、ios.yml、android.yml、codeql.yml、cd-staging.yml、release.yml（見 docs/CICD.md）
fastlane/                             # 兩平台簽章、上傳設定與商店文字（見 docs/CICD.md）
integration_test/                     # 雙平台截圖情境（地圖、sheet、車種切換、深淺色），iOS 模擬器與 Android 模擬器共用
README.md                             # 安裝、Supabase 建置（中文）
```

## 主要套件
`google_maps_flutter`, `google_maps_flutter_ios_sdk9`, `pointer_interceptor`；預覽與離線測試保留 `flutter_map`, `flutter_map_marker_cluster`, `latlong2`。其餘為 `geolocator`, `flutter_riverpod`, `go_router`,
`supabase_flutter`, `shared_preferences`, `url_launcher`（跳 Google/Apple 地圖導航）, `flutter_local_notifications`（計時提醒）。
UI：`material_ui`、`cupertino_ui`（Flutter 官方設計套件，取代框架內建的 `flutter/material.dart`、`flutter/cupertino.dart`）、`cupertino_native_better`（iOS 原生 Liquid Glass 元件）、`material_3_expressive`（Android M3 Expressive 主題與元件，`M3ETheme` + `M3E*`）、`dynamic_color`（Android 動態配色）。需 Flutter ≥ 3.47（`material_ui` 的下限）。

## UI 設計規範（雙平台）
目標：iOS 看起來像 iOS、Android 看起來像 Android，各自符合最新設計規範；內容、資訊架構與品牌一致。

### 現況限制（2026-10 查證）
| 平台 | 最新規範 | Flutter 官方支援 | 對策 |
|---|---|---|---|
| iOS | **Liquid Glass**（iOS 26 推出；iOS 27 調整：預設透明度降低、系統設定可調玻璃強度） | 無。官方 [`cupertino_ui`](https://pub.dev/packages/cupertino_ui) 套件已發布（2026-10，1.1.2），但尚未包含 Liquid Glass；Flutter 自繪畫面，不會自動套用（[flutter#170310](https://github.com/flutter/flutter/issues/170310)） | 導覽與控制元件以 `cupertino_native_better` 嵌入**原生** UIKit 元件 |
| Android | **Material 3 Expressive**（形狀、彈簧動態、浮動工具列、強調字級） | 部分。官方 [`material_ui`](https://pub.dev/packages/material_ui) 套件已發布（2026-10，1.6.0，取代框架內建 Material），提供 `StyleVariant.material3Expressive` 列舉，但**只有個別元件支援**（1.5.0 起為 `IconButton`），`ThemeData` 沒有全域切換，官方標示仍在開發中（[flutter#168813](https://github.com/flutter/flutter/issues/168813)） | 以 `material_3_expressive` 的 `M3ETheme` + `M3E*` 元件實作（該套件建立在 `material_ui` 上）；官方元件陸續支援 Expressive 後逐一替換 |

### 自適應元件層 `lib/ui/adaptive/`
畫面只使用這一層的元件，不直接呼叫平台套件；官方支援補齊後只需替換這一層。
- **一律使用官方獨立套件**：全專案只 import `package:material_ui/material_ui.dart` 與 `package:cupertino_ui/cupertino_ui.dart`，**禁止** import `package:flutter/material.dart`、`package:flutter/cupertino.dart`，避免同時存在兩套主題與在地化設定（`material_3_expressive` 也明文要求）。在地化改用 `material_ui` 提供的 `GlobalMaterialLocalizations`（繁體中文）。CI 加一道檢查（只掃描本專案的 `lib/`、`test/`、`integration_test/`，不含第三方套件），發現禁止的 import 即失敗。
- **舊版相依的相容橋接（必要）**：`cupertino_native_better` 仍 import 框架內建的 `flutter/cupertino.dart` 與 `flutter/material.dart`（例如 `CNBottomSheet` 內部呼叫舊版 `showCupertinoSheet`），其主題與在地化型別和官方新套件不同。依 [`cupertino_ui`](https://pub.dev/packages/cupertino_ui#migrating-existing-code-to-this-package)／[`material_ui`](https://pub.dev/packages/material_ui#migrating-existing-code-to-this-package) 遷移指南第 3 步，在根 App 的 `builder` 同時包上 `MaterialUiCompatibilityBridge` 與 `CupertinoUiCompatibilityBridge`，讓舊版元件取得正確的 `ThemeData`／`CupertinoThemeData` 與 `MaterialLocalizations`／`CupertinoLocalizations`。`builder` 包住整個 Navigator，因此經路由開啟的 sheet 也在橋接範圍內。
- **實作前的相容性驗證**：開始實作時先做最小雛形，在橋接下確認 `CNTabBar`、`CNBottomSheet` 的主題、深淺色與繁中在地化正確（並納入 iOS 截圖測試）。原生元件的顏色仍以設計 token 明確傳入作為額外保險，但不取代橋接。
- **元件對照表**：實作時記錄每個 Android 元件目前用 `M3E*` 還是官方元件；每次升級 `material_ui`／`cupertino_ui` 時重新檢查，官方已提供就移除第三方套件（`cupertino_ui` 加入 Liquid Glass 後同理替換 `cupertino_native_better`）。
- APP 最低支援 iOS 15（`cupertino_native_better` 的下限），iOS 26 以上才使用原生 Liquid Glass。

| 元件 | iOS 26+ | iOS 15–18 | Android |
|---|---|---|---|
| `AdaptiveTabScaffold`（探索／個人中心／貢獻） | 原生 Liquid Glass 分頁列（`CNTabBar`） | `CupertinoTabBar` | `M3ENavigationBar` |
| `AdaptiveNavBar` | 透明 `CupertinoNavigationBar` + 原生玻璃圖示按鈕（`CNButton.icon`） | `CupertinoNavigationBar` | `M3EAppBar` |
| `AdaptiveSegmented`（普通機車／大型重機） | 原生 segmented control（`CNSegmentedControl`） | `CupertinoSlidingSegmentedControl` | `M3EButtonGroup` |
| `AdaptiveButton`、`AdaptiveSwitch`、`AdaptiveSlider` | `CNButton`、`CNSwitch`、`CNSlider` | Cupertino 元件 | `M3EButton`、`M3ESwitch`、`M3ESlider` |
| `AdaptiveSheet` | 車位詳情：`CNBottomSheet.show` + `DraggableScrollableSheet`；一般表單：`CNBottomSheet.showCupertino` | 同左 | 官方 `showModalBottomSheet`，詳情內容使用 `DraggableScrollableSheet` |
| 地圖動作（定位、記錄停車；篩選在上方篩選列） | 原生玻璃按鈕（`CNButton`）：定位用 glass，「記錄停車」用 prominentGlass。依 HIG，同尺寸選項以樣式而非大小區分主要動作，且主要動作獨立成焦點、每畫面只一個；日後新增圖層、指北等相關控制時，再以 `CNGlassButtonGroup` 群組 | Cupertino 按鈕（記錄停車用主色底） | `M3EToolbar.floating`（垂直，定位）+ 80dp `M3EFab`「記錄停車」 |

### iOS 規則（HIG）
- **玻璃只用在導覽／控制層**，不用在內容上；地圖滿版延伸到分頁列與導覽列下方。
- 原生元件會自動跟隨系統的玻璃強度（iOS 27）、「減少透明度」「增加對比」設定；Flutter 自繪的部分讀取無障礙設定（`MediaQuery` 的 high contrast、disable animations 等），必要時改用不透明背景與無動態效果。
- 使用 SF Symbols；支援動態字級（Dynamic Type）；點擊區域 ≥ 44pt。
- 原生元件以 platform view 疊在地圖上有效能成本：數量控制在分頁列與少數按鈕，實作時量測捲動與縮放幀率。
- **原生元件與彈出層的疊放協調**（套件[必要設定](https://pub.dev/packages/cupertino_native_better#required-setup-register-cntabbarrouteobserver)）：原生元件疊在 Flutter 畫面下方合成，若不協調，分頁列等原生元件會蓋在 sheet 上（例如遮住回報表單的輸入框），玻璃光暈也會透出。
  - 在根 `GoRouter` 的 `observers` 註冊 `CNTabBarRouteObserver`。
  - iOS 的 sheet 一律要讓套件知道它的位置：
    - 一般 sheet（回報表單等）以 `CNBottomSheet.showCupertino` 開啟（自動加上 `CNSheetGeometryProbe`）。
    - 車位詳情需要停在半高／全高，因此使用 `CNBottomSheet.show(useRootNavigator: true, enableDrag: false, isScrollControlled: true, ...)`（底層為 `showModalBottomSheet`，路由型別 `ModalBottomSheetRoute`，並自動加上 `CNSheetGeometryProbe`）。內容使用 `DraggableScrollableSheet`，設定 `initialChildSize: 0.5`、`minChildSize: 0.5`、`maxChildSize: 1.0`、`snap: true`、`shouldCloseOnMinExtent: false`。停回半高不自動關閉；只有在半高且內容已捲至頂端時，另一次向下拖曳才關閉。外層停用拖曳，避免直接收掉整個路由。
    - `CNTabBarRouteObserver` 只把**型別名稱含 `Sheet`** 的路由視為 modal 並隱藏分頁列（[原始碼](https://github.com/gunumdogdu/cupertino_native_better/blob/main/lib/components/tab_bar.dart)），`CNSheetGeometryProbe` 只回報位置、不會觸發隱藏。因此不得用 `PageRouteBuilder` 等一般路由開 sheet；若真的需要自訂路由，路由類別名稱必須含 `Sheet`。
  - 不使用不經路由的彈出層（例如 `Scaffold.showBottomSheet`）：`markAnyModalActive()`／`markAnyModalInactive()` 只增減 `anyModalDepth`（處理玻璃按鈕光暈與搜尋型分頁列），一般 `CNTabBar` 監聽的是只由 `*Sheet*` 路由觸發的 `modalDepth`，手動呼叫無法讓分頁列隱藏。若日後確有需要，除了呼叫上述方法處理光暈，彈出層也不得與分頁列重疊。

### Android 規則（Material 3 Expressive）
- 以 `M3ETheme`（`M3EThemeData`）提供 Expressive 主題，畫面一律使用上表的 `M3E*` 元件；`StyleVariant.material3Expressive` 只用在官方已支援的個別元件（目前為 `IconButton`），不當成全域設定。
- Android 12+ 使用桌布動態配色（`dynamic_color`），其餘使用品牌種子色。
- Edge-to-edge（Android 15+ 強制）；支援預測式返回手勢。
- Material Symbols 圖示、Expressive 形狀與彈簧動態；點擊區域 ≥ 48dp。

### 共用規則
- **深淺色模式**皆支援；字型用系統預設（PingFang TC／Noto Sans CJK TC）。
- **可停／有條件／不可停**三種狀態：除了顏色，還要用不同圖示或形狀區分（色盲友善），淺色與深色模式都要通過 WCAG AA 對比。
- **騎士情境**：常戴手套操作，「記錄停車」「導航回車旁」等主要動作放大、放在拇指可及處；地圖頁顯示「行駛中請勿操作」提示，不提供行駛中互動功能。
- 地圖標記、插圖等品牌元素兩平台一致。

### 驗證
- Golden 截圖測試：每個主要畫面 × iOS / Android × 淺色 / 深色。
- iOS 必測情境：在地圖頁開啟車位詳情與回報表單 sheet，確認分頁列與玻璃按鈕不會蓋住 sheet、輸入框可見可輸入、關閉後原生元件正常復原。
- 此開發容器無 macOS，iOS 原生 Liquid Glass 元件改由 **GitHub Actions macOS runner** 驗證（已獲同意；公開 repo 使用 GitHub 提供的標準 runner 不另收費）：
  - `ios.yml`：在 `macos-26` 以 `flutter build ios --release --no-codesign` 建置一次真機 Release，驗證 Release 設定與 AOT；另以 `flutter build ios --simulator --debug --no-codesign --target=integration_test/ui_test.dart --dart-define=OFFLINE_MAP=true` 建置一次模擬器測試 App。不需要簽章或 Apple 開發者帳號；測試 `.app` 封裝成 tar 上傳，保留執行權限與符號連結。
  - iOS 26 與 iOS 27 模擬器下載同一份 App，以 `flutter drive --use-application-binary` 執行 `integration_test` 截圖情境，不重新編譯：地圖頁、車種切換、車位詳情與回報 sheet（含上述疊放測試）、深淺色模式；截圖上傳為 workflow artifact，供 PR 審查時查看。
  - 執行條件：PR 變更 `lib/`、`ios/`、`integration_test/`、`pubspec.*` 或 `.github/workflows/ios.yml` 本身時才實際建置與截圖；只改文件時所有 job 直接回報成功，以節省排隊時間。
  - 穩定後將 iOS 建置列為 main ruleset 的必要檢查。注意：設為必要檢查的 workflow 不能用 workflow 層級的路徑過濾（只改文件的 PR 會一直等不到檢查結果而無法合併）；改為 workflow 每次都觸發，在 job 內判斷變更路徑，不需要時直接回報成功。
- Android 同樣由 CI 在**真實模擬器**上截圖（`android.yml`，GitHub Linux runner 支援 Android 模擬器硬體加速）。golden 測試由 Flutter 在測試程序內繪製，看不到下列系統層行為，所以必須在模擬器上確認：
  - 以一般 App 入口執行一次 `flutter build apk --release`，驗證 Release 設定與 AOT。
  - 以 `integration_test/ui_test.dart` 與 `OFFLINE_MAP=true` 建置一次 x86_64 Debug APK；兩個模擬器下載同一份 artifact，以 `flutter drive --use-application-binary` 執行，不重新編譯。
  - 模擬器：Android 16（API 36）與 Android 11（API 30），各跑淺色與深色。
  - Android 16：桌布動態配色、edge-to-edge 下系統列與內容不重疊、預測式返回手勢動畫（以 UI 自動化觸發返回手勢，截取動畫中途畫面）。
  - Android 11：沒有動態配色時改用品牌種子色。
  - 共用 `integration_test/` 的截圖情境：地圖頁、車種切換、車位詳情半高／全高、回報表單、深淺色；另檢查繁中字型。
  - 截圖上傳為 workflow artifact；執行條件比照 iOS：變更 `lib/`、`android/`、`integration_test/`、`pubspec.*` 或 `android.yml` 本身時才實際執行，路徑判斷寫在 job 內。

## 核心資料模型
- `VehicleType`：`scooter`（普通機車，白/綠牌 ≤250cc）、`heavy`（大型重機，黃牌 250–550cc / 紅牌 >550cc，可在設定選牌色供顯示）。地圖篩選列提供單一切換入口，選擇持久化。
- `ParkingSpot`：id, source(tdx/community), name, lat/lng, city, spaceType(路邊收費機車格/免費機車格/重機專用格/汽車格/路外停車場), feeNote, scooterTotal/available, heavyAllowed(nullable：依場站規定), updatedAt。
- `CityRule`：city, vehicle, allowedSpaceTypes, feeNote, canUseTwoSpaces, exceptions（如台北免費巷弄格不開放）, effectiveDate, sourceUrl, version。
- `eligibility(spot, vehicle, rule)` → `allowed / conditional(附說明) / notAllowed`，地圖標記顏色據此呈現。

## Supabase 資料表（RLS）
- `community_spots`：geography(Point) + 欄位同上；所有人可讀非 `hidden` 點位（`pending`／`confirmed` 均可見）；**RLS 禁止客戶端直接寫入**，新增與建議一律經 Edge Function `submit-report`（見「防濫用」）。
- `spot_votes`：保留既有 `(spot_id, user_id)` 唯一、`still_there / gone` 與加權門檻，供歷史資料及舊版 API 相容；新版 UI 不再送出存在狀態投票。不存在回報使用 `flag`，送入 `moderation_queue` 待審。
- `favorites`：user_id 私有。
- `city_rules`：公開唯讀，僅管理者可寫（讓規則改變時不必發版）。
- RPC `nearby_spots(lat, lng, radius_m)` 用 `ST_DWithin`。

## 規則資料初始內容
內建 JSON 先放：全國預設、台北、新北、桃園、台中、高雄。實作時逐一以各市政府/停管處官方公告查證並附 `sourceUrl`，查不到官方來源的欄位標示「請以現場標誌標線為準」。規則頁永遠顯示免責聲明與最後更新日期。

## 官方資料來源（分層，依查證結果決定用哪幾層）
| 層 | 來源 | 提供內容 | 已知限制 / 待確認 |
|---|---|---|---|
| 1 | **TDX**（交通部運輸資料流通服務） | 路外停車場靜態（`CarPark`）、車位類型與數量（`ParkingSpace`）、即時剩餘（`ParkingAvailability`）、路邊路段（`OnStreet/ParkingSegment*`），以 City 代碼分縣市 | 交通部自述機車車位數「若有才提供」；各縣市資料及統計方式不一、部分縣市未開放齊全；**完全沒有「重機可否停」欄位** |
| 2 | **縣市自有開放資料**（補 TDX 缺口） | 台北停管處路邊格位圖層（含機車格數、格種，每日更新）、台中路外/路邊剩餘（含機車欄位、10 分鐘更新）、台南 Parkweb API（含機車剩餘 `moto`） | 格式各異，每市要寫一個 adapter；只在 TDX 審查發現缺口時才接 |
| 3 | **縣市公告（人工整理）** | 重機開放規則、重機專用格位置（如新北 17 格專用格的路段） | 多半只有新聞稿/公告，無開放資料 → 進 `city_rules` 與 `official_heavy_spots` 表，由管理者維護；地圖以 `official_viewport_spots` 讀取已生效（`effective_date` 已到）的點位，與社群、TDX 資料合併顯示 |

### Phase 0：TDX 資料完整性稽核（實作前先做）
> 2026-10-17：改以 `tool/import_mymaps.py` 逐縣市比對官方資料（各縣市自有資料優先，TDX 補缺），結果見 `data/imports/google-mymaps/REPORT.md`；以下為原規劃。
在開發用的雲端環境實測時，`tdx.transportdata.tw`、`data.taipei`、`data.gov.tw` 都被網路政策擋下（403），所以**目前無法親自確認完整性**，稽核要在放行網域並取得 TDX 金鑰後執行：
- 寫 `tool/tdx_audit.dart`（或 Deno script），逐一跑 22 縣市，輸出 `docs/tdx-coverage.md`：
  - 路外停車場數、其中有機車車位數（`ParkingSpace` 機車類型）的比例
  - 有即時剩餘、且即時資料含機車欄位的比例；資料最後更新時間分佈（判斷是否「假即時」）
  - 座標缺漏/明顯錯誤（落在海上、0,0）比例
  - 路邊路段資料是否有機車格、是否有即時
- 對 3–5 個抽樣點（台北、新北、台中、高雄、一個偏鄉縣）與縣市官方資料交叉比對總格數
- 依結果決定：哪些縣市 TDX 足夠、哪些需接第 2 層 adapter、哪些只能靠社群回報。地圖上每個點都標示資料來源與更新時間。

## TDX 介接（Edge Function）
> 2026-10-17：本階段只做靜態點，`tdx-parking` Edge Function、App 的 TDX 即時層與 TDX 點位註記介面已移除。TDX 憑證只供 `tool/import_mymaps.py` 核驗與補入靜態停車場；`spot_annotations`、`confirmed_annotations` 與 `submit-report` 的 annotation 動作已一併移除（migration `202610170003_drop_annotations.sql`）。以下為原設計。
- 憑證 `TDX_CLIENT_ID` / `TDX_CLIENT_SECRET` 存於 Supabase secrets，App 內不含金鑰。
- 端點（以 Phase 0 稽核與 TDX Swagger 確認路徑與欄位）；只取機車相關車位類型並正規化為 `ParkingSpot`。
- 回應加快取（基本資料長、即時剩餘 1–2 分鐘），避免打爆配額。

## 社群回報機制
目標：補官方資料沒有的資訊（特別是「重機實際能不能停」），同時防止錯誤與灌水。

### 存在狀態與修改建議（2026-10-11 更新）
- 未收到不存在回報的點位視同存在，正常顯示；不要求使用者持續點「還在」維持可見。
- 移除獨立「還在／已不存在」按鈕。詳情以「導航到這裡／修改建議」為主要動作；小螢幕或放大字級時改為上下排列。標題與關閉獨占首列，收藏／分享放在次列。
- 「修改建議 → 點位已不存在」提供獨立項目與現場說明表單；描述撤除、施工或封閉狀況，必填內容送出 `flag`，供管理者審核，不因一次回報直接刪除或隱藏。
- 「存在」只代表仍列於地圖，不等同合法可停、剩餘車位或停放資格已驗證。既有可信度欄位仍供資格判斷與歷史相容，不再於詳情顯示「尚未確認／最後確認」等需要例行操作的提示。
- 正式回報需登入；範例模式只供本次功能測試。官方點與社群點都可提出修改建議；已移除的 TDX 範例（fixture）點會在收藏載入時清除。

### 回報與可信度規則
1. **兩種回報**
   - 新增停車點：長按地圖 → 表單（格位類型、普通機車可停、重機可停、收費、樓層/入口備註、選填照片）。
   - ~~**官方點位註記**~~（2026-10-17 隨 TDX 即時層移除）：在 TDX 停車場上回報「重機可停 / 不可停 / 須停汽車格」「入口限高/坡道陡」等，TDX 本身沒有這些欄位。
     - 註記先以 `pending` 存入 `spot_annotations`，管理者改為 `confirmed` 後才生效：`tdx-parking` 回傳停車點時以 RPC `confirmed_annotations` 取每個點最新一筆已確認註記，設定 `heavy_allowed`（須停汽車格視為可停）並在備註標示「社群回報經審核」。查詢失敗時維持 TDX 原資料，重機資格保持「有條件」。
2. **去重**：送出前查 15 公尺內同類型點，有的話引導查看既有點並提出修改建議，而非重複新增。
3. **存在與可信度分開處理**：新增點位的 `pending` 資料也正常可見；未知資格保留「有條件／請確認現場標示」。歷史投票的合格帳號與加權隱藏門檻保留於後端，但不是新版介面的存在確認流程。不存在／資訊錯誤建議進入 `moderation_queue` 待審；管理者判定後處理，資料超過 180 天未確認仍可提示可能過時。
4. **防濫用**：匿名身分可被任意重建（`signInAnonymously()` 每次都產生新 user id，[Supabase 官方文件](https://supabase.com/docs/guides/auth/auth-anonymous)亦建議搭配 CAPTCHA），因此**不能把匿名帳號當成一個人**：
   - **權限分級**：匿名或未登入只能瀏覽、收藏、記錄停車位置（收藏與停車紀錄不影響他人）；**回報、確認、投票、檢舉**需以 Google / Apple 帳號登入。
   - **CAPTCHA**：Supabase Auth 啟用 Cloudflare Turnstile（或 hCaptcha），登入時驗證。
   - **伺服器端限流**：所有寫入經 Edge Function `submit-report`，依 user id **與** IP 雙重限流（如每帳號每日 10 筆、每 IP 每日 30 筆），並記錄於 `rate_limit_events`；Supabase Auth 本身的註冊/登入速率限制同時開啟。
   - **裝置驗證（第二階段）**：上架後加入 Android Play Integrity / iOS App Attest，由 Edge Function 驗證後才接受寫入。
   - 不能確認自己的回報；檢舉按鈕 → `moderation_queue`；照片存 Supabase Storage，上傳前移除 EXIF。
5. **管理**：Web 管理介面完成前用 Supabase Dashboard；管理介面的範圍、管理者角色與審核畫面見 [ADMIN_WEB.md](ADMIN_WEB.md)。
   | 工作 | Dashboard 位置 |
   |---|---|
   | 建立、停用使用者（含匯入用帳號） | Authentication → Users |
   | 審核修改建議、不存在回報 | Table Editor → `moderation_queue` |
   | 維護縣市規則（見下方 `restriction` 說明） | Table Editor → `city_rules` |
   | 維護官方點 | Table Editor → `official_heavy_spots` |
   | 匯入資料（`official.sql`／`import.sql`）、批次修改 | SQL Editor |

   改 `city_rules` 並調高 `version` 時（App 只在資料庫版本較大時改用資料庫那份），`restriction` 要一起確認：
   - `pilot_area`：限公告的試辦行政區或路段。
   - `signage`：限現場標示開放的車格。
   - `unverified`：規則本身尚未核實，條件車格一律顯示「待確認」。
   - `conditional_space_types` 含路外以外的格位時必填，資料庫約束 `city_rules_restriction_required` 會擋下漏填；同時更新 `assets/rules/parking_rules.json`。

### 外部社群地圖（Google 我的地圖）（2026-10-17 更新）
「Alan大重停車記事」Google 我的地圖（https://www.google.com/maps/d/viewer?mid=1ORD5DnL6yqrCrtQJYB9TeTgOOlvo-Yc）列為資料來源之一。只取地點、類型、費率等事實資訊並重新整理為專案格式，不沿用原說明全文、連結、照片與回報者署名。
- 工具：`python3 tool/import_mymaps.py --mid <mid> --output data/imports/google-mymaps [--refresh] [--sql-owner <auth uid>]`。KML、官方資料與國土測繪中心查詢結果快取在 `artifacts/mymaps-cache/`（不進版控）；`--sql-owner` 另產生待審的 `community_spots` SQL，不直接寫入資料庫。
- 圖層：匯入 7 個停車相關圖層；「重機友善店家」不是停車點，「路邊友善車格」中的行政區政策說明點屬於城市規則，皆不建點。三重的路段線段以線段中點建點並保留 `road_segment`。
- 圖示對應：汽車區 → `heavyCar`、機車區 → `scooterHeavy`、重機專用格 → `heavyOnly`，以 `parking_zones` 表示；禁停圖層為 `heavy_allowed=false`，未確定圖層為 `null`。來源圖例的灰色（未確認）、橘色（進出場需注意）、藍色（特殊收費）轉為備註或入口說明。
- 官方驗證與修正：
  - 縣市／行政區：內政部國土測繪中心 `TownVillagePointQuery` 逐點反查。
  - 路外停車場：比對各縣市官方開放資料，有官方資料的欄位才改用官方值（名稱、地址、費率、機車格數；臺北另有大型重機格數）。
    - 臺北市停車場資訊（停管處 `TCMSV_alldesc`）、新北市路外公共停車場資訊、臺中市路外剩餘車位、桃園市停車率、高雄市公有路外停車場一覽表、臺南市路外停車場動態資訊、新竹市公有停車場相關資訊。
    - 高雄市民營路外停車場一覽表沒有座標，只在同一行政區內以名稱比對（相似度 ≥ 0.9），並保留來源座標。
    - 比對規則：去除營運商品牌、通用字與縣市前綴後比較名稱；80 公尺內相似度 ≥ 0.45、200 公尺內 ≥ 0.6，超過 200 公尺須名稱幾乎一致。來源名稱寫明「機車停車場」但官方資料的機車格為 0，或兩邊名稱標示不同型式（地下／立體／平面）時，視為不同場站。
    - 座標偏差超過 150 公尺時保留來源座標並列為待人工確認；偏差超過 400 公尺且名稱幾乎一致時才改用官方座標。
    - TDX 路外停車場（`CarPark`、`ParkingSpace`，22 縣市）：先比對縣市自有資料，配不到才用 TDX，避免同一場站因兩邊編號不同而無法合併。憑證取自環境變數或 `--tdx-env`（預設 `supabase/functions/.env`）；TDX 每把金鑰每分鐘限 5 次，工具每次請求間隔 13 秒、遇 429 依 `Retry-After` 重試，結果快取在 `artifacts/mymaps-cache/tdx/`。單一縣市失敗只記入報告。截至 2026-10-17，TDX 的新北市與基隆市路外資料為 0 筆。
    - 新竹市主機缺少 TLS 中繼憑證，工具從憑證的 AIA 網址取得 TWCA 中繼憑證後照常驗證，不關閉驗證。
  - 臺北市路外 36 處試辦重機停機車區（115/4/6 首波 24 處、115/7/6 新增 12 處）：依停管處新聞稿附件補上「機車區」與機車費率 2 倍的重機費率；試辦期限已屆，是否延續須以現場公告為準。
  - 臺北市路邊收費機車格：依 115/10/6 起的新制（115/9/30 公告），大型重機依路段收費方式計費：計次路段每次 40 元；計時路段每小時 20 元、當日上限 100 元；限時格首 20 分鐘 0 元；皆可斜停 2 格。來源格點無法判定收費方式，因此三種都列出。
  - 同一官方場站的多個來源標點（例如汽車區、機車區）合併為一個點位、多個 zones；來源回報彼此矛盾時改為 `null` 並列入待人工確認。
- 詳情十二欄（見 [DESIGN.md](DESIGN.md)「點位詳情十二欄分組版」）：名稱、費率、停放車種（`parking_access`／`parking_zones`）、GPS、來源、狀態與更新時間全數填入；類型取自官方資料或名稱中的地下／立體／平面；說明依內容分入「入口」「停車指引」「備註」；官方地址或路段填入位置；試辦規則與限時開放填入特殊規則。照片不匯入（屬來源作者的著作）；即時車位不屬於匯入資料。`community_spots` 尚無這些延伸欄位，`--sql-owner` 產生的 SQL 只含既有欄位；延伸欄位保留在 JSON，待後端加上對應欄位後再寫入。
- 點位只分兩種（2026-10-17 決定）：
  - **官方點**：我的地圖點位通過官方核驗，或官方資料有、我的地圖沒有且記載機車格／重機證據的場站（含 TDX 獨有的停車場，作為靜態資料補入；與縣市資料或既有官方點重複者略過）。資料來源顯示該縣市政府（如「臺北市政府」），`status=confirmed`，寫入 `official_heavy_spots`。
  - **社群點**：我的地圖有但未通過核驗，`source='import'`、`status='pending'`，資料來源顯示「社群回報整理」，詳情顯示「待確認」。
  - 來源地圖自己標示未確認（灰色圖示、「未確定」圖層），且未通過核驗的點不錄入。
  - App 已無 TDX 即時點；使用者舊收藏中的 TDX 點仍歸為官方點，來源顯示該縣市政府。
- 官方點的重機資格只採官方明載（臺北市大型重機格數、36 處路外試辦場域），其餘維持「有條件」；我的地圖的重機回報、分區、入口與停車指引以「社群補充（未經官方查核）」標示。一般機車資格依官方記載的機車格數。
- 本階段只做靜態點：TDX 只用於核驗與補入靜態停車場，不串接即時車位。
- 結果：官方點 `data/imports/official/spots.json`；社群點 `data/imports/google-mymaps/spots.json`；`verification.json`（每點的核驗紀錄與處理結果）與 `REPORT.md`（統計、修正、待人工確認與不錄入清單）。`--sql-owner` 另產生 `import.sql`（社群點）與 `official.sql`（以 service role 執行的官方點 upsert），都不直接寫入資料庫。
- 限制：其餘縣市自有資料不是缺座標（基隆、屏東）就是查無資料集，改由 TDX 比對；觀光景點、量販店等未登記為路外停車場的地點仍無官方資料可比對。臺中與桃園的市府資料沒有費率。

資料表在原本的 `community_spots` / `spot_votes` 之外新增：`moderation_queue`、`official_heavy_spots`（官方點，含詳情十二欄）、`rate_limit_events`。`spot_annotations` 已於 2026-10-17 移除。

## 驗證方式
1. 使用 `.flutter-version` 指定的 Flutter SDK，執行程式分析與 Flutter 測試，包含資格判斷、搜尋、抽屜互動、Google 地圖橋接及匯入資料檢查；`tool/` 的 Python 測試涵蓋匯入工具與 CI 路徑分流。
2. `flutter build web` 後用預裝 Chromium + Playwright 開啟，模擬台北定位，截圖確認：車種切換改變標記顏色、規則頁、記錄停車位置、收藏、新增回報（demo 模式）。Web 版走 Material 路徑，iOS 原生元件需另依「UI 設計規範 › 驗證」確認。
3. Edge Function `submit-report` 的驗證邏輯抽成純函式並以 `deno test` 測試；SQL migration 與 RLS 在本機以 `supabase db reset` + `supabase test db`（pgTAP）開發驗證，CI 以同樣指令從零驗證（見「本機開發環境」與 [CICD.md](CICD.md)）。
4. 依 CLAUDE.md 的 PR 流程：draft PR → 自我審查 → Ready for review → 處理 CI 與 Codex 意見到全綠。

## 待準備事項
- Google Maps 平台 API Key：Android／iOS／Web 各自限制用途與應用程式，存於不進版控的本機設定；平台已啟用，金鑰尚未設定。
- CI／CD 所需的商店、Supabase 與 GitHub 設定，見 [CICD.md](CICD.md)「待準備事項」
- Supabase：staging 專案已建立並部署（2026-10-21；GitHub `staging` Environment 已設定 Supabase 的 3 個 secret 與 2 個 variable，CI 用 Scoped token 只限 staging 專案）。待辦：匯入停車點（`official.sql`／`import.sql`，需匯入用帳號 UUID）、開啟 Google／Apple 登入與 Turnstile CAPTCHA；production 專案（Pro）於上線前另建。
- TDX 會員 Client ID / Secret（已取得；只在本機 `supabase/functions/.env` 供匯入核驗使用）
- ~~雲端環境網路放行 TDX 與縣市開放資料網域~~：已改在本機執行 `tool/import_mymaps.py` 取得官方資料並核驗（2026-10-17），不再需要。
- ~~執行順序（先 demo／本機開發，放行後再做 Phase 0 與 TDX 介接）~~：App 本體、schema、社群回報與靜態官方點匯入已完成；TDX 即時介接本階段不做。
- 本機開發：Docker 與 Supabase CLI；開發用 Google OAuth client（redirect 到本機 Auth）
- 上架用的 App 名稱、圖示、bundle id（第一版先用 placeholder）

## 參考資料
- [台北市 10/6 起開放 6.3 萬個路邊收費機車格給重機（TVBS）](https://news.tvbs.com.tw/life/4023234)
- [各縣市重機停機車格規定比較（工商時報）](https://www.ctee.com.tw/news/20260916700948-430104)
- [新北市大重機專用停車格（TVBS）](https://cars.tvbs.com.tw/life/263674)
- [TDX 常見問題（各縣市資料完整度不一）](https://motc-ptx.gitbook.io/tdx-xin-shou-zhi-yin/chang-jian-wen-ti/ping-tai-shi-yong-chang-jian-wen-ti)
- [TDX 資料服務範疇](https://motc-ptx.gitbook.io/tdx-zi-liao-shi-yong-kui-hua-bao-dian)
- [TDX 路邊停車動態資料（政府資料開放平臺）](https://data.gov.tw/en/datasets/174357)
- [臺中市路外剩餘車位](https://data.gov.tw/dataset/83931)
- [臺北市路邊停車格位資料](https://data.gov.tw/dataset/157491)
- [臺南市 Parkweb 匯出 API](https://parkweb.tainan.gov.tw/doc/Parkweb_export_API_.pdf)
- [Liquid Glass（Wikipedia，含 iOS 27 調整）](https://en.wikipedia.org/wiki/Liquid_Glass)
- [Flutter：Cupertino 支援 Liquid Glass 追蹤 issue](https://github.com/flutter/flutter/issues/170310)
- [Flutter：Material 3 Expressive 追蹤 issue](https://github.com/flutter/flutter/issues/168813)
- [cupertino_native_better（pub.dev）](https://pub.dev/packages/cupertino_native_better)
- [material_3_expressive（pub.dev）](https://pub.dev/packages/material_3_expressive)
- [material_ui（Flutter 官方，pub.dev）](https://pub.dev/packages/material_ui)
- [cupertino_ui（Flutter 官方，pub.dev）](https://pub.dev/packages/cupertino_ui)
