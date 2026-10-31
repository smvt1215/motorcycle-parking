---
name: 機車停車指南管理站
description: 審核者用的管理站：每一筆資格都用普通機車／大型重機兩面車牌回答。
colors:
  rail-black: "#16181A"
  aluminium: "#E4E7E9"
  plate-white: "#FAFAF6"
  paper-white: "#FFFFFF"
  action-blue: "#1F5FA8"
  action-blue-deep: "#164A85"
  graphite: "#565C62"
  steel: "#9AA0A6"
  rivet: "#C9CDD1"
  divider: "#E1E4E6"
  section-divider: "#DDE0E3"
  map-ground: "#D6DADD"
  reflective-yellow: "#FFF3C4"
  destructive: "#A3241B"
  destructive-border: "#D9A7A2"
  plate-ink: "#1C1C1C"
  plate-ordinary-green: "#2E7D4F"
  plate-heavy-red: "#C62828"
  plate-heavy-yellow: "#F2C200"
  marker-allowed: "#186348"
  marker-conditional: "#865500"
  marker-unverified: "#59646C"
  marker-denied: "#A13042"
  marker-badge-ink: "#22282D"
typography:
  headline:
    fontFamily: "Noto Sans TC, sans-serif"
    fontSize: "28px"
    fontWeight: 900
    lineHeight: 1.25
  title:
    fontFamily: "Noto Sans TC, sans-serif"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.5
  body:
    fontFamily: "Noto Sans TC, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Noto Sans TC, sans-serif"
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1.5
  caption:
    fontFamily: "Noto Sans TC, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  numeral:
    fontFamily: "Barlow Condensed, Noto Sans TC, sans-serif"
    fontWeight: 600
    fontFeature: "tnum"
  numeral-figure:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "22px"
    fontWeight: 600
    fontFeature: "tnum"
rounded:
  tag: "3px"
  plate: "3.5px"
  control: "6px"
  panel: "8px"
  dialog: "10px"
  sheet: "14px"
  chip: "20px"
spacing:
  "4": "4px"
  "8": "8px"
  "12": "12px"
  "16": "16px"
  "20": "20px"
  "24": "24px"
  "32": "32px"
  "40": "40px"
components:
  button-primary:
    backgroundColor: "{colors.action-blue}"
    textColor: "{colors.paper-white}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "48px"
  button-primary-hover:
    backgroundColor: "{colors.action-blue-deep}"
  button-secondary:
    backgroundColor: "{colors.paper-white}"
    textColor: "{colors.rail-black}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "48px"
  button-destructive:
    backgroundColor: "{colors.paper-white}"
    textColor: "{colors.destructive}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "48px"
  button-quiet:
    textColor: "{colors.rail-black}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "48px"
  chip:
    backgroundColor: "{colors.plate-white}"
    textColor: "{colors.rail-black}"
    rounded: "{rounded.chip}"
    padding: "0 14px"
    height: "44px"
  chip-selected:
    backgroundColor: "{colors.rail-black}"
    textColor: "{colors.paper-white}"
  input:
    backgroundColor: "{colors.paper-white}"
    textColor: "{colors.rail-black}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "48px"
  input-changed:
    backgroundColor: "{colors.reflective-yellow}"
  tag-modified:
    backgroundColor: "{colors.reflective-yellow}"
    textColor: "{colors.rail-black}"
    typography: "{typography.label}"
    rounded: "{rounded.tag}"
    padding: "0 6px"
    height: "20px"
  tag-status-open:
    backgroundColor: "{colors.plate-white}"
    textColor: "{colors.rail-black}"
    typography: "{typography.label}"
    rounded: "{rounded.tag}"
    padding: "0 7px"
    height: "20px"
  tag-status-closed:
    backgroundColor: "{colors.rail-black}"
    textColor: "{colors.paper-white}"
    typography: "{typography.label}"
    rounded: "{rounded.tag}"
    padding: "0 7px"
    height: "20px"
  tag-status-deleted:
    backgroundColor: "{colors.plate-white}"
    textColor: "{colors.destructive}"
    typography: "{typography.label}"
    rounded: "{rounded.tag}"
    padding: "0 7px"
    height: "20px"
  rail:
    backgroundColor: "{colors.rail-black}"
    textColor: "{colors.rivet}"
    width: "96px"
  rail-item-active:
    backgroundColor: "{colors.plate-white}"
    textColor: "{colors.rail-black}"
    rounded: "{rounded.control}"
    width: "80px"
    height: "64px"
  list-row:
    backgroundColor: "{colors.plate-white}"
    textColor: "{colors.rail-black}"
    padding: "14px 20px"
  list-row-selected:
    backgroundColor: "{colors.paper-white}"
  panel:
    backgroundColor: "{colors.plate-white}"
    rounded: "{rounded.panel}"
    padding: "20px 24px"
  dialog:
    backgroundColor: "{colors.plate-white}"
    rounded: "{rounded.dialog}"
    width: "560px"
---

# Design System: 機車停車指南管理站

> 本文件記錄的是管理站設計稿畫布（https://claude.ai/artifact/SV7aXcXUjKsC9bkMGJstDd ，私人連結，需由擁有者分享；2026-10-31 Version 48，共 17 張畫板，設計基礎見「設計基礎」畫板）實際畫出來的設計，不是已上線的程式碼。畫板原始檔（`*.dc.html` 靜態樣稿）不在 repo 裡，本文以下提到的 `*.dc.html` 都是畫板名稱。這些樣稿是給之後要做的 React + Redux Toolkit 管理站用的；實作時以這份文件的 token 為準，再回頭對照畫布。

## Overview

**Creative North Star: "The Plate Bench"（車牌檢驗台）**

管理站是審核者的工作台，不是報表後台。每一個點位的資格，都用 App 的兩面疊牌回答：左邊普通機車、右邊大型重機。審核者打開一筆回報，第一眼看到的是「這筆會改變哪一種車能不能停」：目前的大車牌 → 建議的大車牌，然後按 A／E／R 套用、修改後套用或駁回，處理完自動跳下一筆，5 秒內可復原。

材質來自路邊：壓印黑的導覽欄像車牌的壓印底框，頁面底是鋁板灰，欄位與面板是牌面白。顏色紀律很嚴：車牌的綠、白、紅、黃只出現在車牌本身；操作藍只給按得下去的東西；反光黃只標「已修改」。層級靠字重（400／700／900）與黑白反轉，不靠放大字級。密度偏高但每個可點的東西都夠大（篩選 44px、按鈕 48px），因為審核者也會用平板與手機。

刻意拒絕的樣子：灰卡片堆疊的通用後台模板、彩色統計卡、把狀態只用顏色表達。

**Key Characteristics:**
- 資格永遠成對出現：普通機車在左、大型重機在右，順序固定。
- 狀態用車牌的「處理方式」表達（全彩、缺角、灰框加 X、虛線加問號、純虛線），文字一定同時寫出來。
- 黑色 96px 導覽欄帶待審計數；選取狀態一律是黑框或黑底反白。
- 三級字級 28／15／13，數字用 Barlow Condensed 等寬數字。
- 平面為主；陰影只給浮在地圖或頁面上的東西。

## Colors

一組冷調金屬中性色，加上一個操作藍、一個反光黃、一個刪除紅；車牌色與地圖標記色是借用 App 的專屬色，不進一般介面。

### Primary
- **操作藍 Action Blue**（`action-blue`）：主要按鈕（套用建議、儲存並關閉、新增停車點）、連結、焦點框（3px outline，offset 2px）、輸入游標、核取方塊。hover 時加深為 `action-blue-deep`。
- **反光黃 Reflective Yellow**（`reflective-yellow`）：「已修改」標籤、差異表中改過的儲存格、改過的輸入框底色、文字選取底色。只表示「這裡跟原本不一樣」。

### Secondary
- **刪除紅 Destructive Red**（`destructive`）：駁回、刪除點位、停權、錯誤訊息與「已刪除」標籤。次要按鈕版本用 `destructive-border` 當框線，不做紅底實心。

### Tertiary（App 專屬色，只在指定元件中出現）
- **車牌色**：普通機車是 `plate-ordinary-green` 後牌加白色前牌（`paper-white`），大型重機是 `plate-heavy-red` 後牌加 `plate-heavy-yellow` 前牌，框線與前牌的號碼線用 `plate-ink`。來源是 App 的 `lib/ui/vehicle_marks.dart` 中的 `platesOf`。
- **地圖標記色**：可停 `marker-allowed`（圓形）、有條件 `marker-conditional`（圓角 10）、待確認 `marker-unverified`（圓角 10）、不可停 `marker-denied`（圓角 4），白色 3px 外框；「共」徽章文字與框線用 `marker-badge-ink`。來源是 App 的 `lib/features/map/map_legend.dart`（A0 標記規格）。

### Neutral
- **壓印黑 Rail Black**（`rail-black`）：導覽欄、正文字、選取框（2px inset）、選取的篩選與分段按鈕底色、施工中／暫時封閉標籤、「社群點／官方點」來源小牌。
- **鋁板灰 Aluminium**（`aluminium`）：頁面底色。
- **牌面白 Plate White**（`plate-white`）：面板、清單、浮動面板、對話框、未選取的篩選。
- **紙白 Paper White**（`paper-white`）：輸入框、按鈕底、被選取或 hover 的清單列（比牌面白更亮一階，讓選取列浮出來）。
- **石墨灰 Graphite**（`graphite`）：次要文字（時間、說明、表頭）、不可停車牌上的 X、官方未標示車牌的虛線框。
- **鋼灰 Steel**（`steel`）：按鈕、篩選、輸入框的框線；不可停車牌的灰框。
- **鉚釘灰 Rivet**（`rivet`）：面板框線、區塊分隔線、導覽欄上的未選取文字。
- **分隔線**（`divider`、`section-divider`）：表格與清單列之間的細線；後者用於審核佇列列與表單區段。
- **地圖底 Map Ground**（`map-ground`）：示意地圖與小地圖的底色，道路用牌面白畫。

### Named Rules
**The Plates-Only Rule.** 車牌的綠、白、紅、黃只出現在車牌上。介面的成功、警告、強調一律不借用這四色。

**The Pressable Blue Rule.** 操作藍只給按得下去的東西：主要按鈕、連結、焦點框。標題、圖示、裝飾不准用藍。

**The Yellow Means Changed Rule.** 反光黃只代表「跟目前值不同」。它不是警告色，也不是強調色。

## Typography

**Body Font:** Noto Sans TC（字重 400／500／700／900，退回 sans-serif）
**Numeral Font:** Barlow Condensed（字重 600／700，`font-variant-numeric: tabular-nums`）

**Character:** Noto Sans TC 負責所有中文，靠字重拉開層級；Barlow Condensed 是車牌與路標的窄體數字，只用在計數、時間、距離、座標與費率數字上，讓數字像牌面上壓印的字。

### Hierarchy
- **Headline**（900, 28px, 1.25）：頁名（審核、點位、規則）與目前點位名稱。一個畫面通常只有一到兩個。
- **Title**（700, 15px, 1.5）：清單列的點位名、區段標題（騎士說明、編輯紀錄）、表單區段標題、欄位名稱欄。
- **Body**（400, 15px, 1.5）：內文、欄位值、按鈕文字（按鈕用 500）。長段落限 64ch。
- **Label**（700, 13px）：表單欄位標籤、回報類型（停放資格、點位資訊）、狀態與「已修改」標籤。
- **Caption**（400, 13px，石墨灰）：時間、行政區、說明文字、表頭（表頭用 500）。
- **Numeral**（Barlow Condensed 600，跟著所在文字的字級）：行內數字，例如「待審 12」「38 m」「10/31 09:12」。導覽欄計數用 700 的同一字體。
- **Numeral Figure**（Barlow Condensed 600, 22px）：獨立呈現的數量，例如匯入試算的新增／更新筆數、規則影響的點位數。

### Named Rules
**The Three Sizes Rule.** 中文字只有 28／15／13 三級。需要更強的層級時，改字重或反白（黑底白字），不要新增字級。

**The Condensed Numerals Rule.** 數字、計數、座標、時間一律用 Barlow Condensed 等寬數字；中文永遠不用這個字體。

## Layout

桌機（1040px 以上）：左側 96px 黑色導覽欄，右邊是雙欄工作區。審核頁是「佇列（360–420px，最舊的在最上）＋詳情」，詳情內再分主欄與 280–340px 的脈絡側欄（小地圖、同點位其他回報、編輯紀錄）；處理按鈕列固定在詳情底部（sticky），左邊主要動作、右邊「跳過」。點位頁是滿版地圖，上面浮著左側 388px 清單與右側 440px 表單。

平板（680–1039px，見 `SpotsTablet.dc.html`）：導覽欄改成上方 64px 黑色分頁列，維持雙欄，只替換右欄內容。

手機（680px 以下，見 `*Phone*.dc.html`）：上方 56px 黑色頂欄，底部 72px 黑色分頁列放 4 個分頁（審核、點位、規則、更多）；清單選中的列就地展開，點位地圖用從底部升起的 sheet。

間距以 4 的倍數為主：元件內 8–14px，面板內距 16–24px，詳情頁外距 28px／40px，欄與欄之間 32px。清單列內距 12–14px × 16–20px，列高至少 60–72px。

## Elevation & Depth

以平面與色階分層為主：鋁板灰的地、牌面白的面板加 1px 鉚釘灰框線、紙白的選取列。陰影只出現在「浮在別的東西上」的元素：地圖上的浮動面板與標記、對話框、手機的底部 sheet。陰影一律用壓印黑（rgba 22,24,26）調色，不用純黑。選取不靠陰影，靠 2px 黑色 inset 框。

### Shadow Vocabulary
- **Float**（`box-shadow: 0 6px 24px rgba(22,24,26,.18)`）：地圖上的點位清單與點位表單。
- **Dialog**（`box-shadow: 0 18px 48px rgba(22,24,26,.35)`）：開放狀態設定、Ctrl K 搜尋、舊資料發布確認等置中對話框，背後用 `rgba(22,24,26,.55)` 遮罩。
- **Sheet**（`box-shadow: 0 -6px 20px rgba(22,24,26,.16)`）：手機點位清單 sheet；刪除確認 sheet 用 `0 -8px 24px rgba(22,24,26,.25)`。
- **Marker**（`box-shadow: 0 2px 6px rgba(22,24,26,.3)`）：地圖標記；選取中的標記再加 `0 0 0 4px` 壓印黑外圈並放大到 38px。

### Named Rules
**The Selection Is a Frame Rule.** 選取狀態是黑框（清單列、選項卡用 `inset 0 0 0 2px`）或黑底反白（篩選、分段按鈕、導覽項目用牌面白底黑字），不是陰影也不是藍色。

## Shapes

小圓角、方正的工具感，像金屬牌與標籤貼紙。標籤 3px、車牌 3.5px、按鈕與輸入框 6px、面板 8px、對話框 10px、手機 sheet 頂部 14px。唯一的膠囊形是篩選 chip（20px）。導覽計數小牌與「社群點／官方點」來源小牌都是 3px 的黑白小方牌。

地圖標記的形狀本身就是意義（沿用 App A0 規格）：可停是圓、有條件與待確認是圓角方（10px）、不可停近乎方形（4px）。車牌的「有條件」用前牌右上角切掉一角（clip-path 缺角）表達。

## Components

### Buttons
工具感、直接：一律 48px 高、6px 圓角、15px／500 字。
- **Primary：** 操作藍底白字，內距 0 18px；hover 加深為 `action-blue-deep`。
- **Secondary：** 紙白底、鋼灰 1px 框、黑字；hover 框線變壓印黑。
- **Destructive：** 紙白底、刪除紅字、`destructive-border` 框（駁回、刪除點位、停權）。
- **Quiet：** 透明底無框（跳過、編輯紀錄、展開未修改欄位）。
- **Focus：** 所有可聚焦元素 3px 操作藍 outline，offset 2px。
- **快捷鍵：** 審核動作按鈕右側附 kbd 小鍵帽（A 套用、E 修改後套用、R 駁回、J 跳過），currentColor 細框。

### Chips
- **Style：** 牌面白底、鋼灰 1px 框、20px 膠囊、至少 44px 高、內距 0 14px，計數用 Barlow 數字。
- **State：** 單選篩選（待審／已刪除、回報類型）選取時黑底白字；地圖圖層的多選切換（官方點、社群點、衛星）選取時改為黑色 1px 框加 1px inset 與 700 字重，底色不變。

### Segmented Control
外框 1px 壓印黑（規則頁用鋼灰並以鉚釘灰分隔）、6px 圓角，選項至少 44px 高；選取項黑底白字。點位頁的車種切換（普通機車／大型重機）每個選項前放對應車牌，切換後所有標記與車牌一起改變。

### Cards / Containers
- **Corner Style：** 8px。
- **Background：** 牌面白。
- **Shadow Strategy：** 一般面板無陰影；浮在地圖上的才用 Float（見 Elevation）。
- **Border：** 1px 鉚釘灰。
- **Internal Padding：** 14–24px。
- **差異表：** 欄位／目前／建議三欄，改過的儲存格反光黃底並附「已修改」標籤；沒改的欄位預設收起，用一個 quiet 按鈕展開。

### Inputs / Fields
- **Style：** 紙白底、鋼灰 1px 框、6px 圓角、至少 48px 高、15px 字；標籤 13px／700 在上方。
- **Focus：** 3px 操作藍 outline；游標色操作藍。
- **Changed：** 反光黃底、壓印黑框。
- **Error：** 必填未選時選項組框線變刪除紅，並附刪除紅框的「必填」小標籤；錯誤區塊為 1.5px 刪除紅框、6px 圓角。
- **驗證碼：** 6 格、60px 高、2px 壓印黑框、Barlow 數字。

### Navigation
- **桌機導覽欄：** 96px 寬壓印黑，頂部白框「P 管」標誌；每項 80×64px，圖示 22px（1.8 細線條）在上、13px 文字在下；未選取鉚釘灰字，hover 底色加深一階，選取為牌面白底黑字 700。待審數用牌面白小方牌；次要計數（匯入試算）用鉚釘灰小方牌。底部放搜尋（Ctrl K）與帳號頭像。
- **平板：** 64px 高黑色頂欄分頁，每項 48px 高，選取同樣牌面白底。
- **手機：** 56px 黑色頂欄＋72px 黑色底部分頁列（4 項，每項至少 56px），選取為牌面白圓角 8px 底。

### Status Tags
20px 高、1.5px 框、3px 圓角、13px／700 字。
- **正常開放：** 牌面白底黑框，前面一個打勾。
- **施工中（到某日）／暫時封閉：** 壓印黑底白字（反白）。
- **已刪除（N 天後永久刪除）：** 刪除紅框紅字。
- **已修改：** 反光黃底黑框。

### Plate Stack（簽名元件）
App 的疊牌（`lib/features/map/vehicle_sheet.dart` 的 `PlateStack`）：後牌 26×17px 在左上，前牌向右下偏移（10px, 8px）疊在上面，1.5px 車牌墨框、3.5px 圓角，前牌中央一條號碼線。普通機車是綠後牌＋白前牌，大型重機是紅後牌＋黃前牌。大尺寸（詳情頁目前 → 建議）是 48×31px 的牌。五種狀態：
- **可停：** 全彩。
- **有條件可停：** 全彩，前牌右上角缺角。
- **不可停：** 透明、鋼灰框，整組蓋一個石墨灰 X。
- **官方未標示：** 透明、石墨灰虛線框，右上角一個壓印黑圓點白色「?」。只用在官方點。
- **待確認（舊資料）：** 同上但沒有「?」。編輯時必須改選。
每組車牌都有 `role="img"` 與完整中文 `aria-label`（例如「普通機車可停，大型重機不可停」）。

### Map Marker
沿用 App A0 規格：30px（選取時 38px 並加 4px 壓印黑外圈），3px 白框，Marker 陰影。可停顯示 Barlow「P」，其他狀態用 Material Icons 白色圖示（有條件 `rule`、不可停 `close`、待確認 `question_mark`）；普大共用格右下角加白底「共」徽章。小地圖上用虛線圈標出 15m 去重範圍。

### Review Action Bar
固定在詳情底部的工具列（`role="toolbar"`），牌面白底、上方 1px 鉚釘灰線：套用建議（primary）、修改後套用（secondary）、駁回（destructive），右側說明「處理完自動跳到下一筆，5 秒內可復原」與跳過（quiet）。

## Do's and Don'ts

### Do:
- **Do** 每個資格都成對顯示兩面車牌，普通機車在左、大型重機在右，並在 `aria-label` 與可見文字中寫出狀態。
- **Do** 用車牌處理方式區分五種狀態（全彩／缺角／灰框加 X／虛線加「?」／純虛線），不要只換顏色。
- **Do** 讓所有按鈕至少 48px 高、篩選與分段按鈕至少 44px 高。
- **Do** 選取狀態用 2px 黑色 inset 框或黑底反白。
- **Do** 改過的值用反光黃底加「已修改」標籤，差異表預設收起沒改的欄位。
- **Do** 數字一律用 Barlow Condensed 等寬數字。
- **Do** 破壞性動作用刪除紅的次要按鈕，並說明保留期（刪除保留 14 天可復原）。

### Don't:
- **Don't** 把車牌的綠、白、紅、黃用在車牌以外的地方（成功、警告、圖表都不行）。
- **Don't** 把操作藍用在不能按的東西上。
- **Don't** 為中文新增 28／15／13 以外的字級來製造層級。
- **Don't** 做成灰卡片堆疊、彩色統計卡的通用後台模板。
- **Don't** 給平放在頁面上的面板加陰影；陰影只給浮在地圖或頁面上的東西。
- **Don't** 把 App 的 IconScout 重機圖示複製進這個 repo；需要時只用文字指稱。
