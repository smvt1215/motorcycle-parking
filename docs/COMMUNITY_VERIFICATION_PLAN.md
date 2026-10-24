# 社群共筆與停車資訊核實機制 — 實作計畫

> 狀態：設計提案，尚未實作／尚未驗收  
> 盤點日期：2026-10-24（Asia/Taipei）  
> 專案：[`smvt1215/motorcycle-parking`](https://github.com/smvt1215/motorcycle-parking)  
> 盤點基準：`main` commit `ee4a1f3c034a1237eb14b18c1f35c1b692cc4bb7`（含 #55、#56）  
> 適用端：Flutter iOS／Android、Supabase Postgres／PostGIS／Auth／Edge Functions、Flutter Admin Web  
> 性質：增量設計。本文不代表已完成的功能，也不更改既有程式碼。

## 1. 目標與原則

以社群貢獻補齊官方靜態點位的缺漏，使每項資訊可追溯、可核實、可提出反證、可回退，同時避免社群投票錯誤地將「點位存在」解讀成「合法可停」。

### 核心原則

1. **存在、資訊正確性、停放資格三個面向分開判定。** 現場有車格不等於目前車種合法可停。
2. **社群提供觀察與證據，不以多數票取代法規。** 停放資格、開放時段、特殊許可應由官方公告、有效標誌標線或場站明確公告核實；爭議送人工審核。
3. **編輯採提案制，不直接覆蓋已公布資訊。** 留存目前值、建議值、提交者、觀察時間、證據、採納結果及歷史版本。
4. **低風險事項可逐步自動核實，高風險事項維持人工把關。** 自動化門檻須依真實審核資料校準。
5. **過時與不存在不同。** 未重新核實應降低欄位可信度，不能直接推論停車點消失。
6. **來源可信度與資料新鮮度各自呈現。** 官方來源亦需註明發布、生效及查核時間。
7. **隱私優先。** 公開資料不可洩漏回報者帳號、IP、裝置識別或未審證據。

### 不在本計畫範圍

- 即時剩餘車位／即時占用率。
- 全自動認定交通法規、取代主管機關解釋。
- 公開使用者排行榜、可交換點數等遊戲化機制。
- 以照片或 GPS 單獨證明停車合法。
- 重建獨立的審核後台；優先沿用 `docs/ADMIN_WEB.md`。

## 2. 已有能力與未完成事項

| 模組 | 已有實作／設計 | 後續工作 |
| --- | --- | --- |
| 新增停車點 | `ReportForm` + `submit-report` + `community_spots` | 補證據、位置品質、修訂溯源 |
| 修改建議 | `spot_suggestions.dart` 的 `flag` 流程 | 送出結構化 `field`／`proposed`／`note` |
| 防濫用 | Google／Apple 登入、帳號年齡、IP／裝置 HMAC、帳號／IP 限流 | 將裝置/IP 僅作風險訊號；加抗重放與可觀測性 |
| 歷史投票 | `spot_votes`、`apply_report` 支援 `still_there`／`gone` | 與停放資格解耦；檢查舊 API 的自動隱藏 |
| 資料可信度 | `TrustStatus.pending/confirmed/hidden`、`EligibilityStatus.unverified` | 由點位級改為存在／欄位／合法性分層 |
| 資料過期 | `ParkingSpot.stale`：`lastConfirmedAt` 有值且超過 180 天 | 空值視為未知；依欄位不同效期 |
| 管理審核後端 | #55 已合併 `moderation_queue` 結構化欄位、`admin_resolve_report`、`admin_audit_log`、MFA 權限 | 提案與審核欄位一致化、衝突檢查 |
| 管理後台 | #56 已合併 Admin Web 外殼（登入、MFA、頁籤、待審數） | 實際審核／點位維護操作尚需實作 |
| 照片 | 點位有 `photo_urls` 顯示與儲存欄位 | Storage 上傳、審核、去識別、權限及保留期 |

相關來源：
- [專案總計畫](PLAN.md)
- [Admin Web 計畫](ADMIN_WEB.md)
- [現有社群建議 UI](../lib/features/report/spot_suggestions.dart)
- [回報驗證](../supabase/functions/submit-report/validate.ts)
- [最新版回報／管理 RPC](../supabase/migrations/202610240003_admin_backend.sql)
- [車種資格判斷](../lib/domain/eligibility.dart)
- [停車點模型](../lib/models/parking.dart)

### 2.1 目前必須處理的風險

**R1（P0）存在確認會間接提升車種資格可信度。** 舊 `apply_report` 在兩個合格且獨立的 `still_there` 投票後，把整筆社群點設成 `confirmed`；`eligibility.dart` 又以 `status == confirmed && !stale` 作為部分停放資格判斷的可信條件。此狀態不能證明「重機可停／普機可停」欄位已獲證據核實。

**R2（P0）回報 UI 尚未使用已建成的結構化審核後端。** `_SuggestionForm.submit()` 目前只送 `action/source_id/reason`；未送 `field/proposed/note`，後台無法直接呈現機器可辨的欄位差異。

**R3（P1）相同理由可能吞掉獨立證據。** `moderation_queue` 有待審案件的 `(source_id, reason)` 唯一索引；`flag` 採 `ON CONFLICT DO NOTHING`。相同文字的不同騎士回報可能不另留可核實的個別觀察。

**R4（P1）資料過期語意與時間更新。** `lastConfirmedAt == null` 不會觸發 `stale`；舊投票達門檻後，後續投票可能再次更新確認時間，即使沒有重新查核特定欄位。

**R5（P1）舊投票仍可使點位隱藏。** 新 UI 已移除單獨的存在投票，但 `submit-report/validate.ts` 與 RPC 仍接受 `vote`；加權負向分數達 3 時會隱藏社群點並進審核。舊版客戶端或直接呼叫的風險需另行控制。

**R6（P1）15 公尺同類型去重過於簡化。** 目前以「15 m 內且相同 `space_type`」判斷重複；同一位置可能有不同入口／分區，也可能有兩個獨立場站。第一版保留防重複提示，不能自動合併。

## 3. 產品流程與可見狀態

### 3.1 共筆入口

沿用目前「貢獻 → 新增停車點」及「停車點詳情 → 提出修改建議」，先完善現有入口而不新增重複頁面。

修改建議的每個提案至少記錄：

- 點位 ID（包含 `official:<uuid>` 與社群 UUID 的識別方式）。
- 受影響欄位鍵（不可只使用繁中文字串）、目前值、建議值。
- 回報類型：`create`、`correct`、`exists`、`removed`、`temporary_closure`、`dispute`。
- 騎士說明、實際觀察時間、送出時間、可選證據。
- 送出當時的點位版本；資料在審核前若已變更，必須提示衝突。
- 提案狀態：待審、待補證據、已採納、已駁回、已撤回／過期。

### 3.2 狀態不可混為一談

| 面向 | 建議狀態 | 意義 |
| --- | --- | --- |
| 存在狀態 `existence` | `observed / unverified / disputed / removed` | 車格或場站是否仍存在 |
| 欄位核實 `field_verification` | `unverified / verified / stale / disputed` | 單一欄位是否有有效證據 |
| 停放資格 `eligibility` | 既有 `allowed / conditional / unverified / notAllowed` | 對指定車種的停車判斷，由規則與已核實事實計算 |
| 地圖公開 `visibility` | `visible / hidden` | 是否顯示，不代表存在或可停 |

相容期保留 `community_spots.status`，但**不得再把它作為所有欄位可信度的代理**。新 UI 可見舊的待確認社群點，但不得因「存在已確認」便把高風險資格改成「可停」。

### 3.3 內容型態與審核策略

| 資料 | 最低證據（建議起點） | 發布策略 |
| --- | --- | --- |
| 場站或車格存在 | 不同使用者的近期獨立觀察 | 可試行低風險自動核實，絕不推導合法性 |
| 名稱、地址／入口 | 現場照片、明確地址、交叉回報 | 低風險欄位經審核資料校準後可自動處理 |
| 收費／時段 | 現場收費牌、營運方或官方資料 | 優先人工確認，有效期較短 |
| 普機／大型重機可停 | 適用官方規則 + 現場標誌／場站公告，必要時管理員查證 | 不以社群票數自動宣告合法 |
| 格位撤除、封閉 | 現場原因、照片及相關公告 | 先標爭議／待核實；永久撤除需人工判定 |
| 縣市法規 | 官方法規或主管機關有效公告與生效日期 | 僅管理員發布，不開放社群表決 |

## 4. 資料模型與最小遷移

原則：**保留既有 `moderation_queue` 作為審核案件、`admin_audit_log` 作為管理操作稽核；新增觀察與欄位核實，而不是另造完整第二套審核系統。**

### 4.1 `spot_observations`（新增）

每次獨立的現場觀察都新增一列，不因文字相同而丟棄。

建議欄位：
- `id uuid PK`、`source_id text`、`reporter_id uuid`（不對外公開）。
- `case_id uuid nullable` → `moderation_queue.id`。
- `kind text`、`field_key text nullable`（固定白名單鍵）。
- `proposed jsonb`、`observed_at timestamptz`、`created_at timestamptz`。
- `comment text`、`evidence_ids uuid[]`（或關聯表）。
- `account_age_bucket`、`independence_result`、`risk_flags jsonb`（不公開；勿保存可逆原始 IP）。
- `idempotency_key text`（同帳號同操作重送不產生重複觀察）。

RLS：只開放本人查自己的提案；管理員 `is_admin()` 才能檢視全部；**一般地圖 API 絕不直接回傳 `reporter_id`、IP／裝置雜湊、風險欄位。**

### 4.2 `spot_field_verifications`（新增）

以 `(source_id, field_key)` 為唯一鍵；存在核實可用特殊 `field_key = 'existence'`。

建議欄位：`state`、`verified_value`、`evidence_policy`、`source_kind`、`verified_at`、`valid_until`、`reviewed_by`、`revision`、`updated_at`。

需保留證據／提案關聯（另設 join table），避免只有最後一個驗證者的結果。對同一點位的 `heavy_allowed` 和 `scooter_allowed` 分開存狀態；場站 `parking_zones` 則考慮 `field_key + zone_id`。

### 4.3 `spot_evidence`（新增，照片階段）

記錄 Storage object key、擁有者、提交時間、證據類型、審核狀態、可公開與否；**不直接信任客戶端傳入任意公開 URL**。

- 預設使用私有 bucket 和審核端限時簽署 URL。
- 圖片處理：類型／大小限制、移除 EXIF、車牌與人臉遮蔽、惡意檔案與濫用檢查。
- 公開照片應採發布後的衍生檔；原始未審證據不可直接在地圖公開。
- 建立保留期、刪除請求及事件追溯規則；保留最少必要資料。

### 4.4 既有表調整

- `moderation_queue`：保留 `field/proposed/note/status/resolved_by/resolution_note`，增加版本比較與提案聚合鍵；同一提案可以關聯多份獨立 `spot_observations`。**不要再以相同 `reason` 代表完整證據已儲存。**
- `community_spots`：暫保留 `status/last_confirmed_at` 為相容欄位，新增必要的版本號或透過核實表衍生；逐步移除 `eligibility` 對點位級 `confirmed` 的信賴。
- `official_heavy_spots`：主資料仍由官方匯入／管理員維護。社群證據只能形成修改提案，不可自行改寫官方來源與 `source_url`。
- `admin_audit_log`：繼續記錄管理端 before／after，若需所有發佈歷史，再增加通用 `spot_revisions`，以避免與管理稽核重複。
- 既有 `spot_votes`：保留歷史相容，不要再把舊票數用於自動授權車種資格；評估移除其自動隱藏副作用。

### 4.5 資料遷移與相容

1. 使用**新增 migration**，不修改已部署的舊 migration。
2. 先加新表與 view／RPC，再改讀取端，最後處理舊 `confirmed` 衍生邏輯。
3. 舊版 App 的 `flag`（純 `reason`）照常接受並列入待審，結構化欄位可為 null；新版本不依賴字串解析。
4. 舊 `confirmed` 點位的欄位核實初始設為 `unverified`，除非具備可回溯來源，**不能批次直接當成合法性已核實**。
5. 遷移前後確保收藏 JSON 舊版可解析；`EligibilityStatus` 的外部語意保持一致。
6. 以功能旗標與 staged rollout 控制核實規則；確保既有客戶端不會因 schema 更新而崩潰。
7. 既有 `moderation_queue` 唯一索引要先規劃替代聚合方式，並在同一 transaction 維持觀察紀錄與案件一致性。

## 5. API、業務規則與核實演算法

### 5.1 近期先接通結構化修改建議

新版 Flutter `flag` payload 示意：

~~~json
{
  "action": "flag",
  "source_id": "official:<uuid-or-community-uuid>",
  "field": "heavy_allowed",
  "proposed": { "heavy_allowed": true },
  "note": "入口公告清楚標示大型重機可停",
  "reason": "機車停放資格：建議大型重機可停"
}
~~~

說明：`source_id` 的值應是**實際點位 ID**：官方 `official:<uuid>`，社群則為純 UUID；上方字串只代表兩種可能形式，不能逐字送出。新增欄位的具體命名與白名單應與 `admin_resolve_report` 的欄位鍵相同。

實作項目：
- UI 以穩定的 `field_key` 傳值，繁體中文僅供畫面顯示。
- `space_type`、`heavy_allowed`、`scooter_allowed` 等使用結構化欄位；名稱、費率、位置等逐步補齊。
- Edge Function 在信任邊界檢查欄位白名單、值型別、座標、大小與權限；不可只信任 Dart 表單。
- 管理員審核時顯示「目前／建議／證據／基礎版本」；採納以既有 `admin_resolve_report` 或擴充版在單一 transaction 寫入。
- 舊版文字 `reason` 繼續保留，避免舊 App 相容問題。

### 5.2 交叉核實的判定

- 計算的單位是**獨立觀察**，而非同一案件數或按鈕點擊數。
- 提案者不能為自己的觀察再加第二筆權重；同一帳號同一案件多次更新，保留歷史，但只計當前有效意見。
- 同 IP／同裝置／建立很新的帳號只增加風險，不把 IP 視為真實身分證明；行動網路 NAT 可能使兩名真實騎士同 IP。
- 建議初期最低門檻：**兩名已登入、帳號超過 7 天且獨立性風險低的使用者**可核實「存在」；此數值須經真實資料調整。
- 任何影響**合法性／限制**的修改，均需可驗證公告或管理員人工確認；即使超過交叉觀察門檻也不能只靠多票自動變「可停」。
- 同一欄位有明顯矛盾的可靠觀察時，先標 `disputed`，保留前一個安全狀態，交由人工審核；不得採單純最新覆蓋。
- 任何提案的 `base_revision` 落後目前版本時，不可直接套用，需重新比對（防止失效提案覆蓋更新的資料）。

### 5.3 過期與再次核實

建議**初始試行週期**，由後台可設定、依誤報率修正：

| 欄位／資訊 | 建議期限 |
| --- | --- |
| 點位存在 | 180 天 |
| 名稱、入口／格位型式 | 180 天 |
| 費率與收費方式 | 30–90 天 |
| 臨時封閉／施工 | 1–7 天或公告載明截止日 |
| 重機停放資格 | 90 天或公告／場站規則變更時 |
| 法規與公告 | 依有效日期、廢止日期及官方來源變動 |

以伺服器儲存的 `verified_at`、`valid_until` 判定，而非只有 Flutter `DateTime.now()`。**沒有查核時間必須是未知，不可視為永久新鮮。**

定期作業只改核實狀態，不應自動刪除點位。法規與現場事實的優先順序：有效的官方規則／公告約束可停條件；現場標誌與營運方公告是重要佐證，與官方資料衝突則標爭議送審，不能由社群覆蓋法律。

## 6. 權限、防濫用與安全

沿用現行 `submit-report` Edge Function + service role RPC 寫入、公開只讀 view 與 RLS 的架構。

- 回報：Google／Apple 登入；管理員操作維持 `is_admin()`（需 `aal2`）。
- 限流：保留每帳號每日 10 筆、每受信任 IP 每日 30 筆作起始值，並評估分操作類型限流／冷卻時間；必須伺服器執行。
- 防重放：`idempotency_key`、重試唯一索引、交易內原子更新；由後端決定信任分數，不信任客戶端傳入 `qualified`。
- 裝置：目前 `device_id` 是 SharedPreferences UUID，容易重設。未來可整合 App Attest／Play Integrity，但這只能提供應用程式完整性訊號，不能證明一機一人。
- IP：只讀可信反向代理覆寫的 header；維持 HMAC 雜湊、secret 輪替及保留期；不顯示給前端。
- 來源與隱私：避免在公開查詢中回傳單筆回報者身分及敏感位置歷史。使用者刪除帳號／撤銷照片同意需有處理程序。
- 照片：上傳限制、內容審核、去 EXIF、臉／車牌遮蔽；高風險證據預設不公開。
- 濫用／撤除：不要讓單一使用者或幾個可疑舊版投票在未審核時直接永久隱藏大型公共場站。

## 7. Admin Web 接軌

接續 `docs/ADMIN_WEB.md` 的既有待審清單／差異表，不另外建立第二個網站：

1. 待審案件中顯示結構化目前值與提案值、照片／公告、觀察數、風險訊號、提案版本。
2. 同一欄位的多筆觀察合併展示，但保留各自的時間與證據來源。
3. 管理動作：採納、修改後採納、駁回、要求補充、標爭議。
4. 管理員採納時，以資料庫 transaction 比對版本 → 寫欄位 → 更新核實紀錄 → 結案 → 留下稽核。
5. 提供歷史版本／還原；當來源官方公告變更時，能重新標註需要人工複查的欄位。
6. 延續 PR #56 的登入／MFA／外殼與 #55 的 `admin_resolve_report`；實際登入、Hosting、SMS 等環境驗收仍依原後台計畫執行。

## 8. 開發階段與驗收標準

### P0 — 可信度語意與安全止血（最高優先）

**範圍：**
- `lib/domain/eligibility.dart`：讓存在確認不能直接使 `heavy_allowed`／`scooter_allowed` 變可信；修正未核實、無時間、過期資料的降級行為。
- 後端：檢視舊 `vote` 路徑，停止未審判定的合法性提升，並讓負向票自動隱藏受安全策略管控；保留必要相容。
- 新增針對不同車種／官方與社群／待確認／過期／衝突的單元測試。

**完成標準：**
- [ ] 兩人確認「仍存在」不使未經資格核實的重機點顯示「可停」。
- [ ] 缺乏核實時間／已過期的社群資格不被當成新鮮證據。
- [ ] 未授權者不得直接利用舊投票 API 修改高風險公開狀態。
- [ ] 官方有效限制與不同車種的既有安全判定不回歸。

### P1 — 結構化共筆與審核串接

**範圍：**
- `lib/features/report/spot_suggestions.dart`：填入 `field/proposed/note`，保留原 `reason`。
- `supabase/functions/submit-report/validate.ts`：欄位白名單、型別與衝突值驗證。
- Admin Web：完成現有規劃中的待審案件比較、採納／駁回與錯誤處理。

**完成標準：**
- [ ] 類型、車種資格、名稱、費率修改以機器可辨的欄位值送審。
- [ ] `admin_resolve_report` 能一次採納並保留 before／after 稽核。
- [ ] 舊 App 只送 `reason` 仍能成功送審。
- [ ] 管理員在提案送出後遇到點位資料變更會看到衝突，不盲目覆蓋。

### P2 — 獨立觀察、證據與版本

**範圍：**
- 新增 `spot_observations`、`spot_evidence`、提案關聯與去重／重放控制。
- Supabase Storage 私有上傳、照片處理、隱私與審核。
- Admin Web 顯示證據及單獨觀察；設計可追溯的版本／回退。

**完成標準：**
- [ ] 相同文字、不同回報者的兩次觀察均完整保存。
- [ ] 同一使用者重送不會把一筆觀察算兩票。
- [ ] 未審照片與回報者資料無法被匿名或一般使用者讀取。
- [ ] 每次採納都有可追溯的前後值及審核紀錄。

### P3 — 分層核實與爭議管理

**範圍：**
- 新增 `spot_field_verifications` 與查詢 view／RPC。
- 低風險存在觀察的交叉核實規則、分歧標示及人工仲裁。
- 接入車種資格計算（僅採具備正確證據等級及有效期的欄位）。

**完成標準：**
- [ ] 「存在已核實」與「重機可停」完全獨立。
- [ ] 同 IP／裝置的判斷不會錯當成絕對身分保證。
- [ ] 相互矛盾的可信觀察不會自動發布較危險的結果。
- [ ] 普機、黃牌／紅牌相關規則仍依有效法規及個別場站限制判定。
- [ ] 自動通過只涵蓋列入允許清單的低風險欄位。

### P4 — 資料新鮮度與維運

**範圍：**
- 欄位級 `valid_until`、定期重驗隊列、來源差異通知。
- Admin Web 過期／爭議篩選；必要時可通知有貢獻的使用者補充。
- 驗證門檻、異常回報率、審核工作量與誤判率儀表指標。

**完成標準：**
- [ ] 沒有核實時間不會被當成「永久有效」。
- [ ] 過期只降低指定欄位信任，不直接抹除整個點位。
- [ ] 可追蹤待審積壓量、被駁回比例、衝突率、撤銷／回退事件。
- [ ] 支援依場站、縣市、格位類型調整資料有效期。

## 9. 必測情境（Flutter + Deno + pgTAP）

| 情境 | 預期 |
| --- | --- |
| 兩名合格騎士回報「仍存在」，`heavy_allowed` 未核實 | 點位存在可確認；重機資格仍待確認 |
| 已確認的社群欄位缺 `verified_at` | 不被當成有有效時效的證據 |
| 兩人同 IP、不同帳號／裝置 | 記錄兩個觀察與風險訊號，不以 IP 直接推導真實身分 |
| 同一帳號快速重送完全相同請求 | 回傳既有結果，不重複計票 |
| 多名使用者相同 `reason` | 全部獨立觀察可查，審核案件可聚合 |
| 不同人回報同欄位相反建議 | 顯示爭議，不自動更新可停資格 |
| 證據不支援合法停放，但多票聲稱可停 | 不得自動升級成可停 |
| 管理員採納前資料已改版 | 觸發版本衝突，需重新檢視 |
| 一次移除／大量負向票、舊 `vote` API | 不會在缺乏足夠可信證據時不可逆地下架點位 |
| 官方點提出修改建議 | 官方來源欄位維持原貌，走人工審核 |
| 非管理員嘗試呼叫管理 RPC | RLS／MFA 權限拒絕 |
| 未審照片、EXIF、個資 | 非法存取失敗；公開只顯示通過隱私審核的衍生檔 |
| 間歇性網路／重試／重放 | 資料與案件關聯一致，無半完成狀態 |
| 來源時間到期 | 僅相關欄位變 stale，不隱藏完整點位 |

CI 至少納入 `flutter analyze`、`flutter test`、Deno `validate_test.ts`、`supabase test db`（pgTAP），以及 Admin Web 的 widget／Chromium smoke test。涉及遷移的 PR 必須在乾淨資料庫及含舊資料的升級路徑都驗證。

## 10. 推進順序與依賴

~~~text
現有 #55 管理後端 + #56 Admin Web 外殼
  ├─ P0：可信度解耦與舊投票安全修正
  └─ P1：結構化修改建議 → Admin 審核畫面
      └─ P2：觀察紀錄／證據／版本
          ├─ P3：欄位級交叉核實與爭議管理
          └─ P4：欄位有效期、到期重驗與指標
~~~

**交付原則：** 每期獨立 PR，附 migration、測試、相容說明及回退方案；需後端先於／配合新版 App 部署。尚未經端到端驗收前不開啟可自動改變高風險可停資格的規則。

**建議首批工作切分：**
1. `fix(trust): separate existence from parking eligibility`
2. `feat(report): send structured spot suggestions`
3. `feat(admin): review structured suggestions and version conflicts`
4. `feat(community): store independent observations and evidence`
5. `feat(verification): field-level verification and expiry`

## 11. 開發前需拍板的設計決策

以下採建議預設，實作前可以在 PR 逐項討論，不阻擋 P0／P1：

1. **核實門檻：** 首期存在核實採兩名合格帳號、低風險獨立觀察；上線後依誤判資料調整，**不將 IP 唯一性當硬性一人一票條件**。
2. **照片政策：** P2 上線私有證據上傳，公開展示需分離審核；未完成安全流程時先允許提供官方來源網址，不急於公開照片。
3. **舊版 `vote`：** 預設保留資料相容、限制自動發布與隱藏副作用，最終依實際使用者版本占比決定淘汰時間。
4. **官方資料優先級：** 官方有效法規決定政策邊界；現場公告若與官方資料衝突，先維持待確認並送管理員處理。
5. **核實結果呈現：** 地圖主要四態維持現有 UI；在詳情內另外呈現「來源／已查核欄位／最近核實時間」，避免標記視覺過載。

---

### 參考文件與變更紀錄

- [`docs/PLAN.md`：社群回報機制](PLAN.md#社群回報機制)
- [`docs/ADMIN_WEB.md`：審核後台與已排開發階段](ADMIN_WEB.md)
- [PR #55：管理權限、結構化建議、審核 RPC](https://github.com/smvt1215/motorcycle-parking/pull/55)（已合併）
- [PR #56：MFA Admin Web 外殼](https://github.com/smvt1215/motorcycle-parking/pull/56)（已合併）

> 註：本文根據 2026-10-24 儲存庫程式碼與文件的靜態檢視形成，尚未執行正式／staging 系統測試。正式實作時，應重新核對 `main` 最新 schema、後台功能進度、地方法規來源與遷移依賴。
