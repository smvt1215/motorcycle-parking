-- 依條目回填點位層資格旗標（#188，PM_ANS_20261101_78）。
--
-- 點位層的 scooter_allowed／heavy_allowed 與 *_not_stated 只給舊版 App 與地圖
-- 讀；新寫入時由 202611010400 的 *_flags_from_entries 觸發器依條目（路外點的
-- parking_zones、路邊點的 parking_segments）彙總。觸發器上線前寫入、之後沒再
-- 更新過的點位（多為匯入點），旗標仍是舊值，和條目不一致。
--
-- 這裡用同一個彙總函式 public.entries_eligibility() 算出條目的值，只更新不一致
-- 的列：
--   - 只改四個資格旗標（社群點另依 community_spots_vehicle_verification 的規則，
--     旗標改變時清掉該車種的 *_verified_at：查核的是舊值）。文字、費率、條目與
--     updated_at 都不動，所以和 #275 我的地圖清除（202611020100／0110／0120，
--     只改文字與費率、更新時停用資格觸發器）任意先後套用結果相同。
--   - 條目沒有表態（沒有條目、或路外點分區未齊全且沒有任何分區允許）的車種，
--     旗標維持原值，與觸發器相同。
--   - 有改到才把 data_versions 的 spots 推進一次（App 依它重新下載）並寫一筆
--     稽核摘要（只記筆數）；沒有不一致時什麼都不做，可重跑。
-- 更新時停用使用者觸發器（同 202611010400 的回填），避免其他觸發器順帶改動
-- 別的欄位；結果就是觸發器在這些列會算出的旗標。

create function private.backfill_spot_eligibility() returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_c integer:=0; v_o integer:=0;
begin
  create temporary table backfill_flags(tbl text,id uuid,s text,h text) on commit drop;
  insert into pg_temp.backfill_flags(tbl,id,s,h)
  select x.tbl,x.id,x.s,x.h from (
    select 'c' tbl,r.id,r.scooter_allowed,r.scooter_not_stated,r.heavy_allowed,r.heavy_not_stated,
      public.entries_eligibility(e.entries,'scooter',e.complete) s,
      public.entries_eligibility(e.entries,'heavy',e.complete) h
    from public.community_spots r
    cross join lateral (select public.condition_off_street(r.space_type,r.facility_type) off) o
    cross join lateral (select case when o.off then r.parking_zones else r.parking_segments end entries,
      case when o.off then coalesce(r.zones_complete,false) else true end complete) e
    union all
    select 'o',r.id,r.scooter_allowed,r.scooter_not_stated,r.heavy_allowed,r.heavy_not_stated,
      public.entries_eligibility(e.entries,'scooter',e.complete),
      public.entries_eligibility(e.entries,'heavy',e.complete)
    from public.official_heavy_spots r
    cross join lateral (select public.condition_off_street(r.space_type,r.facility_type) off) o
    cross join lateral (select case when o.off then r.parking_zones else r.parking_segments end entries,
      case when o.off then coalesce(r.zones_complete,false) else true end complete) e
  ) x
  where (x.s is not null and x.s is distinct from
          (case when x.scooter_not_stated then 'not_stated' else x.scooter_allowed::text end))
     or (x.h is not null and x.h is distinct from
          (case when x.heavy_not_stated then 'not_stated' else x.heavy_allowed::text end));

  if exists(select 1 from pg_temp.backfill_flags) then
    alter table public.community_spots disable trigger user;
    alter table public.official_heavy_spots disable trigger user;
    update public.community_spots r set
        scooter_allowed=case when b.s is null then r.scooter_allowed when b.s='not_stated' then null else b.s::boolean end,
        scooter_not_stated=case when b.s is null then r.scooter_not_stated else b.s='not_stated' end,
        heavy_allowed=case when b.h is null then r.heavy_allowed when b.h='not_stated' then null else b.h::boolean end,
        heavy_not_stated=case when b.h is null then r.heavy_not_stated else b.h='not_stated' end,
        scooter_verified_at=case when b.s is not null and r.scooter_allowed is distinct from
          (case when b.s='not_stated' then null else b.s::boolean end) then null else r.scooter_verified_at end,
        heavy_verified_at=case when b.h is not null and r.heavy_allowed is distinct from
          (case when b.h='not_stated' then null else b.h::boolean end) then null else r.heavy_verified_at end
      from pg_temp.backfill_flags b where b.tbl='c' and b.id=r.id;
    get diagnostics v_c=row_count;
    update public.official_heavy_spots r set
        scooter_allowed=case when b.s is null then r.scooter_allowed when b.s='not_stated' then null else b.s::boolean end,
        scooter_not_stated=case when b.s is null then r.scooter_not_stated else b.s='not_stated' end,
        heavy_allowed=case when b.h is null then r.heavy_allowed when b.h='not_stated' then null else b.h::boolean end,
        heavy_not_stated=case when b.h is null then r.heavy_not_stated else b.h='not_stated' end
      from pg_temp.backfill_flags b where b.tbl='o' and b.id=r.id;
    get diagnostics v_o=row_count;
    alter table public.community_spots enable trigger user;
    alter table public.official_heavy_spots enable trigger user;

    -- The statement triggers above were off: one bump for both tables.
    update public.data_versions set version=version+1,updated_at=now() where key='spots';
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values('00000000-0000-0000-0000-0000000000de','backfill_eligibility','spots','188',null,
      jsonb_build_object('community_spots',v_c,'official_heavy_spots',v_o),
      '依條目回填點位層資格旗標（#188）');
  end if;
  drop table pg_temp.backfill_flags;
  return jsonb_build_object('community_spots',v_c,'official_heavy_spots',v_o);
end;
$$;
revoke execute on function private.backfill_spot_eligibility() from public, anon, authenticated, service_role;

select private.backfill_spot_eligibility();
