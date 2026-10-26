# 停放條件與費率模型（P1–P4 設計）

> 狀態：設計草案；§7 的 9 項設計取捨已全部由使用者於 2026-10-26 決定（皆採建議）。只寫設計，不含程式。實作排在目前兩個 stack（第一批 #90–#95、stack B #97–#101 與後續層）合併之後，另開一個 stack。
>
> 依據：Codex 交接（使用者已確認的需求 1–7、法規核對 A–E、程式對照、草案 P0–P6、使用者決定）；[PLAN.md](../PLAN.md)「費率結構」「社群回報機制」；[結構化分區費率](2026-10-25-structured-zone-fees.md)；[核實計畫](../COMMUNITY_VERIFICATION_PLAN.md) §3.2–§3.4、§4、§5.3；[可行性研究](../CONTRIBUTION_TIERS_FEASIBILITY.md) §5.1、§5.6、§5.7、§5.8；[ADMIN_WEB.md](../ADMIN_WEB.md)。程式基準為 `main` b827aab，另參考進行中的 #91、#94、#96。
>
> 範圍：交接草案的 P1（停放條件）、P2（費率）、P3（資格判斷）、P4（三端契約與 App／管理站接入）。草案的 P5（既有資料轉換）在本文寫成和 stack B P6 匯入的銜接規則；草案的 P6（相容與驗收）在本文 §5。P0（身障資格文字、汽機共用誤分類、本機套件解析）已決定馬上修，不在本文範圍，但本文的轉換層會取代 P0 修過的 `reportedAccess` 分支。

## 0. 用詞

| 本文 | 意思 | 來源 |
| --- | --- | --- |
| 普通 | 普通重型機車（`VehicleType.scooter`） | 需求 2 |
| 大型 | 大型重型機車（`VehicleType.heavy`） | 需求 2 |
| 專用 | 大型重機專用格 | 需求 2 |
| 汽車 | 一般汽車格（小型車） | 需求 2 |
| usual／share | 格位用途：依格位本身車種使用／公告指定的共用格 | 需求 3 |
| Toll／Free | 收費屬性：收費格／免費格 | 需求 3 |
| 未確認 | 資料沒有提供或無法判定。一律不回退成別的車種、別的分區或場站的值 | 法規 B |

## 1. 概念模型

### 1.1 七個面向

停放條件拆成七個彼此獨立的面向。前四個描述「這是什麼格位」，後三個描述「誰、何時、怎麼停」。

| 面向 | 值 | 存放位置 | 說明 |
| --- | --- | --- | --- |
| 位置 placement | `on_street`（路邊）／`off_street`（路外） | 不新增欄位，由 `space_type` 與 `facility_type` 推導 | `space_type='offStreet'` 或 `facility_type` 為 `multiStorey`／`underground`／`surface` 即路外，其餘為路邊。#94 的 `lot_roadside`、`street_lot_details` 已經擋下互相矛盾的組合 |
| 停車場允許車種 | 普通／大型各為 可進場／不可進場／未確認 | 既有 `scooter_allowed`、`heavy_allowed`（路外點） | 只代表**能不能進場**，不代表有可停的格位（需求 5、DESIGN.md「兩種車種都可進入停車場，不足以推定共用同一格位」） |
| 區域 area | `motorcycle`（機車區）／`car`（汽車區）／`heavy`（重機專區）／`mixed`（混合）／未填 | 新增 `parking_zones[].area` | 只用於路外分區。機車區依公告適用機車或重機費率，汽車區依公告適用汽車費率（需求 5） |
| 格位 bay | 類別 `motorcycle`／`heavy`／`car` ＋ 用途 `usual`／`share` | 新增 `condition.bay`、`condition.use`、`condition.share` | 共用分兩種，不能混用（需求 4）：`scooter_heavy`（普大共用，畫在機車格上）、`car_motorcycle`（汽機車共用，畫在汽車格上，本專案只列路邊） |
| 收費屬性 charge | `toll`／`free`／未填 | 新增 `condition.charge` | Toll 方案的首段可以是 0 元，仍是 Toll，不等於 Free（法規 D） |
| 限制 limits | `kind` 是限制類型：`time_limit`（限時，另帶 `max_minutes`）、`special_vehicle`（限特製車輛，另以 `vehicle` 鍵寫車型，目前只有 `disabled_modified`）、`ev_only`（限電動機車） | 新增 `condition.limits[]` | 身障專用機車格是 `{"kind":"special_vehicle","vehicle":"disabled_modified"}`：須為經監理單位檢驗合格的特製機車，持識別證本身不足（法規 C）。`kind` 只放限制類型，車型一律放 `vehicle`，兩者不共用鍵 |
| 分區明確車種 allow | 普通／大型各為 `true`／`false`，缺鍵＝依法規與公告 | 新增 `parking_zones[].condition.allow` | 保存分區的明確排除與開放，例如普機專用 `{"scooter":true,"heavy":false}`、機車不可停 `{"scooter":false,"heavy":false}`。只用在分區；路邊點沿用既有 `scooter_allowed`／`heavy_allowed`，不另存一份 |
| 時段 schedule | 多段 `{days, from, to, vehicles}` | 新增 `condition.schedule[]` | 汽機彈性共用依平日／假日／時段切換允許車種（法規 E）；沒有涵蓋的時間為未確認 |

資格（誰能停）與價格（要付多少）不在 `condition` 裡：資格由 §3 的判斷函式依法規、公告與上述面向計算；價格存在 `fee`（§2）。

### 1.2 組合成「停放條件」

一個 `condition` 物件同時用在兩個層級：

- **路邊點**：點位頂層 `condition`，描述這個格位（或這一段格位）。
- **路外點**：點位頂層 `condition` 為 null，每個分區各有 `parking_zones[].condition`；分區另有 `area`。路外點頂層的 `scooter_allowed`／`heavy_allowed` 仍是「停車場允許車種」。

```text
停放條件 = 位置（推導） × [停車場允許車種 → 區域] × 格位（類別＋用途） × 收費屬性 × 限制 × 時段
          └ 路外才有 ┘
```

`condition` 的 JSON 契約（所有鍵都可省略，省略即未確認。未確認**一律以省略鍵表示**：`limits`、`schedule` 不收空陣列，`allow` 不收空物件，分區不收空的 `condition`。分鐘、金額等整數欄位接受沒有小數部分的數字，`20.0` 視同 `20`，`20.5` 不合法。`basis` 的日期年份須在 1900–9999（Postgres 沒有 0 年）；`source_url` 最長 2048 個 UTF-16 code unit（BMP 以外的字元算 2）。以上三端一致）：

```json
{
  "bay": "motorcycle",
  "use": "share",
  "share": "scooter_heavy",
  "charge": "toll",
  "limits": [{ "kind": "time_limit", "max_minutes": 20 }],
  "schedule": [
    { "days": "weekday", "from": "07:00", "to": "20:00", "vehicles": ["car"] },
    { "days": "weekday", "from": "20:00", "to": "07:00", "vehicles": ["car", "scooter"] }
  ],
  "basis": {
    "source_url": "https://…",
    "evidence_id": null,
    "effective_date": "2026-10-06",
    "expires_on": null
  }
}
```

- `use='share'` 時 `share` 必填；`use='usual'` 時不得有 `share`。
- `schedule[].days` 為 `all`／`weekday`／`holiday`，或星期陣列 `["mon",…]`；`from > to` 表示跨午夜。`from` 與 `to` 不可相同；**全天以同時省略 `from` 與 `to` 表示**（例：`{"days":"holiday","vehicles":["car","scooter"]}`），不寫 `00:00`–`24:00`，只省略其中一個不合法。`schedule` 最多 8 段；費率 `by_time.periods` 的時段用同一套規則（最多 6 段，§2.2）。`vehicles` 為該時段允許停放的車種（`scooter`／`heavy`／`car`）。汽機車共用格（`share='car_motorcycle'`）的機車涵蓋範圍不預設，只認 `vehicles` 依公告寫明的車種，沒寫的車種為待確認（§7 第 1 項，已決定）。
- `basis` 記錄這個條件本身的公告依據（例如臺北 36 處試辦場域的分區），與 `city_rules` 分開。`expires_on` 已過即視為依據失效（§3.3）。依據的種類與照片規則見 §1.4。
- 「特殊車型及地方特別開放另處理」（需求 6）：特殊車型用 `limits[]` 的 `{"kind":"special_vehicle","vehicle":…}`；地方開放仍放在 `city_rules`，不寫進格位。
- 身障專用機車格的完整範例：

```json
{"space_type":"disabledMotorcycle",
 "condition":{"bay":"motorcycle","use":"usual","charge":"free",
              "limits":[{"kind":"special_vehicle","vehicle":"disabled_modified"}]}}
```

- 分區的 `allow` 範例（普機專用的機車區）：

```json
{"name":"B1 機車區","area":"motorcycle",
 "condition":{"bay":"motorcycle","use":"usual","charge":"toll",
              "allow":{"scooter":true,"heavy":false}}}
```

### 1.3 與 `SpaceType` 的單一轉換層

`space_type` 有 9 個 wire 值（`paidMotorcycle`…`evMotorcycle`），被兩版 viewport、收藏快照、`validate.ts`、`city_rules.allowed_space_types`、資料表 check 與舊版 App 使用，**保留不動**。新增的 `condition` 是唯一的權威狀態；`space_type` 在有 `condition` 時一律由它推導，不各自編輯，避免雙份狀態。

轉換只有一份，放在 `lib/models/parking_condition.dart`（Dart）與 `supabase/functions/_shared/parking_contract.json`（共用資料，§4）。SQL 的 `condition_space_type()` 依同一份資料實作，並由共同測試向量比對：

**讀取：`conditionOf(spot)`（`condition` 為 null 的既有資料）**

| `space_type` | 推導出的 condition | 備註 |
| --- | --- | --- |
| `paidMotorcycle` | bay=motorcycle, use=usual, charge=toll | |
| `freeMotorcycle` | bay=motorcycle, use=usual, charge=free | |
| `heavyOnly` | bay=heavy, use=usual, charge 未確認 | |
| `car` | bay=car, use=usual, charge 未確認 | |
| `offStreet` | null（看分區） | |
| `disabledMotorcycle` | bay=motorcycle, limits=[{kind:special_vehicle, vehicle:disabled_modified}] | 修正法規 C |
| `timedMotorcycle` | bay=motorcycle, use=usual, limits=[time_limit]，charge **未確認** | 現行把它一律當 `paidMotorcycle`，無法表達限時免費格 |
| `flexShared` | bay=car, use=share, share=car_motorcycle，schedule 未確認 | 取代 `reportedAccess` 把它推成普大共用的分支 |
| `evMotorcycle` | bay=motorcycle, limits=[ev_only] | |

分區沒有 `condition` 時，由既有 `access` 推導，明確排除一律寫進 `allow`，不會在轉換中遺失：`scooterOnly`→機車格 usual，`allow={scooter:true,heavy:false}`；`scooterHeavy`→機車格 share=scooter_heavy，`allow={scooter:true,heavy:true}`；`heavyCar`→汽車格 usual，`allow={scooter:false,heavy:true}`（大型重機依法可停汽車格）；`heavyOnly`→重機格 usual，`allow={scooter:false,heavy:true}`；`noMotorcycle`→bay 未填，`allow={scooter:false,heavy:false}`；null→未確認。反向推導 `access` 時也先看 `allow`，所以兩者一一對應。`access` 保留為舊版相容欄位，有 `condition` 時由轉換層推導寫回，不另外編輯。

**寫入：`legacySpaceType(condition, placement)`（有 `condition` 的資料）**

依序比對，第一個符合的就是 `space_type`：路外→`offStreet`；`special_vehicle`→`disabledMotorcycle`；`ev_only`→`evMotorcycle`；`share=car_motorcycle`→`flexShared`；`time_limit`→`timedMotorcycle`；bay=heavy→`heavyOnly`；bay=car→`car`；bay=motorcycle 且 charge=toll→`paidMotorcycle`；bay=motorcycle 且 charge=free→`freeMotorcycle`。

**舊版能不能正確表示（`legacySafe`）**：condition 依上表轉回 `space_type`，再用 `conditionOf` 讀回來，結果與原 condition 相同（或只少了舊版本來就當成未確認的資訊），才算 legacy-safe。例如：

- 機車格、共用 scooter_heavy、Toll → `paidMotorcycle`，安全（舊版依縣市規則判斷，結果一致或更保守）。
- 機車格、沒有限制且 charge 未確認 → 沒有對應的舊值。`space_type` 不可為空，因此這個組合不允許寫入（§4.3）：回報者必須選收費或免費格，與現行表單一致；真的無法判斷時不寫 `condition`。
- 有 `schedule` 的重機格、有 `basis.expires_on` 的條件 → 舊版會忽略時段或期限，**不安全**。
- 限時格且 charge=free → `timedMotorcycle`，舊版當成收費限時格，資格可能較寬鬆，**不安全**。
- **路外點要檢查每個分區**：分區的 condition 能由 `access` 完整表達（沒有 `schedule`、`limits`、`basis.expires_on`，`allow` 能對到一個 `access` 值）才算安全。任一分區不安全，整個場站就不安全。例：§2.4 機車區帶 `basis.expires_on`，舊版會忽略期限，照 `access=scooterHeavy` 顯示大型重機可停，所以這個場站不安全。

**精確定義**（C1 實作，使用者 2026-10-26 同意；規則資料在 `parking_contract.json` 的 `conversion.legacy_safe`，案例檔逐條列出正反例）：先 `legacySpaceType` 再 `conditionOf`，與原 condition 比較時**只允許遺失**：

- (a) `share='scooter_heavy'` 讀回 `use='usual'`。
- (b) 沒有 `expires_on` 的 `basis`（`source_url`、`evidence_id`、`effective_date`）。
- (c) `time_limit.max_minutes`。
- (d) 讀回後為未確認的面向（bay、use、share、charge，即 `lossy_when_unconfirmed`；例如 `heavyOnly` 讀回沒有 charge，`disabledMotorcycle` 讀回沒有 use 與 charge），但 `assumed_charge` 列出的舊值除外：舊版把 `timedMotorcycle` 當收費格，所以限時格的 charge 只能是 toll 或未確認。例：重機格＋toll 安全；限時格＋free 不安全；限時格＋toll 安全。反方向（原本未填、讀回後有值，例如 `{"bay":"heavy"}` 讀回 `use='usual'`）不算遺失，判為不安全。

有 `schedule`、`basis.expires_on` 或其他差異一律不安全。**分區**：依 `allow`（`from_access` 有 bay 時再比對 bay）推導 `access`，再由 `from_access` 讀回，可遺失 (b) 與讀回後未確認的面向（例如 charge）；有 `limits` 或 `schedule` 即不安全，對不到 `access`（`allow` 缺鍵或組合不存在）也不安全。路外點頂層不得有 `condition`，所有分區都安全才算安全。

不安全的資料在**所有版本**的 viewport（原版、v2）與收藏中都改用保守投影（§5.2、§5.3）。

### 1.4 公告依據：網址或現場牌面照片（使用者 2026-10-26 補充）

`condition.basis` 必須有 `source_url`（公告網址）**或** `evidence_id`（現場牌面照片），兩者擇一即可，也可以兩者都有。

- **照片走核實計畫 P2 的 `spot_evidence`**，依使用者 2026-10-25 對 P2 的拍板：照片存在私有 bucket，只有管理員看得到（P2 D1）；本人可以看自己還沒審的原圖（D3）；保留期依狀態分級（D2），用於核實的照片保留到核實到期後 30 天。
- **照片計入依據的前提**：審核者確認照片是**這個場站或路段的牌面**，而且**內容與要寫入的條件相符**（`spot_evidence.content_state='confirmed'`）。未確認、被拒或與其他點位共用的照片不計入。P2 只開放管理員確認；之後由 L3 確認時沿用研究文件 §5.1、§5.2 的規則。
- **P2 照片上傳上線前只能附網址**：`evidence_id` 的鍵先保留在契約裡（C1），在 P2 的 `spot_evidence` 合併以前，三端都拒收帶 `evidence_id` 的資料。
- **寫入的人**：`condition.basis` 只由管理員或匯入寫入。車友不能直接寫 `basis`，但送出時可以附上依據（網址或照片），作為審核案件的證據；管理員採納時才把它寫進 `basis`。管理員 RPC 會檢查 `evidence_id` 存在、屬於同一個點位、而且內容已確認。
- **公開 view 不暴露照片**：`basis.evidence_id` 在 viewport 輸出時改寫成 `{"evidence":"photo","confirmed_at":"…"}`，不帶 id 和網址；App 顯示「依據：現場牌面照片（管理員確認於 YYYY-MM-DD）」。照片公開要等 P2 D1 的手動遮蔽流程。
- **期限**：照片沒有網址可以查生效日和截止日，管理員依牌面內容填 `effective_date`、`expires_on`；牌面沒寫就留空。照片依據在核實計畫 §5.3 的有效期內才算數，預設依「費率與收費方式」的 30–90 天，時段與限制比照。期限過了之後只是依據失效、回到待確認，資料不會刪除。

各處需要「公告依據」的地方一致處理如下：

| 需要依據的資料 | 網址 | 牌面照片 | 理由 |
| --- | --- | --- | --- |
| 普大共用的免費格（§4.3） | 可 | 可 | 使用者 2026-10-26 指定 |
| 格位的共用標示、汽機共用的時段與車種（§1.2、§7 第 1 項） | 可 | 可 | 現場牌面就是公告本身 |
| 限時、限電動、身障特製機車等格位限制 | 可 | 可 | 同上 |
| 場域試辦（分區 `basis`，例如臺北 36 處） | 可 | 可（網址優先，因為期限寫在新聞稿附件） | |
| 路外場站業者的車種規則 | 可 | 可 | 核實計畫 §5.2 本來就要求入口公告照片 |
| 縣市規則 `city_rules`（地方開放、行政區、試辦期限） | 必須 | **不可**當規則來源，只能作為研究文件 §5.7 的 `rule_evidence` 現場佐證 | 縣市法規只能依官方法規或主管機關公告發布（核實計畫 §3.3 A 類） |

## 2. 費率模型

### 2.1 範圍

在既有 `Fee { scooter, heavy }` 加上 `car`（使用者 2026-10-26 決定納入汽車結構化費率），並擴充 `Rate`。原則不變：

- 缺少的車種＝未確認。沒有重機費率時**不回退成機車費率**；只有公告明定比照時才寫 `same_as_*`（法規 B）。
- 比照只在**同一條計費規則**（§2.6 的 `fee_plans[]` 一條，相當於原本的一個 `fee` 物件）內解析：`heavy: same_as_car` 找同一條規則的 `car`，找不到就是未確認，不找其他規則或點位（#80 的決定延伸）。
- 每種收費方式只能帶自己使用的鍵；未知的鍵讓整個車種讀成未確認（既有 `Rate.fromJson` 行為，也是舊版 App 讀到新格式時的保守結果）。

### 2.2 Rate 契約 v2

```text
fee  = {"scooter": rate, "heavy": rate | follow, "car": rate}
follow = {"mode":"same_as_scooter"|"same_as_car"[,"factor_pct":n]}   只有 heavy 可用
rate = {"mode":"free"} | {"mode":"posted"}
     | {"mode":"hourly","amount":元,"per_minutes":分
          [,"unit_minutes":分][,"free_minutes":分][,"daily_cap":元][,"cap_reset":r]}
     | {"mode":"per_visit","amount":元[,"max_minutes":分][,"renew":w][,"extension":ext]}
     | {"mode":"daily","amount":元[,"cap_reset":r]}
     | {"mode":"by_time","periods":[{"days":d,"from":"HH:MM","to":"HH:MM","rate":rate}]
          [,"cross_period":c]}
ext  = {"amount":元,"max_times":n[,"minutes":分]}
r    = "calendar_day" | "rolling_24h" | "per_entry"
w    = "none" | "midnight"                    計次是否隔日另計，缺＝未確認
c    = "each_period" | "entry_only"           計次跨時段怎麼計，缺＝未確認
```

| 新鍵 | 意思 | 範圍 | 缺值 |
| --- | --- | --- | --- |
| `factor_pct` | 比照倍率，200＝2 倍 | 整數 100–1000 | 1 倍 |
| `unit_minutes` | 計費單位（例：每小時 20 元、半小時計） | 1–`per_minutes` | 未確認計費單位（顯示時不寫單位） |
| `free_minutes` | 免費前段（Toll 方案首段 0 元） | 1–1440 | 沒有免費前段 |
| `cap_reset` | `daily_cap`／`daily` 何時重新起算 | 三選一 | 未確認（顯示上限，加註「上限計算方式未確認」） |
| `max_minutes` | 計次有效時間（既有） | 1–1440 | 未確認 |
| `renew` | 計次是否隔日另計：`none`＝不另計（停多久都只收一次）、`midnight`＝隔日另計（跨過每日零時重新計次）。只用於 `per_visit`，`by_time` 內每一段計次各自設定 | `none`／`midnight` | **未確認**。「沒填」不代表「不另計」（§2.5） |
| `by_time.cross_period` | 停放跨進另一個計次時段時怎麼計：`each_period`＝每進入一個計次時段依該段費率另計一次、`entry_only`＝只依進場時段的費率計 | 二選一 | **未確認**（§2.5、§7 第 7 項，已決定） |
| `extension` | 付費延長：每次金額、最多次數、每次分鐘 | 金額 0–10000、次數 1–10、分鐘 1–1440 | 沒有 `extension`＝未確認可否延長；`minutes` 缺＝延長時長未確認 |
| `by_time.periods` | 時段差別費率，最多 6 段（§2.5）；內層 `rate` 不可再是 `by_time` 或比照 | | 沒有涵蓋的時間＝未確認 |

- `car` 不可用 `same_as_*`；`scooter` 也不可（既有規則）。
- 時段費率不寫 `holiday` 以外的節日。本輪不依目前時間選用時段費率，只逐段顯示（§7 第 4 項，已決定）。
- 資料表 `valid_fee()` 的大小上限由 1024 bytes 提高到 8192 bytes，以容納 `by_time`。上限刻意大於契約允許的最大費率（`tool/fee_text.py` 的 `largest_fee`，pg_column_size 約 5.8 KB，三端共同測試），合法形狀的費率不會因大小被任何一端拒絕（C3 Codex 審查：JSON 字數與 `pg_column_size` 算法不同，原本 4096 會讓三端判斷不一致）。

### 2.3 Toll 首段 0 元 ≠ Free

`charge='toll'` 的格位，費率可以是 `per_visit` `amount:0`＋`max_minutes`，或 `hourly`＋`free_minutes`；顯示為「首 20 分鐘 0 元」，**不**顯示「免費」，也不讓價格篩選把它當成免費格。只有 `mode:'free'` 才是免費。組合規則見 §4.3。

#94 在研究文件 §5.8 留下的階段 1 候選規則「計次或每日 0 元」會誤攔臺北限時格（首 20 分鐘 0 元）。實作這條規則時，**必須排除帶 `max_minutes` 的 `per_visit` 費率**（`amount:0`＋`max_minutes` 正是 Toll 首段 0 元的寫法），只攔沒有 `max_minutes` 的計次 0 元與 `daily` 0 元。這項排除列入 stack C 的 C5 範圍（§6），由 `precheck_rules.json` 的規則參數與 `precheck_cases.json` 的不誤攔案例（臺北限時格）固定下來；如果階段 1 先於 C5 實作，就由實作階段 1 的 PR 一併做到。

### 2.4 臺北實例

以下金額除臺北路邊新制外都是示意，結構才是重點；實際值以匯入時的公告為準。

**(a) 路邊收費機車格，大型重機新制（115/10/6 起，停管處 115/9/30 公告）**

公告原文：計次路段「每次新臺幣 40 元」「凡跨越每日零時停車者，累計收費」（即隔日另計，下方計次路段範例的 `renew:'midnight'`）；計時路段「每小時新臺幣 20 元，停車當日上限為 100 元」「停車計費單位採半小時計算」；限時停車格「首單新臺幣 0 元，限停 20 分鐘（得付費新臺幣 40 元延長 1 次停放）」。來源：https://pma.gov.taipei/News_Content.aspx?n=E43F2E5AE1223B3D&s=1190C312983454BA&sms=78D644F2755ACCAA

```json
// 計次路段
{"space_type":"paidMotorcycle",
 "condition":{"bay":"motorcycle","use":"usual","charge":"toll"},
 "fee":{"heavy":{"mode":"per_visit","amount":40,"renew":"midnight"}}}

// 計時路段
{"space_type":"paidMotorcycle",
 "condition":{"bay":"motorcycle","use":"usual","charge":"toll"},
 "fee":{"heavy":{"mode":"hourly","amount":20,"per_minutes":60,"unit_minutes":30,
                 "daily_cap":100,"cap_reset":"calendar_day"}}}

// 限時停車格
{"space_type":"timedMotorcycle",
 "condition":{"bay":"motorcycle","use":"usual","charge":"toll",
              "limits":[{"kind":"time_limit","max_minutes":20}]},
 "fee":{"heavy":{"mode":"per_visit","amount":0,"max_minutes":20,
                 "extension":{"amount":40,"max_times":1}}}}
```

- 三例的 `scooter` 都省略：普通機車在這些路段的費率不在這份公告，屬未確認，不因大型重機有值而推定。
- 限時格延長一次的時長，公告頁沒有寫，因此 `extension.minutes` 省略（待查證）。
- 公告頁沒有提到斜停兩格；斜停仍由 `city_rules.can_use_two_spaces` 表達，不放在費率裡。
- 來源格點無法分辨計次或計時路段時（PLAN.md 匯入說明），匯入不寫 `fee`，維持文字，不挑一個寫入。

**(b) 路外試辦場域（36 處，115/4/6 首波 24 處、115/7/6 新增 12 處）**

PLAN.md 匯入紀錄：「依停管處新聞稿附件補上『機車區』與機車費率 2 倍的重機費率；試辦期限已屆，是否延續須以現場公告為準。」交接法規 B：機車區為機車費率 2 倍，汽車區為小型車費率。臺北市公有停車場收費費率自治條例附表亦載「大型重型機車：依小型車費率計收」（附表版本與是否已修正待查證）。

```json
{"space_type":"offStreet","facility_type":"underground",
 "heavy_allowed":true,"zones_complete":false,
 "parking_zones":[
  {"name":"機車區","area":"motorcycle","access":"scooterHeavy",
   "condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"toll",
     "basis":{"source_url":"https://…（停管處新聞稿附件）",
              "effective_date":"2026-04-06","expires_on":"2026-10-05"}},
   "fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60},
          "heavy":{"mode":"same_as_scooter","factor_pct":200}}},
  {"name":"汽車區","area":"car","access":"heavyCar",
   "condition":{"bay":"car","use":"usual","charge":"toll"},
   "fee":{"car":{"mode":"hourly","amount":40,"per_minutes":60},
          "heavy":{"mode":"same_as_car"}}}]}
```

- 機車區的 `expires_on` 為示意：各場域的試辦期限須逐處以附件核對（待查證）。期限已過時，機車區的大型重機資格依 §3.3 顯示待確認；費率仍可顯示，但標示「試辦期間費率」。
- 汽車區的大型重機資格來自汽車格本身（標誌標線號誌設置規則 §190，見 `eligibility.dart` 註解），不依賴試辦公告，所以 `basis` 省略。
- 機車區的 `heavy` 寫「比照機車 2 倍」，而不是直接寫 20 元：公告的寫法是倍率，機車費率之後調整時不必兩邊同步改。

### 2.5 計次的隔日另計（使用者 2026-10-26 要求）

**三態，缺欄位就是未確認。** 計次費率的 `renew` 只有兩個值，加上缺欄位共三態：

| 狀態 | JSON | 編輯器選項 | 費率文字（`feeNoteOf`／`fee_note_of`） |
| --- | --- | --- | --- |
| 隔日另計 | `"renew":"midnight"` | 隔日另計 | 每次 40 元，隔日另計 |
| 不另計 | `"renew":"none"` | 停多久都只收一次 | 每次 40 元，停多久都只收一次 |
| 未確認 | 不帶 `renew` | 未確認 | 每次 40 元（隔日是否另計未確認） |

- 這與「缺值一律未確認」一致：既有 `per_visit` 資料（C3 之前寫入的）都沒有 `renew`，C3 合併後一律讀成未確認，不推定為不另計。
- 帶 `max_minutes`（計次有效時間）時，「停多久都只收一次」改寫成「有效時間內只收一次」，例：「每次 30 元（3 小時內），隔日另計」。
- `PriceAnswer`（§3.2 第 4 步）在 `renew` 未確認時回 `partial`，缺口為「隔日是否另計」。價格比較之後只能把它當成「至少每次 40 元」。
- 舊版 App 讀到 `renew` 是未知鍵，該車種整個讀成未確認（§2.1），保守。
- C3 的 migration 要對已有 `fee` 的列依新句子重算 `fee_note`：新句子會多出「（隔日是否另計未確認）」，不重算的話，管理員下次改費率時會被 #96 的 `fee_note_matches` 擋下。

**時段差別費率裡的計次。** `by_time` 的每一段如果是 `per_visit`，各自帶 `renew`，例如白天計次不另計、夜間計次隔日另計。停放跨進另一個時段時怎麼計，由 `by_time` 層級的 `cross_period` 決定，同樣是三態：

- `each_period`：每進入一個計次時段，就依該段費率再收一次。
- `entry_only`：只依進場時段的費率計，換時段不另收；之後只看進場時段那一段的 `renew`。
- 缺欄位：未確認，`PriceAnswer` 回 `partial`，缺口為「跨時段如何計費」。

同一時刻同時發生跨時段與跨日（時段正好在 00:00 切換）時，**只收一次**，金額用新時段的費率。

**範例**（示意金額，結構才是重點）：白天 08:00–20:00 每次 30 元，夜間 20:00–08:00 每次 50 元。18:00 進場，隔天 09:00 離場。

| `cross_period` | 白天 `renew` | 夜間 `renew` | 收費時點 | 合計 |
| --- | --- | --- | --- | --- |
| `each_period` | `none` | `none` | 18:00 白天 30、20:00 夜間 50、08:00 白天 30 | 110 元 |
| `each_period` | `none` | `midnight` | 上列，加 00:00 夜間隔日另計 50 | 160 元 |
| `entry_only` | `midnight` | （不適用） | 18:00 白天 30、00:00 依白天費率隔日另計 30 | 60 元 |
| `entry_only` | `none` | （不適用） | 18:00 白天 30 | 30 元 |
| 未確認 | — | — | 只能確定進場時收 30 | 至少 30 元（未確認） |

如果夜間改成 00:00–08:00，那麼 00:00 同時是跨日和換時段：`each_period` 時只依夜間費率收一次，不會收兩次。

**長度上限**：兩張點位表的 `char_length(fee_note) <= 200` 約束與 `submit-report/validate.ts` 的 200 字上限，容不下多時段費率逐段串接的句子，而 `fee_note = fee_note_of(fee)` 不放寬。C3 因此一併處理：(1) 契約限制 `by_time` 最多 6 段；(2) 依契約允許的最長組合（每個車種都是 6 段計次，含有效時間、隔日另計、跨時段計法）算出 `fee_note_of` 的最大長度，把兩表的 check 與 `validate.ts` 的上限改成同一個值（由 `tool/gen_contract_sql.py` 從契約產生，不手寫數字）；(3) 加一個測試，用這個最長組合呼叫 Dart、SQL、Deno 三端的句子函式，確認結果都不超過上限。回報者自由填寫的備註仍維持原本的長度限制。

`by_time` 的費率文字會逐段寫出，最後一句寫跨時段的計法，例如：「每天：08:00–20:00 每次 30 元，停多久都只收一次；20:00–隔日 08:00 每次 50 元，隔日另計；跨時段分別計費」。三種說法分別是 `each_period` 寫「跨時段分別計費」、`entry_only` 寫「依進場時段計費」、缺欄位寫「跨時段計費方式未確認」。

**C3 實作的句子規則**（`fee_note_of`／`feeNoteOf`／`tool/fee_text.py` 共用，`parking_contract_cases.json` 的 `fee_notes` 逐條固定）：

- 車種依「機車、大型重機、汽車」排列，以「；」相接，每段前面寫車種；大型重機費率未知時最後加「大型重機費率未確認」；沒有任何已知車種時維持「請依現場公告」。例：「機車每小時 10 元；大型重機每小時 20 元」「汽車每小時 40 元；大型重機費率未確認」。
- 比照一律寫算好的金額（#140），倍率套在金額、當日上限與延長金額，最多兩位小數（每次 15 元 ×150% →「每次 22.5 元」）；被比照的車種未確認時寫「大型重機費率未提供」。
- `posted`（依現場公告）與只有 `posted` 時段的 `by_time` 讀成未確認（§7 第 15 項）。
- `by_time` 依時段涵蓋的日子分組，依出現順序寫「每天：」「平日：」「假日：」或指定的星期（「週六：」「週一、週三：」），組內各段以「；」相接；跨午夜寫「20:00–隔日 08:00」，全天寫「全天」。有 `cross_period`，或有兩段以上計次時，最後加跨時段的說法。
- 計時：「首 30 分鐘 0 元，之後每小時 10 元（以 30 分鐘計），當日上限 100 元（零時重算）」；上限重算方式未填寫「（上限計算方式未確認）」。計次首段 0 元（金額 0 且有有效時間）寫「首 20 分鐘 0 元」，不寫隔日是否另計。延長寫「，可付 40 元延長 1 次（每次 20 分鐘）」，沒有分鐘寫「（延長時間未確認）」。
- 長度上限 `fee_note_max_length()` 由 `tool/fee_text.py` 依契約算出（目前 1909 字），寫在 `supabase/functions/_shared/fee_note_limit.json`；兩表的 `fee_note` check 改為「200 字以內，或等於 `fee_note_of(fee)` 且不超過上限」，`validate.ts` 同樣只讓費率本身的句子超過 200 字。

**編輯器（`FeeEditor` 擴充，C3 做元件、C5／C6 接入表單）**

- 選擇「計次」後出現「跨日怎麼收」單選，三個選項依序為「隔日另計」「停多久都只收一次」「未確認」，**預設選「未確認」**，不替回報者推定。有填有效時間時，第二個選項改為「有效時間內只收一次」。
- 時段費率的每一段是計次時，各自有同樣的單選。有兩段以上計次時，另外出現「停到下一個時段時」單選：「進入新時段再收一次」「只依進場時段收」「未確認」，預設「未確認」。
- 單選下方即時顯示 App 會呈現的費率文字（沿用 #96 的公告牌預覽），讓回報者看見選擇的結果。
- 觸控目標 ≥ 48 px，在 320 px、1.6 倍字級時選項換行，不水平捲動。

### 2.6 格位與計費規則分離（使用者 2026-10-26，停放條件畫布 C6 留言）

管理站要能在同一個區域登錄多種格位，而幾種格位常常同價。因此**計費規則獨立於格位**：

- **點位層新增 `fee_plans`**：計費規則清單，每條 `{ "id": "p1", "name": "機車計時", "fee": Fee }`。`id` 在同一點位內唯一（`[a-z0-9_-]{1,20}`），`name` 1–20 字，只給管理員辨識，App 不顯示；`fee` 沿用 §2.2 的 v2 契約。最多 12 條。
- **分區改為引用規則**：`parking_zones[].fee_plan`（規則 `id`）取代分區自己的 `fee`。一個分區仍然只有一種格位（C1 契約不變：`condition.bay` 單值）；「同一區域多種格位」在資料上是多個 `area` 相同的分區，管理站畫面把它們合成一張區域卡（§8.4）。
- **規則可以只對部分車種有值**：例如「重機計時」只有 `heavy`。分區對某車種的費率＝它引用的規則中該車種的值；規則沒有這個車種＝未確認。
- **路邊點**沒有分區，點位直接用 `fee_plan` 引用一條規則（或沿用點位 `fee`，見下方相容）。
- **App 顯示不變**：公告牌仍逐分區、逐車種顯示解析後的費率（§8.4），騎士看不到規則名稱。
- **相容與遷移（C3）**：
  - 既有資料的分區 `fee` 與點位 `fee` 在 C3 的 migration 中轉成規則：相同內容的 `fee` 合併成同一條規則，名稱依車種與收費方式自動產生（例：「機車計時」），分區改寫成 `fee_plan`。
  - 讀取端在過渡期同時支援兩種寫法：分區或點位有 `fee_plan` 時用規則，否則讀它自己的 `fee`。舊版 App 只認得後者，所以 viewport v2 與原版要把規則**展開回** `fee` 再回傳：分區的引用展開成分區 `fee`，路邊點的點位層引用展開成頂層 `fee`（既有 `ParkingSpot.fromJson` 只讀頂層 `fee`）。與 §5.2 的投影同一處處理。
  - 收藏 JSON 一律存展開後的 `fee`（分區 `fee` 與頂層 `fee` 皆是），不存規則（收藏只需要顯示結果）。
  - 修改建議（§5.4）仍以「分區 × 車種」為單位提出；管理員採納時，若該規則被多個分區引用，審核頁要問「只改這個分區（另開一條規則）」或「改這條規則（影響 N 個分區）」，預設只改這個分區。
- **契約與驗證**：`fee_plans` 與 `fee_plan` 的鍵、長度、條數、引用存在性，加入 C3 的契約更新與 `valid_fee_plans()`；引用不存在的規則＝寫入拒絕。
- **預檢以分區為單位投影**：一條規則可同時服務多種格位（例如同價的機車格與重機格共用含 `scooter`、`heavy` 的規則），所以分兩步：(1) 規則本身的檢查（含比照依賴，如 `fee_follows_missing_scooter`）對**完整規則**執行，並先依 §2.1／§3.2 把比照解析成實際費率；(2) §4.3 的組合檢查再把解析後的規則**投影到該分區適用的車種**（bay=heavy 只取 `heavy`；其他格位取分區 `allow` 允許的機車車種，`car` 照原樣保留）再檢查。規則中供其他格位使用的車種不算此分區的費率，不觸發「bay=heavy 而有 `fee.scooter`」等規則；§4.3 各列的 `fee` 指的都是這份投影後的分區費率，汽車格開放機車仍需依據的檢查照常適用。分區自己寫 `fee`（未改用規則）時不投影，§4.3 照原文檢查。公告牌（§8.4）也只顯示投影後的車種。

## 3. 資格判斷（P3）

### 3.1 現況問題（交接程式對照）

1. `eligibility()` 不讀 `fee` 與 `zones`，路外只看場站旗標：官方場站 `heavyAllowed=true`、已列分區皆 `scooterOnly` 時仍回 `allowed`。
2. 反過來也不行：分區資料可能不完整，不能因為已知分區都不可停就推定全場禁停。
3. `timedMotorcycle` 一律映射 `paidMotorcycle`，無法表達限時免費格。
4. 身障理由只提識別證（P0 先改文字，P3 改成 `special_vehicle` 限制）。
5. `CityRule` 有生效日與行政區，沒有截止日與結構化時段。

### 3.2 判斷順序

新增純函式 `decideParking(spot, vehicle, rules, {now}) → ParkingDecision`，放在 `lib/domain/parking_decision.dart`。既有 `eligibility()` 改為它的薄包裝，回傳同一個 `Eligibility(status, reason, restriction)`，地圖標記、搜尋排序與 #91 的 `eligibilityDisplay()` 不必同時改。

```text
0. 資料可信度   既有語意：未核實的社群說法不能讓結果變成「可停」或「不可停」
1. 法定資格     車種 × 格位類別 × 限制（不看縣市）
2. 地方公告     匹配有效公告：縣市、車種、生效日 ≤ now < 截止日、行政區、時段
3. 場站／分區／格位  路外：場站允許車種 → 逐區判斷；路邊：格位本身的 condition
4. 價格         與 1–3 分開，回傳每個可停處的價格是否已知
```

**1. 法定資格**（全國一致，任何公告都要先過這一關）

| 格位 | 普通 | 大型 |
| --- | --- | --- |
| 機車格 usual | 進入第 2 步 | 進入第 2 步（是否開放由地方公告決定，法規 A） |
| 機車格 share=scooter_heavy | 進入第 2 步 | 進入第 2 步；共用標示本身就是公告的一種，但仍須有效 |
| 重機格 | 不可停 | 進入第 2 步 |
| 汽車格 usual | 不可停，除非地方公告開放（需求 6；`eligibility.dart` 引 §112 末段） | 依法可停 |
| 汽車格 share=car_motorcycle | 只在 `schedule[].vehicles` 依公告寫明 `scooter` 的時段可停；沒寫就是待確認，不預設（§7 第 1 項，已決定） | 依法可停汽車格，不受共用標示影響；`schedule` 寫明 `heavy` 時另顯示該時段 |
| `special_vehicle`（`vehicle:'disabled_modified'`） | 有條件：「限經監理單位檢驗合格的身障特製機車，持識別證本身不足」 | 同左 |
| `ev_only` | 有條件：限電動機車 | 同左 |

**2. 地方公告**

- 公告來源有兩層：縣市規則 `city_rules`（全市或行政區），以及條件自己的 `basis`（特定場域、特定路段，例如試辦場域）。`basis` 可以是網址或已確認內容的牌面照片（§1.4）；照片超過有效期時，這份依據失效。
- `city_rules` 新增 `expires_on date`（可為 null）。`now ≥ expires_on` 的規則不算有效，結果為「此地區的規則已過期，請以現場標誌標線為準」（`unverified`），不回落到全國規則，因為過期的地方開放可能已經延長也可能已經結束。
- **舊版相容**：舊版 App 直接查 `city_rules`（`lib/data/repositories.dart`），`CityRule.fromJson` 與 `eligibility()` 只看生效日，不認得 `expires_on`。只把過期列藏起來不夠：`RulesRepository.load()` 先載入內建的 `assets/rules/parking_rules.json`，再用遠端列覆蓋同縣市同車種的那筆，遠端沒回傳的列不會移除內建版本，舊版因此會退回內建的開放規則（例如臺北市大型重機的收費機車格）。所以過期列要**改成保守投影後照常回傳**，覆蓋內建版本：
  - C4 把資料表改名為 `city_rules_data`（新增 `expires_on`），並建立同名的 view `city_rules`（`security_invoker`）給舊版讀。未過期的列原樣回傳；已過期的列（`expires_on <= (now() at time zone 'Asia/Taipei')::date`）改成 `allowed_space_types = '{}'`、原本開放與有條件的格位全部併入 `conditional_space_types`、`district_space_types = '{}'`、`restriction = 'unverified'`、`exceptions = '此地區的規則已過期，請以現場標誌標線為準'`，`version` 不變（不低於內建版本，所以會覆蓋）。
  - 舊版 `eligibility()` 遇到「格位在 `conditionalSpaceTypes` 且 `restriction == unverified`」就回傳待確認並顯示 `exceptions`（既有分支），不會開放任何格位，也不會因為清空行政區而判成不可停；汽車格的普通機車判斷讀的是 `allowed`／`conditional` 兩者，結果同樣不會變成可停。
  - 新版改呼叫 `city_rules_v2()`（`security definer`，讀 `city_rules_data`，回傳含已過期的列與 `expires_on`），才能顯示「規則已過期」並套用上面的判斷。管理站與管理員 RPC（P5 的 `admin_*_city_rule`、`city_rules_history` trigger）改用 `city_rules_data`；直接寫入已撤銷，view 不需要可寫。#108 的 `data_versions` trigger 跟著資料表改名，不受影響。
  - pgTAP 驗證：過期列經 view 回傳的是保守投影、未過期列不變、`anon` 讀不到 `city_rules_data`；Flutter 測試用舊版的 `RulesRepository` 加內建規則，確認過期投影覆蓋內建開放規則後結果為待確認。
  - 剩下的空窗：舊版在規則到期前抓到、離線保存的副本，要到下次重新抓取才會換成保守投影；到期不是寫入，不會觸發 #108 的通知（§5.6），這個空窗記在 C4 的 PR 說明。
- 規則以格位面向判斷，取代 `ruleSpaceType()`：`ruleKindOf(condition)` 依 bay＋charge 對到 `allowed_space_types` 用的舊值（機車格 toll→`paidMotorcycle`、free→`freeMotorcycle`、charge 未確認→無法對應，結果為待確認）。限時格因此依它真正的收費屬性比對，不再一律當收費格。
- `basis` 與 `city_rules` 同時有效且結論相反（例如縣市規則不開放機車格，但場域公告開放共用）→ 較具體的 `basis` 優先；`basis` 已過期而 `city_rules` 沒有涵蓋 → 待確認；兩個都有效但無法排出具體程度（兩份全市公告互相矛盾）→ `unverified`，理由「公告不一致，請以現場公告為準」，並列出兩個來源。
- 這一步的輸出就是研究文件 §5.7 要抽出的純規則函式 `ruleVerdict()`：`open / conditional(restriction) / closed / noRule / unknownDistrict / expired / conflict`。法規預審引擎直接呼叫它，不重用混入信任狀態的 `eligibility()`。

**3. 場站／分區／格位**

路邊點直接用第 1、2 步的結果。路外點：

| 場站允許車種（可信） | 已知分區 | `zones_complete` | 結果 |
| --- | --- | --- | --- |
| 不可進場 | 任意 | 任意 | 不可停 |
| 可進場 | 至少一區對目前車種開放且依據有效 | 任意 | 可停或有條件，列出可停分區 |
| 可進場 | 沒有分區資料 | — | 維持現行：官方資料可停（請確認入口公告） |
| 可進場 | 有分區，但沒有一區對目前車種開放 | false | **待確認**（§7 第 6 項，已決定）：「場站開放大型重機，但已知分區沒有標示可停區域，請依入口公告」；不推定全場禁停 |
| 可進場 | 同上 | true | **待確認**：「場站與分區資料不一致」，送管理員（不是不可停，因為兩份資料互相矛盾） |
| 未確認 | 至少一區開放 | 任意 | 待確認（分區開放不能推出場站可進場，現行語意） |

- `zones_complete`（新增，點位層級布林，預設 false）：只有官方匯入或管理員能設為 true，表示分區清單涵蓋全場。社群回報與 `validate.ts` 不接受此鍵。
- 分區的開放判斷：有 `condition` 用 condition，沒有則用 `access` 推導（§1.3）；推導不出就是該區未確認。可信資料中 `allow` 對目前車種為 `false` 時，該區直接是不可停（「此分區標示不開放大型重機」），不再進第 2 步依地方公告判斷；例如普機專用分區不會因臺北開放收費機車格而變成大型重機可停。`allow` 為 `true` 只代表場站開放，仍要通過第 1 步的法定資格。未確認的分區不繼承其他分區或場站的資格（DESIGN.md 既有決定）。
- 分區 `basis.expires_on` 已過 → 該區的開放依據失效，該區視為未確認。

**4. 價格**

價格與資格分開回傳，價格未知不會讓資格變差，資格未知也不會隱藏已知價格：

- 每個可停處（路邊點，或每個對目前車種開放的分區）各回一個 `PriceAnswer`：`known(rate)`／`partial(rate, gaps)`（例如有費率但上限計算方式或延長時長未確認）／`unknown`。
- 解析順序沿用 #80，加上 §2.6 的規則：分區引用的計費規則（`fee_plan`）→ 分區自己的 `fee`（過渡期）→ 點位 `fee_plan`／`fee`（只在所有分區都沒有費率時）→ 舊文字。比照依 §2.1 只在同一條規則內解析，倍率直接套在金額、上限與延長金額上；被比照的車種缺值時回 `unknown`，文字為「大型重機費率未提供」（不寫「比照汽車」，§7 第 11 項）。
- 價格篩選（PLAN.md：轉換完成前不開放）之後只看 `known` 與 `partial`，`unknown` 不被篩掉也不排在前面。

### 3.3 回傳結構

```dart
class ParkingDecision {
  final EligibilityStatus status;       // 不變的四態
  final String reason;
  final RuleRestriction? restriction;
  final List<DecisionBasis> basis;      // 法條、縣市規則版本、場域公告、資料來源與日期
  final List<ZoneDecision> zones;       // 每區：狀態、限制、依據、PriceAnswer
  final PriceAnswer? price;             // 路邊點或單一區
  final Set<DecisionGap> gaps;          // zonesIncomplete、zonesConflict、noticeExpired、
                                        // noticeConflict、districtUnknown、scheduleUnknown、chargeUnknown
}
```

- `status` 的四態語意與核實計畫 §3.2 一致；`gaps` 不新增狀態，只說明為什麼是待確認，詳情頁據此寫理由。
- **與核實計畫 §3.4 顯示分層（#91）**：分層由 `basis` 的來源種類決定（官方、管理員核驗、社群欄位核實、車友回報、無資料），`decideParking` 只負責把來源帶出來；#91 的 `eligibilityDisplay()` 改讀 `ParkingDecision.basis`，判斷不變。「依縣市規則判定的路邊格位不受分層影響」維持。
- **與研究文件 §5.7**：`ruleVerdict()` 是第 2 步的純函式，Dart 與伺服器各一份，以 `assets/rules/parking_rules.json` 加 §4.2 的共同測試向量確保一致。`expired`、`conflict` 是本文新增的兩個結果，引擎一律視為「規則無法單獨回答」。
- **時段**：本輪先確認目前車種至少出現在一個時段的 `vehicles` 裡，才回 `conditional(timeLimited)`（顯示「有條件・限時段」）並列出各時段允許車種；目前車種沒有被任何時段列出時維持 `unverified`（缺口 `scheduleUnknown`，理由「公告沒有列出普通機車的開放時段」），不顯示成有條件。例如汽機共用格的時段只列 `car` 時，普通機車是待確認。大型重機在汽車格依法可停，不受這條影響。不依目前時間切換狀態，依時間切換留待之後（§7 第 4 項，已決定）。

## 4. 三端契約與驗證

### 4.1 單一來源

比照 #94 預檢的做法（`precheck_rules.json` 由 Deno 讀取，Dart 鏡像並以測試逐欄比對；`precheck_cases.json` 兩邊共同執行）：

| 檔案 | 內容 | 讀取者 |
| --- | --- | --- |
| `supabase/functions/_shared/parking_contract.json` | 列舉值（bay、use、share、charge、limits、area、days、fee mode）、每個 mode 的鍵與範圍、§1.3 轉換表、§4.3 組合表 | `validate.ts` 直接 import；Dart 鏡像常數，測試與 JSON 逐欄比對；`tool/gen_contract_sql.py` 產生 SQL |
| `supabase/functions/_shared/parking_contract_cases.json` | 合法／不合法的 `condition`、`fee`、分區與組合案例，以及轉換往返、`legacySafe` 的期望值。`renew` 三態與 `cross_period` 三態各有案例，並附每個案例的期望費率文字（§2.5）；`renew` 出現在 `hourly`／`daily`、`cross_period` 出現在 `by_time` 以外、或值不在列舉中，都是不合法案例 | Deno 測試、Flutter 測試、由產生器轉成 pgTAP |
| `assets/rules/parking_rules.json`（既有） | 縣市規則 | App、§5.7 引擎的測試向量 |

SQL 不能在執行時讀 JSON，所以由 `tool/gen_contract_sql.py` 從契約產生 `valid_condition()`、`valid_fee()` 的鍵表與 pgTAP 案例檔，產物進版控；CI 重新產生並以 `git diff --exit-code` 確認沒有漂移（`tool/ci_changes.py` 把契約 JSON 變更同時路由到 Flutter、Deno 與 DB 檢查，同 #94）。

### 4.2 三端各自負責

| 層 | 檢查 | 失敗時 |
| --- | --- | --- |
| 資料表 check（`valid_condition`、`valid_fee` v2、`valid_zones`） | 形狀、鍵、範圍；不可能成立的組合（§4.3 標 DB 的列） | 寫入失敗。管理員 RPC 與匯入也受約束 |
| `validate.ts` | 同上，外加信任邊界：社群不可帶 `zones_complete`、`condition.basis`（依據改以案件證據附上：新增選填鍵 `evidence_url`（https，存進案件，不寫入點位），或 P2 上線後的 `evidence_ids`，§1.4）；`proposed` 白名單加入 `condition`；P2 合併前拒收 `evidence_id` | 400 |
| 預檢 `precheck.ts`（#94） | §4.3 標「預檢」的範圍與政策組合，可單獨停用、調參 | `fix`／`hold` |
| Dart `ParkingCondition.fromJson`、`Fee.fromJson` | 同形狀規則，不讓整張地圖失敗。`condition` 只要有任何一處不合法，**整個 condition 讀成 null（未確認）**，不逐面向降級：丟掉不合法的 `limits` 會讓格位看起來沒有限制，反而變寬鬆。另提供嚴格的 `validCondition`，與 Deno、SQL 共用同一份案例；`Fee` 維持逐車種未確認 | condition 整個未確認；費率該車種未確認 |

原則：**資料表只擋「任何情況都不成立」的組合；本專案範圍或政策上的限制放在預檢**，因為範圍會隨公告改變（例如桃園 2026/4/1 起試辦開放免費機車格），寫死在 check 會擋下合法的新資料。

### 4.3 組合一致性（格位用途 × fee × facility_type）

| 組合 | 層 | 動作 | 理由 |
| --- | --- | --- | --- |
| 路外點（`offStreet` 或路外 `facility_type`）帶頂層 `condition` | DB | 拒絕 | 路外的格位資訊在分區 |
| 路邊點帶 `parking_zones` 或 `zones_complete` | DB | 拒絕 | 同 #94 `street_lot_details` |
| 有 `condition` 但 `space_type ≠ legacySpaceType(condition)` | DB | 拒絕 | 避免雙份狀態 |
| `use='share'` 缺 `share`，或 `use='usual'` 帶 `share` | DB | 拒絕 | |
| 頂層 `condition` 帶 `allow`；`allow.scooter=true` 而 bay=heavy；限制 `kind` 不在列舉，或 `vehicle` 出現在 `special_vehicle` 以外 | DB | 拒絕 | 路邊沿用既有車種旗標；限制類型與車型分鍵（§1.1） |
| 路邊點的 `condition` 缺 `bay`；或 bay=motorcycle、沒有 `time_limit`／`special_vehicle`／`ev_only`、也沒有 `charge` | DB | 拒絕 | 推導不出 `space_type`（§1.3） |
| `share='scooter_heavy'` 但 bay ≠ motorcycle；`share='car_motorcycle'` 但 bay ≠ car | DB | 拒絕 | 需求 4 |
| `share='car_motorcycle'` 在路外分區 | 預檢 | fix | 本專案只列路邊（需求 4），屬範圍而非不可能 |
| `share='scooter_heavy'` 且 `charge='free'` | 預檢 | hold，要求附公告依據：公告網址或現場牌面照片擇一（§1.4；照片要等 P2 上線）；沒有依據時預檢提示補上 | 契約允許（§7 第 2 項，已決定）：不可變成大型重機不能停免費機車格的全國限制（法規 A），但保留「目前多為 Toll」的查核 |
| `charge='free'` 而任一已填車種的費率不是 `free` | 預檢 | fix | |
| `charge='toll'` 而某車種為 `mode:'free'` | 預檢 | fix，提示改用「首段 0 元」 | 法規 D |
| bay=heavy 而有 `fee.scooter` | 預檢 | fix | 普通機車不能停重機格 |
| bay=motorcycle 或 area=motorcycle 而有 `fee.car` | 預檢 | fix | |
| area=car 而有 `fee.scooter`、且沒有地方公告開放 | 預檢 | hold | 需求 6；特別開放須另附依據 |
| `time_limit.max_minutes` 與 `per_visit.max_minutes` 不同 | 預檢 | fix | |
| `heavy` 為 `same_as_car` 但同一 `fee` 沒有 `car`（新送出） | 預檢 | fix | 延伸 #94 `fee_follows_missing_scooter`；既有資料仍允許，讀成未確認。**對合併後的費率判斷**，見本表下方說明 |
| `daily_cap < amount`、`hourly` 且 `amount=0` 沒有 `free_minutes` | 預檢 | fix | 既有 #94 規則沿用到 `car` 與 `by_time` 內層 |
| `renew` 出現在 `per_visit` 以外；`cross_period` 出現在 `by_time` 以外；值不在列舉中 | DB | 拒絕 | §2.5；三端以同一份契約檢查 |
| `by_time` 帶 `cross_period`，但計次時段不到兩段 | 預檢 | fix | 沒有可以跨的計次時段 |
| `charge='free'` 而有 `renew` | 預檢 | fix | 免費格沒有計次 |
| `extension` 在 `charge='free'` 的格位 | 預檢 | fix | |

**修改建議要用合併後的費率檢查**：費率修改建議逐車種合併（§5.4），只送有改的車種，例如點位已有汽車費率、使用者只把大型重機改為比照汽車時，`proposed.fee` 只有 `{"heavy":{"mode":"same_as_car"}}`。比照依賴（`same_as_car`、既有的 `same_as_scooter`）與本表其他跨車種、跨欄位的組合規則，因此一律對「現值合併 `proposed.fee` 後」的結果判斷，不直接檢查 `proposed`。做法：

- App 與管理站送出前已經有點位現值，預檢函式改收 `(current, proposed)`，先合併再檢查；新增停車點沒有現值，`current` 為空，結果與現在相同。
- `submit-report/index.ts` 目前在讀取點位前就呼叫 `precheck(body)`。C3 改為：只看 `proposed` 本身就能判斷的規則（形狀、占位詞、個資格式等）維持在讀取前；組合規則移到讀取點位、合併之後再跑。Dart 與 Deno 共用 `precheck_cases.json`，新增「只送 `heavy: same_as_car`、現值有 `car`」與同樣情況的 `same_as_scooter` 兩個不誤攔案例，以及現值沒有 `car` 時仍回 `fix` 的案例。
- `apply_report` 採納時同樣以合併結果寫入，`valid_fee()` 與 DB 層規則檢查的也是合併結果。

## 5. 遷移與相容（交接 P6）

### 5.1 migration 原則

- 一律新增 migration，不改已部署的檔案；版號實作時向 main 申請（目前已分配到 202610260260，本 stack 需要 3 個）。
- 先加欄位與函式，再改讀取端，最後才讓寫入端送新欄位；每一步都可以單獨回退。
- 重新定義 `apply_report`、`admin_resolve_report`、`admin_upsert_spot`、`admin_promote_spot`、`admin_spot_fields` 時，以當時 `main` 的最新定義為基礎（目前最新分別在 #96 的 202610260010 與 202610250080）。
- 新增：`community_spots.condition jsonb`、`official_heavy_spots.condition jsonb`、兩表 `zones_complete boolean not null default false`、`city_rules.expires_on date`（C4 同時把資料表改名為 `city_rules_data`，原名改為給舊版的保守投影 view，§3.2）；`valid_zones()` 取代 `valid_zone_fees()` 的 check（多檢查 `area`、`condition`）。`valid_fee()` 以 `create or replace` 擴充，既有資料全部仍合法（新契約是舊契約的超集合）。
- 新 check 用 `not valid` 加上後再 `validate constraint`，與 `city_rules_restriction_required` 的做法一致；既有資料 `condition` 皆為 null，不會失敗。

### 5.2 兩版（三版）viewport

`ParkingRepository._viewport` 目前先呼叫 `_v2`，`PGRST202` 時回退到原版。本 stack 新增 `_v3`，新版 App 依序嘗試 v3 → v2 → 原版：

| RPC | 給誰 | 回傳 |
| --- | --- | --- |
| 原版 | 不認得 4 種新 `space_type` 的舊版 | 仍只回原本 5 種；**不安全的列同樣改回保守投影**（同下一列）。只過濾新 `space_type` 不夠，例如帶 `schedule` 的重機格仍是 `heavyOnly`，舊版會依全國規則顯示可停 |
| `_v2` | 認得 9 種 `space_type`、不認得 `condition` 的版本 | legacy-safe 的列照舊；**不安全的列改回保守投影**：`space_type='offStreet'`、兩個車種旗標 null、`status='pending'`（社群點），不安全場站的每個不安全分區移除 `access`（舊版讀成未確認）。這些版本對這種投影一律判「待確認」，與收藏 `exact` 的既有做法相同 |
| `_v3` | 新版 | 全部欄位，含 `condition`、`zones_complete`、新 `fee` |

`public_spots` view 新增欄位會一併出現在 v2 的回傳型別中；舊版 `ParkingSpot.fromJson` 忽略不認得的鍵，所以多出欄位不會出錯，需要處理的只有「舊版會誤讀」的列。官方點的 v2 沒有 `status` 可降，改成兩個車種旗標 null，舊版官方路外點在旗標 null 時判待確認。

分區的新鍵（`area`、`condition`）舊版會忽略，所以安全的分區不需要投影：`access` 由轉換層寫回，舊版看到的分區分類與新版一致。不安全的分區（帶時段、限制、期限）在原版與 v2 的回傳裡移除 `access`，場站頂層同時改成保守投影，舊版的 `eligibility()` 與分區顯示都會是待確認。投影由同一個 SQL 函式 `legacy_projection(row)` 產生，原版與 v2 共用。

### 5.3 收藏 JSON

- `toJson` 新增 `condition`、`zones_complete`。legacy-safe 的點照舊寫；不安全的點（含任一分區不安全的場站，判定同 §1.3）沿用 `_newKinds` 的手法，但把真實值放在**新的** `exact_v2` 鍵（`space_type`、旗標、`status`、`condition`、完整 `parking_zones`），頂層寫保守投影，頂層 `parking_zones` 中不安全分區移除 `access`，與 viewport 投影相同。
- 不能沿用既有 `exact` 鍵：目前已發布的版本會把 `exact` 合併回頂層，再存檔時寫回放寬的值且丟掉 `condition`。改用它不認得的 `exact_v2`，舊版只會讀到保守的頂層，再存檔時遺失的是資訊而不是安全性。
- 新版讀收藏時 `exact_v2` 優先於 `exact` 優先於頂層。收藏的 `fee` 原樣保存；舊版讀到新 `Rate` 鍵時該車種為未確認。

### 5.4 新舊 App 讀寫

| 情境 | 結果 | 處理 |
| --- | --- | --- |
| 舊版讀新資料 | 不能表示的條件顯示待確認；新費率鍵的車種顯示未確認；`car` 被忽略 | §5.2、§5.3 的投影 |
| 舊版新增停車點 | 不帶 `condition`，伺服器存 null，新版用 `conditionOf` 推導 | 不需處理 |
| 舊版擁有者修改（`update`） | `apply_report` 只更新名稱、`fee_note`、備註，不碰 `condition`／`fee` | 重新定義時維持只更新這三欄 |
| 舊版送費率修改建議 | 舊版把它讀不懂的車種當成未確認，送出的 `fee` 會少掉 `car` 或少掉被它判成未確認的 `heavy` | **費率建議改為逐車種合併**：`proposed.fee` 沒有的車種保留現值，要清除須明確送 `null`（§7 第 3 項，已決定）。`validFee` 只在 `proposed.fee` 內接受車種值為 `null`，點位與分區的 `fee` 欄位仍不接受；審核頁差異表照合併後的結果顯示 |
| 舊版送 `fee_note` 與 `fee` | #96 要求 `fee_note = fee_note_of(fee)`，新版句子不同時會被擋 | 審核頁採納費率時一律用新版 `feeNoteOf` 重算 `fee_note`，不採用建議中的文字 |
| 匯入覆寫 | `official_sql()` 原以 `on conflict do update set` 覆寫全部欄位，含 `parking_zones`（SQL 輸出已於 #117 移除，匯入只經 P6） | P6 匯入改為只更新官方欄位（研究 §5.6 第 7 點），並逐區保留匯入資料沒有提供的 `condition` |

### 5.5 匯入與資料轉換（銜接 stack B P6）

P6 匯入（`feat/admin-import`，stack B 第 5 層）的轉換規則延伸到條件與汽車費率，不另做一套：

- **只轉換確定的文字**：同一段文字只能對到一種 `condition`／`rate` 才寫入；「請依現場公告」「未知」、混有月租或身障費率、無法分辨計次或計時路段者，維持 null 交人工。
- **保留原文與來源**：原始費率文字不能放在 `fee_note`（#96 要求它等於 `fee_note_of(fee)`），另存在新欄位 `fee_source_text`（§7 第 5 項，已決定；由 C3 新增，只有匯入與管理員寫入，只在管理站點位表單唯讀顯示，App 不顯示（§7 第 12 項）），並在 `condition.basis`／`source_url` 保留出處。
- **差異試算多三欄**：條件可轉換／費率可轉換（含汽車）／需人工；有覆蓋層或管理員已改過的欄位另列（研究 §5.6 第 7 點）。
- **轉換器共用契約**：P6 的解析結果以 `parking_contract.json` 與 `valid_fee()` 驗證。若 P6 先於本 stack 的 P2 合併，P6 只產生 v1 費率（scooter／heavy），汽車金額留在文字；P2 合併後重跑 P6 的差異試算即可補上汽車，不重寫轉換器。
- 臺北路邊格位的官方格種代碼可直接對應條件（`SpaceType` 註解已記錄 pktype 04／18 身障、20 限時、22 汽機彈性共用、11 機車區）；代碼表其餘值待查證，對不到的不轉換。

### 5.6 與即時通知（#108）及即時車位計畫（#109）的關係

- **#108 點位變更即時通知**（`202610260040_data_versions.sql`、`lib/data/data_updates.dart`）：`community_spots`、`official_heavy_spots`、`city_rules` 每個寫入陳述式都會讓 `data_versions` 加一，App 收到後重新載入目前畫面的點位或規則。本設計寫入 `condition`、`zones_complete`、新 `fee`、`city_rules.expires_on` 都走同樣的表，所以會自動觸發通知，不需要新的 trigger。App 重新載入時走同一條 `_viewport` 路徑（v3 → v2 → 原版），舊版重新載入拿到的仍是 §5.2 的保守投影。C3 重算既有列 `fee_note` 的 migration 是一個陳述式，只會加一次版本，不會讓所有 App 連續重載。依據到期（`basis.expires_on`、`city_rules.expires_on`）是時間到了才生效，不是寫入，所以不會觸發通知；App 每次判斷時用當下時間計算（§3.2），不依賴通知。
- **#109 即時車位**（`docs/REALTIME_AVAILABILITY_UI_PLAN.md`、`docs/designs/2026-10-26-realtime-availability-ui.md`）：剩餘車位改由獨立的 `AvailabilitySnapshot` 與 `viewport_availability` 提供，不放在 `condition` 或 `fee`，兩者互不依賴。設計上有三點一致：
  - 「可不可以停」與「有沒有位」分開：#109 的剩餘數膠囊只用中性墨色；本文的 `FeeBoard` 也不用資格色。詳情頁由上而下是資格結論、剩餘車位摘要、收費公告牌，三者不合併成一塊。
  - 收藏不保存即時剩餘數（#109 把 `available` 視為舊版相容欄位），本文的 `exact_v2` 也不加入剩餘數。
  - #109 計畫「有多個格種區域時，依官方資料顯示分區」，但沒有規定剩餘數怎麼對應到分區。本文的分區目前只有名稱、沒有穩定 id；C2 實作時要和 #109 的實作者確認是否需要 `parking_zones[].id`（不影響本文的契約，只多一個選填鍵）。

## 6. 實作切分（stack C，兩個 stack 合併後開工）

順序由下而上，每張的 base 是下一層分支。每張都可單獨合併：上層沒合併時，下層只是多了沒人使用的欄位或函式。

| # | 分支 | 範圍 | 依賴 | 測試 | 回退 |
| --- | --- | --- | --- | --- | --- |
| C1 | `feat/parking-contract` | `parking_contract.json`（`basis` 含保留的 `evidence_id`，P2 前拒收）、案例檔、`ParkingCondition` 模型與轉換層（純 Dart）、`validate.ts` 的 `validCondition`（尚未接上 action）、SQL 產生器與 CI 漂移檢查。**無 migration、無行為變更** | main | 轉換往返、`legacySafe` 窮舉 9 種 `space_type` × 5 種 `access`；JSON 與 Dart 常數逐欄比對；Deno 與 Flutter 共同執行案例 | 直接 revert |
| C2 | `feat/parking-condition-db`（P1） | migration：`condition`、`zones_complete`、`valid_condition`、`valid_zones`、`public_spots` 加欄位、viewport v3 與 v2 保守投影；`apply_report` 建立時存 `condition`；`admin_spot_fields`、`admin_resolve_report` 白名單；`ParkingSpot` 讀寫、收藏 `exact_v2`；`reportedAccess` 改走轉換層 | C1 | pgTAP：check 允許／拒絕、v2 投影、v3 完整、RLS；收藏往返（新版→舊版模擬→新版）；舊 JSON 相容 | 新欄位全為 null 時行為與現在相同；App 回退到 v2 |
| C3 | `feat/fee-v2`（P2） | `Fee.car`、`Rate` 新鍵與 `by_time`；`valid_fee` 擴充；`fee_note_of` SQL 與 `feeNoteOf` 新句子（沿用 #96 的共用句子測試）；`fee_source_text` 欄位；計費規則 `fee_plans`／`fee_plan` 與既有分區 `fee` 的轉換（§2.6）；費率建議逐車種合併（`proposed.fee` 的車種可為 `null`＝清除）；`renew`／`cross_period` 三態與句子（§2.5），以及重算既有列的 `fee_note`；`FeeEditor` 加汽車、跨日與跨時段單選等新選項；**儲存的 `fee = {}` 統一視為「無結構化資料」**（來自 #96 Codex 第二輪 P2，追蹤到本 PR）：伺服器端 `fee_note` 一致檢查（#96 202610260010 的 `fee_note_matches`，以及 `admin_upsert_spot`、`admin_resolve_report`）與管理站 `storedFee()` 用同一語意，讓管理員能編輯這類點位的費率文字；staging 目前 0 筆受影響 | C1（可與 C2 平行，建議疊在 C2 上減少衝突） | 舊 fee 全部仍合法；新鍵允許／拒絕；`renew`／`cross_period` 三態與 §2.5 範例表的收費時點；Dart／SQL／Deno 句子一致；舊版讀新 fee 為未確認；合併語意 pgTAP；`fee = {}` 點位：pgTAP 與管理站 widget 測試「編輯 fee={} 點位的費率文字可儲存」 | 新鍵不寫入即與現況相同 |
| C4 | `feat/parking-decision`（P3） | `decideParking`、`ruleVerdict`、`PriceAnswer`；`eligibility()` 改為包裝；`city_rules.expires_on`、`city_rules_data` 改名與給舊版的保守投影 view、`city_rules_v2()`（§3.2 舊版相容）；#91 `eligibilityDisplay` 改讀 `basis` | C2、C3 | 窮舉 條件 × 車種 × 規則 × 分區完整度 × 期限；`eligibility()` 包裝對既有測試全數不變（除交接列出的三個錯誤）；§5.7 共同向量 | 包裝可切回舊實作（保留一版） |
| C5 | `feat/parking-conditions-app`（P4 App） | 詳情（分區、時段、首段 0 元、延長、依據與期限，含「現場牌面照片」依據的顯示）、送出時附依據（網址；P2 合併後才開放附牌面照片，以功能旗標控制）、篩選、新增停車點與修改建議的條件／汽車費率欄位；預檢規則（§4.3，含普大共用 Free 的 hold）加入 `precheck_rules.json`；階段 1 候選「計次或每日 0 元」排除帶 `max_minutes` 的計次費率（§2.3） | C4；附照片依據另依核實計畫 P2（`spot_evidence` 上傳與內容確認） | widget：320／390／700／1280 px、1.6 倍、深色；不溢出、觸控 ≥ 48 px；預檢案例，含臺北限時格（`per_visit` 0 元＋`max_minutes:20`）不被誤攔 | UI 隱藏新欄位 |
| C6 | `feat/parking-conditions-admin`（P4 管理站） | 點位表單分區編輯（`area`、`condition`、`fee`、`zones_complete`）、依據選「公告網址」或「牌面照片」（從該點已確認內容的照片中挑選；P2 合併前只顯示網址）、審核頁條件差異、規則頁 `expires_on` | C4（可與 C5 平行）；照片依據依核實計畫 P2 | admin smoke desktop-light／mobile-dark；pgTAP 管理員路徑 | 同上 |

每張 PR 要改的畫面、元件與 RWD 驗證見 §8.7；UI 修正跟著各張 PR 依 §8 實作，不另開小 PR 先改現有 FeeEditor（使用者 2026-10-26）。

**會動到的既有功能與避免重工**

| 既有 | 本 stack 如何接 |
| --- | --- |
| #80 分區費率（`ParkingZone.fee`、詳情優先順序） | 優先順序與「不沿用其他分區」不變；C3 只擴充 `Fee`，C5 在既有逐區顯示上加汽車列 |
| #96 管理站費率（`fee_note_of`、`FeeEditor`、審核 `fitsField`） | C3 以 #96 的 SQL `fee_note_of` 與共用句子測試為基礎擴充，不另寫一份；`FeeEditor` 加汽車區塊，管理站與 App 同時受益 |
| #91 資格分層 | C4 讓 `eligibilityDisplay()` 改讀 `ParkingDecision.basis`，分層表不變 |
| #94 預檢 | §4.3 的「預檢」列加進同一份 `precheck_rules.json`，不另建；階段 1 候選「計次或每日 0 元」須排除帶 `max_minutes` 的計次費率（§2.3），列入 C5 |
| P5 規則頁（stack B 第 4 層） | 若 P5 先合併，C6 在其表單加 `expires_on`；若 C4 先合併，P5 直接含此欄位。兩邊都以 `CityRule` 模型為準 |
| P6 匯入（stack B 第 5 層） | 見 §5.5；轉換器共用契約，C3 合併後重跑差異試算 |
| P0（身障文字、汽機共用分類） | C2 用轉換層取代 P0 修過的分支，P0 的測試保留為回歸測試 |

## 7. 已決定的設計取捨

### 第一批（使用者，2026-10-26）

原列為待拍板的 6 項，使用者於 2026-10-26 全部採用建議方案。各章節已依結論同步。

| # | 議題 | 結論 | 影響章節與 PR |
| --- | --- | --- | --- |
| 1 | 汽機車共用格的機車涵蓋範圍（交接需求 4） | **C 不預設**：每筆共用格在 `schedule[].vehicles` 依公告寫明車種；沒寫的車種顯示待確認。大型重機停汽車格的法源與共用標示無關，不受影響 | §1.2、§3.2 第 1 步；C1 契約、C4 判斷 |
| 2 | 普大共用能不能是 Free | **B 允許**：契約接受 `share='scooter_heavy'`＋`charge='free'`，預檢先 hold 並要求附公告依據。依據可以是公告網址**或**現場牌面照片，擇一即可（使用者 2026-10-26 補充；照片須經內容確認，P2 照片上傳上線前只能附網址，§1.4）。縣市規則開放一般免費機車格時，格位用途仍是 `usual` | §1.4、§4.3；C1 契約、C5 預檢、核實計畫 P2 |
| 3 | 費率修改建議的寫入語意 | **A 逐車種合併**：`proposed.fee` 沒有的車種保留現值，清除須明確送 `null` | §5.4；C3 |
| 4 | 時段是否依目前時間判斷 | **A 本輪只顯示時段**：狀態固定「有條件・限時段」，列出各時段允許車種；依時間切換（需要國定假日資料）留待之後，屆時不必改資料格式 | §2.2、§3.3；C4、C5 |
| 5 | 原始費率文字存放位置 | **A 新增 `fee_source_text`**：匯入與管理員寫入，詳情「資料與查核」顯示原始公告文字；#96 的 `fee_note = fee_note_of(fee)` 規則不放寬 | §5.5；C3、stack B P6 |
| 6 | 官方場站可進場但已知分區皆不開放 | **A 待確認**：理由寫明「已知分區沒有標示可停區域，請依入口公告」，不推定全場禁停。受影響的官方點數在 C4 實作時以 staging 查詢列出，寫進 PR 說明 | §3.2 第 3 步；C4 |

另外列入範圍（非拍板事項，main 2026-10-26 要求寫入）：#94 階段 1 候選規則「計次或每日 0 元」須排除帶 `max_minutes` 的計次費率，避免誤攔臺北限時格（§2.3）；列入 C5 的範圍與測試（§6）。

### 第二批（使用者，2026-10-26，全部採建議 A）

| # | 議題 | 結論 | 影響章節與 PR |
| --- | --- | --- | --- |
| 7 | 計次費率跨時段的計法（起於使用者「計次費率的時段要有隔日另計的選項」；隔日另計本身是 §2.5 的 `renew` 三態） | **A 新增 `by_time.cross_period` 三態**：每進入新時段另計（`each_period`）／只依進場時段計（`entry_only`）／未確認（缺欄位）；逐筆設定，預設未確認；換時段和跨日在同一刻發生時只收一次，用新時段的費率 | §2.2、§2.5、§4.3、§8.5；C1 契約、C3 |
| 8 | App 詳情頁的費率呈現 | **A 改用收費公告牌 `FeeBoard`**：白底、柏油色細框、目前車種排第一；App 與管理站 #96 用同一個元件 | §8.3、§8.4；C3（元件）、C5（詳情頁） |
| 9 | 手機上的 FeeEditor 展開方式 | **A 一次只展開一個車種**：其他車種收合成一行摘要（就是公告牌上那句話），App 表單預設展開目前車種 | §8.5；C3 |

### 第三批（使用者，2026-10-26，於 UI 設計稿畫布定案）

設計稿：即時車位畫布與[停放條件與費率畫布](https://claude.ai/artifact/7fMgUdRjNzzqttrGMVPUhj)。下列各項取代本文較早的寫法。

| # | 議題 | 結論 | 影響章節與 PR |
| --- | --- | --- | --- |
| 10 | 格位與計費規則 | **分離**：點位層 `fee_plans` 清單，分區以 `fee_plan` 引用；同一區域多種格位＝多個同 `area` 分區，管理站合成一張區域卡 | §2.1、§2.6、§3.2、§8.4；C3、C6 |
| 11 | 比照的顯示文字 | **直接寫算好的金額**，不寫「比照汽車／比照機車」「機車費率的 2 倍」；被比照車種缺值時寫「○○費率未提供」。管理員編輯器的選項名稱「比照其他車種」保留（issue #140） | §3.2、§8.3、§8.4、§8.6；C3、C5 |
| 12 | 原始公告文字（`fee_source_text`） | **App 詳情不顯示**，只在管理站點位表單唯讀顯示；取代第 5 項中「詳情『資料與查核』顯示原始公告文字」 | §5.5、§8.4；C5、C6 |
| 13 | 依據行用詞 | 「核實」一律改「確認」：依據行「管理員確認，日期」（社群上線後「車友確認」），過期標題「曾確認可停」；停車點存在寫「此處確實有停車點」（#132，P0 已實作） | §3.3、§8.6；C4、C5 |
| 14 | 詳情摘要的費率 | **依目前時間顯示當下時段的費率**（#120）：時段 `days` 依當天星期幾判斷，支援全部／平日（週一至五）／假日（週六、日）／指定星期幾；國定假日與補班日暫依星期幾計。首段 0 元寫「首 20 分鐘 0 元」、不收費時段寫「此時段不收費」並附下一段起價、時段沒涵蓋現在寫「現在的費率未確認」 | §2.2、§3.2、§8.4；C4（時段判斷）、C5 |
| 15 | 「依現場公告」與「未確認」重複 | **合併為未確認**：編輯器移除「依現場公告」選項，新寫入不再產生 `posted`；既有 `posted` 在 C3 遷移時轉為未確認（刪除該車種），契約暫時仍接受 `posted` 讀成未確認，以免舊版 App 送出被拒。App 對未確認費率一律寫「費率未確認，請依現場公告」 | §2.2、§8.5、§8.6；C3 |

## 8. UI 設計

依 frontend-design 的流程寫成：先列設計計畫，再對照需求檢查有沒有落入通用預設，最後定稿。**既有設計系統不變**：App 依 [DESIGN.md](../DESIGN.md)（海藍 `#176273`、可停深綠 `#186348`、條件琥珀 `#865500`、不可停暗紅 `#A13042`、待確認石灰 `#59646C`、紙白；繁中系統字體，數字 Outfit；車牌色塊、地面標線選擇格 `GroundMarking`）。管理站依 [ADMIN_WEB.md](../ADMIN_WEB.md)（路面灰 `#ECEEEF`、標線白、柏油 `#2A2E33`、停車標誌藍 `#1F5FA8`、黃牌黃 `#E3AE00`、紅線紅 `#C3362E`，Noto Sans TC，數字用等寬數字）。另遵守 TEAM_RULES「設計品質」一節。本節不新增顏色或字體，只決定版面、元件與文案。

> **2026-10-26 起以設計稿畫布為準**：[停放條件與費率 UI 設計稿](https://claude.ai/artifact/7fMgUdRjNzzqttrGMVPUhj)（使用者核准）。本節的線框與文案是較早的文字版，與畫布或 §7 第三批衝突時以後者為準；實作 PR 須附截圖與畫布並排比對。

### 8.1 設計計畫（初稿）

- **主題**：騎士在入口或路邊要回答兩件事：「我這台車能不能停、停哪一區」以及「要付多少、什麼時候會多收」。資料來源是現場的收費公告牌、地面標線和車牌顏色。
- **色彩**：沿用上列語意色，不加新色。費率本身不帶語意色（價格不是「可停／不可停」），只有資格用語意色。
- **字體**：沿用系統字體；金額與時間用數字字體的等寬數字，讓多個時段的金額直向對齊。
- **版面**：初稿是每個車種一張圓角卡片，卡片內列出費率欄位，上方加「費率」小標。
- **原則**：資格結論最醒目，費率其次；費率以公告牌形式呈現。

### 8.2 對照需求自我檢查，修正之處

| 初稿 | 問題 | 定稿 |
| --- | --- | --- |
| 每個車種一張圓角卡片、同樣陰影 | 這正是「SaaS 卡片堆疊」的通用預設，三張一樣的卡分不出哪一張和目前車種有關 | 全場或每一區只放**一塊收費公告牌**（白底、柏油色細框、直角，仿入口公告）。公告牌裡的車種列以車牌色塊開頭，**目前車種那一列排第一**，其他車種的列排在後面且字重較輕。外框表示「這是一份公告」，不拿來裝飾 |
| 區塊上方加「費率」「條件」小標 | 小標在每個區塊重複，只是裝飾 | 公告牌本身就說明它是費率；只在分區有名稱時用分區名稱當標題（「機車區」「汽車區」），那是真實資訊 |
| 首段 0 元用綠色「免費」膠囊 | 顏色和文字都會讓人以為免費，違反法規 D | 寫成「首 20 分鐘 0 元」，前面加計時圖示；**永遠不出現「免費」兩個字，也不用可停綠** |
| 時段費率用分頁切換「平日／假日」 | 現場公告是一張表，切分頁會藏住另一段 | 公告牌內直接列成時段表：左欄時間、右欄金額，跨午夜的時段寫「20:00–隔日 08:00」 |
| 「未確認」用淺灰字 | 只靠顏色，深色模式下還會對比不足 | 未確認一律「問號圖示＋『未確認』文字」，維持 DESIGN.md 的待確認石灰，對比達 WCAG AA |
| 表單把所有費率欄位一次攤開 | 手機上一個車種就要十幾個欄位，騎士會放棄 | 漸進展開（§8.5）：先選收費方式，只出現必要欄位；選填規則收在「更多收費規則」 |

再檢查一次通用預設：沒有全大寫標籤、沒有「A · B · C」串接（#91 已把車種串接改成車牌色塊，本節沿用）、按鈕不加「→」、沒有編號（費率規則不是步驟；只有時段表的列是真實的時間順序）、沒有裝飾性進場動畫。唯一的動態是使用者展開或收合一個車種、一個時段時的高度變化，且遵守「減少動態」。

### 8.3 視覺語彙

| 狀態 | 文字（同時是螢幕閱讀器標籤） | 圖示 | 顏色 | 不可以 |
| --- | --- | --- | --- | --- |
| 計時 | 每小時 20 元，半小時計 | 無 | 柏油字 | |
| 計次 | 每次 40 元 | 無 | 柏油字 | |
| 首段 0 元 | 首 20 分鐘 0 元 | 計時器 | 柏油字 | 寫「免費」、用可停綠 |
| 免費 | 免費 | 無 | 柏油字；格位是 Free 時才出現 | 用在 Toll 格 |
| 隔日另計 | 隔日另計 | 月亮加日曆 | 柏油字 | 省略不寫（未確認要寫出來） |
| 停多久都只收一次 | 停多久都只收一次 | 無 | 柏油字 | |
| 跨日或跨時段未確認 | 隔日是否另計未確認／跨時段計費方式未確認 | 問號 | 待確認石灰 | 只用淺灰字 |
| 當日上限 | 當日上限 100 元（零時重算） | 無 | 柏油字 | 沒有 `cap_reset` 時寫「上限計算方式未確認」 |
| 可延長 | 可付 40 元延長 1 次（延長時間未確認） | 加號圓圈 | 柏油字 | |
| 比照 | 直接寫解析後的金額，例如「每小時 20 元」（§7 第 11 項） | 無 | 柏油字 | 寫「比照汽車」「機車費率的 2 倍」「×2」 |
| 被比照的車種沒資料 | 大型重機費率未提供 | 問號 | 待確認石灰 | 回退成機車費率 |
| 依據有期限 | 試辦至 2026-10-05；過期時寫「試辦已於 2026-10-05 到期，請看現場公告」 | 日曆 | 未到期柏油字；過期琥珀 | 只用顏色表示過期 |
| 車種 | 普通機車／大型重機／汽車 | 車牌色塊（綠白牌、紅黃牌）與汽車圖示 | 車牌色 | 只用色塊不寫字 |

公告牌在 App 和管理站是同一個元件 `FeeBoard`（C3 新增），#96 管理站的「App 顯示的費率」公告牌改用它，兩邊看到的公告牌一致。

### 8.4 線框

每個畫面只讓一個元素最醒目，以 ★ 標出。

**詳情頁的費率與條件區（App，C5）**

手機 390 px：

```text
┌──────────────────────────────────────┐
│ 市府轉運站地下停車場            ✕     │
│ 地下停車場  臺北市信義區  350 m      │
│ ★ 有條件・機車區可停                 │ ← 資格結論（唯一粗體，§3.4 分層）
│   依政府公開資料，更新於 2026-10-20  │
│   ▣ 試辦至 2026-12-31（示意日期）    │
│                                      │
│ 機車區                               │
│ ┌──────────────────────────────────┐ │
│ │ [紅黃牌] 大型重機                │ │ ← 目前車種排第一
│ │   機車費率的 2 倍，每小時 20 元  │ │
│ │ [綠白牌] 普通機車  每小時 10 元  │ │
│ └──────────────────────────────────┘ │
│ 汽車區                               │
│ ┌──────────────────────────────────┐ │
│ │ [紅黃牌] 大型重機  比照汽車費率  │ │
│ │   每小時 40 元                   │ │
│ │ [汽車]   汽車      每小時 40 元  │ │
│ └──────────────────────────────────┘ │
├──────────────────────────────────────┤
│ [ 導航到這裡 ]   [ 提出修改建議 ]    │
└──────────────────────────────────────┘
```

寬螢幕（≥ 700 px 的雙欄，詳情寬度上限 640）：公告牌改成兩欄，左欄車種、右欄金額；多個分區左右並排，最多兩欄，第三區換行。資格結論仍在最上方，橫跨全寬。

```text
┌──────────────────────────────────────────────────────────┐
│ ★ 有條件・機車區可停          依政府公開資料 2026-10-20  │
│   ▣ 試辦至 2026-12-31（示意日期）                         │
│ 機車區                        汽車區                     │
│ ┌──────────────────────────┐ ┌──────────────────────────┐ │
│ │ [紅黃牌] 大型重機  20 元/時│ │ [紅黃牌] 大型重機  40 元/時│ │
│ │   機車費率的 2 倍          │ │   比照汽車費率            │ │
│ │ [綠白牌] 普通機車  10 元/時│ │ [汽車]   汽車      40 元/時│ │
│ └──────────────────────────┘ └──────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

最醒目的是資格結論：騎士打開詳情就是要知道能不能停（沿用 #91）。依據過期時（§3.3），結論改為待確認，依據列改寫「試辦已於 YYYY-MM-DD 到期，請看現場公告」。費率公告牌是第二層，用外框而不用粗體或顏色突出。

路邊限時格與時段費率的公告牌內容（手機）：

```text
┌──────────────────────────────────┐
│ [紅黃牌] 大型重機                │
│   ⏱ 首 20 分鐘 0 元              │
│   ⊕ 可付 40 元延長 1 次（延長時間未確認） │
│ [綠白牌] 普通機車  ? 未確認      │
└──────────────────────────────────┘
┌──────────────────────────────────┐
│ [汽車] 汽車                      │
│   08:00–20:00     每次 30 元     │
│                   停多久都只收一次 │
│   20:00–隔日08:00 每次 50 元     │
│                   ☾ 隔日另計     │
│   跨時段分別計費                     │
└──────────────────────────────────┘
```

**FeeEditor 擴充（共用元件，C3）**

手機 390 px，一次只展開一個車種（§8.5、§7 第 9 項，已決定）：

```text
收費
┌──────────────────────────────────────┐
│ [綠白牌] 普通機車  每小時 10 元   修改 │ ← 收合：一行摘要
├──────────────────────────────────────┤
│ [紅黃牌] 大型重機                 收合 │ ← 展開中
│ 收費方式                             │
│ (未確認)(免費)(依現場公告)(計時)     │
│ (●計次)(每日)(依時段不同)(比照其他車種) │
│ 每次金額  [ 40 ] 元                  │
│ 跨日怎麼收                           │
│ ( 隔日另計 )                         │
│ ( 停多久都只收一次 )                 │
│ (● 未確認 )                          │
│ 更多收費規則 ▸                       │ ← 有效時間、延長
├──────────────────────────────────────┤
│ [汽車] 汽車  未確認               修改 │
└──────────────────────────────────────┘
★ App 會顯示：大型重機每次 40 元（隔日是否另計未確認） │ ← 公告牌預覽
```

寬螢幕（≥ 1040 px，管理站與平板）：左邊車種清單，右邊固定公告牌預覽；展開的車種欄位在中間。

```text
┌────────────────┬──────────────────────────────┬────────────────────┐
│ 普通機車 每小時10元│ 大型重機                      │ ★ App 會顯示       │
│ ▶ 大型重機       │ 收費方式 (計次)               │ ┌────────────────┐ │
│ 汽車   未確認    │ 每次金額 [40] 元              │ │ [紅黃牌] 大型重機│ │
│                │ 跨日怎麼收 (隔日另計)          │ │   每次 40 元     │ │
│                │ 更多收費規則 ▸                │ │   ☾ 隔日另計     │ │
│                │                              │ └────────────────┘ │
└────────────────┴──────────────────────────────┴────────────────────┘
```

最醒目的是公告牌預覽：編輯者要確認的是騎士會讀到的那句話，這與 #96 的決定一致。

**新增停車點與修改建議（App，C5）**

手機 390 px：

```text
新增停車點                        取消
位置：地圖中心（臺北市大安區）
格位
[機車格][重機格][汽車格]            ← GroundMarking，沿用
收費格還是免費格
( 收費 )( 免費 )( 未確認 )
有限制嗎（可複選）
[ ] 限時   [ ] 限電動機車   [ ] 身障特製機車
……可停車種、收費（FeeEditor）、補充資訊……
[ ★ 送出停車點 ]
```

修改建議的收費頁：每個車種顯示目前值；沒動的車種寫「維持目前：每小時 10 元」，送出時不帶這個車種（§7 第 3 項逐車種合併）；要清除時必須按「改成未確認」，送出前的「你要改的內容」清單會寫「大型重機費率：每次 40 元 → 未確認」。

寬螢幕（≥ 700 px）：表單維持單欄、最寬 560 px，FeeEditor 的車種並排（沿用 ≥ 520 px 並排的既有規則），公告牌預覽固定在表單右側。最醒目的是送出按鈕，因為這是表單唯一的主要動作；預檢提示放在出錯的欄位正下方（沿用 #94）。

**管理站點位表單與審核差異表（C6）**

手機 390 px（管理站 mobile-dark smoke 也驗這個寬度）：

```text
點位：市府轉運站地下停車場
分區資料已涵蓋全場  [ 否 ▾ ]       ← zones_complete，有說明文字
分區 機車區                    展開 ▾
  區域 [機車區▾]  格位 [機車格▾] 用途 [普大共用▾]
  收費格 [收費▾]  依據 (●公告網址)(牌面照片) [https://…]
  到期日 [2026-10-05]
  FeeEditor（同 App）
原始公告文字（匯入，唯讀）
  「重機比照機車費率2倍…」
[ ★ 儲存點位 ]
```

審核頁差異表，寬螢幕：

```text
┌───────────┬────────────────────┬────────────────────┬────────┐
│ 欄位        │ 目前               │ 建議（合併後）      │        │
├───────────┼────────────────────┼────────────────────┼────────┤
│ 普通機車費率 │ 每小時 10 元        │ 維持目前            │        │
│ 大型重機費率 │ 每次 40 元          │ 每次 40 元，隔日另計 │ 有變更  │ ← 黃牌黃底線＋文字
│ 汽車費率    │ 每小時 40 元        │ 改成未確認（清除）   │ 會清除  │ ← 紅線紅＋文字
└───────────┴────────────────────┴────────────────────┴────────┘
[ 套用建議 ]  [ 修改後套用 ]  [ 駁回 ]
```

手機上差異表改成上下排列：每個欄位一組，依序「目前」「建議」與狀態文字。最醒目的是「建議（合併後）」欄，因為管理員要判斷的是套用後的結果，不是建議原文；狀態同時用文字（「有變更」「會清除」）與底線表示，不只靠顏色。

### 8.5 FeeEditor 的分組與漸進展開

1. **以車種分組**，順序固定為普通機車、大型重機、汽車；App 表單中目前車種預設展開，其他收合成一行摘要（摘要就是公告牌上的那句話）。管理站寬螢幕全部列在左欄。
2. **先選收費方式**，選了才出現必要欄位：計時→金額、計費時間；計次→金額、跨日怎麼收；每日→金額；依時段不同→時段清單；比照其他車種→比照誰、倍率（預設 1 倍）。
3. **選填規則收在「更多收費規則」**：首段 0 元（前幾分鐘 0 元）、計費單位、當日上限與何時重算、計次有效時間、延長。已經有值的規則即使收合，也在「更多收費規則」旁列出（例：「已設：當日上限 100 元」），不藏住已填的資料。
4. **時段清單**：每一段收合成「08:00–20:00 每次 30 元」，點了才展開；「加一個時段」放在清單末端；時段重疊或沒涵蓋 24 小時時，清單下方直接寫出缺的時間（「20:00–隔日 08:00 還沒有費率，會顯示未確認」），不擋儲存。
5. **三態選項永遠看得到**：計次的「跨日怎麼收」、多段計次的「停到下一個時段時」不收在「更多收費規則」，因為使用者要求明確選擇，預設「未確認」。
6. **320 px 與 1.6 倍字級**：選項改成每列一個，選項文字換行，不水平捲動；觸控目標 ≥ 48 px；鍵盤彈出時，目前輸入的金額欄位捲到鍵盤上方。

### 8.6 文案原則與關鍵文案草稿

原則：用騎士在公告牌上讀到的說法，不用系統名詞（不寫 `per_visit`、`renew`、「模式」）；主動語態；同一個動作在按鈕、提示、結果用同一個詞；錯誤訊息先說哪裡不對，再說怎麼改，不道歉。

| 位置 | 文案 |
| --- | --- |
| 收費方式選項 | 未確認、免費、計時、計次、每日、依時段不同、比照其他車種（「依現場公告」併入未確認，§7 第 15 項） |
| 跨日選項 | 隔日另計、停多久都只收一次、未確認 |
| 跨時段選項 | 進入新時段再收一次、只依進場時段收、未確認 |
| 首段 0 元欄位 | 前幾分鐘 0 元 ［ 20 ］ 分鐘（說明：「公告寫『首 20 分鐘 0 元』時填這裡，這不是免費格」） |
| 倍率欄位 | 是機車費率的幾倍 ［ 2 ］ 倍 |
| 主要按鈕 | 管理站「儲存費率」「儲存點位」；App「送出停車點」「送出修改建議」 |
| 成功提示 | 「已送出修改建議，管理員審核後會更新」（與按鈕同一個詞「送出」） |
| 錯誤：計時 0 元 | 「計時 0 元等於免費。格位免費請選『免費』；前段免費請填『前幾分鐘 0 元』。」 |
| 錯誤：收費格選了免費 | 「這是收費格，費率不能是『免費』。公告寫首段 0 元時，請填『前幾分鐘 0 元』。」 |
| 錯誤：比照的車種沒費率 | 「大型重機比照汽車費率，但還沒填汽車費率。請填汽車費率，或改選其他收費方式。」 |
| 提示：普大共用的免費格 | 「普大共用的免費格較少見，請附上公告連結或現場牌面照片，審核會比較快。」（P2 上線前只寫「公告連結」） |
| 依據顯示 | 「依據：現場牌面照片（管理員確認於 2026-10-20）」／「依據：公告（2026-10-06 起）」 |
| 修改建議：未改的車種 | 「維持目前：每小時 10 元」 |
| 修改建議：清除 | 按鈕「改成未確認」；確認清單「大型重機費率：每次 40 元 → 未確認」 |
| 空狀態：沒有費率 | 「還沒有費率資料。在現場看到收費公告牌，可以提出修改建議。」 |
| 過期依據 | 「試辦已於 2026-10-05 到期，請看現場公告」 |

### 8.7 各 PR 的畫面與驗證

每個畫面都驗 320、390、約 700（雙欄窄欄 320–360 px）、1280 px，1.6 倍字級與深色模式；widget test 斷言沒有 overflow、主要按鈕可點、觸控 ≥ 48 px、鍵盤彈出時表單與操作列可用。管理站另跑 `tool/admin_smoke.cjs`（desktop-light、mobile-dark），並親自看手機截圖。PR 說明附截圖路徑與一句設計說明。

| PR | 畫面與元件 | 設計品質重點 |
| --- | --- | --- |
| C1 | 無 UI | — |
| C2 | 詳情頁的停放分類文字改由轉換層產生（汽機共用不再顯示成普大共用），版面不變 | 文字與 P0 修正一致 |
| C3 | `FeeEditor`／`RateEditor` 擴充（汽車、比照與倍率、依時段不同、首段 0 元、計次三態、跨時段三態、延長、上限重算、計費單位）、新元件 `FeeBoard`；#96 管理站點位表單與審核頁「修改後套用」改用新元件；詳情頁的費率句子更新 | 首段 0 元不顯示成免費；三態預設未確認；手機一次展開一個車種；公告牌預覽是唯一醒目元素 |
| C4 | 詳情資格橫幅的依據列與缺口說明（試辦到期、分區不完整、公告不一致），銜接 #91 分層；逐區資格 | 資格結論仍是唯一粗體；過期用文字＋日曆圖示，不只靠琥珀色 |
| C5 | App 詳情頁費率與條件區（分區公告牌、時段表、首段 0 元、延長、隔日另計、汽車費率、依據與期限）；篩選（「免費」只篩 `mode:'free'`，首段 0 元不算免費；價格篩選仍等 P6 轉換完成）；新增停車點（收費屬性、限制、時段、分區區域、汽車費率）；修改建議（條件、汽車費率、維持目前、改成未確認、確認清單）；附依據（公告連結；P2 合併後加「附牌面照片」）；詳情顯示照片依據的文字（不顯示照片）；預檢提示 | 目前車種排第一；未確認＝問號＋文字；錯誤寫在欄位下方並說怎麼改 |
| C6 | 管理站點位表單（分區編輯：區域、格位、用途、收費屬性、依據與到期日、`zones_complete`、FeeEditor；依據選公告網址或已確認的牌面照片；`fee_source_text` 唯讀）；審核頁差異表（逐車種合併後的結果、會清除的標示）與「修改後套用」；匯入差異試算加「條件可轉換／費率可轉換／需人工」欄（銜接 stack B P6）；規則頁加到期日與到期提醒（銜接 stack B P5） | 「有變更」「會清除」用文字＋底線，不只靠黃／紅；主要動作只有一個 |

## 參考

- 臺北市停車管理工程處，大型重型機車停放路邊收費機車格新制（115/9/30 公告、115/10/6 實施）：https://pma.gov.taipei/News_Content.aspx?n=E43F2E5AE1223B3D&s=1190C312983454BA&sms=78D644F2755ACCAA （2026-10-26 讀取）
- 身心障礙者專用停車位設置管理辦法第 12 條第 3 項「非經監理單位檢驗合格之特製機車不得使用身心障礙者專用機車停車位」：https://law.moj.gov.tw/LawClass/LawSingle.aspx?pcode=D0050069&flno=12 （2026-10-26 讀取）
- 臺北路外試辦「機車費率 2 倍」：PLAN.md 匯入紀錄（停管處新聞稿附件）；媒體報導 TVBS https://cars.tvbs.com.tw/life/313047 。各場域期限待逐處查證。
- 臺北市公有停車場收費費率自治條例附表「大型重型機車：依小型車費率計收」：https://laws.gov.taipei/law/LawSearch/LawPrint/FL012579?type=0 （依搜尋結果摘錄，未逐字核對原文；附表現行版本待查證）
- 桃園市 2026/4/1 試辦（含免費機車格）：交接法規 A 與 `assets/rules/parking_rules.json` 的來源網址，本文未重新查證。
