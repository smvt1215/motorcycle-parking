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
  main.dart, app.dart                 # go_router（底部分頁：地圖/規則/我的車/收藏）、主題
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
test/                                 # eligibility、rules 解析、TDX 正規化、車種切換 widget test
.github/workflows/flutter.yml         # analyze + test
README.md                             # 安裝、Supabase 建置、TDX 金鑰申請步驟（中文）
```

## 主要套件
`flutter_map`, `latlong2`, `flutter_map_marker_cluster`, `geolocator`, `flutter_riverpod`, `go_router`,
`supabase_flutter`, `shared_preferences`, `url_launcher`（跳 Google/Apple 地圖導航）, `flutter_local_notifications`（計時提醒）。

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
2. `flutter build web` 後用預裝 Chromium + Playwright 開啟，模擬台北定位，截圖確認：車種切換改變標記顏色、規則頁、記錄停車位置、收藏、新增回報（demo 模式）。
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
