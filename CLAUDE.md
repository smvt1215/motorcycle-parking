# CLAUDE.md

## 專案
台灣機車停車指南 APP（普通機車 + 大型重機），實作計畫見 [docs/PLAN.md](docs/PLAN.md)。

## Git 與 PR 規則
- `main` 受 ruleset 保護：必須經 PR 合併、禁止 force push、需簽章 commit、線性歷史。合併一律用 **Squash and merge**。
- **PR 合併後必須清理本機 worktree 與分支**：
  1. 先確認 PR 狀態為 merged（不是 closed）。
  2. `git fetch --prune origin`
  3. 若該分支有獨立 worktree：`git worktree remove <path>`（有未提交變更時先停下來詢問，不要加 `--force`）。
  4. 切回 `main` 並同步：`git checkout main && git merge --ff-only origin/main`
  5. 刪除本機分支：`git branch -D <branch>`（Squash merge 後 `-d` 會判定未合併而失敗，確認已 merged 後才可用 `-D`）。
  6. `git worktree prune`
- 遠端分支由 GitHub「Automatically delete head branches」在合併時自動刪除。
