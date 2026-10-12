# CD 設定與操作

程式入口為 `.github/workflows/cd-staging.yml` 與 `.github/workflows/release.yml`；流程與設計取捨見 [CICD.md](CICD.md)。外部設定完成前不要推送正式版本 tag。

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
| 手機 APP 名稱 | 機車停車指南 | 機車停車指南 β |

在各自 Supabase Auth 的 Redirect URLs 加入對應的 callback。兩個 APP 的 callback 分開，避免同時安裝時登入回到另一環境。production 的 Google Maps Android 限制使用 **Google Play App Signing 發布憑證**指紋；直接測試已簽署的 AAB／APK 時另加入 upload key 指紋。staging 使用 staging keystore 指紋。

後端部署只套用 migrations 與 functions，**不推送 local seed**；TDX／Turnstile 等後端秘密仍只設定在各自 Supabase 專案。首次部署後確認 migration、RLS、Auth provider 與函式秘密齊備。

## staging：Firebase 與 iOS 測試裝置

staging profile 必須是 Ad Hoc，包含受邀 iPhone 的 UDID；production profile 必須是 App Store，不能包含 `ProvisionedDevices`。

簽章 Team ID 與 profile 的 App ID Prefix 分別使用原始欄位，不假設相同，以支援既有 Apple 帳號；參考 [Apple QA1879](https://developer.apple.com/library/archive/qa/qa1879/_index.html)。archive 與 export 使用同一份 profile，保留一致的 App ID Prefix。

| Variable | 內容 |
|---|---|
| `FIREBASE_IOS_APP_ID` | Firebase 中 staging iOS APP 的 App ID |
| `FIREBASE_WORKLOAD_IDENTITY_PROVIDER` | Google Cloud Workload Identity Provider 的完整 resource name |
| `FIREBASE_SERVICE_ACCOUNT` | 有 Firebase App Distribution Admin 角色的服務帳號 email |

建立 Firebase iOS APP 時 bundle ID 必須是 `tw.motopark.motorcycleParking.staging`。建立測試群組 `staging-ios`，邀請測試者。

Google Cloud 的 OIDC provider 信任 GitHub，attribute condition 限定 subject 為 `repo:smvt1215/motorcycle-parking:environment:staging`，並將該 principal 授權為目標服務帳號的 Workload Identity User。服務帳號只給 Firebase App Distribution Admin，啟用必要 API。認證 action 產生 external-account ADC 設定，Firebase CLI 使用該檔換取短期 token；不需服務帳號長期私鑰。依 [Firebase 官方 CI 說明](https://firebase.google.com/docs/app-distribution/best-practices-distributing-android-apps-to-qa-testers-with-ci-cd)，Workload Identity Federation 可使用 credential configuration file。

每次 main 的 CI、Android、iOS 都成功後，staging 後端才開始部署。進入佇列前與取得固定部署鎖後，都查核最新 SHA、CI 及該 SHA 的既有部署紀錄；已實際成功部署過就略過重複事件，避免重複建置與 Firebase 通知。失敗的部署沒有成功紀錄，可以重試。較舊 SHA 的 job 即使流程成功結束，也沒有 `Record staging deployment` 步驟成功紀錄，因此不會誤認為已部署。後端成功後，手機建置失敗時重跑失敗的手機 job，不用重新部署後端。

Android 的安裝檔在該 CD workflow 的 `staging-android-SHA` artifact，保留 30 天。iOS IPA 只送 Firebase，不放 GitHub artifact 或快取。若 iOS job 完成時 main 已前進，就略過 Firebase 發佈，避免舊版成為最新通知。

測試者第一次以 iPhone Safari 接受 Firebase 邀請並註冊裝置。擁有者在 Apple Developer 加入 UDID，重新產生 Ad Hoc profile，更新 `IOS_PROFILE_BASE64`，再重跑最新 SHA 的 staging iOS job。安裝時依 iPhone 系統提示處理描述檔與開發者模式；這部分須以實機驗證。之後從 Firebase App Tester 安裝新版本。

## production：商店準備

| 類型 | 名稱 | 內容 |
|---|---|---|
| Secret | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | 已在 Play Console 授權發布的服務帳號完整 JSON |
| Secret | `APP_STORE_KEY_ID` | App Store Connect API key ID |
| Secret | `APP_STORE_ISSUER_ID` | API key issuer ID |
| Secret | `APP_STORE_KEY_BASE64` | `.p8` 私鑰的 base64 單行編碼 |
| Variable | `APP_STORE_APP_ID` | 本 APP 在 App Store Connect 的數字 Apple ID |
| Variable | `APP_STORE_COPYRIGHT` | 正式商店使用的 copyright 文字 |
| Variable | `APP_STORE_SUPPORT_URL` | 已公開且可用的支援頁網址 |
| Variable | `APP_STORE_PRIVACY_URL` | 已公開且可用的隱私權政策網址 |
| Secret | `APP_STORE_SUBMISSION_INFORMATION` | fastlane deliver 所需的 submission information JSON；依 APP 的出口合規／廣告等實際聲明設定，不能直接套用其他 APP 的答案 |

先在兩個商店建立 APP。Google Play 啟用 App Signing、完成權限與商店資訊，並依商店要求手動上傳第一個建置。App Store Connect 完成 App Privacy、分級、審查聯絡與登入測試資料、出口合規，以及首次版本的必要截圖。API key 使用有上傳及送審權限的角色。

繁體中文文字在 `fastlane/metadata/ios/zh-Hant/`，發版前一起審核與更新。若要由 repo 更新截圖，放在該語系的 `screenshots/` 子資料夾；資料夾沒有截圖時保留 App Store Connect 已設定的截圖。Android workflow 保留 Play Console 的商店文字與截圖，僅發布建置。

## 正式發版與重跑

1. 在 PR 將 `pubspec.yaml` 升到正式版本，完成 CI 並合併。
2. 等同一 SHA 的 staging 後端實際成功，並完成測試。發版期間暫停合併其他 PR。
3. 在 main 最新 commit 推送 `vX.Y.Z` tag，版本必須與 pubspec 名稱部分相同。
4. workflow 檢查版本、完整 Git 歷史、三個 CI 彙總 job、staging 的實際部署步驟及 production 核准設定。staging／CI 還在跑時最多等待 60 分鐘。
5. 核准 production 部署，核准後再次檢查最新 main。後端先部署，再執行 Android 與 iOS 商店工作。
6. Android 以 10% production rollout 發布；iOS 上傳後獨立送審並啟用七天 phased release。兩平台成功後公開 GitHub Release。

建置號為 `commit 數 × 10 + run_attempt`，attempt 只能為 1–9，完整整數不能超過 9999。超出限制要先修改號碼規則與查詢範圍，不讓 CD 默默重用號碼。

Android 查詢所有軌道（含自訂軌道），同一 commit 的 9 個號碼已在 production 時略過上傳；在其他軌道時推進既有版本，沒有既有版本才建置與上傳。iOS 只查本 APP、本版本與同一 commit 的範圍，等待 PROCESSING 最多 60 分鐘，只重用 VALID；FAILED／INVALID 改用重跑的新號碼。上傳成功但送審失敗時，重跑仍會補送審；已等待審查或後續狀態則保留原送審建置。

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
