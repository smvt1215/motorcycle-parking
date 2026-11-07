-- #190：分區的 condition 推導不出 access 時，分區不帶 access。
--
-- 決定 32 原本要求有 condition 的分區一定要有 access，所以「汽車格普機可停」
-- （S1b／S2 畫板的 B3 汽車區）和「機車格只開放大型重機」存不進去。使用者決定
-- 放寬（2026-11-07）：推導不出就不帶，比照官方未標示（#201）。舊版只讀 access，
-- 會把這種分區讀成未確認，方向保守。推導得出時仍必須帶，而且要和推導值相同；
-- 「重機格開放普通機車」本身矛盾，繼續由 valid_condition() 擋下。
--
-- 只放寬，既有資料不受影響。下面的函式由 tool/gen_contract_sql.py 產生，
-- 來自 supabase/contract/parking_contract.sql；tool/test_gen_contract_sql.py
-- 會檢查這裡和產生器一致。

-- Whether a zone's access agrees with its condition (§1.3, decision 32): a
-- zone without a condition is not checked here; one with a condition has an
-- allow naming both vehicles, and its access is the one the condition writes
-- back. A condition that writes back no access (a car bay scooters may park
-- in, #190; or an allow saying not_stated for a vehicle, #201) has none to
-- write back, so the zone carries none and old builds read it as unconfirmed.
create or replace function public.zone_condition_consistent(p_zone jsonb) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p_zone->'condition'),'null')='null'
    or case when jsonb_typeof(p_zone->'condition'->'allow')='object' and exists(
        select 1 from jsonb_each(p_zone->'condition'->'allow') e
        where e.value=(public.parking_contract()->'eligibility'->'not_stated'))
      then coalesce(jsonb_typeof(p_zone->'access'),'null')='null'
        and p_zone->'condition'->'allow' ?& array['scooter','heavy']
      when jsonb_typeof(p_zone->'condition'->'allow')='object'
        and p_zone->'condition'->'allow' ?& array['scooter','heavy']
        and public.condition_legacy_access(p_zone->'condition') is null
      then coalesce(jsonb_typeof(p_zone->'access'),'null')='null'
      else jsonb_typeof(p_zone->'access')='string'
        and coalesce((p_zone->>'access')=public.condition_legacy_access(p_zone->'condition'),false) end;
$$;
