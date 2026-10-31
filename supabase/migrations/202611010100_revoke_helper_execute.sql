-- 收回內部 helper 的 EXECUTE（#195 P0 權限查核）。
--
-- public schema 的函式預設讓 PUBLIC、anon、authenticated 都能執行，所以
-- 契約驗證、費率文字、分區 patch 等內部 helper 也能被任何人從
-- /rest/v1/rpc/<name> 直接呼叫。這些函式不是 API：只由 SECURITY DEFINER
-- 函式（owner postgres）、CHECK 約束與觸發器使用；兩張點位表對
-- anon／authenticated 只有 SELECT policy，CHECK 只在 postgres／service role
-- 寫入時執行；App、管理站與 Edge Functions 也沒有直接呼叫它們。
-- 依據：2026-10-31 在 staging 實查 has_function_privilege、引用它們的
-- invoker 函式／view／policy／欄位預設值，以及 Supabase security advisors。
--
-- 刻意保留（anon 經由 invoker 函式或 view 會用到，收了 App 就壞）：
--   legacy_projection → condition_legacy_safe_spot、zone_legacy_safe、
--   condition_legacy_safe、condition_legacy_access、condition_off_street、
--   condition_space_type → parking_contract（viewport_spots、_v2 與官方版）；
--   closure_state → closure_ends_on → closure_date（public_spots view、
--   official_viewport_spots_v3）；city_rules_v2（city_rules view）；
--   以及所有 App API。
-- 只收回 EXECUTE，不改函式本體，也不改 default privileges；service_role
-- 與 postgres 不受影響。之後新增的內部 helper 請在同一支 migration 裡
-- 一併 revoke（見 supabase/tests/helper_privileges_test.sql）。

-- 觸發器與事件觸發器函式：只能由觸發器執行。
revoke execute on function public.admin_audit_log_immutable() from public, anon, authenticated;
revoke execute on function public.assign_entry_ids() from public, anon, authenticated;
revoke execute on function public.city_rules_history_immutable() from public, anon, authenticated;
revoke execute on function public.community_spots_confirmed_at() from public, anon, authenticated;
revoke execute on function public.moderation_base_version() from public, anon, authenticated;
revoke execute on function public.moderation_close_legacy() from public, anon, authenticated;
revoke execute on function public.spot_fee_plans_sync() from public, anon, authenticated;
revoke execute on function public.spot_fee_source_text() from public, anon, authenticated;
revoke execute on function public.sync_facility_types() from public, anon, authenticated;

-- Supabase 平台建立的事件觸發器函式（Security Advisor：anon 可執行的
-- SECURITY DEFINER）。不在本 repo 的 migration 裡，本機與新專案可能沒有。
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end
$$;

-- 即時車位與騎士回報的內部計算。
revoke execute on function public.availability_classify(p_total integer, p_available integer) from public, anon, authenticated;
revoke execute on function public.availability_int(p jsonb) from public, anon, authenticated;
revoke execute on function public.rider_min_credibility() from public, anon, authenticated;
revoke execute on function public.sighting_official_level(p_available integer, p_total integer) from public, anon, authenticated;

-- 契約驗證（由 tool/gen_contract_sql.py 產生的函式與其 helper）。
revoke execute on function public.condition_bay_kind(p_condition jsonb) from public, anon, authenticated;
revoke execute on function public.contract_date(p jsonb) from public, anon, authenticated;
revoke execute on function public.contract_entry_ids(p jsonb) from public, anon, authenticated;
revoke execute on function public.contract_fee_fields(p jsonb, p_spec jsonb, p_vehicle text) from public, anon, authenticated;
revoke execute on function public.contract_fee_rate(p jsonb, p_vehicle text, p_nested boolean) from public, anon, authenticated;
revoke execute on function public.contract_https(p jsonb) from public, anon, authenticated;
revoke execute on function public.contract_slot_keys(p jsonb, p_keys jsonb) from public, anon, authenticated;
revoke execute on function public.contract_slot_times(p jsonb) from public, anon, authenticated;
revoke execute on function public.contract_str_in(p jsonb, p_list jsonb) from public, anon, authenticated;
revoke execute on function public.contract_subset(p jsonb, p_list jsonb) from public, anon, authenticated;
revoke execute on function public.contract_text(p jsonb, p_max integer) from public, anon, authenticated;
revoke execute on function public.contract_whole(p jsonb, p_min numeric, p_max numeric) from public, anon, authenticated;
revoke execute on function public.facility_types_ordered(p text[]) from public, anon, authenticated;
revoke execute on function public.valid_closure(p jsonb) from public, anon, authenticated;
revoke execute on function public.valid_condition(p_condition jsonb, p_zone boolean) from public, anon, authenticated;
revoke execute on function public.valid_facility_types(p text[]) from public, anon, authenticated;
revoke execute on function public.valid_segments(p_segments jsonb) from public, anon, authenticated;
revoke execute on function public.valid_spot_condition(p_space_type text, p_facility_type text, p_condition jsonb, p_zones jsonb, p_zones_complete boolean) from public, anon, authenticated;
revoke execute on function public.valid_zones(p_zones jsonb) from public, anon, authenticated;
revoke execute on function public.zone_condition_consistent(p_zone jsonb) from public, anon, authenticated;

-- 分區與路段的 id 與 patch。
revoke execute on function public.entries_have_ids(p jsonb) from public, anon, authenticated;
revoke execute on function public.entries_patch(p_current jsonb, p_patch jsonb) from public, anon, authenticated;
revoke execute on function public.entries_patch_conflict(p_base jsonb, p_current jsonb, p_patch jsonb) from public, anon, authenticated;
revoke execute on function public.entries_with_ids(p_new jsonb, p_old jsonb, p_keys text[]) from public, anon, authenticated;

-- 費率驗證與收費文字。
revoke execute on function public.fee_note_max_length() from public, anon, authenticated;
revoke execute on function public.fee_note_of(p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.fee_plan_name(p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.fee_plans_absorb(p_plans jsonb, p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.fee_text_day_mask(p jsonb) from public, anon, authenticated;
revoke execute on function public.fee_text_days(p_mask integer) from public, anon, authenticated;
revoke execute on function public.fee_text_every(p jsonb) from public, anon, authenticated;
revoke execute on function public.fee_text_money(p jsonb, p_pct integer) from public, anon, authenticated;
revoke execute on function public.fee_text_rate(p jsonb, p_pct integer) from public, anon, authenticated;
revoke execute on function public.fee_text_reset(p text) from public, anon, authenticated;
revoke execute on function public.fee_text_span(p jsonb) from public, anon, authenticated;
revoke execute on function public.fee_whole(p_value jsonb, p_min integer, p_max integer) from public, anon, authenticated;
revoke execute on function public.valid_fee(p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.valid_fee_plans(p_plans jsonb, p_fee_plan text, p_fee jsonb, p_zones jsonb) from public, anon, authenticated;
revoke execute on function public.valid_fee_rate(p_rate jsonb, p_heavy boolean) from public, anon, authenticated;
revoke execute on function public.valid_zone_fees(p_zones jsonb) from public, anon, authenticated;
revoke execute on function public.zones_without_plans(p_zones jsonb) from public, anon, authenticated;
