# 既有停車點費率轉換：staging 執行紀錄（2026-11-01）

Refs #235。工具：`tool/convert_fees.dart`（#253）。這份是 staging 的紀錄；production 上線時要依同樣步驟重跑（列在 #262 的上線清單）。

## 決定
- 使用者先選「逐類核准推定規則」（PM_ANS_20261101_88），再逐類勾選核准 5 類（PM_ANS_20261101_91）。
- 使用者確認抽樣與 45 種寫法都讀對後，同意只寫入 staging（PM_ANS_20261101_100）。
- 由使用者在自己的終端機執行（PM_ANS_20261101_101）。
- 執行者是匯入機器人（service actor，沒有登入方式；PM_ANS_20261101_102）。
- 左營海軍眷村 3 筆不轉換，改人工補正（#258）。

## 執行
- 時間：2026-11-01T12:56:42Z（UTC）
- 環境：staging（`xtrtpyfzifggcmskrkyu`），main `43afc9f` 的獨立 worktree；migration 202611011200 由 CD `ae3c741` 部署後執行。
- 執行者：`e6e2f137-db36-506e-b91f-e0b94cd0ccb2`（匯入機器人）；稽核 `convert_fee` 186 筆。
- 指令（金鑰只放在使用者 shell 的環境變數，不進檔案）：

```sh
dart run tool/convert_fees.dart --apply \
  --actor e6e2f137-db36-506e-b91f-e0b94cd0ccb2 \
  --note "staging 依推定轉換既有費率（#235，PM_ANS_20261101_100）" \
  --assume motorcycle-bay-unlabelled --assume official-lot-unlabelled \
  --assume official-scooter-beside-unlabelled --assume car-bay-unlabelled \
  --assume community-heavy-as-car \
  --exclude official:2124a574-a937-52ff-a717-b74b630f1f4a \
  --exclude official:9b2a65e4-9b81-5bb9-8838-a5eb0b502cbd \
  --exclude official:c3935586-138c-5b64-830e-e72bf75b0f57
```

## 結果
`fee` 為空的點位 1,341 筆（社群 489、官方 852），其中寫入 186 筆、略過 0 筆：

| 類別 | 寫入 |
|---|---:|
| motorcycle-bay-unlabelled（機車格費率未註明車種 → 普通機車） | 56 |
| official-lot-unlabelled（官方停車場費率未註明車種 → 普通機車） | 2 |
| official-scooter-beside-unlabelled（官方機車費率旁另有未註明車種的費率；扣除左營 3 筆） | 4 |
| car-bay-unlabelled（汽車格寫「免費」 → 大型重機免費） | 18 |
| community-heavy-as-car（車友回報：大型重機比照汽車費率，45 種寫法） | 106 |
| **合計** | **186** |

沒有寫入的：
- 無法判斷，維持空值：785 筆。其中沒寫明費率 531、只有汽車費率 216、只有月租或定期票 38。
- 不能推定，或推定類別未核准：367 筆。
- 排除：3 筆（#258）。

## 抽查（唯讀 SELECT，10 筆，5 類都有）
寫入的 `fee` 與重算的 `fee_note` 都和預覽一致：

| 點位 | 類別 | fee_note |
|---|---|---|
| 中央路3段 普大共用機車格 | motorcycle-bay-unlabelled | 機車每 4 小時 30 元；大型重機費率未提供 |
| 義山路二段 普大共用機車格 | motorcycle-bay-unlabelled | 機車每 4 小時 30 元；大型重機費率未提供 |
| 好市多中華店停車場 | official-lot-unlabelled | 機車免費；大型重機費率未提供 |
| 國雲小港轉運站(立體)停車場 | official-lot-unlabelled | 機車免費；大型重機費率未提供 |
| 大統百貨停車場 | official-scooter-beside-unlabelled | 機車免費；大型重機費率未提供 |
| 燦坤堤頂停車場 | official-scooter-beside-unlabelled | 機車免費；大型重機費率未提供 |
| 仁愛路四段122巷4號對面汽機車共用車格 | car-bay-unlabelled | 大型重機免費 |
| 台北市信義區松勇路 | car-bay-unlabelled | 大型重機免費 |
| 桃園醫院露天汽車停車場 | community-heavy-as-car | 大型重機每小時 30 元，當日上限 150 元 |
| 台灣聯通 台中草悟廣場-按車牌進 | community-heavy-as-car | 大型重機每小時 40 元 |

## production 上線時
1. 確認 production 已部署 migration 202611011200（`admin_convert_fees_as`）。#271 會讓 CLI 在缺少這支函式時先停下。
2. 確認匯入機器人已設成 service actor（PM_ANS_20261101_102）。
3. 先用相同的 `--assume`／`--exclude` 預覽（不加 `--apply`），核對各類筆數，再加 `--apply` 執行。
4. 執行後抽查，並另寫一份紀錄。

完整預覽與每筆清單只留在本機 scratch，不進 repo。
