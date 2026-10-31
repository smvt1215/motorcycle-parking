-- 收回 #201／#200 新增內部 helper 的 EXECUTE（#195 P0 第 2 批）。
--
-- 202611010100_revoke_helper_execute.sql 只能收當時 main 上已有的函式；
-- 202610310200_eligibility_not_stated.sql 與 202610310300_soft_delete_spots.sql
-- 新增的 helper 沿用 public schema 預設，anon／authenticated 都能從
-- /rest/v1/rpc 直接呼叫。依 2026-11-01 在 staging 實查：
--   - eligibility_values_ok、eligibility_stated、zone_eligibility_stated、
--     zone_patch_stated：只由 apply_report、admin_upsert_spot、
--     admin_promote_spot、admin_resolve_report（SECURITY DEFINER）呼叫；
--   - spot_delete_grace：admin_set_spot_hidden、purge_deleted_spots 與
--     軟刪除觸發器使用；
--   - admin_import_pair：只由已收權的 admin_import_plan 呼叫；
--   - sync_not_stated：觸發器函式。
-- 沒有 anon 可執行的 invoker 函式、view、policy 或 CHECK 約束用到它們。
-- spot_deleted、spot_reports_locked 與軟刪除的觸發器函式在原 migration
-- 已經收權，這裡不重複。

revoke execute on function public.admin_import_pair(p_field text) from public, anon, authenticated;
revoke execute on function public.eligibility_stated(p jsonb) from public, anon, authenticated;
revoke execute on function public.eligibility_values_ok(p jsonb) from public, anon, authenticated;
revoke execute on function public.spot_delete_grace() from public, anon, authenticated;
revoke execute on function public.sync_not_stated() from public, anon, authenticated;
revoke execute on function public.zone_eligibility_stated(p_zone jsonb) from public, anon, authenticated;
revoke execute on function public.zone_patch_stated(p_patch jsonb, p_merged jsonb) from public, anon, authenticated;
