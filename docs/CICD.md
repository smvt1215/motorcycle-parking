# CI／CD 規劃

> 狀態：CI 與 CD staging／release workflows 已實作。CD staging 已就緒：`staging` Environment 的 Supabase、簽章、Maps 金鑰與 Firebase 設定已完成，main 的 CI、Android、iOS 都成功後部署 staging 後端與管理站，並把 Android APK、iOS Ad Hoc IPA 送到 Firebase App Distribution（2026-10-25 `b827aab` 五個 job 皆成功）。`production` Environment 已設定核准者，但尚未設定任何 secret 或 variable，也尚未推送版本 tag，release workflow 還沒有實際執行過。CodeQL 改採五類語言 Advanced Setup，AI Scan 維持停用。商店與 production 的外部設定依 [CD_SETUP.md](CD_SETUP.md) 完成。最後更新：2026-10-25。整體計畫見 [PLAN.md](PLAN.md)。

## 決策摘要
- 平台：**GitHub Actions**（公開 repo 使用 GitHub 標準 runner 不收費，含 macOS）。
- 簽章與上架工具：**fastlane**（iOS 用 App Store Connect API key，Android 用 Google Play 服務帳號）。
- 後端環境：**Supabase staging + production** 兩個專案。
- **發佈通道（2026-10-23 起）**：

  | 通道 | 觸發 | iOS | Android | 後端 |
  |---|---|---|---|---|
  | alpha（內部預覽） | 合併到 `main` | Firebase App Distribution（Ad Hoc） | Firebase App Distribution | staging |
  | beta | tag `vX.Y.Z-beta.N` | TestFlight 外部公開連結 | Play 封閉測試 | staging（不部署 production） |
  | RC | tag `vX.Y.Z-rc.N` | TestFlight 外部公開連結 | Play 開放測試 | production |
  | 正式版 | tag `vX.Y.Z` | 最後一個 RC 的同一個建置送 App Store 審核 | 同一個版本碼推進 production | production（沿用 RC 時已部署的版本） |
- **alpha 只給內部**：`.staging` App（名稱加「α」）連 staging 後端，只經 Firebase 發給受邀成員，不上傳商店；iOS 為 Ad Hoc 簽章，需先登記 UDID。
- **beta／RC／正式版是同一個正式 App**：同一個 bundle id 與 applicationId。**beta 連 staging 後端**，正式資料庫不會收到 beta 的 migration，beta 測試者的資料也留在 staging；RC 起連 production 後端，測試者從 beta 升到 RC 需重新登入；正式版不重新建置，商店上架的就是測試者驗證過的 RC 二進位檔。
- 已具備：Apple Developer Program、Google Play Console。

## 整體流程
```
PR ──► CI（檢查 + 測試）──► 全綠 ──► Squash merge 到 main
                                         │
                                         ▼
                         CD staging（alpha）：Supabase staging 部署
                                   + Android／iOS alpha（Firebase App Distribution，內部成員）
                                         │
              推送 tag vX.Y.Z-beta.N ──┤
                vX.Y.Z-rc.N ──────────┤
                                         ▼
                         CD release（需人工核准）：Supabase production 部署
                                   + TestFlight 外部公開連結／Play 封閉（beta）或開放（RC）測試
                                   + GitHub prerelease
                                         │
                推送 tag vX.Y.Z（打在最後一個 RC 的 commit）
                                         ▼
                         CD release（需人工核准）：不重新建置
                                   + RC 建置送 App Store 審核（分階段發布）／Play production（分階段推出）
                                   + GitHub Release
```

## Workflow 一覽
| 檔案 | 觸發 | Runner | 內容 |
|---|---|---|---|
| `ci.yml` | PR、push 到 `main` | Linux | 跨平台檢查：Flutter 檢查與測試、Web 建置、Supabase 檢查 |
| `android.yml` | PR、push 到 `main` | Linux（模擬器硬體加速） | production／staging Release APK 設定檢查（僅 PR）＋一次測試 APK 建置，Android 11／16 模擬器共用測試產物執行與截圖 |
| `ios.yml` | PR、push 到 `main` | macOS | production／staging 真機 Release 設定檢查（僅 PR）＋一次模擬器測試 App 建置，iOS 26／27 共用測試產物執行與截圖（見 PLAN.md「UI 設計規範 › 驗證」） |
| `codeql.yml` | PR、push 到 `main`、每週、手動 | Linux + macOS | Actions、JavaScript／TypeScript、Python、Java／Kotlin、Swift 安全分析；原生 PR 掃描依相關路徑執行 |
| `actions-cleanup.yml` | 每週日（UTC 19:17）、手動（可選 dry-run） | Linux | 清理 Actions 執行紀錄與快取（規則見下方「Actions 清理」） |
| `cd-staging.yml` | `main` 上的三條 CI 都成功後（`workflow_run`） | Linux + macOS | 部署 staging 後端、產生 Android 測試 APK 與 iOS 測試 IPA（不上傳商店） |
| `release.yml` | 推送 tag `v*` | Linux + macOS | beta：以 staging 後端設定建置；RC：部署 production 後端並建置；兩者上傳 TestFlight 與 Play 測試軌道、建立 GitHub prerelease；正式版：把 RC 建置推上 App Store 與 Play production、建立 GitHub Release |

Workflow 依平台分工：跨平台檢查放 `ci.yml`，各平台的建置與模擬器測試放各自的 workflow，並共用同一套路徑判斷（只改文件時略過）。

### 路徑分流與合併門檻

- `tool/ci_changes.py` 只控制昂貴的 steps，不用 workflow 層級 paths filter，避免必要 checks 留在 Pending。Git diff 出錯會直接失敗；刪除與跨目錄搬移仍涵蓋舊路徑。
- 文件與發版工具變更：保留 Python／fastlane 自動化測試及版本政策；略過 Flutter、Web、平台建置、模擬器及本機 Supabase。
- Flutter 共用程式、測試、assets、SDK 與 pub 相依變更：執行品質與雙平台驗證；`web/`、analysis options 只觸發品質，`android/`／`ios/` 只觸發對應平台，`supabase/` 觸發後端。
- `data/imports/` 只觸發品質（`test/imported_spots_test.dart` 驗證匯入資料）。
- `tool/boot_ios_simulator.py` 只觸發 iOS；seed 產生器、seed.sql 與 demo／rules 資料來源會驗證生成結果與資料庫。路徑判斷與其測試、CodeQL workflow 變更會重新驗證全部目標。
- `tool/` 的 Python 測試仍一律執行，不因不觸發平台建置而略過工具回歸測試。
- 三個既有必要彙總 checks 仍要求所有前置 jobs 成功；取消／失敗不得偽裝為通過。嚴格同步 main、簽章、線性歷史、Squash 與審查 thread 結案規則不變。
- 管理介面的 `lib/admin/`、`lib/main_admin.dart`、`test/admin/`、`admin_web/`、`firebase.json`、`.firebaserc` 與 Hosting 整理工具只觸發品質，不觸發 Android／iOS 模擬器；與共用程式一起修改時仍跑平台驗證。`web/admin/` 沿用 Web 的品質路徑；新增共用套件仍由 `pubspec` 觸發所有平台。
- CD staging 建置 Android APK 與 iOS IPA 前，先以 `tool/export_rules.py --config config/staging.json` 把 staging 最新的縣市規則寫進這次建置的 `assets/rules/parking_rules.json`，讓從未連線過的新安裝也用最新規則；匯出失敗時建置失敗，不會沿用舊檔。匯出結果不寫回 repo；repo 內的檔案落後時，該次 run 會出現「Bundled rules behind staging」警告。production 開專案時以同一支腳本讀 production 設定。
- 品質 job 另建置 `lib/main_admin.dart` 到 `build/admin`，套用管理站 metadata；原 App Web 仍獨立建置到 `build/web`。
- React 管理站（`admin_web/react/`，#195 P7 改寫）由獨立的 `admin-react` job 檢查（Prettier、ESLint、Vitest、`tsc -b`＋Vite 建置），只由 `admin_web/react/`、`admin_web/DESIGN.md`、`ci.yml` 與路徑判斷檔觸發；它不觸發 Flutter 品質、行動平台或後端。尚未部署到 Hosting。

### 管理介面 staging Hosting

`cd-staging.yml` 在 staging 後端部署成功後，執行 `Staging admin Hosting`。本階段只部署 staging；production Hosting 與 RC 流程尚未加入。

| staging Environment 設定 | 用途 |
|---|---|
| variable `FIREBASE_HOSTING_SITE` | 已建立的管理站 site ID；未設定時明確略過 Hosting 並在 Actions 摘要說明 |
| variables `FIREBASE_WORKLOAD_IDENTITY_PROVIDER`、`FIREBASE_SERVICE_ACCOUNT` | 沿用 `github-staging` OIDC 與 staging 服務帳號，無長期 JSON 金鑰 |
| variables `SUPABASE_URL`、`SUPABASE_ANON_KEY` | 管理站使用的 staging 後端公開設定 |
| secret `SUPABASE_PROJECT_REF` | 由 `cd_config.py staging web` 檢查 URL 與 staging 專案一致 |
| secret `GOOGLE_MAPS_WEB_API_KEY` | 受管理站 referrer 限制的 Maps Web 金鑰 |

`.firebaserc` 的 `staging` alias 指向 `motocycle-parking-guide`。CI 以 `firebase target:apply hosting admin-staging "$FIREBASE_HOSTING_SITE" --project staging` 建立目標對應，再只部署 `hosting:admin-staging`。部署前重新檢查 main SHA，避免排隊中的舊版本覆蓋新站。設定了 site 後，缺少憑證、金鑰或 Hosting 權限會讓 job 失敗，不會偽裝部署成功。

建置沿用鎖定 Flutter，執行：

```bash
python3 tool/cd_config.py staging web
flutter build web -t lib/main_admin.dart -o build/admin --no-web-resources-cdn --no-wasm-dry-run --dart-define-from-file=config/staging.json
python3 tool/prepare_admin_web.py
firebase deploy --only hosting:admin-staging --project staging --non-interactive
```

`firebase.json` 僅服務 `build/admin`，設定 SPA rewrite、CSP、`X-Frame-Options: DENY`、`X-Robots-Tag: noindex, nofollow`、`nosniff` 與重新驗證快取。CanvasKit 從同站載入；CSP 允許 Supabase HTTPS／WebSocket 與 Maps／Fonts 所需來源。管理站的 `index.html` 也含 `noindex`，不引用 App 的 manifest。

staging 設定已於 2026-10-24 完成，並以真實 Google 登入＋TOTP 取得 `aal2` 驗收：

| 項目 | 設定 |
|---|---|
| Hosting site | `motopark-admin-staging`（https://motopark-admin-staging.web.app ），staging Environment variable `FIREBASE_HOSTING_SITE` |
| 部署權限 | `github-staging-distribution@motocycle-parking-guide.iam.gserviceaccount.com` 具 App Distribution Admin、Firebase Hosting Admin（`roles/firebasehosting.admin`）、API Keys Viewer（`roles/serviceusage.apiKeysViewer`，[Firebase CLI 的角色要求](https://firebase.google.com/docs/projects/iam/roles-predefined-product)） |
| Maps Web 金鑰 | GCP 金鑰「Motopark staging admin web」：只允許 Maps JavaScript API，referrer 限 `https://motopark-admin-staging.web.app/*`、`https://motopark-admin-staging.firebaseapp.com/*`；存於 secret `GOOGLE_MAPS_WEB_API_KEY` |
| Supabase Auth | Redirect URLs 加入 `https://motopark-admin-staging.web.app/**`，啟用 TOTP；簡訊驗證尚未驗收 |
| 管理帳號 | 以 service role 將 `app_metadata.role` 設為 `admin`（service role 不放到網站）；需登記至少兩個驗證器 App |

`cd-staging.yml` 只由 `workflow_run` 觸發；只需重新部署管理站時，重跑最新 main 的 CD staging 中「Staging admin Hosting」單一 job，避免重新發送 APK／IPA。改用自訂網域時，需同步更新 Maps 金鑰 referrer 與 Supabase Redirect URLs。

### Actions 清理

- `tool/actions_cleanup.py` 刪除已完成且超過 7 天的執行紀錄，以及已關閉 PR、已刪除分支的快取。
- 一律保留：`main` 最新 commit 的所有執行紀錄（`cd_gate.py` 部署前要讀 CI 與 staging 部署紀錄）、執行中的紀錄、所有 `Release` 紀錄（正式發版稽核）、`main` 與 tag 的快取。
- 手動執行時可勾選 dry-run，只列出會刪除的項目。刪除無法復原。

### CodeQL Advanced Setup

- Actions、JavaScript／TypeScript、Python 採 `build-mode: none`；Java／Kotlin、Swift 採 `manual`，先準備鎖定版本 Flutter 與 plugins，不能直接 autobuild 裸 Gradle／Xcode 專案。
- Kotlin 由 Flutter 建置 production Debug APK，產生 `android/local.properties`；禁用 Gradle daemon／build cache，確保編譯能被追蹤。
- Swift 先以 Flutter `--config-only` 產生 plugin Swift package，再在 CodeQL init 後以 xcodebuild 建置無簽章模擬器 App；關閉編譯快取及 integrated driver，不修改一般 UI 測試的編譯旗標。
- PR 的 Kotlin 掃描僅在相關路徑或 CodeQL／mobile setup 改動時執行；**Swift 不在 PR 上掃描**（job 層級略過，不佔用 macOS runner），只在 push 到 main、每週與手動執行。main、每週與手動執行完整掃描五類。腳本三類在每個 PR 都執行。
- macOS runner 在 Enterprise 以下的方案（含 Pro）同時最多 5 個 job，而每個 PR 的 iOS CI 本身就要用到 macOS；Swift 原生程式碼很少，改在 main 上掃描，換取 PR 不必排隊。
- 切換前必須停用 Default Setup，否則 Advanced Setup 的 SARIF 上傳會被拒絕。五類實際分析穩定且 main 有基準後，再確認 CodeQL 合併門檻；本次保留三個既有必要 checks，不提前要求尚未驗證的安全 check。
- `CodeQL 全部通過` 代表分析 jobs 成功，不等於沒有安全警示。安全警示仍在 Security／Code scanning 審查，不以全專案既有警示阻擋未修改範圍的 PR。
- 設計與驗收記錄見 [PR checks 設計](designs/2026-10-14-pr-checks-design.md)。

## CI（每個 PR）
### `ci.yml`（Linux）
1. **環境**：Flutter 版本固定在 repo 的 `.flutter-version`（≥ 3.47，`material_ui` 下限），以 `subosito/flutter-action` 安裝並快取 pub 套件。
2. **程式碼品質**：
   - `dart format --set-exit-if-changed .`
   - `flutter analyze`（`analysis_options.yaml` 開嚴格模式，警告視為錯誤）
   - 禁用 import 檢查：`lib/`、`test/`、`integration_test/` 不得出現 `package:flutter/material.dart`、`package:flutter/cupertino.dart`（見 PLAN.md）
3. **測試**：`flutter test --coverage`，涵蓋：
   - 單元測試：可停判斷 `eligibility`、規則 JSON 解析、來源標示
   - widget 測試
   - golden 截圖測試（Material 路徑，淺色與深色）：快速抓版面回歸，但由 Flutter 在測試程序內繪製，不含動態配色、系統列等系統層行為，這些由 `android.yml` 補
   - 覆蓋率報告上傳為 artifact；先不設門檻，穩定後再訂
4. **Supabase**（`supabase/` 有變更時才實際執行）：
   - `supabase start` 在 runner 內起本機堆疊（Docker），從零套用全部 migration，確認可重建。
   - `supabase test db` 執行 pgTAP 測試，重點驗證 **RLS**：
     - 匿名不能寫入
     - 只能改自己的資料
     - 每日回報上限
     - 隱藏待審的門檻
   - Edge Function：`deno fmt --check`、`deno lint`、`deno check`、`deno test`（`submit-report` 驗證邏輯、`admin-users` 權限與稽核）。
5. **版本號檢查**：`pubspec.yaml` 的 `version` 必須**大於**最新的 release tag（見下方「版本號規則」）。

### `ios.yml`（macOS）
- CI 在真機 Release job 各建置 production 與 staging，兩者皆不簽章；模擬器測試 App 使用獨立 job，只建置一次。
- `iOS Release 建置` 在 `macos-26` 執行 `flutter build ios --release --no-codesign`，以一般 App 入口驗證真機 Release 設定與 AOT；不簽章、不匯出 IPA。**只在 PR 執行**：PR 必須與 `main` 同步才能合併，squash 後 `main` 的程式碼與 PR 相同，push 到 `main` 時重跑沒有新資訊，而且 CD staging 會再以正式設定與簽章建置；`iOS 全部通過` 在 push 時接受此 job 為 skipped，CD 閘門仍檢查該彙總結果。
- `iOS 模擬器 App 建置` 在 `macos-26` 執行 `flutter build ios --simulator --debug --no-codesign --target=integration_test/ui_test.dart --dart-define=OFFLINE_MAP=true`，不需要簽章。
- 將 `Runner.app` 封裝成 tar 後上傳為 `ios-test-app` artifact，保留執行權限與符號連結。
- iOS 26／27 模擬器 job 以 `needs: [app]` 等待建置，以 `max-parallel: 1` **依序**執行（兩個版本需要不同的 runner 映像，沒有映像同時具備 iOS 26 與 27 runtime，無法合併成一個 job；依序執行讓每個 PR 同時最多只佔一台 macOS 跑模擬器），各自下載與解開同一份 App，再以 `flutter drive --use-application-binary=artifacts/ios-app/Runner.app` 執行測試與截圖，不重新編譯。
- 真機 Release 與 Debug 模擬器 App 是不同平台產物，不能共用；簽章與 IPA 匯出由後續 CD staging／release 流程處理。
- Release 與測試建置 job 各自執行同一套路徑判斷，測試建置再將 `run` output 傳給模擬器 job：只改文件時所有 job 直接回報成功，不下載產物；改到 `ios.yml` 本身時照常實際建置。

### `android.yml`（Linux，Android 模擬器）
- CI 在 Release job 各建置 production 與 staging APK，皆不使用正式憑證；測試 APK 使用獨立 job，只建置一次。
- `Android Release APK 建置` 執行 `flutter build apk --release`，以一般 App 入口驗證 Release 設定與 AOT；目前不使用正式簽章金鑰。與 iOS 相同，**只在 PR 執行**，`Android 全部通過` 在 push 到 `main` 時接受它為 skipped。
- `Android 測試 APK 建置` 執行 `flutter build apk --debug --target=integration_test/ui_test.dart --target-platform=android-x64 --dart-define=OFFLINE_MAP=true`，建置包含整合測試入口的 x86_64 APK，上傳為 `android-test-apk` artifact。
- Android 模擬器 job 以 `needs: [apk]` 等待建置，各自下載同一份 APK；在 Linux runner 啟用 KVM，以 `flutter drive --use-application-binary=artifacts/android-app/app-debug.apk` 執行 `integration_test/` 截圖情境，不重新編譯，與 iOS 共用同一組情境。
- 模擬器：Android 16（API 36）與 Android 11（API 30），各跑淺色與深色；映像版本實作時確認。
- 重點檢查：桌布動態配色（API 36）與品牌種子色後備（API 30）、edge-to-edge、預測式返回手勢、繁中字型。
- 截圖上傳為 workflow artifact。
- 路徑判斷同 iOS，由建置 job 將 `run` output 傳給模擬器 job；變更 `lib/`、`android/`、`integration_test/`、`pubspec.*` 或 `android.yml` 本身時才實際執行。
- 模擬器測試較慢且偶有不穩：開機逾時算基礎設施失敗，可重跑一次；測試本身失敗一律視為真實失敗，不得略過。
- iOS／Android 的 `flutter drive` 經 `tool/retry_command.py` 執行：每次嘗試有獨立逾時（iOS 12 分鐘、Android 8 分鐘，正常約 3–8 分鐘），卡住時結束整個程序群組；失敗或逾時自動再試一次（Android 先 `adb reconnect`），並在執行紀錄留下 warning。兩次都失敗才算失敗，所以真正失敗的測試仍會擋下 PR；重試成功的 warning 代表模擬器或測試不穩，需追查。

### 必要檢查（main ruleset）
- 每個 workflow 有一個彙總 job：`CI 全部通過`（`ci-ok`）、`Android 全部通過`（`android-ok`）、`iOS 全部通過`（`ios-ok`）。`needs` 該 workflow 所有 job，包含各平台的 Release、測試建置與模擬器測試，`if: always()`，任何一個失敗或被取消就失敗。
- ruleset 只把這三個彙總 job 的顯示名稱（check 名稱）設為必要檢查。這樣新增或拆分 job 時不必改 ruleset，被路徑判斷略過的 job 也不會卡住合併。
- **只有 PR 會取消舊的 run**：`ci.yml`、`android.yml`、`ios.yml` 的 `concurrency` 設為 `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`。
  - 同一個 PR 推了新的 commit 時，舊的 run 才會被取消。
  - main 上已經開始的 run 一定會跑完。CD staging 要等這三個 workflow 都在同一個 main commit 上成功才會部署；iOS 模擬器約要 40 分鐘，而 main 合併的頻率比這更高。之前 main 的 push 也會被下一次 push 取消，結果 CD 一直等不到跑完的 commit，staging 從 02cf55a 之後就停止部署（#265）。
  - GitHub 的 concurrency 群組最多保留一個排隊中的 run。所以 main 連續合併時，排隊中的舊 commit 會被更新的 commit 取代，但進行中的那個和最新的那個都會跑完。CD 依序部署跑完的 commit，最後一定會部署到最新的 main。
  - CodeQL 照舊會取消舊的 run，因為 CD 不等它。
- 這與 CLAUDE.md 的「全綠」定義一致：CI 通過才算全綠。

## CD：staging（每次合併到 main）
`cd-staging.yml`，綁定 GitHub Environment `staging`：
0. **等 CI 全部成功才開始**：
   - 不用 `push` 觸發，因為那會和 CI 同時跑，CI 失敗前就可能已部署。
   - 改用 `workflow_run` 監聽 `ci.yml`、`ios.yml`、`android.yml` 在 `main` 上完成。
   - 第一個 job 以 GitHub API 查詢該 commit（`workflow_run.head_sha`）三個彙總檢查的結果：全部成功才繼續；仍有未完成的就結束，交給最後完成的那條 CI 觸發的執行；任何一個失敗就停止。
   - 部署的程式碼一律 checkout `workflow_run.head_sha`，不用當下 `main` 的最新 commit。
   - **所有 staging 部署排成一列**：部署 job 的 `concurrency` 使用固定群組 `cd-staging`（設在 job 層級，檢查 job 不排隊），不取消進行中的執行，所以任何時刻最多只有一個 staging 部署在跑。
     - 依 GitHub 的行為，排隊中的執行只保留最新一個，中間的 commit 會被略過，這是預期行為。
   - **只部署 `main` 最新的 commit**：檢查 `workflow_run.head_sha` 是否為 `main` 最新的 commit，做兩次：
     - 第一次在不排隊的檢查 job 裡，與上面的 CI 結果查詢一起做，不是最新就直接結束，不進佇列。否則較舊 commit 晚到的重複觸發，可能取代佇列中最新 commit 的執行。
     - 第二次在部署 job 取得執行權後再確認一次。
     - 只要不是最新就略過部署，因為之後的 commit 會帶著更新的程式碼部署。如此 staging 不會被舊程式碼覆蓋。
   - 部署 job 的成功或略過要分得清楚：只有實際完成部署才算「已部署」，供正式發版檢查。
   - **同一 SHA 去重**：進佇列前與取得 `cd-staging` 固定鎖後皆查詢既有實際成功的後端部署紀錄。第一個執行完成後，排隊中的重複事件會略過部署與手機建置，避免重複通知；失敗紀錄不阻擋重試。
1. **後端**：
   - `supabase link --project-ref $STAGING_REF`
   - `supabase db push` 套用新 migration
   - `supabase functions deploy --prune --yes` 部署 Edge Function，並刪除遠端已不在 repo 的函式（例如已移除的 `tdx-parking`）
   - 這些步驟可重複執行，重跑時再套用一次也不會出錯。
2. **Android 測試 APK**（不上傳商店）：
   - `android-apk` 為獨立 job，等待後端實際完成部署，使用 `cd-staging-android` 佇列，不阻擋下一次後端部署。正式發版的 staging 成功判定只看後端 job 的實際部署紀錄。
   - 以 `--dart-define` 帶入 staging 的 Supabase URL／anon key，`flutter build apk --release`。
   - APK 同時保留為 workflow artifact，並以 `firebase appdistribution:distribute --app <Firebase Android App ID> --groups staging-android` 發佈；與 iOS 共用同一個 OIDC provider 與服務帳號，發佈前再次確認仍是 main 最新 commit。測試者可透過 Firebase 邀請連結自行加入 `staging-android` 群組，不需註冊裝置。
   - 使用獨立的 applicationId 後綴 `.staging`、APP 名稱加上「β」、圖示加上測試標記，可以和商店版並存，一眼分得出來。
   - 以專用的 staging 簽章金鑰簽署，和正式版上傳金鑰分開。
   - 上傳為 workflow artifact（保留 30 天），下載後直接安裝到手機測試。
3. **iOS 測試 IPA**（Ad Hoc 簽章，經 Firebase App Distribution OTA 安裝，不上傳 TestFlight）：
   - 獨立的 job `ios-ipa`（macOS runner），`needs` 部署 job，且只在部署 job 回報**實際完成部署**時執行；部署被略過（不是 `main` 最新的 commit）就不建置，避免產生連到舊後端狀態的安裝檔。
     - 使用自己的 `concurrency` 群組 `cd-staging-ios`（不取消進行中的執行），不和後端部署共用佇列，建置 IPA 不會擋住下一次後端部署。
     - 發佈到 Firebase 前再確認一次 `workflow_run.head_sha` 仍是 `main` 最新的 commit，不是就略過發佈（較新的 commit 會發佈自己的版本），避免較舊的建置晚完成而成為測試者看到的最新版。
     - 正式發版的「已部署到 staging」檢查只看部署 job；IPA 建置或發佈失敗會讓這次執行顯示失敗並需要修正，但不影響後端已部署的判斷。
   - 與 Android 相同的 staging 外觀：Flutter flavor `staging`（Xcode 的 `staging` scheme 與 build configuration），bundle id 加上 `.staging` 後綴、APP 名稱加上「β」、圖示加上測試標記，可以和商店版並存。
   - checkout `workflow_run.head_sha`，以 `--dart-define` 帶入 staging 的 Supabase URL／anon key。
   - 簽章：從 `staging` Environment 取出 staging 專用的 Apple Distribution 憑證（`.p12`）與 Ad Hoc provisioning profile，匯入 runner 的暫時 keychain，建置後刪除。
     - 和正式版的發布憑證分開，`staging` Environment 也不放 App Store Connect API key，所以 staging 流程無法上傳或送審。
   - 建置：`flutter build ipa --release --flavor staging --export-options-plist=ios/ExportOptions-staging.plist`。
     - `ExportOptions-staging.plist` 納入版本控管：`method` 為 Ad Hoc（Xcode 15.3 起新名稱為 `release-testing`，舊名 `ad-hoc` 仍可用，實作時依 runner 的 Xcode 版本確認）、`signingStyle` 為 `manual`，並以 `provisioningProfiles` 指定 `.staging` bundle id 對應的 profile 名稱；不使用 `flutter build ipa` 的預設匯出（App Store）。
     - 建置號改為 `<2020-01-01 起算的 UTC 日序（從 1 起）>.<當日十秒序號除以 100 的商>.<餘數>`。
       - 原規劃的 Unix 秒數超過 [Apple CFBundleVersion](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html) 第二段最多兩位的限制；新格式第一段最多四位、後兩段最多兩位。
       - job 在簽章準備後等待下一個 UTC 十秒邊界（最多十秒）再分配號碼。`ios-ipa` 的固定佇列確保不同 job 與重跑拿到遞增號碼；午夜跨日仍遞增。
       - 日序超過 9999 時明確失敗，需調整基準日；不悄悄回繞。commit SHA 與標題記錄在 Firebase release notes，版本仍可追溯。
   - **發佈：Firebase App Distribution**（[說明](https://firebase.google.com/docs/app-distribution)）：
     - 以 Firebase CLI（`firebase-tools`，固定版本）執行 `firebase appdistribution:distribute <ipa> --app <Firebase iOS App ID> --groups staging-ios --release-notes "<commit SHA 與標題>"`。
     - 認證優先用 **Workload Identity Federation**（`google-github-actions/auth`，釘選 SHA；job 加 `id-token: write`），不存放長期金鑰：
       - Google Cloud 的 provider 以 attribute condition 限定 `sub` 為 `staging` Environment，只有綁定 `staging` Environment 的 job 能換到憑證。本 repo 啟用 GitHub 不可變 subject，實際值為 `repo:smvt1215@25175632/motorcycle-parking@1413881483:environment:staging`，不是 `repo:smvt1215/motorcycle-parking:environment:staging`（舊格式會被 attribute condition 拒絕）。
       - 對應的服務帳號只給 **Firebase App Distribution Admin** 角色。
       - 已確認 Firebase CLI 能使用這種外部帳號憑證（staging 的 APK、IPA 與管理站部署都以此認證），不需服務帳號 JSON 金鑰。
     - **IPA 不上傳為 GitHub artifact**：Ad Hoc IPA 內嵌的 provisioning profile（`embedded.mobileprovision`）的 `ProvisionedDevices` 列出**所有測試裝置的 UDID**（[Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)），公開 repo 的 artifact 任何登入 GitHub 的人都能下載。Firebase 上的版本只有受邀的測試者看得到；原始 IPA 不放進快取，job 結束即隨 runner 銷毀。
     - Firebase 上的版本保留 150 天後過期；App Distribution 本身不需要 Firebase SDK（APP 內的 Firebase 只用於 App Check，見下方〈App Check〉）。
   - **測試者 OTA 安裝**（在 iPhone 上完成，不需要 Mac）：
     1. 第一次：在 iPhone 的 Safari 開啟 Firebase 的邀請 email（邀請 30 天內有效），以 Google 帳號登入並接受邀請。
     2. 依頁面指示「註冊裝置」，安裝 Firebase 的描述檔；描述檔會把該 iPhone 的 UDID 回報給 Firebase，並以 email 通知專案擁有者。
     3. 擁有者把 UDID 加入 Apple Developer、重新產生 Ad Hoc profile、更新 `staging` Environment 的 profile secret（見下方「測試裝置管理」）；之後的 staging 建置就能裝在這台 iPhone 上。
     4. 之後每次有新建置，測試者會收到通知，在 iPhone 上（Firebase 加到主畫面的 App Tester 網頁）點選安裝即可。
     - iOS 16 以上可能需在「設定 › 隱私權與安全性」開啟「開發者模式」（第三方文件指出 Ad Hoc 建置需要，Apple 文件未明列；實作時以實機確認，並寫進 README）。
   - **測試裝置管理**：
     - 新裝置的 UDID 由上述 Firebase 描述檔收集（也可在 Firebase 主控台匯出 UDID CSV，於 Apple Developer 網站以「Register Multiple Devices」匯入）。
     - 註冊後要重新產生 Ad Hoc profile 並更新 `staging` Environment 的 profile secret；下一次 staging 建置（新的合併，或重跑最新 commit 的 `ios-ipa` job）才會包含新裝置。未註冊的裝置無法安裝。
     - 每個會員年度每種裝置類型（iPhone）最多註冊 100 台，年度更新時才能移除名額。
     - 移除測試者：從 Firebase 的 `staging-ios` 群組移除即無法再取得新版本。
   - iOS 的 UI 驗證仍以 `ios.yml` 的模擬器截圖為主；IPA 用來在實機確認定位、通知、原生 Liquid Glass 元件與 staging 後端的整體行為。

## CD：beta／RC／正式版（推送版本 tag）
`release.yml` 依 tag 判斷通道（`tool/cd_gate.py` 的 `release_tag`）：

- **`vX.Y.Z-beta.N`、`vX.Y.Z-rc.N`**：做完下方全部檢查後（**只有 RC 部署 production 後端**；beta 不部署，以 `STAGING_SUPABASE_*` 建置連 staging 的 App，閘門已確認該 SHA 的 staging 部署成功），iOS 以 fastlane `ios testing` 上傳 TestFlight 並發給外部公開群組（`TESTFLIGHT_GROUP`），Android 以 `android testing` 上傳 Play 封閉測試（beta，API 軌道名 `alpha`）或開放測試（RC，API 軌道名 `beta`）。beta 與 RC 連不同後端，所以**建置號範圍分開**（見下方「建置號」），RC 絕不沿用 beta 的建置；同一通道重跑時，該 commit 範圍內已有建置就沿用並推進軌道，不重新建置。每個版本的第一個 TestFlight 外部建置要等 Apple 的 Beta App Review。
- **`vX.Y.Z`**：必須打在**同版本最後一個 RC 的 commit**（`promoted_candidate`），且該 RC tag 自己的 `release.yml` 最新一次執行必須成功（`release_succeeded`）；不要求是 `main` 最新，也不再等待 CI／staging（RC 時已通過）。`ios release` 與 `android release` 只尋找該 commit 範圍內、RC 實際發出的建置（iOS 須在 `TESTFLIGHT_GROUP` 群組內且已可由外部測試者安裝，即 `IN_BETA_TESTING`；仍在 Beta App Review 或只在其他群組的建置不算。Android 須在開放測試軌道的 `completed` 發佈中，或已在 production；草稿或分階段發佈都不算）並送審／推進 production，找不到就失敗，**絕不重新建置**，只在封閉測試的 beta 建置不會被推上商店；後端也不重新部署，避免較舊的 commit 覆蓋之後 RC 已部署的 Edge Functions。
- 同一個 commit 上其他版本 tag 的 Release 若已有建置的 SHA-256 紀錄，沿用時會複製到本次 Release（`HASH_SOURCES`），讓正式版的 Release 列出商店實際使用的建置雜湊。

以下為 beta／RC 的檢查；正式版只做版本號、完整歷史、production 核准設定與 RC commit 檢查。

1. **前置檢查**（Linux）：
   - tag 指向的 commit 必須**就是 `main` 目前最新的 commit**，不能只是 `main` 的祖先。staging 只部署 `main` 最新的 commit，打在較舊 commit 的 tag 可能從未在 staging 驗證過；同時也確保建置號大於前一次發版。
     - 這個檢查在流程開始時與人工核准之後**各做一次**，因為等待核准期間 `main` 可能已前進。
     - 不符合時流程失敗，並提示刪除 tag、在最新的 `main` 上重新打 tag。
     - **發版期間（從打 tag 到 `release.yml` 成功結束）暫停合併其他 PR**，不是只到核准完成為止。核准後的部署、上傳或送審若失敗，重跑時 tag 仍是 `main` 最新的 commit，才能通過檢查安全重試。
   - **同時只跑一個正式發版**：`release.yml` 使用固定的 `concurrency` 群組 `release`，不取消進行中的執行，避免兩個 tag 的發版重疊。同一個 tag 的重跑照常排隊執行。
   - `pubspec.yaml` 的 `version` 必須等於 tag 的版本號（例如 `1.2.0`）。
   - 該 commit 的 CI 必須全綠。
   - **該 commit 必須已成功部署到 staging**：查詢 `cd-staging.yml` 針對同一個 SHA 的執行，部署 job 必須實際成功，被略過不算。
     - staging 還在跑：等它完成，最多 60 分鐘；逾時就失敗。
     - staging 失敗或被略過：正式發版失敗，並提示先修好 staging。
2. **人工核准**：
   - 綁定 GitHub Environment `production`，設定必須由你核准才會繼續。
   - 公開 repo 免費可用。
   - production 的金鑰只存在這個 Environment，staging 流程拿不到。
3. **後端先行**：
   - production `supabase db push` 與 `functions deploy`。
   - 先部署後端，再上架 APP。
4. **建置號**：`commit 數 × 10 + 個位數`。個位數依通道分開：**beta 用 1～4、RC 用 5～9**（正式版沿用 RC 的範圍，不建置）。beta 與 RC 連不同後端，分開範圍讓同一個 commit 的兩種建置不會撞號，也不會被對方沿用（`tool/cd_gate.py` 的 `build_range`、`fastlane/release_policy.rb` 的 `range`）。
   - commit 數 = `git rev-list --count HEAD`。checkout 必須設定 `fetch-depth: 0` 取得完整歷史，因為 `actions/checkout` 預設只抓 1 個 commit，計數會永遠是 1。計算前檢查 `git rev-parse --is-shallow-repository` 為 `false`，否則讓流程失敗。
   - 個位數由 `github.run_attempt` 決定：beta 第 1～4 次嘗試對應 1～4，RC 第 1～5 次對應 5～9；超過就讓流程失敗並提示人工處理。重跑時嘗試次數增加，會拿到新號碼。
   - tag 必須在 `main` 最新 commit 上，所以每次發版的 commit 數都大於上一次，建置號單調遞增。
   - Android `versionCode` 上限為 2,100,000,000；目前兩平台共用單一整數號碼，另採 Apple 第一段最多四位的限制，因此號碼大於 9999 時先阻止發版，需調整 iOS 編碼與商店範圍查詢後再繼續。
   - **每個平台各自冪等**：上傳前先向商店查詢，已有落在本通道範圍（beta：`commit 數 × 10 + 1～4`；RC：`+ 5～9`）內的建置號，就代表這個版本已上傳過，**略過上傳這一步**（後續步驟見下方 Android、iOS 各自的規則）。查詢必須涵蓋**完整範圍**：
     - **iOS**：不用 `latest_testflight_build_number`，它只回傳最新的一個建置。改在 fastlane lane 中用 App Store Connect API（Spaceship `ConnectAPI::Build`，或 `GET /v1/builds`）查詢範圍內的 9 個號碼：
       - **限定範圍**：一律加上 `filter[app]`（本 APP 的 Apple ID）與 `filter[preReleaseVersion.version]`（本次版本號，例如 `1.2.0`），避免同帳號下其他 APP 剛好用到相同的建置號。
       - **只認處理成功的建置**：
         - `processingState` 為 `VALID` 才算「已上傳」，可以略過上傳並用於送審。
         - `PROCESSING` 就輪詢等待結果，最多 60 分鐘。逾時後不再等這個舊建置，改用本次執行自己的建置號（嘗試次數不同，不會撞號）照常上傳。之後若有多個 `VALID` 建置，送審時用號碼最大的那個。
         - `FAILED`／`INVALID` 不算，照常上傳新建置；重跑時嘗試次數已增加，會用新的建置號。
     - **Android**：`google_play_track_version_codes` 只回傳單一軌道，所以要查詢所有軌道（internal、alpha、beta、production）後取聯集再比對。
     - 部分失敗時（例如 Android 成功、iOS 失敗）重跑，只會補傳失敗的平台。
5. **Android**：
   - 以 production 設定建置 AAB。
   - fastlane `upload_to_play_store` 的上傳與指定軌道在同一個 Play edit 內一起提交，任一步失敗整個 edit 不會生效。所以範圍內已有版本碼、而且已在 production 軌道上，才視為完成；版本碼存在但不在 production 軌道（例如人工操作留下的），就改為把既有版本碼推進 production 軌道，不重新上傳。
   - 上傳 **正式版（production）軌道**，**分階段推出 10%**。
   - 觀察後在 Play Console 調高比例，有問題可暫停。
6. **iOS**：上傳與送審分成兩個獨立步驟。Apple 的上傳、選擇建置、送審是不同階段，上傳成功不代表已送審。
   - **上傳**：以 production 設定建置 IPA，上傳 App Store Connect；範圍內已有建置就略過，沿用既有建置。
   - **送審**：每次執行都要檢查，不因上傳被略過而跳過。
     - 以 App Store Connect API 查詢該版本的狀態，已在「等待審查」或之後的狀態（審查中、待發布、已上架等）才視為完成。
     - 否則用 fastlane `deliver` 指定範圍內 `VALID` 的建置號，更新商店文字並送審，啟用**分階段發布**（7 天）。
     - 這樣即使上傳成功、送審失敗，重跑也會補完送審。
   - 商店文字與截圖放在 `fastlane/metadata`，一併版本控管。
7. **GitHub Release**：
   - 依兩個 tag 之間的 commit 產生更新說明。
   - 附上 AAB／IPA 的檔案雜湊值（不附檔案本身）。
   - 核准後先建立 draft Release，每次商店上傳前先附上該平台／建置號的 SHA-256 文字紀錄。重跑沿用舊建置時，取回原檔雜湊，不用重新建置的不同二進位檔替代。
   - 兩平台完成後才公開 Release；只將實際選用的兩個商店建置的雜湊加入說明。若人工上傳的建置缺少原始雜湊紀錄，Release 發佈失敗，需先補上原檔的紀錄。

## 簽章與金鑰
| 項目 | 存放 | 用途 |
|---|---|---|
| Android 上傳金鑰（upload keystore，base64）與密碼 | Environment secrets（只在 `production`） | 簽 AAB；Google Play App Signing 保管真正的發布金鑰 |
| Android staging 簽章金鑰（base64）與密碼 | Environment secrets（`staging`） | 簽 staging 測試 APK，和正式版金鑰分開 |
| iOS staging 發布憑證 `.p12`（base64）與密碼、Ad Hoc provisioning profile（base64） | Environment secrets（`staging`） | 簽 staging 測試 IPA；匯入暫時 keychain，建置後刪除；和正式版憑證分開 |
| Firebase iOS／Android App ID、Workload Identity provider 與服務帳號名稱 | Environment variables（`staging`） | 發佈 staging IPA 到 Firebase App Distribution；以 OIDC 換取短期憑證，不存長期金鑰（服務帳號只有 App Distribution Admin 角色） |
| Google Play 服務帳號 JSON | Environment secrets（只在 `production`） | fastlane 上傳 |
| App Store Connect API key（`.p8`、Key ID、Issuer ID） | Environment secrets（只在 `production`） | fastlane 上傳／送審 |
| iOS 發布憑證 `.p12`（base64）與密碼、provisioning profile | Environment secrets（只在 `production`） | 匯入 runner 的暫時 keychain，建置後刪除 |
| Supabase access token、各環境 project ref、DB 密碼 | Environment secrets（各自環境） | `supabase link`／`db push`／`functions deploy` |
| Supabase URL、anon key | Environment variables | 以 `--dart-define` 帶入 APP（anon key 本來就會出現在 APP 內） |
| Turnstile secret | **只放 Supabase secrets**，不放 GitHub | Edge Function 使用；`supabase secrets set` 由人工設定，CI 不經手 |
| TDX Client ID／Secret | 只放開發者本機 `supabase/functions/.env`（不進版控） | 僅供 `tool/import_mymaps.py` 靜態核驗；App 與 Edge Function 不再使用 |

原則：
- 任何金鑰都不進 repo。
- PR 的 CI 不使用任何 secret：來自 fork 的 PR 拿不到，CI 也不需要。
- 只有 `main` 與 tag 的流程讀得到 Environment secrets。

## App Check（#203）
寫入端點以 Firebase App Check 確認請求來自自家 APP。後端驗證 `X-Firebase-AppCheck` header（`supabase/functions/_shared/app_check.ts`）；`APP_CHECK_MODE=log` 時只記錄結果、不擋請求。

### dart-define
不使用 `google-services.json`、`GoogleService-Info.plist` 或 `flutterfire configure` 產生的檔案；`tool/cd_config.py` 依平台把下列值寫進 `config/<環境>.json`，再以 `--dart-define-from-file` 帶入：

| dart-define | 來源 |
|---|---|
| `FIREBASE_API_KEY` | Environment variable `FIREBASE_ANDROID_API_KEY`／`FIREBASE_IOS_API_KEY`（只開 App Check 與 Installations API） |
| `FIREBASE_APP_ID` | Environment variable `FIREBASE_ANDROID_APP_ID`／`FIREBASE_IOS_APP_ID` |
| `FIREBASE_MESSAGING_SENDER_ID` | 由 App ID 中間的專案編號取出（staging：`815509193159`） |
| `FIREBASE_PROJECT_ID` | Environment variable `FIREBASE_PROJECT_ID`；staging 未設定時用 `motocycle-parking-guide`，production 沒有預設值 |
| `APP_CHECK_DEBUG_TOKEN` | 選用，只給本機 debug build 指定已註冊的 debug token；不放進 repo 或 CI |

- 該平台的 API key 與 App ID 都沒設定時（本機、PR CI、web、管理站、production 尚未設定）APP 不初始化 Firebase，照常運作，只是不送 token；只設定其中一項、App ID 平台不符，或缺 `FIREBASE_PROJECT_ID` 時，設定檢查會報錯。
- `cd-staging.yml` 的 Android、iOS job 各自帶該平台的 key 與 App ID；`release.yml` 以同樣名稱讀取 production Environment，尚未設定時 production 建置停用 App Check。

### Provider
| 建置 | Android | iOS |
|---|---|---|
| debug | debug provider | debug provider |
| profile／release（含 staging） | Play Integrity | App Attest（不支援時退回 DeviceCheck） |

- iOS release／profile 設定使用 `ios/Runner/Runner.entitlements`（`com.apple.developer.devicecheck.appattest-environment = production`）。Apple Developer 的 App ID（staging 與 production 各一）必須啟用 **App Attest** capability，並重新產生 provisioning profile、更新 `IOS_PROFILE_BASE64`；舊 profile 沒有此 entitlement，簽章會失敗。
- APP 取 token 最多等 3 秒（`lib/core/app_check.dart`）；失敗、逾時或未啟用時不帶 header，照常送出，由後端依模式決定。

### 註冊 debug token
1. 以 debug 模式帶入 Firebase 的 dart-define 執行 APP（例如 `--dart-define-from-file` 指向本機、不進版控的設定檔）。
2. 第一次送出回報時，SDK 會在裝置 log 印出 debug token：Android 在 Logcat 搜尋 `DebugAppCheckProvider`；iOS 先在 Xcode scheme 的 Run → Arguments 加上 `-FIRDebugEnabled`，再於 console 搜尋 `Firebase App Check Debug Token`。也可以自己產生一組 UUID，先註冊再以 `--dart-define=APP_CHECK_DEBUG_TOKEN=<UUID>` 帶入，每次重裝都沿用同一組。
3. 到 Firebase Console → App Check → 應用程式 → 該 APP 的選單 →「管理偵錯權杖」，加入該 token 並命名裝置。
4. token 等同通行證：只存在個人裝置或私人密碼管理工具，不貼進 issue、PR 或 repo；裝置不再使用時從 Console 刪除。

### 限制：維持 log 模式
Play Integrity 只認得從 Google Play 安裝的 APP。staging 的 APK 經 Firebase App Distribution 側載，拿到的 token 會被判為無效；iOS Ad Hoc 版本的 App Attest 也要等 profile 更新後才有效。因此 staging 維持 `APP_CHECK_MODE=log`，等正式版從商店安裝、且 log 中有效比例足夠後，再評估改為 `enforce`。

## 供應鏈安全
- 第三方 GitHub Action 一律**釘選到 commit SHA**（不用 `@v4` 這類可變標籤）。
- Dependabot 每週檢查 `github-actions` 與 `pub` 相依；每個 ecosystem 的 minor／patch 版本更新分組，major 仍獨立審查，不忽略更新也不改變安全修補政策。更新一樣走 PR 與 CI。
- 每個 workflow 預設 `permissions: contents: read`，需要時才在 job 層級加權限（例如建立 Release 需要 `contents: write`）。
- `pubspec.lock` 納入版本控管，CI 使用鎖定版本。

## 版本號規則
- `pubspec.yaml` 的 `version` 名稱部分（例如 `1.2.0`）就是商店顯示的版本號；beta、RC、正式版共用同一個版本號，商店只接受 `X.Y.Z`。建置號由 `release.yml` 依上述公式產生，`pubspec.yaml` 的 `+N` 不使用。
- 發版流程：
  1. 開一個 PR 把版本改成要發的版本，例如 `1.2.0`。
  2. 合併後在 `main` 最新 commit 打 `v1.2.0-beta.1`；修正後再合併、打 `v1.2.0-beta.2`……
  3. 準備上架時在 `main` 最新 commit 打 `v1.2.0-rc.1`；RC 期間只合併必要修正，每次修正後打下一個 RC。
  4. 最後一個 RC 驗證完成後，在**同一個 commit** 打 `v1.2.0`，把該 RC 的建置送上商店。
- 版本號檢查只比對正式版 tag（`vX.Y.Z`），beta／RC tag 不影響。
- 發版之後，**下一個合併到 `main` 的 PR 必須先升版**（例如 `1.2.1`）。原因是 App Store Connect 不接受已上架版本號的新建置，沒有升版的話，下一次發版會被拒收。
- CI 的版本號檢查負責把關：版本不大於最新 tag 時，PR 無法合併。

## 資料庫 migration 規則
- migration 只在 **RC tag** 時套用到 production（beta 只到 staging），且無法撤回：RC 之後即使不上架，正式資料庫也已變更。
- 舊版 APP 會在使用者手機上留存一段時間，所以 production migration 必須**向下相容**（先擴充、後收斂）：
  - 新增欄位要有預設值。
  - 刪除或改名欄位分兩次發版，等舊版 APP 不再使用後才移除。
- migration 只能往前，不寫 down migration；出錯時用新的 migration 修正。
- 每個 migration 都必須能在 CI 從零套用成功（`supabase start`）。

## 最低支援版本（不相容的發版，#195 P2）
`api_v1.client_config()` 會回傳 `min_supported_app_version`。版本低於它的 App 會**整個擋下**，必須更新才能繼續使用（使用者決定）。這個值一旦設錯，所有人都打不開 App，所以：
- 伺服器寧可不擋：沒有設定、格式不對或讀取失敗時，一律回 `0.1.0`。
- App 離線或讀不到 `client_config` 時，也不可以擋。
- 只有 `admin_v1.set_min_supported_app_version()` 能修改這個值，每次修改都會寫入 `admin_audit_log`：
  - 管理員可以調高或調低。調低（例如發現新版有問題，要讓舊版回來）只能由管理員手動操作。
  - CD 只能調高，稽核紀錄的 actor 是 `00000000-0000-0000-0000-0000000000cd`，並附上 run 的網址。

**哪種改動算不相容**：舊版 App 在新後端上會壞掉或資料會被拒絕的改動。例如：
- 舊版送出的回報被新的驗證規則拒絕。
- 舊版讀取的欄位被移除，或改了語意。
- 規則或資料的格式變了，舊版解析不了。

依「資料庫 migration 規則」先擴充、後收斂的改動，不算不相容，不必標記。

**怎麼標記**：在造成不相容的那個 PR 裡，把 `config/app_compat.json` 的 `min_supported_app_version` 改成這一版的 pubspec 版本（`x.y.z`，不含 build number）。PR 審查時會在 diff 上看到這個改動。CI 的 `tool/check_app_compat.py` 會檢查：
- 值必須是 `x.y.z`，而且不能大於 pubspec 的版本。
- 只能調高，而且只能調成這一版的 pubspec 版本。要調低就由管理員手動處理，不要改這個檔案。
- 這個 PR 沒有同時調整 pubspec 版本時，會在 PR 上顯示警告，提醒確認這一版確實是不相容的那一版。

**何時生效**：
- **staging**：`cd-staging.yml` 部署後端後立刻調高，讓 Firebase 封測版和後端同時推出。CD 對每個標記只處理一次（資料表記錄 `last_cd_mark`），所以檔案沒有改時不會有任何變動；管理員手動回退後，之後用同一個標記部署也不會把值調回去，只有更新的標記才會再調高。
- **production**：部署當下不會調高。release 結束時，摘要會提醒這件事。等這一版在 App Store 與 Google Play 都上架後，手動執行 workflow「Raise production minimum App version」（`raise-min-app-version.yml`）。這個 workflow：
  1. 要經過 `production` environment 的人工核准。
  2. 用 App Store 的公開查詢 API 確認 `tw.motopark.motorcycleParking` 的版本已經 ≥ 標記的版本。
  3. 確認 Google Play：
     - 已設定 `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`：用 Play Developer API 建一個暫時的 edit，讀 production track，最後一律刪除該 edit、不 commit。這一版的 versionCode 取自 GitHub Release `vX.Y.Z` 的附件 `sha256-android-<number>.txt`，也就是實際上架的 Android 建置。CD 自己產生 build number，正式版沿用 RC 的建置，所以不能用 pubspec 的 build number。這個 versionCode必須是 `completed`，或 `inProgress` 且 `userFraction` 為 1；分階段推出還沒到 100% 時不放行，訊息會寫出目前的比例。
     - 還沒有服務帳號：由核准人勾選 `play_confirmed`。
     - 執行結果會寫明用的是哪一種確認方式。
  4. 兩個商店都確認後，呼叫 `admin_v1.set_min_supported_app_version()` 調高。

## 回復與應變
- **Android**：在 Play Console 暫停分階段推出，修正後發新版本。
- **iOS**：暫停分階段發布，修正後送審新版本。
- **後端**：
  - Edge Function 重新部署上一個 tag 的版本。
  - 資料庫以新的 migration 修正。

## 費用
- GitHub Actions：公開 repo 的標準 runner（含 macOS）免費。
- Supabase：免費方案可建立 2 個專案，正好對應 staging 與 production。
  - 免費專案閒置一週會暫停，staging 可能需要手動喚醒。
  - production 正式上線後評估是否升級付費方案。
- Apple Developer Program（年費）與 Google Play（一次性）已具備。
- Firebase App Distribution：免費。

## 實作順序
1. **第一個實作 PR**：`ci.yml`、`ios.yml`、`android.yml` 與各自的彙總 job；跑過一次後到 ruleset 設定必要檢查。
2. **建立 Supabase 兩個專案與 GitHub Environments**：設定 secrets；`production` 設定必須核准。
3. **`cd-staging.yml`**：只需要 Supabase staging、Android staging 簽章金鑰、iOS staging 憑證與 Ad Hoc profile，以及 Firebase App Distribution，不需要商店（Play Console、App Store Connect APP）設定。
4. **`release.yml`**：
   - 先手動在兩個商店建立 APP。
   - Play 需要先手動上傳第一個版本，之後才能用 API 上傳。
   - 準備商店文字與截圖後，第一次正式發版。

## 待準備事項（CI／CD 專屬）
- **Google Play Console**：
  - 建立 APP 並啟用 Play App Signing。
  - 建立服務帳號並授權發布。同一個服務帳號（`production` 的 `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`）也讓「Raise production minimum App version」能讀取 production track；這個用途只需要讀取 release 的權限。
  - 手動上傳第一個正式版建置，之後才能由 CD 以 API 上傳。
- **`production` environment**：設定必要的核准人（required reviewers）。「Raise production minimum App version」要靠這道人工核准，才能調高最低支援版本。
- **Apple Developer（staging 測試 IPA）**（已完成：staging Ad Hoc IPA 已由 CD 建置並送到 Firebase；新增測試裝置時仍需更新 profile）：
  - 註冊 staging bundle id（正式 bundle id 加 `.staging`）。
  - 註冊測試者 iPhone 的 UDID（可由 Firebase 收集，見上方「測試者 OTA 安裝」）。
  - 建立 staging 專用的 Apple Distribution 憑證，以及包含上述裝置的 Ad Hoc provisioning profile。
- **Firebase（staging 測試 IPA 的 OTA 發佈）**（已完成：iOS 與 Android APP、`staging-ios`／`staging-android` 群組、Workload Identity Federation 與服務帳號）：
  - 建立 Firebase 專案（同時是一個 Google Cloud 專案，下方的 Workload Identity Federation 也設在這裡），新增 iOS APP，bundle id 填 staging 的 `.staging` bundle id，記下 App ID。
  - 啟用 App Distribution，建立測試者群組 `staging-ios` 並邀請測試者。
  - 在 Google Cloud 設定 Workload Identity Federation（GitHub OIDC provider，限定 `staging` Environment）與只有 Firebase App Distribution Admin 角色的服務帳號。
- **App Store Connect**：
  - 建立 APP 與 bundle id。
  - 建立 API key（App Manager 權限）。
  - 建立發布憑證與 provisioning profile。
- **Supabase**：
  - 建立 staging、production 兩個專案（staging 已建立並由 CD 部署；production 於上線前另建）。
  - 產生 access token。
- **GitHub**：建立 `staging`、`production` 兩個 Environment，`production` 設定由你核准（已完成；`production` 的 secret 與 variable 尚未設定）。
