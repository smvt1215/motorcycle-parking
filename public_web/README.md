# 公開網頁（public_web）

機車停車指南對外的網頁：刪除帳號說明與申請、客服表單、隱私權政策等。和管理站（`admin_web/react`）用同一套工具鏈（React 19、Redux Toolkit、React Router、Vite、Vitest），但是**另一個網站**：不打包管理站的程式碼，部署到自己的 Firebase Hosting 網站，網址是 `motoparking.smvtstudio.com`。

設計稿（已核准，版本 20）：https://claude.ai/artifact/5YXW7ZGBPs5qof2d1BEKAB

## 路徑

| 路徑                          | 內容                                   | 狀態   |
| ----------------------------- | -------------------------------------- | ------ |
| `/account-deletion`           | 刪除帳號說明（Google Play 連結的頁面） | 已完成 |
| `/account-deletion`（登入後） | 確認、送出、冷靜期內登入的選擇（#270） | 已完成 |
| `/`                           | 轉到 `/account-deletion`               | 已完成 |
| `/support`                    | 客服表單（沒辦法登入時申請刪除）       | 已完成 |
| `/support/verify#token=…`     | 確認信的一次性連結（#285）             | 已完成 |
| `/support/cancel#token=…`     | 通知信的「取消刪除」連結（#289）       | 已完成 |
| `/privacy`                    | 隱私權政策                             | 已完成 |
| `/terms`、`/data-sources`     | 政策頁                                 | 之後   |

政策內容放在 `src/legal/*.md`，版本和日期放在 `src/legal/policies.ts`。改稿時換 Markdown，並更新這兩個值。

## 登入與 API

- 登入透過 `src/auth/port.ts` 的 `AuthPort` 介面，在頁面內完成，不整頁跳轉。結果分成：已登入、這個身分沒有帳號、再登入一次時選了別的帳號、嘗試太多次、連不上後端、沒有完成。為刪除而登入**不會建立帳號**（PM_ANS_20261105_186）：網頁先在瀏覽器取得 Google／Apple 的 ID token，送到 `deletion-precheck`（附 Firebase App Check token）確認這個身分有帳號，有帳號才用同一個 token 和 nonce 呼叫 `signInWithIdToken`（`src/auth/idTokenAuth.ts`）。
  - Google 只能透過 Google Identity Services 自己畫的按鈕取得 ID token，所以 Google 按鈕是 GIS 畫的；Apple 按鈕是我們的，點下去時直接開 Apple 的彈出視窗。
  - 傳給 Google／Apple 的 nonce 是原始 nonce 的 SHA-256（小寫十六進位），傳給後端和 Supabase Auth 的是原始 nonce。
  - Apple 帳號送出刪除申請前，用這次 Apple 登入拿到的授權碼呼叫 `apple-revoke` 撤銷授權（只在送出前，登入時不撤銷）。授權碼只放在記憶體，超過約 4.5 分鐘或用過就請騎士再用 Apple 登入一次。撤銷失敗仍會送出申請，之後顯示和 App 一樣的提醒。
  - 再登入一次時，新的 ID token 必須是目前帳號的同一個身分（`sub`），否則不呼叫後端，登入也不會切換。
  - 建置時缺少下表任何一個登入設定，網站就沒有登入功能，只顯示說明和客服表單。
- 刪除帳號 API 用 RTK Query 呼叫 `api_v1`。`src/api/api_v1.generated.ts` 由 `npm run codegen` 從 `supabase/api/v1/api_v1.json` 產生，只產生這個網頁用到的函式（`scripts/codegen.mjs`）；文件改了沒重新產生，CI 會失敗。
- 超過 10 分鐘要再登入一次：同一個帳號登入後就直接送出申請；如果選了別的帳號，什麼都不送，目前的登入也不會切換。

建置時需要的環境變數（都不是秘密，但 Firebase 的 apiKey 不進版控，由 CD 提供）：

| 變數                            | 內容                                                   | staging 的值                                                               |
| ------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------- |
| `VITE_SUPABASE_URL`             | Supabase 專案網址（RC 之前是 staging，#304）           | CD 提供                                                                    |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | 專案的 publishable key（本來就是公開的）               | CD 提供                                                                    |
| `VITE_GOOGLE_CLIENT_ID`         | Google 網頁 OAuth client（Supabase Google 登入接受的） | `815509193159-ov6pl4uler43hqnpgd31ict71mpmmqe4.apps.googleusercontent.com` |
| `VITE_APPLE_SERVICES_ID`        | Apple Services ID（網頁的「使用 Apple 登入」）         | `tw.motopark.motorcycleParking.web`                                        |
| `VITE_FIREBASE_API_KEY`         | Firebase 網頁 app 的 apiKey（App Check）               | CD 提供，不進版控                                                          |
| `VITE_FIREBASE_APP_ID`          | Firebase 網頁 app id（和客服表單同一個）               | `1:815509193159:web:e7b64394adb054b03a99e2`                                |
| `VITE_FIREBASE_PROJECT_ID`      | Firebase 專案                                          | `motocycle-parking-guide`                                                  |
| `VITE_RECAPTCHA_SITE_KEY`       | App Check 用的 reCAPTCHA Enterprise site key           | `6Ld2dxEuAAAAAIhpRpFRazrsrQ2vljzC6jtGfGUn`                                 |

Apple 的 Return URL 是 `${網站來源}/account-deletion`，正式站必須是 `https://motoparking.smvtstudio.com/account-deletion`（和 Apple Services ID、`apple-revoke` 的 `APPLE_WEB_REDIRECT_URI` 一致）。`npm run dev` 時 App Check 用 debug token（`FIREBASE_APPCHECK_DEBUG_TOKEN`），不把 localhost 加到任何允許清單。

版面檢查用的 smoke 建置（`--mode smoke`）改用 `src/smoke/smokeAuth.ts` 的假登入。正式建置不會包含它，CI 會檢查。

## 客服表單與一次性連結

- `/support` 呼叫 Edge Function `support-request`，附 Firebase App Check token（`x-firebase-appcheck`，和刪除帳號頁同一個 Firebase 網頁 app，所以 staging 的 `SUPPORT_APP_CHECK_APP_IDS` 要列這個 app id）。不需要登入。建置缺少 Supabase 或任何一個 App Check 設定時，不提供表單，只顯示「客服表單暫時無法使用」。不論有沒有對應的帳號，送出成功的畫面都一樣。
- `/support/verify` 與 `/support/cancel` 從網址的 fragment（`#token=<申請 id>.<秘密>`）讀出 token，讀到後立刻以 replace 導航把 fragment 從網址列拿掉（不留在瀏覽紀錄，也不會出現在 referrer）。打開頁面只送 `view`（不改變任何東西，信件掃描自動開啟也沒關係），要按下「是我，申請刪除帳號」「不是我申請的」「取消刪除」才會送出對應的動作，都 POST 到 `support-confirm`。這兩頁不需要 App Check。
- 後端寄出的連結由 `SUPPORT_CONFIRM_URL`、`SUPPORT_CANCEL_URL` 決定，要設成 `${網站來源}/support/verify` 與 `${網站來源}/support/cancel`。
- smoke 建置的表單用固定的 App Check token，Edge Function 的回應由 `scripts/smoke.mjs` 的 `page.route` 提供。

## 文案

和 App 共用的字句：說明頁（會刪除、會保留、防濫用雜湊）放在 `src/content.ts`，登入後的流程放在 `src/deletion/text.ts`，客服表單與一次性連結放在 `src/support/text.ts`（`src/support/text.test.ts` 會讀取 `supabase/functions/support-request/resend.ts`，比對申請編號、寄件人、按鈕名稱與連結效期）。`src/content.test.ts` 和 `src/deletion/text.test.ts` 會讀取 `lib/domain/account_deletion_display.dart`，比對兩邊的內容，App 改了這裡沒改，CI 就會失敗。網頁和 App 說法不同的地方，在常數的註解寫明原因。

聯絡一律走 `/support` 的客服表單，網頁上不提供 `mailto:` 連結（#295：案件在管理站列管）。

## 開發

```sh
npm ci
npm run dev
npm test
npm run lint && npm run format:check && npm run build
# 版面檢查：每個畫面在 320／390／700／1024／1440／1920 寬各開一次，
# 不可以橫向捲動，截圖存在 artifacts/smoke/
npm run build:smoke && npm run smoke
```

版面斷點和管理站一樣：手機 680px 以下、平板 680–1039px、桌機 1040px 以上。
