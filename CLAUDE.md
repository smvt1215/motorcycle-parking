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
