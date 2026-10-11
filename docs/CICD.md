# CI／CD 規劃

> 狀態：規劃中（尚未建立 workflow）。最後更新：2026-10-11。整體計畫見 [PLAN.md](PLAN.md)。

## 決策摘要
- 平台：**GitHub Actions**（公開 repo 使用 GitHub 標準 runner 不收費，含 macOS）。
- 簽章與上架工具：**fastlane**（iOS 用 App Store Connect API key，Android 用 Google Play 服務帳號）。
- 後端環境：**Supabase staging + production** 兩個專案。
- 發版觸發：推送版本 tag `vX.Y.Z`；合併到 `main` 只更新 staging 後端並產生測試用 APK。
- **商店只上架正式版**：staging 建置一律不上傳 Google Play 或 TestFlight，測試者不會被商店替換版本，也不會誤連到另一個後端。
- 已具備：Apple Developer Program、Google Play Console。

## 整體流程
```
PR ──► CI（檢查 + 測試）──► 全綠 ──► Squash merge 到 main
                                         │
                                         ▼
                         CD staging：Supabase staging 部署
                                   + 連 staging 的 Android 測試 APK（workflow artifact，直接安裝）
                                         │
                       推送 tag vX.Y.Z ──┘
                                         ▼
                         CD release（需人工核准）：Supabase production 部署
                                   + App Store 送審（分階段發布）/ Play 正式版（分階段推出）
                                   + GitHub Release
```

## Workflow 一覽
| 檔案 | 觸發 | Runner | 內容 |
|---|---|---|---|
| `ci.yml` | PR、push 到 `main` | Linux | Flutter 檢查與測試、Supabase 檢查、Android 建置 |
| `ios.yml` | PR、push 到 `main`、手動 | macOS | iOS 模擬器建置與截圖（見 PLAN.md「UI 設計規範 › 驗證」） |
| `android.yml` | PR、push 到 `main`、手動 | Linux（模擬器硬體加速） | Android 模擬器截圖（API 36 與 API 30） |
| `cd-staging.yml` | `main` 上的三條 CI 都成功後（`workflow_run`） | Linux | 部署 staging 後端、產生 Android 測試 APK（不上傳商店） |
| `release.yml` | 推送 tag `v*` | Linux + macOS | 部署 production 後端、上架兩平台、建立 GitHub Release |

## CI（每個 PR）
### `ci.yml`（Linux）
1. **環境**：Flutter 版本固定在 repo 的 `.flutter-version`（≥ 3.47，`material_ui` 下限），以 `subosito/flutter-action` 安裝並快取 pub 套件。
2. **程式碼品質**：
   - `dart format --set-exit-if-changed .`
   - `flutter analyze`（`analysis_options.yaml` 開嚴格模式，警告視為錯誤）
   - 禁用 import 檢查：`lib/`、`test/`、`integration_test/` 不得出現 `package:flutter/material.dart`、`package:flutter/cupertino.dart`（見 PLAN.md）
3. **測試**：`flutter test --coverage`，涵蓋：
   - 單元測試：可停判斷 `eligibility`、規則 JSON 解析、TDX 正規化
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
   - Edge Function：`deno fmt --check`、`deno lint`、`deno test`（TDX 正規化與 `submit-report` 限流邏輯，用固定的範例 JSON）。
5. **Android 建置**：`flutter build apk --debug`，確認 Gradle 設定沒壞。
6. **版本號檢查**：`pubspec.yaml` 的 `version` 必須**大於**最新的 release tag（見下方「版本號規則」）。

### `ios.yml`（macOS）
沿用 PLAN.md 已定的設計：
- 模擬器建置，不需要簽章。
- iOS 26／27 模擬器截圖。
- 路徑判斷寫在 job 內：只改文件時直接回報成功；改到 `ios.yml` 本身時照常實際建置。

### `android.yml`（Linux，Android 模擬器）
- 在 Linux runner 啟用 KVM，以 Android 模擬器執行 `integration_test/` 截圖情境，與 iOS 共用同一組情境。
- 模擬器：Android 16（API 36）與 Android 11（API 30），各跑淺色與深色；映像版本實作時確認。
- 重點檢查：桌布動態配色（API 36）與品牌種子色後備（API 30）、edge-to-edge、預測式返回手勢、繁中字型。
- 截圖上傳為 workflow artifact。
- 路徑判斷同 iOS：變更 `lib/`、`android/`、`integration_test/`、`pubspec.*` 或 `android.yml` 本身時才實際執行。
- 模擬器測試較慢且偶有不穩：開機逾時算基礎設施失敗，可重跑一次；測試本身失敗一律視為真實失敗，不得略過。

### 必要檢查（main ruleset）
- 新增一個彙總 job `ci-ok`：`needs` 所有 CI job，`if: always()`，任何一個失敗或被取消就失敗。
- ruleset 只把 `ci-ok`（以及 `ios.yml`、`android.yml` 的對應彙總 job）設為必要檢查。這樣新增或拆分 job 時不必改 ruleset，被路徑判斷略過的 job 也不會卡住合併。
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
1. **後端**：
   - `supabase link --project-ref $STAGING_REF`
   - `supabase db push` 套用新 migration
   - `supabase functions deploy` 部署 Edge Function
   - 這些步驟可重複執行，重跑時再套用一次也不會出錯。
2. **Android 測試 APK**（不上傳商店）：
   - 以 `--dart-define` 帶入 staging 的 Supabase URL／anon key，`flutter build apk --release`。
   - 使用獨立的 applicationId 後綴 `.staging`、APP 名稱加上「β」、圖示加上測試標記，可以和商店版並存，一眼分得出來。
   - 以專用的 staging 簽章金鑰簽署，和正式版上傳金鑰分開。
   - 上傳為 workflow artifact（保留 30 天），下載後直接安裝到手機測試。
3. **iOS**：
   - iOS 不經商店或 TestFlight 無法安裝到一般手機，所以 staging 階段不產生 iOS 安裝檔。
   - iOS 的 staging 驗證靠 `ios.yml` 的模擬器截圖，以及開發者在自己的 Mac 上連 staging 執行。

## CD：正式發版（推送 tag `vX.Y.Z`）
`release.yml`：
1. **前置檢查**（Linux）：
   - tag 指向的 commit 必須**就是 `main` 目前最新的 commit**，不能只是 `main` 的祖先。staging 只部署 `main` 最新的 commit，打在較舊 commit 的 tag 可能從未在 staging 驗證過；同時也確保建置號大於前一次發版。
     - 這個檢查在流程開始時與人工核准之後**各做一次**，因為等待核准期間 `main` 可能已前進。
     - 不符合時流程失敗，並提示刪除 tag、在最新的 `main` 上重新打 tag。
     - 發版期間（從打 tag 到核准完成）暫停合併其他 PR。
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
4. **建置號**：`commit 數 × 10 + 嘗試次數`（只有正式版會上傳商店，不需要通道位數）。
   - commit 數 = `git rev-list --count HEAD`。checkout 必須設定 `fetch-depth: 0` 取得完整歷史，因為 `actions/checkout` 預設只抓 1 個 commit，計數會永遠是 1。計算前檢查 `git rev-parse --is-shallow-repository` 為 `false`，否則讓流程失敗。
   - 嘗試次數 = `github.run_attempt`，上限 9，超過就讓流程失敗並提示人工處理。重跑時嘗試次數增加，會拿到新號碼。
   - tag 必須在 `main` 最新 commit 上，所以每次發版的 commit 數都大於上一次，建置號單調遞增。
   - 遠低於 Android `versionCode` 上限 2,100,000,000（commit 數需少於約 2.1 億）。
   - **每個平台各自冪等**：上傳前先向商店查詢，已有落在 `commit 數 × 10 + 1～9` 範圍內的建置號，就代表這個版本已上傳過，**略過上傳這一步**（後續步驟見下方 Android、iOS 各自的規則）。查詢必須涵蓋**完整範圍**：
     - **iOS**：不用 `latest_testflight_build_number`，它只回傳最新的一個建置。改在 fastlane lane 中用 App Store Connect API（Spaceship `ConnectAPI::Build`，或 `GET /v1/builds` 以建置號篩選），逐一查詢範圍內的 9 個號碼。
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
     - 否則用 fastlane `deliver` 指定範圍內已有的建置號，更新商店文字並送審，啟用**分階段發布**（7 天）。
     - 這樣即使上傳成功、送審失敗，重跑也會補完送審。
   - 商店文字與截圖放在 `fastlane/metadata`，一併版本控管。
7. **GitHub Release**：
   - 依兩個 tag 之間的 commit 產生更新說明。
   - 附上 AAB／IPA 的檔案雜湊值（不附檔案本身）。

## 簽章與金鑰
| 項目 | 存放 | 用途 |
|---|---|---|
| Android 上傳金鑰（upload keystore，base64）與密碼 | Environment secrets（只在 `production`） | 簽 AAB；Google Play App Signing 保管真正的發布金鑰 |
| Android staging 簽章金鑰（base64）與密碼 | Environment secrets（`staging`） | 簽 staging 測試 APK，和正式版金鑰分開 |
| Google Play 服務帳號 JSON | Environment secrets（只在 `production`） | fastlane 上傳 |
| App Store Connect API key（`.p8`、Key ID、Issuer ID） | Environment secrets（只在 `production`） | fastlane 上傳／送審 |
| iOS 發布憑證 `.p12`（base64）與密碼、provisioning profile | Environment secrets（只在 `production`） | 匯入 runner 的暫時 keychain，建置後刪除 |
| Supabase access token、各環境 project ref、DB 密碼 | Environment secrets（各自環境） | `supabase link`／`db push`／`functions deploy` |
| Supabase URL、anon key | Environment variables | 以 `--dart-define` 帶入 APP（anon key 本來就會出現在 APP 內） |
| TDX Client ID／Secret、Turnstile secret | **只放 Supabase secrets**，不放 GitHub | Edge Function 使用；`supabase secrets set` 由人工設定，CI 不經手 |

原則：
- 任何金鑰都不進 repo。
- PR 的 CI 不使用任何 secret：來自 fork 的 PR 拿不到，CI 也不需要。
- 只有 `main` 與 tag 的流程讀得到 Environment secrets。

## 供應鏈安全
- 第三方 GitHub Action 一律**釘選到 commit SHA**（不用 `@v4` 這類可變標籤）。
- Dependabot 每週檢查 `github-actions` 與 `pub` 相依，更新一樣走 PR 與 CI。
- 每個 workflow 預設 `permissions: contents: read`，需要時才在 job 層級加權限（例如建立 Release 需要 `contents: write`）。
- `pubspec.lock` 納入版本控管，CI 使用鎖定版本。

## 版本號規則
- `pubspec.yaml` 的 `version` 名稱部分（例如 `1.2.0`）就是商店顯示的版本號；建置號由 `release.yml` 依上述公式產生，`pubspec.yaml` 的 `+N` 不使用。
- 發版流程：
  1. 開一個 PR 把版本改成要發的版本，例如 `1.2.0`。
  2. 合併後在該 commit 打 tag `v1.2.0`。
- 發版之後，**下一個合併到 `main` 的 PR 必須先升版**（例如 `1.2.1`）。原因是 App Store Connect 不接受已上架版本號的新建置，沒有升版的話，下一次發版會被拒收。
- CI 的版本號檢查負責把關：版本不大於最新 tag 時，PR 無法合併。

## 資料庫 migration 規則
- 舊版 APP 會在使用者手機上留存一段時間，所以 production migration 必須**向下相容**（先擴充、後收斂）：
  - 新增欄位要有預設值。
  - 刪除或改名欄位分兩次發版，等舊版 APP 不再使用後才移除。
- migration 只能往前，不寫 down migration；出錯時用新的 migration 修正。
- 每個 migration 都必須能在 CI 從零套用成功（`supabase start`）。

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

## 實作順序
1. **第一個實作 PR**：`ci.yml`、`ios.yml`、`android.yml` 與各自的彙總 job；跑過一次後到 ruleset 設定必要檢查。
2. **建立 Supabase 兩個專案與 GitHub Environments**：設定 secrets；`production` 設定必須核准。
3. **`cd-staging.yml`**：只需要 Supabase staging 與 staging 簽章金鑰，不需要商店設定。
4. **`release.yml`**：
   - 先手動在兩個商店建立 APP。
   - Play 需要先手動上傳第一個版本，之後才能用 API 上傳。
   - 準備商店文字與截圖後，第一次正式發版。

## 待準備事項（CI／CD 專屬）
- **Google Play Console**：
  - 建立 APP 並啟用 Play App Signing。
  - 建立服務帳號並授權發布。
  - 手動上傳第一個正式版建置，之後才能由 CD 以 API 上傳。
- **App Store Connect**：
  - 建立 APP 與 bundle id。
  - 建立 API key（App Manager 權限）。
  - 建立發布憑證與 provisioning profile。
- **Supabase**：
  - 建立 staging、production 兩個專案。
  - 產生 access token。
- **GitHub**：建立 `staging`、`production` 兩個 Environment，`production` 設定由你核准。
