# 停放條件與費率模型（P1–P4 設計）

> 狀態：設計草案，待使用者核准（2026-10-26）。只寫設計，不含程式。實作排在目前兩個 stack（第一批 #90–#95、stack B #97–#101 與後續層）合併之後，另開一個 stack。
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
| 限制 limits | `time_limit`（限時，帶 `max_minutes`）、`special_vehicle`（限特製車輛，帶 `kind`）、`ev_only`（限電動機車） | 新增 `condition.limits[]` | 身障專用機車格是 `special_vehicle`＋`kind:'disabled_modified'`：須為經監理單位檢驗合格的特製機車，持識別證本身不足（法規 C） |
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

`condition` 的 JSON 契約（所有鍵都可省略，省略即未確認）：

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
    "effective_date": "2026-10-06",
    "expires_on": null
  }
}
```

- `use='share'` 時 `share` 必填；`use='usual'` 時不得有 `share`。
- `schedule[].days` 為 `all`／`weekday`／`holiday`，或星期陣列 `["mon",…]`；`from > to` 表示跨午夜。`vehicles` 為該時段允許停放的車種（`scooter`／`heavy`／`car`）。
- `basis` 記錄這個條件本身的公告依據（例如臺北 36 處試辦場域的分區），與 `city_rules` 分開。`expires_on` 已過即視為依據失效（§3.3）。
- 「特殊車型及地方特別開放另處理」（需求 6）：特殊車型用 `limits[].kind='special_vehicle'`；地方開放仍放在 `city_rules`，不寫進格位。

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
| `disabledMotorcycle` | bay=motorcycle, limits=[special_vehicle: disabled_modified] | 修正法規 C |
| `timedMotorcycle` | bay=motorcycle, use=usual, limits=[time_limit]，charge **未確認** | 現行把它一律當 `paidMotorcycle`，無法表達限時免費格 |
| `flexShared` | bay=car, use=share, share=car_motorcycle，schedule 未確認 | 取代 `reportedAccess` 把它推成普大共用的分支 |
| `evMotorcycle` | bay=motorcycle, limits=[ev_only] | |

分區沒有 `condition` 時，由既有 `access` 推導：`scooterOnly`→機車格 usual 只限普通；`scooterHeavy`→機車格 share=scooter_heavy；`heavyCar`→汽車格 usual（大型重機依法可停汽車格）；`heavyOnly`→重機格 usual；`noMotorcycle`→沒有機車可停的格位；null→未確認。`access` 保留為舊版相容欄位，有 `condition` 時由轉換層推導寫回，不另外編輯。

**寫入：`legacySpaceType(condition, placement)`（有 `condition` 的資料）**

依序比對，第一個符合的就是 `space_type`：路外→`offStreet`；`special_vehicle`→`disabledMotorcycle`；`ev_only`→`evMotorcycle`；`share=car_motorcycle`→`flexShared`；`time_limit`→`timedMotorcycle`；bay=heavy→`heavyOnly`；bay=car→`car`；bay=motorcycle 且 charge=toll→`paidMotorcycle`；bay=motorcycle 且 charge=free→`freeMotorcycle`。

**舊版能不能正確表示（`legacySafe`）**：condition 依上表轉回 `space_type`，再用 `conditionOf` 讀回來，結果與原 condition 相同（或只少了舊版本來就當成未確認的資訊），才算 legacy-safe。例如：

- 機車格、共用 scooter_heavy、Toll → `paidMotorcycle`，安全（舊版依縣市規則判斷，結果一致或更保守）。
- 機車格、charge 未確認 → 沒有對應的舊值，**不安全**。
- 有 `schedule` 的重機格、有 `basis.expires_on` 的條件 → 舊版會忽略時段或期限，**不安全**。
- 限時格且 charge=free → `timedMotorcycle`，舊版當成收費限時格，資格可能較寬鬆，**不安全**。

不安全的資料在兩版 viewport 與收藏中改用保守投影（§5.2、§5.3）。

## 2. 費率模型

### 2.1 範圍

在既有 `Fee { scooter, heavy }` 加上 `car`（使用者 2026-10-26 決定納入汽車結構化費率），並擴充 `Rate`。原則不變：

- 缺少的車種＝未確認。沒有重機費率時**不回退成機車費率**；只有公告明定比照時才寫 `same_as_*`（法規 B）。
- 比照只在**同一個 `fee` 物件**內解析：分區的 `heavy: same_as_car` 找同一分區的 `car`，找不到就是未確認，不找點位或其他分區（#80 的決定延伸）。
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
     | {"mode":"by_time","periods":[{"days":d,"from":"HH:MM","to":"HH:MM","rate":rate}]}
ext  = {"amount":元,"max_times":n[,"minutes":分]}
r    = "calendar_day" | "rolling_24h" | "per_entry"
w    = "midnight"
```

| 新鍵 | 意思 | 範圍 | 缺值 |
| --- | --- | --- | --- |
| `factor_pct` | 比照倍率，200＝2 倍 | 整數 100–1000 | 1 倍 |
| `unit_minutes` | 計費單位（例：每小時 20 元、半小時計） | 1–`per_minutes` | 未確認計費單位（顯示時不寫單位） |
| `free_minutes` | 免費前段（Toll 方案首段 0 元） | 1–1440 | 沒有免費前段 |
| `cap_reset` | `daily_cap`／`daily` 何時重新起算 | 三選一 | 未確認（顯示上限，加註「上限計算方式未確認」） |
| `max_minutes` | 計次有效時間（既有） | 1–1440 | 未確認 |
| `renew` | 計次跨過某時點重新計次（例：跨日零時累計收費） | `midnight` | 未確認 |
| `extension` | 付費延長：每次金額、最多次數、每次分鐘 | 金額 0–10000、次數 1–10、分鐘 1–1440 | 沒有 `extension`＝未確認可否延長；`minutes` 缺＝延長時長未確認 |
| `by_time.periods` | 時段差別費率，最多 8 段；內層 `rate` 不可再是 `by_time` 或比照 | | 沒有涵蓋的時間＝未確認 |

- `car` 不可用 `same_as_*`；`scooter` 也不可（既有規則）。
- 時段費率不寫 `holiday` 以外的節日；國定假日判定見 §7 第 4 項。
- 資料表 `valid_fee()` 的大小上限由 1024 bytes 提高到 4096 bytes，以容納 `by_time`。

### 2.3 Toll 首段 0 元 ≠ Free

`charge='toll'` 的格位，費率可以是 `per_visit` `amount:0`＋`max_minutes`，或 `hourly`＋`free_minutes`；顯示為「首 20 分鐘 0 元」，**不**顯示「免費」，也不讓價格篩選把它當成免費格。只有 `mode:'free'` 才是免費。組合規則見 §4.3。

#94 在研究文件 §5.8 留下的階段 1 候選規則「計次或每日 0 元」會誤攔臺北限時格；實作那條規則時須排除 `per_visit` 帶 `max_minutes`（或 `charge='toll'` 的限時格）的情況。

### 2.4 臺北實例

以下金額除臺北路邊新制外都是示意，結構才是重點；實際值以匯入時的公告為準。

**(a) 路邊收費機車格，大型重機新制（115/10/6 起，停管處 115/9/30 公告）**

公告原文：計次路段「每次新臺幣 40 元」「凡跨越每日零時停車者，累計收費」；計時路段「每小時新臺幣 20 元，停車當日上限為 100 元」「停車計費單位採半小時計算」；限時停車格「首單新臺幣 0 元，限停 20 分鐘（得付費新臺幣 40 元延長 1 次停放）」。來源：https://pma.gov.taipei/News_Content.aspx?n=E43F2E5AE1223B3D&s=1190C312983454BA&sms=78D644F2755ACCAA

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
| 汽車格 share=car_motorcycle | 依 schedule 與共用涵蓋範圍（§7 第 1 項） | 依法可停汽車格；schedule 只限制機車時段 |
| `special_vehicle: disabled_modified` | 有條件：「限經監理單位檢驗合格的身障特製機車，持識別證本身不足」 | 同左 |
| `ev_only` | 有條件：限電動機車 | 同左 |

**2. 地方公告**

- 公告來源有兩層：縣市規則 `city_rules`（全市或行政區），以及條件自己的 `basis`（特定場域、特定路段，例如試辦場域）。
- `city_rules` 新增 `expires_on date`（可為 null）。`now ≥ expires_on` 的規則不算有效，結果為「此地區的規則已過期，請以現場標誌標線為準」（`unverified`），不回落到全國規則，因為過期的地方開放可能已經延長也可能已經結束。
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
| 可進場 | 有分區，但沒有一區對目前車種開放 | false | **待確認**：「場站開放大型重機，但已知分區沒有標示可停區域，請依入口公告」；不推定全場禁停 |
| 可進場 | 同上 | true | **待確認**：「場站與分區資料不一致」，送管理員（不是不可停，因為兩份資料互相矛盾） |
| 未確認 | 至少一區開放 | 任意 | 待確認（分區開放不能推出場站可進場，現行語意） |

- `zones_complete`（新增，點位層級布林，預設 false）：只有官方匯入或管理員能設為 true，表示分區清單涵蓋全場。社群回報與 `validate.ts` 不接受此鍵。
- 分區的開放判斷：有 `condition` 用 condition，沒有則用 `access` 推導（§1.3）；推導不出就是該區未確認。未確認的分區不繼承其他分區或場站的資格（DESIGN.md 既有決定）。
- 分區 `basis.expires_on` 已過 → 該區的開放依據失效，該區視為未確認。

**4. 價格**

價格與資格分開回傳，價格未知不會讓資格變差，資格未知也不會隱藏已知價格：

- 每個可停處（路邊點，或每個對目前車種開放的分區）各回一個 `PriceAnswer`：`known(rate)`／`partial(rate, gaps)`（例如有費率但上限計算方式或延長時長未確認）／`unknown`。
- 解析順序沿用 #80：分區自己的 `fee` → 點位 `fee`（只在所有分區都沒有 `fee` 時）→ 舊文字。比照依 §2.1 只在同一 `fee` 物件內解析，倍率直接套在金額、上限與延長金額上；被比照的車種缺值時回 `unknown`，文字為「比照汽車費率（汽車費率未提供）」。
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
- **時段**：本輪只判斷「此格位有時段限制」並回 `conditional(timeLimited)`，顯示各時段允許車種；不依目前時間切換狀態（§7 第 4 項）。

## 4. 三端契約與驗證

### 4.1 單一來源

比照 #94 預檢的做法（`precheck_rules.json` 由 Deno 讀取，Dart 鏡像並以測試逐欄比對；`precheck_cases.json` 兩邊共同執行）：

| 檔案 | 內容 | 讀取者 |
| --- | --- | --- |
| `supabase/functions/_shared/parking_contract.json` | 列舉值（bay、use、share、charge、limits、area、days、fee mode）、每個 mode 的鍵與範圍、§1.3 轉換表、§4.3 組合表 | `validate.ts` 直接 import；Dart 鏡像常數，測試與 JSON 逐欄比對；`tool/gen_contract_sql.py` 產生 SQL |
| `supabase/functions/_shared/parking_contract_cases.json` | 合法／不合法的 `condition`、`fee`、分區與組合案例，以及轉換往返、`legacySafe` 的期望值 | Deno 測試、Flutter 測試、由產生器轉成 pgTAP |
| `assets/rules/parking_rules.json`（既有） | 縣市規則 | App、§5.7 引擎的測試向量 |

SQL 不能在執行時讀 JSON，所以由 `tool/gen_contract_sql.py` 從契約產生 `valid_condition()`、`valid_fee()` 的鍵表與 pgTAP 案例檔，產物進版控；CI 重新產生並以 `git diff --exit-code` 確認沒有漂移（`tool/ci_changes.py` 把契約 JSON 變更同時路由到 Flutter、Deno 與 DB 檢查，同 #94）。

### 4.2 三端各自負責

| 層 | 檢查 | 失敗時 |
| --- | --- | --- |
| 資料表 check（`valid_condition`、`valid_fee` v2、`valid_zones`） | 形狀、鍵、範圍；不可能成立的組合（§4.3 標 DB 的列） | 寫入失敗。管理員 RPC 與匯入也受約束 |
| `validate.ts` | 同上，外加信任邊界：社群不可帶 `zones_complete`、`basis`；`proposed` 白名單加入 `condition` | 400 |
| 預檢 `precheck.ts`（#94） | §4.3 標「預檢」的範圍與政策組合，可單獨停用、調參 | `fix`／`hold` |
| Dart `ParkingCondition.fromJson`、`Fee.fromJson` | 同形狀規則；不合法的部分讀成未確認，不讓整張地圖失敗 | 該面向未確認 |

原則：**資料表只擋「任何情況都不成立」的組合；本專案範圍或政策上的限制放在預檢**，因為範圍會隨公告改變（例如桃園 2026/4/1 起試辦開放免費機車格），寫死在 check 會擋下合法的新資料。

### 4.3 組合一致性（格位用途 × fee × facility_type）

| 組合 | 層 | 動作 | 理由 |
| --- | --- | --- | --- |
| 路外點（`offStreet` 或路外 `facility_type`）帶頂層 `condition` | DB | 拒絕 | 路外的格位資訊在分區 |
| 路邊點帶 `parking_zones` 或 `zones_complete` | DB | 拒絕 | 同 #94 `street_lot_details` |
| 有 `condition` 但 `space_type ≠ legacySpaceType(condition)` | DB | 拒絕 | 避免雙份狀態 |
| `use='share'` 缺 `share`，或 `use='usual'` 帶 `share` | DB | 拒絕 | |
| `share='scooter_heavy'` 但 bay ≠ motorcycle；`share='car_motorcycle'` 但 bay ≠ car | DB | 拒絕 | 需求 4 |
| `share='car_motorcycle'` 在路外分區 | 預檢 | fix | 本專案只列路邊（需求 4），屬範圍而非不可能 |
| `share='scooter_heavy'` 且 `charge='free'` | 預檢 | 見 §7 第 2 項 | 使用者列為「目前僅 Toll」，但不可變成大型重機不能停免費機車格的全國限制（法規 A） |
| `charge='free'` 而任一已填車種的費率不是 `free` | 預檢 | fix | |
| `charge='toll'` 而某車種為 `mode:'free'` | 預檢 | fix，提示改用「首段 0 元」 | 法規 D |
| bay=heavy 而有 `fee.scooter` | 預檢 | fix | 普通機車不能停重機格 |
| bay=motorcycle 或 area=motorcycle 而有 `fee.car` | 預檢 | fix | |
| area=car 而有 `fee.scooter`、且沒有地方公告開放 | 預檢 | hold | 需求 6；特別開放須另附依據 |
| `time_limit.max_minutes` 與 `per_visit.max_minutes` 不同 | 預檢 | fix | |
| `heavy` 為 `same_as_car` 但同一 `fee` 沒有 `car`（新送出） | 預檢 | fix | 延伸 #94 `fee_follows_missing_scooter`；既有資料仍允許，讀成未確認 |
| `daily_cap < amount`、`hourly` 且 `amount=0` 沒有 `free_minutes` | 預檢 | fix | 既有 #94 規則沿用到 `car` 與 `by_time` 內層 |
| `extension` 在 `charge='free'` 的格位 | 預檢 | fix | |

## 5. 遷移與相容（交接 P6）

### 5.1 migration 原則

- 一律新增 migration，不改已部署的檔案；版號實作時向 main 申請（目前已分配到 202610260260，本 stack 需要 3 個）。
- 先加欄位與函式，再改讀取端，最後才讓寫入端送新欄位；每一步都可以單獨回退。
- 重新定義 `apply_report`、`admin_resolve_report`、`admin_upsert_spot`、`admin_promote_spot`、`admin_spot_fields` 時，以當時 `main` 的最新定義為基礎（目前最新分別在 #96 的 202610260010 與 202610250080）。
- 新增：`community_spots.condition jsonb`、`official_heavy_spots.condition jsonb`、兩表 `zones_complete boolean not null default false`、`city_rules.expires_on date`；`valid_zones()` 取代 `valid_zone_fees()` 的 check（多檢查 `area`、`condition`）。`valid_fee()` 以 `create or replace` 擴充，既有資料全部仍合法（新契約是舊契約的超集合）。
- 新 check 用 `not valid` 加上後再 `validate constraint`，與 `city_rules_restriction_required` 的做法一致；既有資料 `condition` 皆為 null，不會失敗。

### 5.2 兩版（三版）viewport

`ParkingRepository._viewport` 目前先呼叫 `_v2`，`PGRST202` 時回退到原版。本 stack 新增 `_v3`，新版 App 依序嘗試 v3 → v2 → 原版：

| RPC | 給誰 | 回傳 |
| --- | --- | --- |
| 原版 | 不認得 4 種新 `space_type` 的舊版 | 不變（只回原本 5 種） |
| `_v2` | 認得 9 種 `space_type`、不認得 `condition` 的版本 | legacy-safe 的列照舊；**不安全的列改回保守投影**：`space_type='offStreet'`、兩個車種旗標 null、`status='pending'`（社群點）。這些版本對這種投影一律判「待確認」，與收藏 `exact` 的既有做法相同 |
| `_v3` | 新版 | 全部欄位，含 `condition`、`zones_complete`、新 `fee` |

`public_spots` view 新增欄位會一併出現在 v2 的回傳型別中；舊版 `ParkingSpot.fromJson` 忽略不認得的鍵，所以多出欄位不會出錯，需要處理的只有「舊版會誤讀」的列。官方點的 v2 沒有 `status` 可降，改成兩個車種旗標 null，舊版官方路外點在旗標 null 時判待確認。

分區的新鍵（`area`、`condition`）不需要投影：舊版只讀 `name`、`access`、`fee` 等既有鍵，`access` 由轉換層寫回，舊版看到的分區分類與新版一致。

### 5.3 收藏 JSON

- `toJson` 新增 `condition`、`zones_complete`。legacy-safe 的點照舊寫；不安全的點沿用 `_newKinds` 的手法，但把真實值放在**新的** `exact_v2` 鍵（`space_type`、旗標、`status`、`condition`），頂層寫保守投影。
- 不能沿用既有 `exact` 鍵：目前已發布的版本會把 `exact` 合併回頂層，再存檔時寫回放寬的值且丟掉 `condition`。改用它不認得的 `exact_v2`，舊版只會讀到保守的頂層，再存檔時遺失的是資訊而不是安全性。
- 新版讀收藏時 `exact_v2` 優先於 `exact` 優先於頂層。收藏的 `fee` 原樣保存；舊版讀到新 `Rate` 鍵時該車種為未確認。

### 5.4 新舊 App 讀寫

| 情境 | 結果 | 處理 |
| --- | --- | --- |
| 舊版讀新資料 | 不能表示的條件顯示待確認；新費率鍵的車種顯示未確認；`car` 被忽略 | §5.2、§5.3 的投影 |
| 舊版新增停車點 | 不帶 `condition`，伺服器存 null，新版用 `conditionOf` 推導 | 不需處理 |
| 舊版擁有者修改（`update`） | `apply_report` 只更新名稱、`fee_note`、備註，不碰 `condition`／`fee` | 重新定義時維持只更新這三欄 |
| 舊版送費率修改建議 | 舊版把它讀不懂的車種當成未確認，送出的 `fee` 會少掉 `car` 或少掉被它判成未確認的 `heavy` | **費率建議改為逐車種合併**：`proposed.fee` 沒有的車種保留現值，要清除須明確送 `null`（§7 第 3 項）；審核頁差異表照合併後的結果顯示 |
| 舊版送 `fee_note` 與 `fee` | #96 要求 `fee_note = fee_note_of(fee)`，新版句子不同時會被擋 | 審核頁採納費率時一律用新版 `feeNoteOf` 重算 `fee_note`，不採用建議中的文字 |
| 匯入覆寫 | `official_sql()` 目前 `on conflict do update set` 全部欄位，含 `parking_zones` | P6 匯入改為只更新官方欄位（研究 §5.6 第 7 點），並逐區保留匯入資料沒有提供的 `condition` |

### 5.5 匯入與資料轉換（銜接 stack B P6）

P6 匯入（`feat/admin-import`，stack B 第 5 層）的轉換規則延伸到條件與汽車費率，不另做一套：

- **只轉換確定的文字**：同一段文字只能對到一種 `condition`／`rate` 才寫入；「請依現場公告」「未知」、混有月租或身障費率、無法分辨計次或計時路段者，維持 null 交人工。
- **保留原文與來源**：原始費率文字不能放在 `fee_note`（#96 要求它等於 `fee_note_of(fee)`），另存在新欄位 `fee_source_text`，並在 `condition.basis`／`source_url` 保留出處（§7 第 5 項）。
- **差異試算多三欄**：條件可轉換／費率可轉換（含汽車）／需人工；有覆蓋層或管理員已改過的欄位另列（研究 §5.6 第 7 點）。
- **轉換器共用契約**：P6 的解析結果以 `parking_contract.json` 與 `valid_fee()` 驗證。若 P6 先於本 stack 的 P2 合併，P6 只產生 v1 費率（scooter／heavy），汽車金額留在文字；P2 合併後重跑 P6 的差異試算即可補上汽車，不重寫轉換器。
- 臺北路邊格位的官方格種代碼可直接對應條件（`SpaceType` 註解已記錄 pktype 04／18 身障、20 限時、22 汽機彈性共用、11 機車區）；代碼表其餘值待查證，對不到的不轉換。

## 6. 實作切分（stack C，兩個 stack 合併後開工）

順序由下而上，每張的 base 是下一層分支。每張都可單獨合併：上層沒合併時，下層只是多了沒人使用的欄位或函式。

| # | 分支 | 範圍 | 依賴 | 測試 | 回退 |
| --- | --- | --- | --- | --- | --- |
| C1 | `feat/parking-contract` | `parking_contract.json`、案例檔、`ParkingCondition` 模型與轉換層（純 Dart）、`validate.ts` 的 `validCondition`（尚未接上 action）、SQL 產生器與 CI 漂移檢查。**無 migration、無行為變更** | main | 轉換往返、`legacySafe` 窮舉 9 種 `space_type` × 5 種 `access`；JSON 與 Dart 常數逐欄比對；Deno 與 Flutter 共同執行案例 | 直接 revert |
| C2 | `feat/parking-condition-db`（P1） | migration：`condition`、`zones_complete`、`valid_condition`、`valid_zones`、`public_spots` 加欄位、viewport v3 與 v2 保守投影；`apply_report` 建立時存 `condition`；`admin_spot_fields`、`admin_resolve_report` 白名單；`ParkingSpot` 讀寫、收藏 `exact_v2`；`reportedAccess` 改走轉換層 | C1 | pgTAP：check 允許／拒絕、v2 投影、v3 完整、RLS；收藏往返（新版→舊版模擬→新版）；舊 JSON 相容 | 新欄位全為 null 時行為與現在相同；App 回退到 v2 |
| C3 | `feat/fee-v2`（P2） | `Fee.car`、`Rate` 新鍵與 `by_time`；`valid_fee` 擴充；`fee_note_of` SQL 與 `feeNoteOf` 新句子（沿用 #96 的共用句子測試）；`fee_source_text` 欄位；費率建議逐車種合併；`FeeEditor` 加汽車與新選項 | C1（可與 C2 平行，建議疊在 C2 上減少衝突） | 舊 fee 全部仍合法；新鍵允許／拒絕；Dart／SQL／Deno 句子一致；舊版讀新 fee 為未確認；合併語意 pgTAP | 新鍵不寫入即與現況相同 |
| C4 | `feat/parking-decision`（P3） | `decideParking`、`ruleVerdict`、`PriceAnswer`；`eligibility()` 改為包裝；`city_rules.expires_on`；#91 `eligibilityDisplay` 改讀 `basis` | C2、C3 | 窮舉 條件 × 車種 × 規則 × 分區完整度 × 期限；`eligibility()` 包裝對既有測試全數不變（除交接列出的三個錯誤）；§5.7 共同向量 | 包裝可切回舊實作（保留一版） |
| C5 | `feat/parking-conditions-app`（P4 App） | 詳情（分區、時段、首段 0 元、延長、依據與期限）、篩選、新增停車點與修改建議的條件／汽車費率欄位；預檢規則（§4.3）加入 `precheck_rules.json` | C4 | widget：320／390／700／1280 px、1.6 倍、深色；不溢出、觸控 ≥ 48 px；預檢案例 | UI 隱藏新欄位 |
| C6 | `feat/parking-conditions-admin`（P4 管理站） | 點位表單分區編輯（`area`、`condition`、`fee`、`zones_complete`）、審核頁條件差異、規則頁 `expires_on` | C4（可與 C5 平行） | admin smoke desktop-light／mobile-dark；pgTAP 管理員路徑 | 同上 |

**會動到的既有功能與避免重工**

| 既有 | 本 stack 如何接 |
| --- | --- |
| #80 分區費率（`ParkingZone.fee`、詳情優先順序） | 優先順序與「不沿用其他分區」不變；C3 只擴充 `Fee`，C5 在既有逐區顯示上加汽車列 |
| #96 管理站費率（`fee_note_of`、`FeeEditor`、審核 `fitsField`） | C3 以 #96 的 SQL `fee_note_of` 與共用句子測試為基礎擴充，不另寫一份；`FeeEditor` 加汽車區塊，管理站與 App 同時受益 |
| #91 資格分層 | C4 讓 `eligibilityDisplay()` 改讀 `ParkingDecision.basis`，分層表不變 |
| #94 預檢 | §4.3 的「預檢」列加進同一份 `precheck_rules.json`，不另建；修正階段 1 候選「計次 0 元」的排除條件（§2.3） |
| P5 規則頁（stack B 第 4 層） | 若 P5 先合併，C6 在其表單加 `expires_on`；若 C4 先合併，P5 直接含此欄位。兩邊都以 `CityRule` 模型為準 |
| P6 匯入（stack B 第 5 層） | 見 §5.5；轉換器共用契約，C3 合併後重跑差異試算 |
| P0（身障文字、汽機共用分類） | C2 用轉換層取代 P0 修過的分支，P0 的測試保留為回歸測試 |

## 7. 待使用者拍板

只列會阻擋實作的決策。

**1. 汽機車共用格的機車涵蓋範圍**（阻擋 C1 的 `share` 契約與 C4 判斷；交接需求 4 尚未確認）

- A. 只涵蓋普通重型機車：大型重機本來就能依法停汽車格，共用標示只影響普通機車。
- B. 普通與大型都涵蓋，大型重機在機車時段也可停。
- C. 不預設，每筆共用格須在 `schedule[].vehicles` 寫明公告列出的車種；沒寫的車種為未確認。

建議 **C**：各縣市公告寫法不同，預設任何一邊都可能放寬。大型重機停汽車格的法源與共用標示無關，不受影響。

**2. 普大共用是否允許 Free**（阻擋 §4.3 的組合規則）

- A. 只允許 Toll（交接目前的列法），免費格標成共用一律攔下。
- B. 契約允許 Free，預檢 `hold` 並要求附公告依據。
- C. 完全不限制。

建議 **B**：桃園 2026/4/1 起試辦已含免費機車格（交接法規 A；本文未重新查證該公告），A 會把它變成全國限制；C 則失去「目前列為僅 Toll」的提醒。另外，縣市規則開放一般免費機車格時格位用途仍是 `usual`，不需要標共用。

**3. 費率修改建議改為逐車種合併**（阻擋 C3；改變既有「缺車種＝未確認」在建議中的意思）

- A. 合併：建議中沒有的車種保留現值，清除要明確送 `null`。
- B. 維持整筆取代，由審核頁提醒「此建議會清除汽車費率」。

建議 **A**：舊版 App 讀不懂新費率時會把那個車種當成未確認並省略，整筆取代會讓舊版的建議清掉新版欄位，違反「舊版寫入不得清掉新版欄位」；B 靠管理員每次注意，容易漏。

**4. 時段是否依目前時間判斷**（阻擋 C4 範圍）

- A. 本輪只顯示時段與各時段允許車種，狀態固定「有條件・限時段」。
- B. 依目前時間切換可停／不可停，需要國定假日資料（來源與更新方式待定）。

建議 **A**：假日判定錯誤會直接造成誤判可停；先有結構化時段資料，之後再加 B 不需要改資料格式。

**5. 原始費率文字存放位置**（阻擋 C3 與 stack B P6 的銜接）

- A. 新增 `fee_source_text`（匯入與管理員寫入，詳情的「資料與查核」顯示「原始公告文字」）。
- B. 放回 `fee_note`，放寬 #96 的 `fee_note = fee_note_of(fee)` 規則。

建議 **A**：#96 的一致性規則是「騎士看到的句子就是結構化費率」的保證，放寬會讓兩者再度分歧；原文另存也能讓 P6 之後重新轉換。

**6. 官方場站可進場但已知分區都不開放時的狀態**（阻擋 C4；會改變現有官方點的顯示）

- A. 待確認，理由寫明「已知分區沒有標示可停區域，請依入口公告」（§3.2 第 3 步）。
- B. 有條件，提示依入口公告找可停區域。

建議 **A**：B 仍暗示「可停」，而資料實際上沒有任何一區可停；A 不推定全場禁停，也不讓騎士以為一定有位置。受影響的點數在 C4 實作時以 staging 查詢列出。

## 參考

- 臺北市停車管理工程處，大型重型機車停放路邊收費機車格新制（115/9/30 公告、115/10/6 實施）：https://pma.gov.taipei/News_Content.aspx?n=E43F2E5AE1223B3D&s=1190C312983454BA&sms=78D644F2755ACCAA （2026-10-26 讀取）
- 身心障礙者專用停車位設置管理辦法第 12 條第 3 項「非經監理單位檢驗合格之特製機車不得使用身心障礙者專用機車停車位」：https://law.moj.gov.tw/LawClass/LawSingle.aspx?pcode=D0050069&flno=12 （2026-10-26 讀取）
- 臺北路外試辦「機車費率 2 倍」：PLAN.md 匯入紀錄（停管處新聞稿附件）；媒體報導 TVBS https://cars.tvbs.com.tw/life/313047 。各場域期限待逐處查證。
- 臺北市公有停車場收費費率自治條例附表「大型重型機車：依小型車費率計收」：https://laws.gov.taipei/law/LawSearch/LawPrint/FL012579?type=0 （依搜尋結果摘錄，未逐字核對原文；附表現行版本待查證）
- 桃園市 2026/4/1 試辦（含免費機車格）：交接法規 A 與 `assets/rules/parking_rules.json` 的來源網址，本文未重新查證。
