# PR checks 精簡與五語言 CodeQL 設計

使用者於 2026-10-14 核准前次檢討的改善建議。

## 範圍與決策

- 維持 `CI 全部通過`、`Android 全部通過`、`iOS 全部通過` 三個必要 checks，以及分支同步、簽章、Squash、審查 thread 結案要求。
- 不用 workflow 層級的 paths filter；僅略過無關的重型 steps，所有彙總仍嚴格要求前置 jobs 成功，失敗與取消不得視為通過。
- Flutter 品質 job 增加路徑判斷。純文件仍執行 Python／fastlane 自動化測試與版本政策，不安裝 Flutter、不跑 Web 建置。
- 移除 `tool/` 的平台全量觸發；模擬器工具只影響 iOS，seed 工具與資料來源影響品質及資料庫。路徑判斷程式與測試變更驗證所有目標；刪除、跨目錄搬移及 Git diff 錯誤有回歸測試。
- Dependabot 依 ecosystem 合併 minor／patch 版本更新；major 與安全性修補維持既有獨立政策，不忽略任何版本。
- CodeQL 改採 Advanced Setup：Actions、JavaScript／TypeScript、Python 使用免建置掃描；Java／Kotlin 與 Swift 先準備 Flutter，再以 manual build 掃描。
- 原生掃描採獨立 jobs，避免改變既有模擬器產物與編譯旗標。PR 只跑相關原生掃描；main、週排程、手動執行一律完整掃描。代價是 App PR 會增加一次原生安全建置，但文件 PR 不會。
- 不變更 CD staging（staging 憑證未設定前部署 job 不會實際部署）與 AI Scan，不變更憑證或正式部署政策。

## 啟用與驗收

1. 本地路徑回歸測試、全套 Python／Ruby 測試及 workflow 靜態檢查通過。
2. 先推送分支，再切換 Default Setup 為停用並建立 draft PR，避免 Default Setup 拒收 Advanced Setup 的 SARIF；核對五類 analysis 實際上傳，不能只看設定成功。
3. PR 自我審查後 Ready for review，處理審查意見與 CI 到全綠，合併依專案規則由使用者執行。
4. 合併後 main 與排程才會使用新 workflow。五類掃描穩定、且 default branch 已有分析基準後，另確認 CodeQL 合併門檻；本次不提前添加會卡住 PR 的未驗證 check。

## 文件依據

- [GitHub required workflows 與 paths filter](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)：整條 required workflow 被略過會留下 Pending。
- [CodeQL compiled-language manual build](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages)：Kotlin／Swift 需要實際編譯。
- [Swift 編譯設定](https://docs.github.com/en/code-security/tutorials/customize-code-scanning/prepare-code-for-analysis)：停用簽章、編譯快取與 integrated driver。
- [Default Setup SARIF 衝突](https://docs.github.com/en/code-security/reference/code-scanning/sarif-files/troubleshoot-sarif-uploads/default-setup-enabled)。
