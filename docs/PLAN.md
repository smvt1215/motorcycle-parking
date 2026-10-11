# 機車停車指南 APP（普通機車 + 大型重機）— 實作計畫

> 狀態：規劃中（尚未開始實作）。最後更新：2026-10-11

## 背景
目標是做一個台灣用的機車停車指南 APP，同時服務「普通機車」與「大型重機（黃牌/紅牌）」騎士。
重機停車規定各縣市差異大且正在快速變動（例：台北市 2026/10/6 起開放約 6.3 萬個路邊收費機車格給重機、可斜停兩格、每次 40 元；新北、桃園、台中、高雄各有不同做法），騎士跨縣市容易誤觸規定，找車位也困難。
本 repo 目前只有 README 與 LICENSE，從零開始。

已確認的決策：
- 平台：**Flutter**（iOS / Android，另可建 Web 方便測試）
- 資料：**TDX 政府開放資料 + 社群回報**
- 後端：**Supabase**（Postgres + PostGIS、Auth、Edge Function 代理 TDX 金鑰與社群寫入）
- 地圖：**flutter_map + OpenStreetMap**（免金鑰；地圖層抽象化，日後可換 Google Maps）
- UI：**雙平台自適應**，iOS 依 Liquid Glass（HIG，iOS 26/27）、Android 依 Material 3 Expressive；iOS 關鍵導覽元件嵌入原生 Liquid Glass 元件（見「UI 設計規範」）
- 第一版功能：地圖找附近停車位、停車規則指南、記住我停哪裡、使用者回報/收藏停車點

## 架構總覽
```
Flutter App ──► Supabase Edge Function `tdx-parking` ──► TDX API（金鑰只存在伺服器）
     │
     └────────► Supabase Postgres（community_spots / spot_votes / favorites / city_rules，RLS 保護）
本機：停車紀錄（隱私，不上傳）、車種設定
```
未設定 Supabase 時（`--dart-define` 未給），App 自動改用內建範例資料，方便開發與測試。

## 專案結構（Flutter 專案放 repo 根目錄）
```
pubspec.yaml
lib/
  main.dart, app.dart                 # go_router（底部分頁：地圖/規則/我的車/收藏）
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
    map/        # 地圖、群聚標記、篩選（車種、空間類型、有即時車位）、車位詳情 bottom sheet、導航
    rules/      # 依縣市 × 車種顯示規則、生效日期、來源連結、免責聲明
    my_parking/ # 一鍵記錄位置/備註/樓層、計時提醒（本機通知）、導航回車旁
    favorites/  # 收藏清單
    report/     # 長按地圖新增停車點、回報「還在/已不存在」
assets/rules/parking_rules.json       # 內建縣市規則（含 sourceUrl、effectiveDate）
supabase/
  migrations/0001_init.sql            # 資料表、PostGIS、RLS、nearby_spots RPC、每日回報上限 trigger
  functions/tdx-parking/index.ts      # Deno：OAuth client_credentials 取 token（快取）、抓路外/路邊車位+即時剩餘、正規化
test/                                 # eligibility、rules 解析、TDX 正規化、車種切換 widget test、雙平台 golden 截圖測試
.github/workflows/flutter.yml         # analyze + test（Linux）
.github/workflows/ios.yml             # iOS 模擬器建置 + 截圖（macOS runner，見「UI 設計規範 › 驗證」）
integration_test/                     # iOS 截圖情境（地圖、sheet、車種切換、深淺色）
README.md                             # 安裝、Supabase 建置、TDX 金鑰申請步驟（中文）
```

## 主要套件
`flutter_map`, `latlong2`, `flutter_map_marker_cluster`, `geolocator`, `flutter_riverpod`, `go_router`,
`supabase_flutter`, `shared_preferences`, `url_launcher`（跳 Google/Apple 地圖導航）, `flutter_local_notifications`（計時提醒）。
UI：`material_ui`、`cupertino_ui`（Flutter 官方設計套件，取代框架內建的 `flutter/material.dart`、`flutter/cupertino.dart`）、`cupertino_native_better`（iOS 原生 Liquid Glass 元件）、`material_3_expressive`（補官方尚未提供的 M3 Expressive 元件）、`dynamic_color`（Android 動態配色）。需 Flutter ≥ 3.47（`material_ui` 的下限）。

## UI 設計規範（雙平台）
目標：iOS 看起來像 iOS、Android 看起來像 Android，各自符合最新設計規範；內容、資訊架構與品牌一致。

### 現況限制（2026-10 查證）
| 平台 | 最新規範 | Flutter 官方支援 | 對策 |
|---|---|---|---|
| iOS | **Liquid Glass**（iOS 26 推出；iOS 27 調整：預設透明度降低、系統設定可調玻璃強度） | 無。官方 [`cupertino_ui`](https://pub.dev/packages/cupertino_ui) 套件已發布（2026-10，1.1.2），但尚未包含 Liquid Glass；Flutter 自繪畫面，不會自動套用（[flutter#170310](https://github.com/flutter/flutter/issues/170310)） | 導覽與控制元件以 `cupertino_native_better` 嵌入**原生** UIKit 元件 |
| Android | **Material 3 Expressive**（形狀、彈簧動態、浮動工具列、強調字級） | 部分。官方 [`material_ui`](https://pub.dev/packages/material_ui) 套件已發布（2026-10，1.6.0，取代框架內建 Material），提供 `StyleVariant.material3Expressive`，官方標示仍在開發中、會陸續加入 Expressive 功能（[flutter#168813](https://github.com/flutter/flutter/issues/168813)） | 以 `material_ui` 為基礎並採用 `material3Expressive` 樣式；官方尚未提供的 Expressive 元件才用 `material_3_expressive` 補（該套件本身也建立在 `material_ui` 上） |

### 自適應元件層 `lib/ui/adaptive/`
畫面只使用這一層的元件，不直接呼叫平台套件；官方支援補齊後只需替換這一層。
- **一律使用官方獨立套件**：全專案只 import `package:material_ui/material_ui.dart` 與 `package:cupertino_ui/cupertino_ui.dart`，**禁止** import `package:flutter/material.dart`、`package:flutter/cupertino.dart`，避免同時存在兩套主題與在地化設定（`material_3_expressive` 也明文要求）。在地化改用 `material_ui` 提供的 `GlobalMaterialLocalizations`（繁體中文）。CI 加一道檢查（只掃描本專案的 `lib/`、`test/`、`integration_test/`，不含第三方套件），發現禁止的 import 即失敗。
- **舊版相依的相容橋接（必要）**：`cupertino_native_better` 仍 import 框架內建的 `flutter/cupertino.dart` 與 `flutter/material.dart`（例如 `CNBottomSheet` 內部呼叫舊版 `showCupertinoSheet`），其主題與在地化型別和官方新套件不同。依 [`cupertino_ui`](https://pub.dev/packages/cupertino_ui#migrating-existing-code-to-this-package)／[`material_ui`](https://pub.dev/packages/material_ui#migrating-existing-code-to-this-package) 遷移指南第 3 步，在根 App 的 `builder` 同時包上 `MaterialUiCompatibilityBridge` 與 `CupertinoUiCompatibilityBridge`，讓舊版元件取得正確的 `ThemeData`／`CupertinoThemeData` 與 `MaterialLocalizations`／`CupertinoLocalizations`。`builder` 包住整個 Navigator，因此經路由開啟的 sheet 也在橋接範圍內。
- **實作前的相容性驗證**：開始實作時先做最小雛形，在橋接下確認 `CNTabBar`、`CNBottomSheet` 的主題、深淺色與繁中在地化正確（並納入 iOS 截圖測試）。原生元件的顏色仍以設計 token 明確傳入作為額外保險，但不取代橋接。
- **缺口清單**：實作時列出 `material_ui` 的 `material3Expressive` 尚未涵蓋、需由 `material_3_expressive` 補的元件；每次升級 `material_ui`／`cupertino_ui` 時重新檢查，官方已提供就移除第三方套件（`cupertino_ui` 加入 Liquid Glass 後同理替換 `cupertino_native_better`）。
- APP 最低支援 iOS 15（`cupertino_native_better` 的下限），iOS 26 以上才使用原生 Liquid Glass。

| 元件 | iOS 26+ | iOS 15–18 | Android |
|---|---|---|---|
| `AdaptiveTabScaffold`（地圖/規則/我的車/收藏） | 原生 Liquid Glass 分頁列（`CNTabBar`） | `CupertinoTabBar` | M3 `NavigationBar` |
| `AdaptiveNavBar` | 透明 `CupertinoNavigationBar` + 原生玻璃圖示按鈕（`CNButton.icon`） | `CupertinoNavigationBar` | M3 top app bar（`AppBar`／`SliverAppBar`） |
| `AdaptiveSegmented`（普通機車／大型重機） | 原生 segmented control（`CNSegmentedControl`） | `CupertinoSlidingSegmentedControl` | M3 Expressive button group |
| `AdaptiveButton`、`AdaptiveSwitch`、`AdaptiveSlider` | `CNButton`、`CNSwitch`、`CNSlider` | Cupertino 元件 | M3 Expressive 元件 |
| `AdaptiveSheet` | 車位詳情：自訂可停於半高／全高的 sheet（見下方 iOS 規則）；回報表單等一般 sheet：`CNBottomSheet.showCupertino` | 同左 | M3 modal bottom sheet（車位詳情同樣可停於半高／全高） |
| 地圖動作（定位、篩選、記錄停車） | 原生玻璃按鈕群（`CNGlassButtonGroup`） | Cupertino 按鈕 | M3 Expressive 浮動工具列 + FAB「記錄停車」 |

### iOS 規則（HIG）
- **玻璃只用在導覽／控制層**，不用在內容上；地圖滿版延伸到分頁列與導覽列下方。
- 原生元件會自動跟隨系統的玻璃強度（iOS 27）、「減少透明度」「增加對比」設定；Flutter 自繪的部分讀取無障礙設定（`MediaQuery` 的 high contrast、disable animations 等），必要時改用不透明背景與無動態效果。
- 使用 SF Symbols；支援動態字級（Dynamic Type）；點擊區域 ≥ 44pt。
- 原生元件以 platform view 疊在地圖上有效能成本：數量控制在分頁列與少數按鈕，實作時量測捲動與縮放幀率。
- **原生元件與彈出層的疊放協調**（套件[必要設定](https://pub.dev/packages/cupertino_native_better#required-setup-register-cntabbarrouteobserver)）：原生元件疊在 Flutter 畫面下方合成，若不協調，分頁列等原生元件會蓋在 sheet 上（例如遮住回報表單的輸入框），玻璃光暈也會透出。
  - 在根 `GoRouter` 的 `observers` 註冊 `CNTabBarRouteObserver`。
  - iOS 的 sheet 一律要讓套件知道它的位置：
    - 一般 sheet（回報表單等）以 `CNBottomSheet.showCupertino` 開啟（自動加上 `CNSheetGeometryProbe`）。
    - 車位詳情需要停在半高／全高，但 `showCupertinoSheet`（`CNBottomSheet.showCupertino` 的底層）只有固定 `topGap` 與拖曳關閉，沒有可停高度（[API](https://pub.dev/documentation/cupertino_ui/latest/cupertino_ui/showCupertinoSheet.html)）。因此改用 `CNBottomSheet.show(isScrollControlled: true, ...)`（底層為 `showModalBottomSheet`，路由型別 `ModalBottomSheetRoute`，並自動加上 `CNSheetGeometryProbe`），內容使用 `DraggableScrollableSheet`，設定 `initialChildSize: 0.5`、`minChildSize: 0.5`、`maxChildSize: 1.0`、`snap: true`（最小與最大值會自動成為停點，不另列 `snapSizes`；預設 `minChildSize` 為 0.25，不設定會多出四分之一高的停點），外觀依 iOS 規範調整（圓角、拖曳把手、背景材質）。
    - `CNTabBarRouteObserver` 只把**型別名稱含 `Sheet`** 的路由視為 modal 並隱藏分頁列（[原始碼](https://github.com/gunumdogdu/cupertino_native_better/blob/main/lib/components/tab_bar.dart)），`CNSheetGeometryProbe` 只回報位置、不會觸發隱藏。因此不得用 `PageRouteBuilder` 等一般路由開 sheet；若真的需要自訂路由，路由類別名稱必須含 `Sheet`。
  - 不使用不經路由的彈出層（例如 `Scaffold.showBottomSheet`）：`markAnyModalActive()`／`markAnyModalInactive()` 只增減 `anyModalDepth`（處理玻璃按鈕光暈與搜尋型分頁列），一般 `CNTabBar` 監聽的是只由 `*Sheet*` 路由觸發的 `modalDepth`，手動呼叫無法讓分頁列隱藏。若日後確有需要，除了呼叫上述方法處理光暈，彈出層也不得與分頁列重疊。

### Android 規則（Material 3 Expressive）
- 以 `material_ui` 的 `StyleVariant.material3Expressive` 為主題樣式；Android 12+ 使用桌布動態配色（`dynamic_color`），其餘使用品牌種子色。
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
  - `ios.yml`：選用含 iOS 26 / 27 模擬器的 Xcode 映像（實作時確認 runner 映像版本），`flutter build ios --simulator --no-codesign`，不需要簽章或 Apple 開發者帳號。
  - 於 iOS 26 與 iOS 27 模擬器執行 `integration_test` 截圖情境：地圖頁、車種切換、車位詳情與回報 sheet（含上述疊放測試）、深淺色模式；截圖上傳為 workflow artifact，供 PR 審查時查看。
  - 執行條件：PR 變更 `lib/`、`ios/`、`integration_test/`、`pubspec.*` 或 `.github/workflows/ios.yml` 本身時才實際建置與截圖，另可手動觸發；只改文件時略過，以節省排隊時間。
  - 穩定後將 iOS 建置列為 main ruleset 的必要檢查。注意：設為必要檢查的 workflow 不能用 workflow 層級的路徑過濾（只改文件的 PR 會一直等不到檢查結果而無法合併）；改為 workflow 每次都觸發，在 job 內判斷變更路徑，不需要時直接回報成功。
- Android 以 Android 16 模擬器確認 Expressive 元件、動態配色、edge-to-edge 與預測式返回。

## 核心資料模型
- `VehicleType`：`scooter`（普通機車，白/綠牌 ≤250cc）、`heavy`（大型重機，黃牌 250–550cc / 紅牌 >550cc，可在設定選牌色供顯示）。AppBar 切換，持久化。
- `ParkingSpot`：id, source(tdx/community), name, lat/lng, city, spaceType(路邊收費機車格/免費機車格/重機專用格/汽車格/路外停車場), feeNote, scooterTotal/available, heavyAllowed(nullable：依場站規定), updatedAt。
- `CityRule`：city, vehicle, allowedSpaceTypes, feeNote, canUseTwoSpaces, exceptions（如台北免費巷弄格不開放）, effectiveDate, sourceUrl, version。
- `eligibility(spot, vehicle, rule)` → `allowed / conditional(附說明) / notAllowed`，地圖標記顏色據此呈現。

## Supabase 資料表（RLS）
- `community_spots`：geography(Point) + 欄位同上；所有人可讀 `status='active'`；**RLS 禁止客戶端直接寫入**，新增/投票一律經 Edge Function `submit-report`（見「防濫用」）；只能改/刪自己的。
- `spot_votes`：(spot_id, user_id) 唯一，vote = still_there / gone；累積「已不存在」達門檻自動隱藏。
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
| 3 | **縣市公告（人工整理）** | 重機開放規則、重機專用格位置（如新北 17 格專用格的路段） | 多半只有新聞稿/公告，無開放資料 → 進 `city_rules` 與 `official_heavy_spots` 表，由管理者維護 |

### Phase 0：TDX 資料完整性稽核（實作前先做）
在開發用的雲端環境實測時，`tdx.transportdata.tw`、`data.taipei`、`data.gov.tw` 都被網路政策擋下（403），所以**目前無法親自確認完整性**，稽核要在放行網域並取得 TDX 金鑰後執行：
- 寫 `tool/tdx_audit.dart`（或 Deno script），逐一跑 22 縣市，輸出 `docs/tdx-coverage.md`：
  - 路外停車場數、其中有機車車位數（`ParkingSpace` 機車類型）的比例
  - 有即時剩餘、且即時資料含機車欄位的比例；資料最後更新時間分佈（判斷是否「假即時」）
  - 座標缺漏/明顯錯誤（落在海上、0,0）比例
  - 路邊路段資料是否有機車格、是否有即時
- 對 3–5 個抽樣點（台北、新北、台中、高雄、一個偏鄉縣）與縣市官方資料交叉比對總格數
- 依結果決定：哪些縣市 TDX 足夠、哪些需接第 2 層 adapter、哪些只能靠社群回報。地圖上每個點都標示資料來源與更新時間。

## TDX 介接（Edge Function）
- 憑證 `TDX_CLIENT_ID` / `TDX_CLIENT_SECRET` 存於 Supabase secrets，App 內不含金鑰。
- 端點（以 Phase 0 稽核與 TDX Swagger 確認路徑與欄位）；只取機車相關車位類型並正規化為 `ParkingSpot`。
- 回應加快取（基本資料長、即時剩餘 1–2 分鐘），避免打爆配額。

## 社群回報機制
目標：補官方資料沒有的資訊（特別是「重機實際能不能停」），同時防止錯誤與灌水。
1. **兩種回報**
   - 新增停車點：長按地圖 → 表單（格位類型、普通機車可停、重機可停、收費、樓層/入口備註、選填照片）。
   - **官方點位註記**：在 TDX 停車場上回報「重機可停 / 不可停 / 須停汽車格」「入口限高/坡道陡」等，TDX 本身沒有這些欄位。
2. **去重**：送出前查 15 公尺內同類型點，有的話引導改成「確認既有點」而非新增。
3. **可信度狀態**：新回報為「待確認」（灰色標記），經 2 位**合格**使用者（非匿名、帳號建立滿 7 天、且非同一 IP/裝置）確認「還在」→「已確認」；「已不存在/資訊錯誤」改為**加權計分**（新帳號權重低），達門檻只「隱藏待審」進 `moderation_queue`，不自動刪除。每個點顯示「最後確認日期」，超過 180 天未確認標示「資訊可能過時」。
4. **防濫用**：匿名身分可被任意重建（`signInAnonymously()` 每次都產生新 user id，[Supabase 官方文件](https://supabase.com/docs/guides/auth/auth-anonymous)亦建議搭配 CAPTCHA），因此**不能把匿名帳號當成一個人**：
   - **權限分級**：匿名或未登入只能瀏覽、收藏、記錄停車位置（收藏與停車紀錄不影響他人）；**回報、確認、投票、檢舉**需以 Google / Apple 帳號登入。
   - **CAPTCHA**：Supabase Auth 啟用 Cloudflare Turnstile（或 hCaptcha），登入時驗證。
   - **伺服器端限流**：所有寫入經 Edge Function `submit-report`，依 user id **與** IP 雙重限流（如每帳號每日 10 筆、每 IP 每日 30 筆），並記錄於 `rate_limit_events`；Supabase Auth 本身的註冊/登入速率限制同時開啟。
   - **裝置驗證（第二階段）**：上架後加入 Android Play Integrity / iOS App Attest，由 Edge Function 驗證後才接受寫入。
   - 不能確認自己的回報；檢舉按鈕 → `moderation_queue`；照片存 Supabase Storage，上傳前移除 EXIF。
5. **管理**：第一版用 Supabase Dashboard 審核 `moderation_queue` 與維護 `city_rules`，不另做後台。

### 外部社群地圖（Google 我的地圖）
有一份他人公開分享的大台北 Google 我的地圖可作為**參考資料**（作者尚未同意匯入）：
- 地圖連結：https://www.google.com/maps/d/viewer?mid=1ORD5DnL6yqrCrtQJYB9TeTgOOlvo-Yc
- 第一版**不匯入**其點位資料；只參考其分類方式與呈現。
- 做一個通用匯入工具 `tool/import_kml.dart`（KML/GeoJSON → `community_spots`，`source='import'`、記錄 `source_name`/`source_url`/授權說明，狀態預設「待確認」），之後取得作者同意或有其他授權資料時可直接用。
- README 附「向地圖作者徵求授權」的建議文字範本。
- 目前環境無法連到 `www.google.com`，若要讀取該地圖需手動匯出 KML 上傳，或放行網域。

資料表在原本的 `community_spots` / `spot_votes` 之外新增：`spot_annotations`（對 TDX 點位的註記，以 `source + source_id` 關聯）、`moderation_queue`、`official_heavy_spots`、`rate_limit_events`。

## 驗證方式
1. 容器內安裝 Flutter SDK（目前未安裝），執行 `flutter pub get`、`flutter analyze`、`flutter test`（含 eligibility 各縣市×車種案例、JSON 解析、TDX 正規化 fixture）。
2. `flutter build web` 後用預裝 Chromium + Playwright 開啟，模擬台北定位，截圖確認：車種切換改變標記顏色、規則頁、記錄停車位置、收藏、新增回報（demo 模式）。Web 版走 Material 路徑，iOS 原生元件需另依「UI 設計規範 › 驗證」確認。
3. Edge Function 的正規化邏輯抽成純函式並用 TDX 範例 JSON 做測試；SQL migration 若容器無 Postgres 則以人工審閱 + README 說明 `supabase db push` 步驟（會明確告知哪些未實際執行）。
4. Commit 並 push 到 `claude/motorcycle-parking-guide-app-kk6f9x`，開 draft PR 並追蹤 CI。

## 待準備事項
- Supabase 專案（URL、anon key），開啟 Google / Apple 登入與 Turnstile CAPTCHA（Cloudflare 免費帳號取得 site key / secret）
- TDX 會員 Client ID / Secret
- 雲端環境網路設定放行 `tdx.transportdata.tw`（以及若要接第 2 層：`data.taipei`、`data.gov.tw`、`datacenter.taichung.gov.tw`、`parkweb.tainan.gov.tw`），才能執行 Phase 0 稽核
- 執行順序：未放行前，先完成 App 本體（demo 資料）、Supabase schema、社群回報；放行後再做 Phase 0 與 TDX 介接
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
