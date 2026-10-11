# CLAUDE.md

## 專案
台灣機車停車指南 APP（普通機車 + 大型重機），實作計畫見 [docs/PLAN.md](docs/PLAN.md)。

## Git 與 PR 規則
- `main` 受 ruleset 保護：必須經 PR 合併、禁止 force push、需簽章 commit、線性歷史。合併一律用 **Squash and merge**。
- **PR 流程：自我審查 → Ready for review → 處理審查意見直到全綠**：
  1. PR 一律先以 draft 建立。
  2. 自我審查：逐行重讀 diff、執行專案的本地檢查（format / lint / test，有的話），確認 PR 說明與實際變更一致。
  3. 自我審查通過後，**不需詢問**，直接將 PR 轉為 Ready for review（會觸發 Codex 等自動審查）。
  4. 持續追蹤 PR，處理每一則審查意見：
     - 意見成立 → 修正並 push，在該 thread 回覆修正的 commit，然後 resolve。
     - 意見不成立 → 在 thread 回覆理由（附推論路徑），然後 resolve。
     - 涉及設計取捨或超出 PR 範圍 → 先詢問使用者再決定。
  5. 「全綠」＝ CI 全部通過、無合併衝突、所有審查 thread 已 resolve、最新一輪自動審查沒有未處理的意見。
  6. 達到全綠後通知使用者可以合併；**合併由使用者執行**（Squash and merge），不自行合併。
- **PR 合併後必須清理本機 worktree 與分支**：
  1. 先確認 PR 狀態為 merged（不是 closed），並記下 PR 最後的 head commit SHA。
  2. `git fetch --prune origin`
  3. 確認本機分支沒有未發佈的 commit：`git log --oneline <PR head SHA>..<branch>` 必須為空。不為空代表有 commit 沒進 PR，**停下來詢問**，不要刪除。
  4. 若該分支有獨立 worktree：先 `cd` 到主 worktree（`git worktree list` 第一列），再於主 worktree 執行 `git worktree remove <path>`（不可在要刪除的 worktree 內執行；有未提交變更時先停下來詢問，不要加 `--force`）。
  5. 在主 worktree 切回 `main` 並同步：`git checkout main && git merge --ff-only origin/main`
  6. 刪除本機分支：`git branch -D <branch>`（Squash merge 後 `-d` 會判定未合併而失敗；第 1、3 步都通過後才可用 `-D`）。
  7. `git worktree prune`
- 遠端分支由 GitHub「Automatically delete head branches」在合併時自動刪除。

## 程式碼解析與搜尋
- 優先使用 Graphify 與 LSP 解析、搜尋程式碼。
- 以 Graphify 查架構、檔案關聯與呼叫路徑，以 LSP 查符號、定義、參照與診斷。
- 修改既有程式碼前先以 LSP 評估影響範圍；修改後檢查診斷。
- 索引需與程式碼同步。工具不支援該語言或不可用時，才以 `rg`／直接讀檔補充，並說明限制。
- Graphify 索引以本機 AST 為主（`graphify extract . --code-only`）；索引產物不進版控。

## 文件查核（Context7）
使用 Context7 MCP 取得函式庫、框架、SDK、API、CLI、雲端服務的最新文件，即使已熟悉也要查核。一般重構、商業邏輯除錯、程式碼審查與通用程式概念不必查。
1. 先用 `resolve-library-id`，除非使用者提供 `/org/project` 格式的確切 ID。
2. 依名稱、相關性、來源信譽、範例數量與評分選最符合的 ID；指定版本時優先使用版本 ID。
3. 用 `query-docs` 查單一具體概念；多個獨立概念分開查詢。
4. 依查得文件實作與回答；Context7 未收錄時查官方文件或套件原始碼。
