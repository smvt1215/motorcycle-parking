# CD 設定與操作

程式入口為 `.github/workflows/cd-staging.yml` 與 `.github/workflows/release.yml`；流程與設計取捨見 [CICD.md](CICD.md)。外部設定完成前不要推送正式版本 tag。

目前進度（2026-10-25）：`staging` 的設定已全部完成，CD staging 實際部署後端與管理站，並發佈 Android／iOS 測試版；`production` 只設定了核准者，下方 production 與商店的項目尚未完成。

## GitHub Environments

建立 `staging` 與 `production`。

- `staging` 的 Deployment branches and tags 僅允許 `main` branch。
- `production` 僅允許 `v*` tags，Required reviewers 設為專案擁有者；發版閘門會查核 reviewer 確實存在，沒有保護就阻止發版。
- 每個讀取正式憑證的 job 都綁定 `production`，GitHub 要求核准時先核對 tag、SHA 與 workflow。Environment 設定不是 YAML 能建立的核准規則。
- 不將正式憑證放在 Repository secrets；同一個 secret 名稱在兩個 Environment 使用不同的值。

## 兩個 Environment 共用的設定名稱

| 類型 | 名稱 | 內容 |
|---|---|---|
| Secret | `SUPABASE_ACCESS_TOKEN` | 可管理該環境專案的 Supabase CLI token |
| Secret | `SUPABASE_PROJECT_REF` | 該環境的 20 字元專案識別碼 |
| Secret | `SUPABASE_DB_PASSWORD` | 該環境資料庫密碼 |
| Variable | `SUPABASE_URL` | 與 project ref 對應的 `https://專案識別碼.supabase.co` |
| Variable | `SUPABASE_ANON_KEY` | APP 使用的公開 anon／publishable key，不使用 service role key |
| Secret | `GOOGLE_MAPS_ANDROID_API_KEY` | 限制 Android applicationId 與簽章憑證指紋的金鑰 |
| Secret | `GOOGLE_MAPS_IOS_API_KEY` | 限制 iOS bundle ID 的金鑰 |
| Secret | `ANDROID_KEYSTORE_BASE64` | 該環境專用的 keystore，base64 單行編碼 |
| Secret | `ANDROID_KEY_ALIAS` | keystore 的 key alias |
| Secret | `ANDROID_KEY_PASSWORD` | key 密碼 |
| Secret | `ANDROID_STORE_PASSWORD` | keystore 密碼 |
| Secret | `IOS_CERTIFICATE_BASE64` | 該環境 Apple Distribution `.p12`，base64 單行編碼 |
| Secret | `IOS_CERTIFICATE_PASSWORD` | `.p12` 匯出密碼 |
| Secret | `IOS_PROFILE_BASE64` | 該環境 provisioning profile，base64 單行編碼 |

設定檢查會阻止空白地圖金鑰、後端 URL 與 project ref 不一致、profile 過期或類型／bundle ID 錯誤。Android 密碼直接由環境變數交給 Gradle，保留反斜線等特殊字元；不寫入 properties。

APP 識別碼：

| 項目 | production | staging |
|---|---|---|
| Android applicationId | `tw.motopark.motorcycle_parking` | `tw.motopark.motorcycle_parking.staging` |
| iOS bundle ID | `tw.motopark.motorcycleParking` | `tw.motopark.motorcycleParking.staging` |
| OAuth callback | `tw.motopark.motorcycleparking://login-callback` | `tw.motopark.motorcycleparking.staging://login-callback` |
| 手機 APP 名稱 | 機車停車指南 | 機車停車指南 α |

在各自 Supabase Auth 的 Redirect URLs 加入對應的 callback。兩個 APP 的 callback 分開，避免同時安裝時登入回到另一環境。production 的 Google Maps Android 限制使用 **Google Play App Signing 發布憑證**指紋；直接測試已簽署的 AAB／APK 時另加入 upload key 指紋。staging 使用 staging keystore 指紋。

後端部署只套用 migrations 與 functions，**不推送 local seed**；TDX／Turnstile 等後端秘密仍只設定在各自 Supabase 專案。首次部署後確認 migration、RLS、Auth provider 與函式秘密齊備。

### 即時車位擷取（`availability-ingest`）

migration `202610270140_availability_p2.sql` 建立 pg_cron 工作 `availability-ingest`，`202610310500_availability_next_update.sql` 改為每分鐘檢查一次：只在來源到了預計出資料時間（`availability_sources.next_expected_at`＝`UPDATETIME`＋更新周期＋學到的公開延遲 `publish_delay`）才經 pg_net 呼叫 Edge Function，未到時間不對外發請求。三個值都只設定在各自 Supabase 專案，**不進版控**；缺任何一個時排程不呼叫（或函式回 503），App 只顯示靜態容量。

1. 產生一組隨機字串作為共用密鑰（例如 `openssl rand -hex 32`，不要貼到聊天或 issue）。
2. Edge Function secret：`supabase secrets set AVAILABILITY_INGEST_SECRET=<密鑰> --project-ref <ref>`。
3. Vault（SQL Editor）：`select vault.create_secret('https://<ref>.supabase.co','project_url');`、`select vault.create_secret('<密鑰>','availability_ingest_secret');`。
4. 確認：`select outcome,source_updated_at,rows,message from availability_ingest_runs order by ran_at desc limit 5;` 應約每 5 分鐘一筆 `ok`；抓到同一批時記 `unchanged` 並在 1 分鐘後重試，連續 4 次重試仍沒有新批次才算一次失敗。連續失敗時 `availability_sources.next_attempt_at` 會退避（最長 1 小時）。`availability_sources.publish_delay` 是最近 12 批（`availability_ingest_runs.publish_delay`）的中位數。

停用來源：`update availability_sources set enabled=false where key='taipei_tcmsv';`。錯誤的場站對應改 `availability_mappings.review_status='rejected'`，之後不會再自動建立。

### pg_cron 執行紀錄清理（`cron-history-prune`）

migration `202610310600_cron_history_prune.sql` 建立每日排程 `cron-history-prune`（`23 20 * * *` UTC＝台灣 04:23），呼叫 `public.cron_history_prune()` 刪除 `cron.job_run_details` 中 `end_time` 早於 7 天前的紀錄（尚未結束、`end_time` 為空的不刪）。不需另外設定；確認：`select jobname,schedule from cron.job where jobname='cron-history-prune';`。

## staging：Firebase 與 iOS 測試裝置

staging profile 必須是 Ad Hoc，包含受邀 iPhone 的 UDID；production profile 必須是 App Store，不能包含 `ProvisionedDevices`。

簽章 Team ID 與 profile 的 App ID Prefix 分別使用原始欄位，不假設相同，以支援既有 Apple 帳號；參考 [Apple QA1879](https://developer.apple.com/library/archive/qa/qa1879/_index.html)。archive 與 export 使用同一份 profile，保留一致的 App ID Prefix。

| Variable | 內容 |
|---|---|
| `FIREBASE_IOS_APP_ID` | Firebase 中 staging iOS APP 的 App ID |
| `FIREBASE_ANDROID_APP_ID` | Firebase 中 staging Android APP 的 App ID（套件名稱 `tw.motopark.motorcycle_parking.staging`） |
| `FIREBASE_WORKLOAD_IDENTITY_PROVIDER` | Google Cloud Workload Identity Provider 的完整 resource name |
| `FIREBASE_SERVICE_ACCOUNT` | 有 Firebase App Distribution Admin 角色的服務帳號 email |
| `FIREBASE_ANDROID_API_KEY`、`FIREBASE_IOS_API_KEY` | App Check 用的 Firebase API key，只開 App Check 與 Installations API；可選 `FIREBASE_PROJECT_ID`（staging 預設 `motocycle-parking-guide`）。見 [CICD.md〈App Check〉](CICD.md#app-check203) |

建立 Firebase iOS APP 時 bundle ID 必須是 `tw.motopark.motorcycleParking.staging`。建立測試群組 `staging-ios` 與 `staging-android`，邀請測試者；也可在 App Distribution 建立邀請連結讓測試者自行加入（iOS 測試者仍需註冊 UDID 並更新 Ad Hoc profile）。

Google Cloud 的 OIDC provider 信任 GitHub，attribute condition 限定 subject 為 staging Environment。本 repo 啟用 GitHub 不可變 subject，條件須寫 `repo:smvt1215@25175632/motorcycle-parking@1413881483:environment:staging`；寫成 `repo:smvt1215/motorcycle-parking:environment:staging` 會被拒絕（rejected by the attribute condition）。該 principal 授權為目標服務帳號的 Workload Identity User。服務帳號只給 Firebase App Distribution Admin，啟用必要 API。認證 action 產生 external-account ADC 設定，Firebase CLI 使用該檔換取短期 token；不需服務帳號長期私鑰。依 [Firebase 官方 CI 說明](https://firebase.google.com/docs/app-distribution/best-practices-distributing-android-apps-to-qa-testers-with-ci-cd)，Workload Identity Federation 可使用 credential configuration file。

每次 main 的 CI、Android、iOS 都成功後，staging 後端才開始部署。進入佇列前與取得固定部署鎖後，都查核最新 SHA、CI 及該 SHA 的既有部署紀錄；已實際成功部署過就略過重複事件，避免重複建置與 Firebase 通知。失敗的部署沒有成功紀錄，可以重試。較舊 SHA 的 job 即使流程成功結束，也沒有 `Record staging deployment` 步驟成功紀錄，因此不會誤認為已部署。後端成功後，手機建置失敗時重跑失敗的手機 job，不用重新部署後端。

手機測試版是選用的：某平台的簽章與地圖設定一項都沒填時（Android：Maps 金鑰、keystore 四項與 `FIREBASE_ANDROID_APP_ID`；iOS：Maps 金鑰、憑證、profile 與 `FIREBASE_IOS_APP_ID`），後端部署後該平台的 job 會略過並留下 notice；只要填了其中一項就照常建置，缺的項目由設定檢查報錯，避免設定一半被當成略過。

Android 的安裝檔送到 Firebase 的 `staging-android` 群組，也保留在該 CD workflow 的 `staging-android-SHA` artifact 30 天。iOS IPA 只送 Firebase，不放 GitHub artifact 或快取。若 iOS job 完成時 main 已前進，就略過 Firebase 發佈，避免舊版成為最新通知。

測試者第一次以 iPhone Safari 接受 Firebase 邀請並註冊裝置。擁有者在 Apple Developer 加入 UDID，重新產生 Ad Hoc profile，更新 `IOS_PROFILE_BASE64`，再重跑最新 SHA 的 staging iOS job。安裝時依 iPhone 系統提示處理描述檔與開發者模式；這部分須以實機驗證。之後從 Firebase App Tester 安裝新版本。

## production：商店準備

| 類型 | 名稱 | 內容 |
|---|---|---|
| Secret | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | 已在 Play Console 授權發布的服務帳號完整 JSON |
| Secret | `APP_STORE_KEY_ID` | App Store Connect API key ID |
| Secret | `APP_STORE_ISSUER_ID` | API key issuer ID |
| Secret | `APP_STORE_KEY_BASE64` | `.p8` 私鑰的 base64 單行編碼 |
| Variable | `APP_STORE_APP_ID` | 本 APP 在 App Store Connect 的數字 Apple ID |
| Variable | `TESTFLIGHT_GROUP` | TestFlight 外部測試群組名稱（beta／RC 發給此群組） |
| Variable | `STAGING_SUPABASE_PROJECT_REF` | staging 的 project ref（beta 建置連 staging；未設定時 beta 建置失敗，不會改連 production） |
| Variable | `STAGING_SUPABASE_URL` | staging 的 `https://專案識別碼.supabase.co` |
| Variable | `STAGING_SUPABASE_ANON_KEY` | staging 的公開 anon／publishable key |
| Variable | `APP_STORE_COPYRIGHT` | 正式商店使用的 copyright 文字 |
| Variable | `APP_STORE_SUPPORT_URL` | 已公開且可用的支援頁網址 |
| Variable | `APP_STORE_PRIVACY_URL` | 已公開且可用的隱私權政策網址 |
| Secret | `APP_STORE_SUBMISSION_INFORMATION` | fastlane deliver 所需的 submission information JSON；依 APP 的出口合規／廣告等實際聲明設定，不能直接套用其他 APP 的答案 |

先在兩個商店建立 APP。Google Play 啟用 App Signing、完成權限與商店資訊，並依商店要求手動上傳第一個建置。App Store Connect 完成 App Privacy、分級、審查聯絡與登入測試資料、出口合規，以及首次版本的必要截圖。API key 使用有上傳及送審權限的角色。

**staging 登入回呼（beta）**：beta 是正式 bundle id／applicationId 的 App，但連 staging 後端，所以 staging Supabase 專案的 Auth「Redirect URLs」要加入正式版回呼 `tw.motopark.motorcycleparking://login-callback`，beta 測試者才能登入。

**TestFlight（beta／RC）**：在 App Store Connect 的 TestFlight 建立外部測試群組（名稱填入 `TESTFLIGHT_GROUP`），開啟公開連結並設定人數上限；填好「測試資訊」（Beta App 說明、意見回饋 email、Beta App Review 聯絡資訊與登入測試資料）。每個版本的第一個外部建置會送 Beta App Review，通過後同版本的後續建置通常不必再審。`Info.plist` 已宣告 `ITSAppUsesNonExemptEncryption = false`（只使用系統 HTTPS），建置不會停在出口合規。

**Google Play 測試軌道（beta／RC）**：在 Play Console 啟用封閉測試（預設軌道，API 名稱 `alpha`）與開放測試（API 名稱 `beta`），設定測試者名單或開放人數，並完成各軌道要求的商店資訊。beta 上傳到封閉測試、RC 上傳到開放測試，狀態為 `completed`；正式版把 RC 的版本碼推進 production 10%。

繁體中文文字在 `fastlane/metadata/ios/zh-Hant/`，發版前一起審核與更新。若要由 repo 更新截圖，放在該語系的 `screenshots/` 子資料夾；資料夾沒有截圖時保留 App Store Connect 已設定的截圖。Android workflow 保留 Play Console 的商店文字與截圖，僅發布建置。

## beta／RC／正式發版與重跑

1. 在 PR 將 `pubspec.yaml` 升到要發的版本，完成 CI 並合併。
2. 等同一 SHA 的 staging 後端實際成功（alpha 已發給內部成員），完成內部測試。
3. **beta／RC**：在 main 最新 commit 推送 `vX.Y.Z-beta.N` 或 `vX.Y.Z-rc.N`（RC 會把 migration 套用到正式資料庫且無法撤回，打 RC 前確認 migration 向下相容），版本必須與 pubspec 名稱部分相同。workflow 檢查版本、完整 Git 歷史、三個 CI 彙總 job、staging 的實際部署步驟及 production 核准設定，staging／CI 還在跑時最多等待 60 分鐘。從打 tag 到 workflow 成功結束暫停合併其他 PR。
4. 核准 production 部署，核准後再次檢查最新 main。**RC** 先部署 production 後端；**beta** 不部署，以 staging 設定建置。之後上傳 TestFlight（外部公開群組）與 Play 測試軌道，最後公開 GitHub prerelease。
5. **正式版**：最後一個 RC 驗證完成後，在**該 RC 的 commit** 推送 `vX.Y.Z`。不重新建置也不重新部署後端；核准後 iOS 將 RC 建置送審並啟用七天 phased release，Android 將同一版本碼以 10% production rollout 推出，兩平台成功後公開 GitHub Release。

建置號為 `commit 數 × 10 + run_attempt`，attempt 只能為 1–9，完整整數不能超過 9999。超出限制要先修改號碼規則與查詢範圍，不讓 CD 默默重用號碼。

Android 查詢所有軌道（含自訂軌道），同一 commit 的 9 個號碼已在 production 且狀態是 `inProgress`／`completed` 時略過上傳；人工暫停的 `halted` 也保留原暫停。production 的 `draft` 不算已發佈，會將既有建置推進 10% rollout；其他軌道的既有版本亦推進 production；正式版找不到 RC 的既有版本就失敗，不建置。beta 與 RC 的建置號範圍分開（beta 個位數 1～4、RC 5～9），同一通道重跑時若該範圍已有版本就推進到目標軌道，沒有才建置與上傳；RC 不會沿用連 staging 的 beta 建置。iOS 只查本 APP、本版本與同一 commit 的範圍，等待 PROCESSING 最多 60 分鐘，只重用 VALID；FAILED／INVALID 改用重跑的新號碼。beta／RC 已在外部群組（等待 Beta 審查或之後的狀態）就不再重送；正式版找不到 VALID 的 RC 建置就失敗。上傳成功但送審失敗時，重跑仍會補送審；已等待審查或後續狀態則保留原送審建置。

上傳前先把原始 AAB／IPA 的 SHA-256 存成 draft Release 的文字資產，因此上傳成功後 runner 中斷仍能恢復原雜湊。重跑會把實際商店建置的紀錄加入 Release 說明，不以重新簽署的不同檔案冒充。若手動上傳的建置恰好在本 commit 範圍內，需先將其原始雜湊紀錄補入 draft Release（檔名 `sha256-android-建置號.txt` 或 `sha256-ios-建置號.txt`；內容格式為 SHA-256、兩個空格、`android-建置號.aab` 或 `ios-建置號.ipa`）。

部分失敗時先修正對應的設定或程式，再重跑 **整個 Release workflow**，讓核准後的 main／staging 查核再次執行。若 main 已前進，重新完成 staging 並在新 commit 發版；不繞過 SHA 檢查。

## 本機與 CI 驗證

```bash
python3 -m unittest discover -s tool -p 'test_*.py'
ruby -c fastlane/Fastfile
ruby fastlane/test_release_policy.rb
bundle exec fastlane lanes
actionlint
```

CI 的 `automation` job 執行 Python 閘門／設定測試與 Ruby 發版政策測試，納入既有 `CI 全部通過` 彙總。Android 原有建置與整合測試改用 production flavor；iOS 原有 Runner scheme 保留，另增加 staging scheme 與三種 configuration。正式憑證、Google OIDC、Ad Hoc 實機安裝與商店 API 的端到端驗證，必須在對應外部設定完成後執行。
