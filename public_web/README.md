# 公開網頁（public_web）

機車停車指南對外的網頁：刪除帳號說明與申請、客服表單、隱私權政策等。和管理站（`admin_web/react`）用同一套工具鏈（React 19、Redux Toolkit、React Router、Vite、Vitest），但是**另一個網站**：不打包管理站的程式碼，部署到自己的 Firebase Hosting 網站，網址是 `motoparking.smvtstudio.com`。

設計稿（已核准，版本 20）：https://claude.ai/artifact/5YXW7ZGBPs5qof2d1BEKAB

## 路徑

| 路徑                                  | 內容                                   | 狀態       |
| ------------------------------------- | -------------------------------------- | ---------- |
| `/account-deletion`                   | 刪除帳號說明（Google Play 連結的頁面） | 已完成     |
| `/`                                   | 轉到 `/account-deletion`               | 已完成     |
| 登入後的確認、冷靜期內登入            | 接 `api_v1` 的刪除帳號 API（#270）     | 下一個 PR  |
| `/support`、確認連結、取消連結        | 客服表單與一次性連結（#285／#289）     | 後端合併後 |
| `/privacy`、`/terms`、`/data-sources` | 政策頁                                 | 之後       |

## 文案

和 App 共用的字句（會刪除、會保留、防濫用雜湊）放在 `src/content.ts`。`src/content.test.ts` 會讀取 `lib/domain/account_deletion_display.dart`，比對兩邊的內容，App 改了這裡沒改，CI 就會失敗。

聯絡一律走 `/support` 的客服表單，網頁上不提供 `mailto:` 連結（#295：案件在管理站列管）。

## 開發

```sh
npm ci
npm run dev
npm test
npm run lint && npm run format:check && npm run build
```

版面斷點和管理站一樣：手機 680px 以下、平板 680–1039px、桌機 1040px 以上。
