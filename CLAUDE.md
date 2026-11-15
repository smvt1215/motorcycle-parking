# CLAUDE.md

這是「台灣機車停車指南 APP」（普通機車 + 大型重機）的專案規則。讀者是在這個 repo 工作的 Claude 與 Codex 工作階段，包括 PM、實作隊友與審查者；每個工作階段開始時都沒有前一個對話的內容。本文件管四件事：與其他工作階段協作、寫程式時怎麼查程式碼與文件、PR 從建立到合併的流程（含誰合併、問題怎麼回報）、合併後的本機清理。實作計畫見 [docs/PLAN.md](docs/PLAN.md)。

## 什麼時候直接做、什麼時候先停下來
- 直接做，不需詢問：自我審查通過後把 PR 轉為 Ready for review。
- 直接合併，不用逐案詢問使用者（只限 PM）：同步最新 main 後，PR 的目前 head 全綠。隊友不合併。
- 先等使用者同意再合併：使用者指定要先看的 PR，例如規則文件、要看截圖的 UI 變更、政策文字。
- 先回報 PM：隊友遇到設計取捨、政策或超出派工範圍的事。沒有 PM 的單一工作階段直接詢問使用者。
- 停下來詢問：合併後清理時，本機分支有沒進 PR 的 commit，或要移除的 worktree 有未提交變更。

細節見下方對應段落。

## 開工前：與其他工作階段協作
與另一個 Claude／Codex 工作階段協作前，先讀 [通訊方式與驗證紀錄](docs/AGENT_COMMUNICATION.md) 並重新確認收件工作階段。文件中的舊 thread ID 不可直接當成新對話的收件位址：它指向當時的對話，訊息投遞過去，新對話不會收到。

## 寫程式時
### 解析與搜尋程式碼（Graphify、LSP）
- 優先用 Graphify 與 LSP：Graphify 查架構、檔案關聯與呼叫路徑；LSP 查符號、定義、參照與診斷。
- 修改既有程式碼前先用 LSP 評估影響範圍，修改後檢查診斷。
- 索引需與程式碼同步，否則查到的是舊結構：切換分支或修改程式後、用 Graphify 查詢前，重跑 `graphify extract . --code-only`。Graphify 索引以本機 AST 為主，產物不進版控。
- 工具不支援該語言或不可用時，才以 `rg`／直接讀檔補充，並說明限制。

### 查核函式庫文件（Context7）
函式庫、框架、SDK、API、CLI、雲端服務的用法會隨版本改變，記得的寫法可能已過時，所以即使已熟悉也要用 Context7 MCP 取得最新文件查核。一般重構、商業邏輯除錯、程式碼審查與通用程式概念不必查。
1. 先 `resolve-library-id`，除非使用者已給 `/org/project` 格式的確切 ID。
2. 依名稱、相關性、來源信譽、範例數量與評分選最符合的 ID；有指定版本時優先用版本 ID。
3. `query-docs` 一次查一個具體概念；多個獨立概念分開查。
4. 依查得文件實作與回答；Context7 未收錄時查官方文件或套件原始碼。

## 從開 PR 到合併
`main` 受 ruleset 保護：必須經 PR 合併、禁止 force push、需簽章 commit、線性歷史，所以每個變更都走 PR。合併方式只用 **Squash and merge**：每個 PR 在 `main` 上成為一個 commit，符合線性歷史。

### PR 流程
1. PR 都先以 draft 建立。Ready for review 會觸發自動審查，draft 讓你先完成自我審查。
2. 自我審查：逐行重讀 diff、跑本地檢查（有的 format / lint / test），確認 PR 說明與變更一致。
3. 通過後**不需詢問**，直接轉 Ready for review（觸發 Codex 等自動審查）。
4. 持續追蹤到全綠，處理每則審查意見：
   - 成立 → 修正並 push，在該 thread 回覆修正的 commit，resolve。
   - 不成立 → 在 thread 回覆理由（附推論路徑），resolve。
   - 涉及設計取捨或超出 PR 範圍 → 依下方「設計取捨與超出範圍的問題」處理。
5. 「全綠」＝ CI 全部通過、無合併衝突、所有審查 thread 已 resolve，而且自動審查已審過**目前 head** 並沒有未處理的意見。審的是舊 commit 不算，因為之後推的變更沒有人看過。審過目前 head 的判斷方式：
   - `codex-review-state` 摘要留言的 `commit_sha` 等於目前 head 且 `status=completed`，或「Reviewed commit」回條是目前 head。
   - `status=running` 就等它完成，不要當成已審。
   - Codex 在 PR 留言表示額度用完時，改由沒寫這個 PR 的審查者做交叉審查（只限本 PR 的 diff），把結論與審查的 head SHA 貼在 PR；結論寫明「可合併」才算。
   - 例外：Dependabot 的純 minor／patch 更新、沒有人工 commit 時，CI 全部通過即可合併，不需 Codex 審查。
6. 全綠後的合併見下方「合併」。

### 設計取捨與超出範圍的問題
隊友遇到設計取捨、政策或超出派工範圍的事，不自己決定，也不直接問使用者，先回報 PM。這讓使用者已做過的決定能被重用，問題也集中在一處追蹤。
- 回報格式：question_id、issue／PR、背景、2–4 個選項與各自的缺點、你的建議、是否擋住進度。
- PM 能依已記錄的使用者決定回答，就直接回答並標「PM 代答」；其餘才問使用者。
- 只有 PM 轉達的答案算使用者的決定。
- 沒有 PM 的單一工作階段，直接詢問使用者。

### 合併
只有 PM 合併，隊友不合併。PM 確認全綠後以 Squash and merge 合併，不用逐案詢問使用者：
1. 把最新 `main` 同步進 PR 分支，等這一輪 CI 通過。`main` 不強制 PR 與最新 main 同步，兩個各自全綠的 PR 先後合併時曾讓 `main` 壞掉，所以合併前要在最新 main 上再驗證一次。同步會產生新的 head，全綠的條件要對這個新 head 成立。
2. `gh pr merge <n> --squash --match-head-commit <head>`：`--match-head-commit` 確保合併的是剛確認過的那個 head；確認後若有人又推了 commit，合併會失敗而不是把沒驗證的變更合進去。

使用者指定要先看的 PR（例如規則文件、要看截圖的 UI 變更、政策文字），全綠後先給使用者看，等使用者同意才合併。

### Review 只限 PR 範圍
所有手動與自動審查都只看該 PR 的 base → head diff，不做全專案審查；每次發出 review prompt 必須寫明此限制。這讓每個 PR 只對自己的變更負責，既有問題不會擋住無關的 PR。
- 相依程式碼只可為判斷變更影響而查看。
- 只回報本 PR 引入或直接影響的問題；未修改的既有問題不列為審查意見或阻擋條件。

## 合併後：清理本機 worktree 與分支
PR 合併後必須清理本機 worktree 與分支。遠端分支由 GitHub「Automatically delete head branches」在合併時自動刪除，不用處理。
1. 確認 PR 是 merged（不是 closed），記下最後的 head commit SHA。closed 代表沒有合併，分支上的工作不在 `main`。
2. `git fetch --prune origin`：更新 `origin/main`，並移除已刪除的遠端分支參照。
3. 確認本機分支沒有未發佈的 commit：`git log --oneline <PR head SHA>..<branch>` 必須為空。squash merge 後原本的 commit 不在 `main` 的歷史裡，所以要跟 PR head SHA 比，不能跟 `main` 比。不為空代表有 commit 沒進 PR，**停下來詢問**，不要刪除。
4. 分支有獨立 worktree 時：`cd` 到主 worktree（`git worktree list` 第一列）再執行 `git worktree remove <path>`。不可在要刪除的 worktree 內執行，那會刪掉自己所在的目錄。有未提交變更就停下來詢問，不加 `--force`，因為 `--force` 會直接丟掉這些變更。
5. 在主 worktree 切回 `main` 並同步：`git checkout main && git merge --ff-only origin/main`。`--ff-only` 讓本機 `main` 只快轉到 `origin/main`，不產生 merge commit。
6. `git branch -D <branch>`：squash merge 後 `-d` 會判定未合併而失敗，所以用 `-D`；第 1、3 步都通過後才可用。
7. `git worktree prune`：清掉已不存在的 worktree 留下的紀錄。
