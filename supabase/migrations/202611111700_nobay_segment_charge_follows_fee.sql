-- 沒寫 bay 的路段，charge 也跟著實際適用的費率走（#399，決定 q399-nobay-charge = A）。
--
-- 202611111300_segment_charge_follows_spot_fee.sql 只處理指定了 bay 的路段。
-- 沒寫 bay 的路段，App 依點位條件判斷（segmentConditionOf()：bay 取點位的，
-- charge 用 seg.charge ?? whole.charge），所以它自己存的 charge 一樣會過期。
--
-- 規則（決定 A）：路段的 condition 沒寫 bay 時，看點位的條件——點位自己的
-- condition，沒有就看 space_type 代表的條件（conversion.from_space_type，即
-- conditionOf()）。點位條件是一般機車格或普大共用格（bay 為 motorcycle，且路段
-- 與點位的限制都沒有 special_vehicle／ev_only，與 bayKindOf() 相同）時，用路段
-- 實際適用的費率重算；推導不出來就移除 charge，判斷改沿用點位的 charge。
-- 沒有 condition 的路段整個沿用點位條件，不動（加上 condition 會改變它的
-- allow，見 segmentConditionOf()）。點位條件不明時也不動。
--
-- 何時重算不變：寫入改了路段實際適用的費率、沒動它的 condition（trigger
-- *_zz_segment_charge）。

-- 點位的整體條件：自己的 condition，沒有就看 space_type 代表的條件；不明為 null。
create or replace function public.spot_whole_condition(p_condition jsonb,p_space_type text) returns jsonb
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_condition)='object' then p_condition
    when jsonb_typeof(public.parking_contract()->'conversion'->'from_space_type'->p_space_type)='object'
      then public.parking_contract()->'conversion'->'from_space_type'->p_space_type end;
$$;

-- p_segment 套用 p_fee 推導的 charge。路段 condition 寫了 bay 就看它自己；沒寫
-- bay 就看 p_whole（點位的整體條件）。不是問收費性質的格位就原樣回傳。
-- condition 只剩 charge 又被移除時，整個 condition 拿掉（valid_condition() 不收
-- 空物件）：兩者在 segmentConditionOf() 都是照點位條件判斷。
create or replace function public.segment_charge_of(p_segment jsonb,p_fee jsonb,p_whole jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case
    when jsonb_typeof(p_segment->'condition')='object'
      and coalesce(p_segment->'condition'->>'bay',
        case when jsonb_typeof(p_whole)='object' then p_whole->>'bay' end)='motorcycle'
      and not exists(select 1 from jsonb_array_elements(
          case when jsonb_typeof(p_segment->'condition'->'limits')='array' then p_segment->'condition'->'limits' else '[]'::jsonb end
          ||case when not p_segment->'condition' ? 'bay' and jsonb_typeof(p_whole->'limits')='array' then p_whole->'limits' else '[]'::jsonb end) l
        where l->>'kind' in ('special_vehicle','ev_only'))
    then (select case when n='{}'::jsonb then p_segment-'condition' else jsonb_set(p_segment,'{condition}',n) end
      from (select (p_segment->'condition')-'charge'||
        coalesce((select jsonb_build_object('charge',c) from public.charge_of_fee(p_fee) c where c is not null),'{}'::jsonb) n) x)
    else p_segment end;
$$;

-- #369 的審核步驟沿用原行為（只看路段自己的 bay）：費率真的變了的情況由
-- trigger 處理，這裡不需要點位條件。
create or replace function public.segment_charge_of(p_segment jsonb,p_fee jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when p_segment->'condition' ? 'bay' then public.segment_charge_of(p_segment,p_fee,null) else p_segment end;
$$;

drop function public.segments_charge_follow_spot_fee(p_old jsonb, p_new jsonb, p_old_fee jsonb, p_new_fee jsonb);

-- p_new（寫入後的路段清單）中，與 p_old 同 id、condition 沒變、實際費率變了的
-- 路段：charge 改成新費率推導的結果。p_old_fee、p_new_fee 是整條路寫入前後的
-- 費率，p_whole 是寫入後點位的整體條件（spot_whole_condition()）。
create function public.segments_charge_follow_spot_fee(p_old jsonb,p_new jsonb,p_old_fee jsonb,p_new_fee jsonb,p_whole jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_new) is distinct from 'array' then p_new else
    (select coalesce(jsonb_agg(case
        when o.seg is not null
          and (z->'condition') is not distinct from (o.seg->'condition')
          and public.segment_fee_of(z,p_new_fee) is distinct from public.segment_fee_of(o.seg,p_old_fee)
        then public.segment_charge_of(z,public.segment_fee_of(z,p_new_fee),p_whole)
        else z end order by n),'[]'::jsonb)
      from jsonb_array_elements(p_new) with ordinality t(z,n)
      left join lateral (select e seg from jsonb_array_elements(
          case when jsonb_typeof(p_old)='array' then p_old else '[]'::jsonb end) e
        where jsonb_typeof(z)='object' and z ? 'id' and e->'id'=z->'id' limit 1) o on true) end;
$$;

-- 內部 helper，不是 API（見 202611010100_revoke_helper_execute.sql）。
revoke execute on function public.spot_whole_condition(p_condition jsonb, p_space_type text) from public, anon, authenticated;
revoke execute on function public.segment_charge_of(p_segment jsonb, p_fee jsonb, p_whole jsonb) from public, anon, authenticated;
revoke execute on function public.segment_charge_of(p_segment jsonb, p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.segments_charge_follow_spot_fee(p_old jsonb, p_new jsonb, p_old_fee jsonb, p_new_fee jsonb, p_whole jsonb) from public, anon, authenticated;

create or replace function public.spot_segments_charge_follow_fee() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.fee is distinct from old.fee or new.parking_segments is distinct from old.parking_segments then
    new.parking_segments:=public.segments_charge_follow_spot_fee(old.parking_segments,new.parking_segments,old.fee,new.fee,
      public.spot_whole_condition(new.condition,new.space_type));
  end if;
  return new;
end;
$$;
