# 公開網頁（public_web）

機車停車指南對外的網頁：刪除帳號說明與申請、客服表單、隱私權政策等。和管理站（`admin_web/react`）用同一套工具鏈（React 19、Redux Toolkit、React Router、Vite、Vitest），但是**另一個網站**：不打包管理站的程式碼，部署到自己的 Firebase Hosting 網站，網址是 `motoparking.smvtstudio.com`。

設計稿（已核准，版本 20）：https://claude.ai/artifact/5YXW7ZGBPs5qof2d1BEKAB

## 路徑

| 路徑                                  | 內容                                   | 狀態       |
| ------------------------------------- | -------------------------------------- | ---------- |
| `/account-deletion`                   | 刪除帳號說明（Google Play 連結的頁面） | 已完成     |
| `/account-deletion`（登入後）         | 確認、送出、冷靜期內登入的選擇（#270） | 已完成     |
| `/`                                   | 轉到 `/account-deletion`               | 已完成     |
| `/support`、確認連結、取消連結        | 客服表單與一次性連結（#285／#289）     | 後端合併後 |
| `/privacy`、`/terms`、`/data-sources` | 政策頁                                 | 之後       |

## 登入與 API

- 登入透過 `src/auth/port.ts` 的 `AuthPort` 介面，在頁面內完成，不整頁跳轉。結果分成四種：已登入、這個身分沒有帳號、再登入一次時選了別的帳號、沒有完成。為刪除而登入**不會建立帳號**（PM_ANS_20261105_186）：網頁先取得 Google／Apple 的 ID token，後端確認這個身分有帳號之後才登入。這部分等後端 API 定案後再接（T_DEL_WEB_Q1）。在那之前，建置出來的網站沒有登入功能，只顯示說明和客服表單。
- 刪除帳號 API 用 RTK Query 呼叫 `api_v1`。`src/api/api_v1.generated.ts` 由 `npm run codegen` 從 `supabase/api/v1/api_v1.json` 產生，只產生這個網頁用到的函式（`scripts/codegen.mjs`）；文件改了沒重新產生，CI 會失敗。
- 超過 10 分鐘要再登入一次：同一個帳號登入後就直接送出申請；如果選了別的帳號，什麼都不送，目前的登入也不會切換。

建置時需要的環境變數：

| 變數                            | 內容                                         |
| ------------------------------- | -------------------------------------------- |
| `VITE_SUPABASE_URL`             | Supabase 專案網址（RC 之前是 staging，#304） |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | 專案的 publishable key（本來就是公開的）     |

版面檢查用的 smoke 建置（`--mode smoke`）改用 `src/smoke/smokeAuth.ts` 的假登入。正式建置不會包含它，CI 會檢查。

## 文案

和 App 共用的字句：說明頁（會刪除、會保留、防濫用雜湊）放在 `src/content.ts`，登入後的流程放在 `src/deletion/text.ts`。`src/content.test.ts` 和 `src/deletion/text.test.ts` 會讀取 `lib/domain/account_deletion_display.dart`，比對兩邊的內容，App 改了這裡沒改，CI 就會失敗。網頁和 App 說法不同的地方，在常數的註解寫明原因。

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
