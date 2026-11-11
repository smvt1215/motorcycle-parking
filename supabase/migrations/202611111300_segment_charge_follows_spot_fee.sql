-- 路段的 condition.charge 跟著它實際適用的費率走，不論費率從哪條路徑改（#399）。
--
-- 202611091000_segment_charge_follows_fee.sql（#369）只在 admin_resolve_report
-- 套用路段自己的費率 patch 時推導 charge。其他改到路段實際費率的寫入仍會留下舊
-- charge：
--   1. 修改整條路的費率（admin_resolve_report 的頂層 fee），沒有自己費率、沿用
--      整條路的路段；
--   2. 管理站直接編輯（admin_upsert_spot 送整份 fee 與 parking_segments）；
--   3. 計費規則（fee_plans）改內容時，spot_fee_plans_sync() 在 trigger 內改寫的
--      整條路與路段費率。
-- 所以改在資料表的 BEFORE UPDATE trigger 處理，排在 …_fee_plans（費率在此定案）
-- 之後。
--
-- 規則與 #369 相同（charge_of_fee()，App 的 chargeOfFee()）；什麼時候重算則以
-- 「這次寫入改了路段實際適用的費率、沒動它的 condition」判斷，也就是 #369 的
-- 「patch 改了 fee、沒有自己帶 condition」在整列層級的說法：
--   - 實際費率：路段自己的費率，沒有（不存在、null 或 {}）就看整條路的；
--   - 寫入同時改了 condition：以寫入者的為準，不動；
--   - 新增的路段（舊列沒有同 id）：寫入者自己給條件，不動；
--   - 只處理指定了 bay 的一般機車格、普大共用格（SpaceKind.asksCharge）；沒寫
--     bay 的路段沿用點位條件，不動（以誰為準待決定，見 #399）；
--   - 推導不出來（沒有費率、普機重機不同）就移除 charge，不留舊值。
-- 只在 UPDATE：新增的點位沒有舊值可比，條件由寫入者給。

-- p_segment 套用 p_fee 推導的 charge；不是問收費性質的格位就原樣回傳。
-- 與 segments_charge_follow_fee() 共用。
create or replace function public.segment_charge_of(p_segment jsonb,p_fee jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case
    when p_segment->'condition'->>'bay'='motorcycle'
      and not exists(select 1 from jsonb_array_elements(
          case when jsonb_typeof(p_segment->'condition'->'limits')='array' then p_segment->'condition'->'limits' else '[]'::jsonb end) l
        where l->>'kind' in ('special_vehicle','ev_only'))
    then jsonb_set(p_segment,'{condition}',(p_segment->'condition')-'charge'||
      coalesce((select jsonb_build_object('charge',c) from public.charge_of_fee(p_fee) c where c is not null),'{}'::jsonb))
    else p_segment end;
$$;

-- 路段實際適用的費率：自己的，沒有就整條路的；兩者都沒有時為 null。
create or replace function public.segment_fee_of(p_segment jsonb,p_spot_fee jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_segment->'fee')='object' and p_segment->'fee'<>'{}'::jsonb then p_segment->'fee'
    when jsonb_typeof(p_spot_fee)='object' and p_spot_fee<>'{}'::jsonb then p_spot_fee end;
$$;

-- #369 的 helper 改用共用的 segment_charge_of()，行為不變。
create or replace function public.segments_charge_follow_fee(p_merged jsonb,p_patch jsonb,p_spot_fee jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(case
      when exists(select 1 from jsonb_array_elements(p_patch) e
          where e->'id'=z->'id' and e ? 'fee' and not e ? 'condition')
      then public.segment_charge_of(z,
          case when jsonb_typeof(z->'fee')='object' and z->'fee'<>'{}'::jsonb then z->'fee' else p_spot_fee end)
      else z end order by n),'[]'::jsonb)
    from jsonb_array_elements(p_merged) with ordinality t(z,n);
$$;

-- p_new（寫入後的路段清單）中，與 p_old 同 id、condition 沒變、實際費率變了的
-- 路段：charge 改成新費率推導的結果。p_old_fee、p_new_fee 是整條路寫入前後的
-- 費率。
create or replace function public.segments_charge_follow_spot_fee(p_old jsonb,p_new jsonb,p_old_fee jsonb,p_new_fee jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_new) is distinct from 'array' then p_new else
    (select coalesce(jsonb_agg(case
        when o.seg is not null
          and (z->'condition') is not distinct from (o.seg->'condition')
          and public.segment_fee_of(z,p_new_fee) is distinct from public.segment_fee_of(o.seg,p_old_fee)
        then public.segment_charge_of(z,public.segment_fee_of(z,p_new_fee))
        else z end order by n),'[]'::jsonb)
      from jsonb_array_elements(p_new) with ordinality t(z,n)
      left join lateral (select e seg from jsonb_array_elements(
          case when jsonb_typeof(p_old)='array' then p_old else '[]'::jsonb end) e
        where jsonb_typeof(z)='object' and z ? 'id' and e->'id'=z->'id' limit 1) o on true) end;
$$;

-- 內部 helper，不是 API（見 202611010100_revoke_helper_execute.sql）。
revoke execute on function public.segment_charge_of(p_segment jsonb, p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.segment_fee_of(p_segment jsonb, p_spot_fee jsonb) from public, anon, authenticated;
revoke execute on function public.segments_charge_follow_fee(p_merged jsonb, p_patch jsonb, p_spot_fee jsonb) from public, anon, authenticated;
revoke execute on function public.segments_charge_follow_spot_fee(p_old jsonb, p_new jsonb, p_old_fee jsonb, p_new_fee jsonb) from public, anon, authenticated;

create or replace function public.spot_segments_charge_follow_fee() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.fee is distinct from old.fee or new.parking_segments is distinct from old.parking_segments then
    new.parking_segments:=public.segments_charge_follow_spot_fee(old.parking_segments,new.parking_segments,old.fee,new.fee);
  end if;
  return new;
end;
$$;
revoke execute on function public.spot_segments_charge_follow_fee() from public, anon, authenticated;

-- 名稱排在 …_fee_plans（spot_fee_plans_sync() 定案整條路與路段的費率）與
-- …_flags_from_entries 之後；charge 不影響其他 trigger 推導的欄位。
create trigger community_spots_segment_charge before update on public.community_spots
  for each row execute function public.spot_segments_charge_follow_fee();
create trigger official_heavy_spots_segment_charge before update on public.official_heavy_spots
  for each row execute function public.spot_segments_charge_follow_fee();
