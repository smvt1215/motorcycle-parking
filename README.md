# motorcycle-parking

台灣機車停車指南 APP，同時服務**普通機車**與**大型重機（黃牌／紅牌）**騎士：

- 地圖找附近停車位（依車種標示可停／有條件／不可停）
- 各縣市停車規則指南（重機停機車格、收費、可否跨兩格）
- 記住我停哪裡（位置、備註、計時提醒、導航回車旁）
- 社群回報與收藏停車點

技術：Flutter + Supabase + Google Maps；未設定地圖金鑰時使用 OpenStreetMap 預覽。停車資料分為官方點（各縣市政府開放資料，以 TDX 輔助核驗）與社群點；目前只提供靜態點，不含即時車位。

MVP 實作與 staging 封測中，已提供地圖範圍搜尋、車種規則、收藏、停車紀錄、社群回報，以及 Web 管理介面（審核與點位維護）。未設定後端時使用明確標示的範例點位。staging 後端已部署並匯入停車點，測試版經 Firebase App Distribution 發給受邀測試者；production 尚未設定。

文件：完整計畫與目前進度見 [docs/PLAN.md](docs/PLAN.md)，介面與驗證說明見 [docs/DESIGN.md](docs/DESIGN.md)，Web 管理介面見 [docs/ADMIN_WEB.md](docs/ADMIN_WEB.md)，社群核實機制見 [docs/COMMUNITY_VERIFICATION_PLAN.md](docs/COMMUNITY_VERIFICATION_PLAN.md)，貢獻等級與遊戲化研究見 [docs/CONTRIBUTION_TIERS_FEASIBILITY.md](docs/CONTRIBUTION_TIERS_FEASIBILITY.md)，Claude／Codex 工作階段之間的通訊方式見 [docs/AGENT_COMMUNICATION.md](docs/AGENT_COMMUNICATION.md)。

使用 `.flutter-version` 指定的 Flutter 版本，執行 `flutter pub get`，再以 `flutter run -d chrome --web-port=3000` 預覽。無網路測試可加 `--dart-define=OFFLINE_MAP=true`。

Google Maps Platform 已啟用；staging 測試版的金鑰存於 GitHub `staging` Environment，不供本機使用。本機要預覽 Google Maps 時，建立 Android／iOS／Web 各自限制用途的金鑰，將 `config/maps.local.example.json` 複製為 `config/maps.local.json`，填入要驗證平台的金鑰，再執行：

```bash
python3 tool/configure_maps.py
flutter run -d chrome --web-port=3000 --dart-define-from-file=config/maps.generated.json
```

本機設定及產生的原生設定均不進版控。Android／iOS 建置也帶入同一份 `config/maps.generated.json`。Android 本機執行與建置指定 `--flavor production`；測試環境使用 `--flavor staging`，並帶入 staging 的後端設定。完整切換範圍與待驗證事項見 [Google Maps 計畫](docs/PLAN.md#google-maps-底圖切換2026-10-11-更新)。

CD staging 已啟用：合併到 `main` 且 CI 通過後部署 staging 後端與管理站，並發佈 Android 測試 APK 與 iOS Ad Hoc 測試版。經人工核准的雙平台正式發版已實作，production 尚待依 [CD 設定與操作](docs/CD_SETUP.md) 設定。流程設計見 [CI／CD](docs/CICD.md)。
