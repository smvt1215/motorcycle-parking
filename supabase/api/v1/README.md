# 統一 API v1（#195）

App 與管理站共用的有版本 API。設計見 issue #195 的架構提案；這裡只記實作慣例。

## Schema

| schema | 誰能用 | 內容 |
|---|---|---|
| `api_v1` | anon、authenticated | 公開 API |
| `admin_v1` | authenticated，但每支函式開頭都要呼叫 `private.require_admin()` | 管理站 API |
| `private` | 只給 owner（postgres） | API 共用的內部函式 |

schema 就是版本：v1 只做加法（新增欄位、新增有預設值的參數）。破壞性變更開 `api_v2` 並行，不改 v1 的語意。

## 新增一支 API

1. 在新的 migration 裡建立函式：`security definer`、`set search_path = ''`。
2. 先 `revoke execute ... from public`，再 grant 給該有的角色（`api_v1` 通常是 `anon, authenticated, service_role`）。`supabase/tests/api_schemas_test.sql` 會擋下任何仍開放給 PUBLIC 的函式。
3. 在 `api_v1.json` 或 `admin_v1.json` 加上 `POST /rpc/<name>`：
   - `operationId` 寫成 `<schema>_<name>`。
   - 不要把 `Content-Profile` 寫成參數：文件頂層的 `x-content-profile` 已標明 schema，用戶端的 base 會自動帶上。
   - 列出 `200` 回應，`default` 指向 `Error`。
   - 只給登入者用的 `api_v1` 函式（只 grant `authenticated, service_role`，例如 #215 的刪除帳號）在 operation 加 `"x-requires-sign-in": true`：`check_responses.ts` 改為檢查 anon 被拒（401 42501），不要求 200。
   `tool/test_api_schema.py` 會檢查文件和 SQL 的函式完全對應。
4. 錯誤：`raise sqlstate 'PTxyz' using message = '<穩定錯誤碼>', detail = '<json>'`，HTTP 狀態就是 xyz。用戶端依 `message` 的錯誤碼顯示文案，不解析其他文字。

## 停權：`account.suspended`（#331）

停權是 App 層級旗標（`private.user_suspensions`），不是 Supabase Auth ban：停權中的帳號照常登入、瀏覽、管理帳號、申請與取消刪除帳號，也照常會被到期刪除。被擋下的只有 App 的寫入：新增停車點、修改建議（含「已經不能停」）、車友回報目擊、檢舉（flag 與內容不當）、確認點位／投票、改名稱與頭像。

| 從哪裡被擋 | 形狀 |
|---|---|
| Edge Function（`submit-report`、`submit-sighting`） | HTTP 403 `{"error":"account.suspended","until":"<ISO 8601>"\|null}` |
| api_v1 函式、資料庫防線 | HTTP 403，`code` `PT403`、`message` `account.suspended`、`details` 為 JSON 字串 `{"until":"<ISO 8601>"\|null}` |
| 名稱與頭像（`auth.updateUser` 的 `display_name`、`profile_avatar_url`） | 不報錯，資料庫保留舊值；頭像 Storage 的上傳與刪除被 RLS 拒絕 |

`until` 為 `null` 代表無限期（直到管理員解除）。App 可先以 `api_v1.my_account_status()` 讀 `{suspended, suspended_until}`。

新增會寫入的 api_v1 函式時，開頭先呼叫 `private.require_not_suspended(<呼叫者>)`；只影響自己、屬於帳號管理的函式改列進 `supabase/tests/app_suspension_test.sql` 的放行清單 `pg_temp.suspension_allowed()`。測試列出 api_v1 所有 volatile 函式，兩者都不是就失敗。

## 呼叫方式

PostgREST 的 RPC：`POST /rest/v1/rpc/<name>`，以 `Content-Profile: api_v1`（或 `admin_v1`）指定 schema。Supabase SDK 用 `supabase.schema('api_v1').rpc('<name>')`。

託管專案（staging、production）要在 Supabase 專案設定的 Data API → Exposed schemas 加上 `api_v1`、`admin_v1`。部署流程不會同步 `supabase/config.toml`；本機與 CI 依 `config.toml` 設定。

## 型別

領域型別（格位、條件、費率）以 `supabase/functions/_shared/parking_contract.json` 為準。這兩份 OpenAPI 文件只描述傳輸格式。TS（RTK Query）由這兩份文件產生：`admin_web/react` 執行 `npm run codegen`，產出 `src/api/v1/*.generated.ts`，CI 會檢查產物沒有漂移。讀取類 API（PostgREST 一律是 POST）要在 `admin_web/react/scripts/codegen.mjs` 的 `READS` 列為 query。App 的 Dart 用戶端由 `python3 tool/gen_api_dart.py` 產生 `lib/api/v1/*.g.dart`（不可變 class、`fromJson`／`toJson`、`==`／`hashCode`，不用 freezed／build_runner）；`ApiV1Client(supabase, headers: ...)` 的 `headers` 每次呼叫前取一次（App Check），每支 API 另有 `...Raw` 回傳原始 JSON。CI 以 `--check` 檢查產物沒有漂移。
