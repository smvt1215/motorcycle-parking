# 管理站（React + Redux Toolkit）

Flutter 管理站（`lib/admin/`）的改寫版本，依 [`../DESIGN.md`](../DESIGN.md)（設計稿畫布 Version 48）實作。計畫見 #195 的 P7 與 [`docs/ADMIN_WEB.md`](../../docs/ADMIN_WEB.md)。

目前只有前端基礎層：設計 token、疊牌、地圖標記、基本元件、導覽外框與 `/design` 樣式頁。各功能頁先顯示「這一頁還沒接上資料」，等 `admin_v1` 完成後再接上。

## 指令

需要 Node 24。

```sh
npm ci
npm run dev           # 開發伺服器
npm test              # Vitest（含 tokens.css 與 DESIGN.md 的比對）
npm run lint          # ESLint
npm run format:check  # Prettier
npm run build         # tsc -b ＋ Vite，輸出 dist/
npm run smoke         # 先 build；Chromium 檢查 RWD 並存截圖到 artifacts/smoke/
```

`npm run smoke` 需要 Playwright 的 Chromium（`npx playwright install chromium-headless-shell`），只在本機跑，不在 CI 跑。它會在 320／390／402（iPhone 16 Pro）／700／820、1180（iPad Air）／1024（13 吋）／1440 寬度檢查：不能橫向捲動、分頁數（手機 4 個，其他 5 個）、導覽與按鈕的觸控目標至少 44px，並且每頁只有一個目前分頁。

## 目錄

| 路徑                    | 內容                                                                                                  |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| `src/design/tokens.css` | DESIGN.md frontmatter 的 token；名稱一一對應（`colors.x` → `--color-x`）。改 token 時先改 DESIGN.md   |
| `src/ui/`               | 疊牌 `PlateStack`／`EligibilityPair`、A0 `MapMarker`、按鈕、篩選 chip、分段控制、狀態標籤、空狀態     |
| `src/shell/`            | 導覽外框：≥1040px 96px 導覽欄、680–1039px 上方分頁、<680px 頂欄＋底部分頁（匯入、使用者收在「更多」） |
| `src/app/`              | Redux store（目前只有介面偏好；伺服器資料之後放 RTK Query）與路由                                     |
| `src/pages/`            | 各功能頁與 `/design` 樣式頁                                                                           |

## 規則

- 只用 DESIGN.md 的 token；車牌的綠、白、紅、黃只出現在車牌上，操作藍只給按得下去的東西，反光黃只表示「已修改」。
- 資格永遠成對顯示：普通機車在左、大型重機在右，`aria-label` 寫出完整狀態。
- 不放看起來像真的示範資料；還沒有資料來源的地方明白寫出來。
- 不要把 App 的 IconScout 重機圖示放進這裡。
