-- 統一 API 層的 schema 骨架（#195 P1，第 1 個 PR）。
--
-- App 與管理站之後都只經由這兩個 schema 存取資料，不再直接讀寫 public 的
-- 資料表或呼叫 public 的 RPC（舊的保留到 P8 收斂）：
--   api_v1    anon／authenticated 可用的公開 API
--   admin_v1  只有管理員（is_admin()：role admin＋aal2）可用的 API
--   private   API 共用的內部函式，不對外開放
-- schema 即版本：破壞性變更開 api_v2 並行，v1 只做加法。
--
-- 每支函式都要明確授權：建立後先 revoke ... from public，再 grant 給該有的
-- 角色。Postgres 內建「函式預設開放給 PUBLIC」是全域預設，以 schema 為
-- 範圍的 ALTER DEFAULT PRIVILEGES 收不回來；改全域預設又會影響 public
-- schema。所以改由 supabase/tests/api_schemas_test.sql 把關：這三個 schema
-- 裡任何一支函式只要還開放給 PUBLIC，CI 就失敗（#195 P0 收權過的問題：
-- 新 helper 自動被 anon 呼叫，不再發生）。
-- Supabase 只對 public 等既有 schema 設了「新物件授權給 anon／authenticated」
-- 的預設，新 schema 沒有，所以不必另外收回。
-- PostgREST 要把 api_v1、admin_v1 加進 exposed schemas 才連得到
-- （本機見 supabase/config.toml；託管專案要在專案設定另外加）。

create schema if not exists api_v1;
create schema if not exists admin_v1;
create schema if not exists private;

revoke all on schema api_v1, admin_v1, private from public;
grant usage on schema api_v1 to anon, authenticated, service_role;
grant usage on schema admin_v1 to authenticated, service_role;
-- private 只給 owner（postgres）與 SECURITY DEFINER 函式使用。

-- admin_v1 每支函式開頭呼叫：不是管理員（或沒有第二步驗證）就以穩定的
-- 錯誤碼拒絕。PostgREST 把 SQLSTATE PTxyz 轉成 HTTP xyz（#195 §2.4）。
create function private.require_admin()
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise sqlstate 'PT403' using message = 'auth.aal2_required',
      detail = '{"reason":"admin with a second factor required"}';
  end if;
end;
$$;
revoke execute on function private.require_admin() from public, anon, authenticated, service_role;

-- App 啟動、回到前景、恢復連線時讀取：最低支援版本與各資料集的版本
-- （#195 §2.1、#202）。min_supported_app_version 低於這個值的 App 要提示更新。
create function api_v1.client_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'min_supported_app_version', '0.1.0',
    'rules_version', (select version from public.data_versions where key = 'rules'),
    'spots_version', (select version from public.data_versions where key = 'spots')
  );
$$;
revoke execute on function api_v1.client_config() from public;
grant execute on function api_v1.client_config() to anon, authenticated, service_role;
