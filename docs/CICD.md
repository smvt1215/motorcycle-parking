# CI／CD 規劃

> 狀態：規劃中（尚未建立 workflow）。最後更新：2026-10-11。整體計畫見 [PLAN.md](PLAN.md)。

## 決策摘要
- 平台：**GitHub Actions**（公開 repo 使用 GitHub 標準 runner 不收費，含 macOS）。
- 簽章與上架工具：**fastlane**（iOS 用 App Store Connect API key，Android 用 Google Play 服務帳號）。
- 後端環境：**Supabase staging + production** 兩個專案。
- 發版觸發：推送版本 tag `vX.Y.Z`；合併到 `main` 只發測試版。
- 已具備：Apple Developer Program、Google Play Console。

## 整體流程
```
PR ──► CI（檢查 + 測試）──► 全綠 ──► Squash merge 到 main
                                         │
                                         ▼
                         CD staging：Supabase staging 部署
                                   + TestFlight 內部測試 / Play 內部測試（連 staging 後端）
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
| `cd-staging.yml` | push 到 `main`（CI 通過後） | Linux + macOS | 部署 staging 後端、上傳兩平台內部測試版 |
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
1. **後端**：
   - `supabase link --project-ref $STAGING_REF`
   - `supabase db push` 套用新 migration
   - `supabase functions deploy` 部署 Edge Function
2. **建置號**：`git rev-list --count HEAD` × 10 + 0。
   - 單調遞增，同一 commit 的正式版用 +1，所以兩條流程不會撞號。
   - 遠低於 Android `versionCode` 上限 2,100,000,000。
3. **Android**：
   - 以 `--dart-define` 帶入 staging 的 Supabase URL／anon key。
   - `flutter build appbundle --release`。
   - fastlane `upload_to_play_store` 上傳到 **內部測試（internal）** 軌道。
4. **iOS**：
   - 同樣帶入 staging 設定，`flutter build ipa`。
   - fastlane `upload_to_testflight`，只開給**內部測試人員**，不送外部審查。
5. 同一個 commit 再次觸發時用 `concurrency` 取消舊的執行，避免重複上傳。

## CD：正式發版（推送 tag `vX.Y.Z`）
`release.yml`：
1. **前置檢查**（Linux）：
   - tag 指向的 commit 必須在 `main` 上。
   - `pubspec.yaml` 的 `version` 必須等於 tag 的版本號（例如 `1.2.0`）。
   - 該 commit 的 CI 必須全綠。
2. **人工核准**：
   - 綁定 GitHub Environment `production`，設定必須由你核准才會繼續。
   - 公開 repo 免費可用。
   - production 的金鑰只存在這個 Environment，staging 流程拿不到。
3. **後端先行**：
   - production `supabase db push` 與 `functions deploy`。
   - 先部署後端，再上架 APP。
4. **建置號**：`git rev-list --count HEAD` × 10 + 1。
5. **Android**：
   - 以 production 設定建置 AAB。
   - 上傳 **正式版（production）軌道**，**分階段推出 10%**。
   - 觀察後在 Play Console 調高比例，有問題可暫停。
6. **iOS**：
   - 以 production 設定建置 IPA，上傳 App Store Connect。
   - fastlane `deliver` 送審並啟用**分階段發布**（7 天）。
   - 商店文字與截圖放在 `fastlane/metadata`，一併版本控管。
7. **GitHub Release**：
   - 依兩個 tag 之間的 commit 產生更新說明。
   - 附上 AAB／IPA 的檔案雜湊值（不附檔案本身）。

## 簽章與金鑰
| 項目 | 存放 | 用途 |
|---|---|---|
| Android 上傳金鑰（upload keystore，base64）與密碼 | Environment secrets（`staging`、`production`） | 簽 AAB；Google Play App Signing 保管真正的發布金鑰 |
| Google Play 服務帳號 JSON | Environment secrets | fastlane 上傳 |
| App Store Connect API key（`.p8`、Key ID、Issuer ID） | Environment secrets | fastlane 上傳 TestFlight／送審 |
| iOS 發布憑證 `.p12`（base64）與密碼、provisioning profile | Environment secrets | 匯入 runner 的暫時 keychain，建置後刪除 |
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
- `pubspec.yaml` 的 `version` 名稱部分（例如 `1.2.0`）就是商店顯示的版本號；建置號由 CD 依上述公式產生，`pubspec.yaml` 的 `+N` 不使用。
- 發版流程：
  1. 開一個 PR 把版本改成要發的版本，例如 `1.2.0`。
  2. 合併後在該 commit 打 tag `v1.2.0`。
- 發版之後，**下一個合併到 `main` 的 PR 必須先升版**（例如 `1.2.1`）。原因是 App Store Connect 不接受已上架版本號的新建置，沒有升版的話，staging 上傳 TestFlight 會失敗。
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
3. **`cd-staging.yml`**：
   - 先手動在兩個商店建立 APP。
   - Play 需要先手動上傳第一個版本，之後才能用 API 上傳。
4. **`release.yml`**：準備商店文字與截圖後，第一次正式發版。

## 待準備事項（CI／CD 專屬）
- **Google Play Console**：
  - 建立 APP 並啟用 Play App Signing。
  - 建立服務帳號並授權發布。
  - 手動上傳第一個版本到內部測試。
- **App Store Connect**：
  - 建立 APP 與 bundle id。
  - 建立 API key（App Manager 權限）。
  - 建立發布憑證與 provisioning profile。
- **Supabase**：
  - 建立 staging、production 兩個專案。
  - 產生 access token。
- **GitHub**：建立 `staging`、`production` 兩個 Environment，`production` 設定由你核准。
