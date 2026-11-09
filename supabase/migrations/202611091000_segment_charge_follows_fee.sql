-- 路段費率修改核准時，condition.charge 跟著費率走（#369）。
--
-- App 的 F1 修改既有路段費率只送 {id, fee}（或 {id, fee: null} 改回沿用整條路），
-- condition.charge 不會變；路段指定了 bay 時 segmentConditionOf() 直接用路段
-- 條件，ruleKindsOf() 又只讀 charge，所以免費改收費後仍按舊規則判斷。
--
-- 在核准時推導，而不是由 App 送出：已安裝的舊版 App 與佇列裡的待審建議都只有
-- {id, fee}，只有核准端能一併處理；App 也不能代送 condition，因為車友的 patch
-- 不得帶 basis（validate.ts），而 condition 一送就是整包取代。這裡只動 charge
-- 一個鍵，條件的其他內容原樣保留。
--
-- 規則與 App 的 chargeOfFee() 相同，submit-report 的 precheck 也用同一套
-- （precheck.ts、lib/domain/precheck.dart），審核前的判斷才會和核准結果一致。

-- p_fee 對機車格的收費性質：普機與重機一致時回 toll 或 free，有一個時段收費
-- 的 by_time 算 toll；沒有資訊或兩者不同時回 null（`chargeOfFeeJson`）。
create or replace function public.charge_of_fee(p_fee jsonb) returns text
language sql immutable set search_path='' as $$
  with rates as (
    select case x->>'mode'
        when 'same_as_scooter' then p_fee->'scooter'
        when 'same_as_car' then p_fee->'car'
        else x end r
      from unnest(array[p_fee->'scooter',p_fee->'heavy']) x
      where jsonb_typeof(x)='object'
  ), charges as (
    select case r->>'mode'
        when 'free' then 'free'
        when 'hourly' then 'toll'
        when 'per_visit' then 'toll'
        when 'by_time' then (
          select case when bool_or(p->'rate'->>'mode' in ('hourly','per_visit')) then 'toll'
                      when bool_or(p->'rate'->>'mode'='free') then 'free' end
            from jsonb_array_elements(case when jsonb_typeof(r->'periods')='array' then r->'periods' else '[]'::jsonb end) p)
      end c
      from rates where jsonb_typeof(r)='object'
  )
  select case when count(distinct c)=1 then min(c) end from charges where c is not null;
$$;

-- p_merged（套用 patch 後的路段清單）中，p_patch 以 id 改了 fee、沒有自己帶
-- condition 的路段：charge 改成費率推導的結果，推導不出來就移除，不留舊值。
-- 沒有自己費率的路段看整條路的 p_spot_fee。只處理問收費性質的格位（一般機車格、
-- 普大共用格，與 SpaceKind.asksCharge 相同）；沒寫 bay 的路段沿用點位條件，不動。
create or replace function public.segments_charge_follow_fee(p_merged jsonb,p_patch jsonb,p_spot_fee jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(case
      when exists(select 1 from jsonb_array_elements(p_patch) e
          where e->'id'=z->'id' and e ? 'fee' and not e ? 'condition')
        and z->'condition'->>'bay'='motorcycle'
        and not exists(select 1 from jsonb_array_elements(
            case when jsonb_typeof(z->'condition'->'limits')='array' then z->'condition'->'limits' else '[]'::jsonb end) l
          where l->>'kind' in ('special_vehicle','ev_only'))
      then jsonb_set(z,'{condition}',(z->'condition')-'charge'||
        coalesce((select jsonb_build_object('charge',c) from public.charge_of_fee(
          case when jsonb_typeof(z->'fee')='object' and z->'fee'<>'{}'::jsonb then z->'fee' else p_spot_fee end) c
          where c is not null),'{}'::jsonb))
      else z end order by n),'[]'::jsonb)
    from jsonb_array_elements(p_merged) with ordinality t(z,n);
$$;

-- 內部 helper，不是 API（見 202611010100_revoke_helper_execute.sql）。
revoke execute on function public.charge_of_fee(p_fee jsonb) from public, anon, authenticated;
revoke execute on function public.segments_charge_follow_fee(p_merged jsonb, p_patch jsonb, p_spot_fee jsonb) from public, anon, authenticated;

-- 與 202610310200_eligibility_not_stated.sql 相同，只在兩張表套用路段 patch 後
-- 多一步 segments_charge_follow_fee()。
CREATE OR REPLACE FUNCTION public.admin_resolve_report(p_id uuid, p_decision text, p_patch jsonb DEFAULT '{}'::jsonb, p_note text DEFAULT ''::text, p_force boolean DEFAULT false, p_resolution_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_kind text:=nullif(btrim(coalesce(p_resolution_kind,'')),'');
  v_fields text[]:=array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','scooter_not_stated','heavy_not_stated','facility_type','facility_types','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','fee','condition','fee_plans','fee_plan','closure',
    'parking_zones','parking_segments'];
  v_table text; v_target uuid; v_bad text; v_before jsonb; v_after jsonb;
  v_conflict boolean:=false;
  v_list text; v_merged jsonb;
  -- The fee_plans the review page built a plan edit on ({"plans": …}); not
  -- a column, so it leaves the patch before the field check.
  v_seen jsonb:=p_patch->'fee_plans_seen';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_decision is null or p_decision not in ('accepted','rejected') then
    raise exception 'invalid decision' using errcode='22023';
  end if;
  if jsonb_typeof(v_patch)<>'object' or char_length(v_note)>500 then
    raise exception 'invalid resolution' using errcode='22023';
  end if;
  if v_kind is not null and v_kind not in ('wrong','duplicate','insufficient','outdated','abuse','other') then
    raise exception 'invalid resolution kind' using errcode='22023';
  end if;
  if p_decision='rejected' and v_kind is null then
    raise exception 'a rejection needs a resolution kind' using errcode='22023';
  end if;
  -- "Other" says nothing by itself; the note is the reason.
  if v_kind='other' and btrim(v_note)='' then
    raise exception 'resolution kind other needs a note' using errcode='22023';
  end if;
  select * into v_report from moderation_queue where id=p_id for update;
  if not found then raise exception 'report not found' using errcode='22023'; end if;
  if v_report.status<>'pending' then raise exception 'report already resolved' using errcode='22023'; end if;
  v_patch:=v_patch-'fee_plans_seen';
  if p_decision='rejected' and v_patch<>'{}'::jsonb then
    raise exception 'a rejected report changes no spot' using errcode='22023';
  end if;

  if v_patch ? 'closure' and not public.valid_closure(v_patch->'closure') then
    raise exception 'invalid closure' using errcode='22023';
  end if;
  -- Eligibility (#201): true, false or not_stated; never cleared.
  if not public.eligibility_values_ok(v_patch) then
    raise exception 'invalid eligibility: true, false or not_stated' using errcode='22023';
  end if;

  if v_patch<>'{}'::jsonb then
    if v_report.source_id like 'official:%' then
      v_table:='official_heavy_spots';
      v_fields:=v_fields||'hidden'::text;
      v_target:=case when substr(v_report.source_id,10) ~* '^[0-9a-f-]{36}$' then substr(v_report.source_id,10)::uuid end;
    else
      v_table:='community_spots';
      -- Community spots are hidden or restored through status, official ones through hidden.
      v_fields:=v_fields||'status'::text;
      v_target:=case when v_report.source_id ~* '^[0-9a-f-]{36}$' then v_report.source_id::uuid end;
    end if;
    select k into v_bad from jsonb_object_keys(v_patch) k where k<>all(v_fields) limit 1;
    if v_bad is not null then raise exception 'field % cannot be changed here',v_bad using errcode='22023'; end if;
    -- Adopting a vehicle field verifies it even when the value is unchanged.
    perform set_config('app.admin_vehicle_fields',(select coalesce(string_agg(k,','),'') from jsonb_object_keys(v_patch) k
      where k in ('scooter_allowed','heavy_allowed','parking_access')),true);

    if v_table='community_spots' then
      select to_jsonb(c)-'user_id'-'location' into v_before from community_spots c where c.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      -- Only the fields this patch writes count: votes or other edits that
      -- leave them alone must not train admins to force every decision.
      -- A plan edit stands for the fee it changes: compared as the fee.
      -- The plans themselves must be the ones the admin was shown.
      v_conflict:=(v_report.base_spot is not null and exists(
          select 1 from jsonb_object_keys(v_patch) k
          -- A vehicle's flag and its not_stated count together (#201): writing
          -- one clears the other.
          cross join lateral (select unnest(case
            when k in ('scooter_allowed','scooter_not_stated') then array['scooter_allowed','scooter_not_stated']
            when k in ('heavy_allowed','heavy_not_stated') then array['heavy_allowed','heavy_not_stated']
            when k in ('fee_plans','fee_plan') then array['fee'] else array[k] end) f) m
          where case when m.f in ('parking_zones','parking_segments') then
            -- Zones and segments by id (#188): only the entries the patch
            -- names count; a report whose snapshot lacks the list falls back
            -- to the version it was made on.
            case when v_report.base_spot ? m.f
              then public.entries_patch_conflict(v_report.base_spot->m.f,v_before->m.f,v_patch->m.f)
              else v_report.base_updated_at is distinct from (v_before->>'updated_at')::timestamptz end
          else (case when m.f='facility_types' and not (v_report.base_spot ? 'facility_types')
            -- A report from before the set existed: its one type as the set.
            then case when v_report.base_spot->>'facility_type' is null then 'null'::jsonb
              else jsonb_build_array(v_report.base_spot->>'facility_type') end
            -- Snapshots from before not_stated existed read it as false.
            when m.f like '%\_not\_stated' then coalesce(v_report.base_spot->m.f,'false'::jsonb)
            else v_report.base_spot->m.f end) is distinct from (v_before->m.f) end))
        or (v_seen is not null and (v_seen->'plans') is distinct from (v_before->'fee_plans'));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
      end if;
      -- A zone or segment patch names entries by id (#188): applied to the
      -- current list, so entries it leaves alone stay as they are.
      foreach v_list in array array['parking_zones','parking_segments'] loop
        continue when not v_patch ? v_list;
        v_merged:=public.entries_patch(v_before->v_list,v_patch->v_list);
        if v_merged is null then
          raise exception '% names an entry the spot does not have',v_list using errcode='22023';
        end if;
        -- Each zone the patch adds or changes states both vehicles (#201).
        if v_list='parking_zones' and not public.zone_patch_stated(v_patch->v_list,v_merged) then
          raise exception 'a zone this patch changes needs both vehicles stated' using errcode='22023';
        end if;
        -- A segment's charge follows the rates the patch changes (#369).
        if v_list='parking_segments' then
          v_merged:=public.segments_charge_follow_fee(v_merged,v_patch->v_list,(v_before||v_patch)->'fee');
        end if;
        v_patch:=jsonb_set(v_patch,array[v_list],v_merged);
      end loop;
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,parking_zones,parking_segments,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.condition,r.fee_plans,r.fee_plan,r.closure,r.parking_zones,r.parking_segments,r.status,now()
          from jsonb_populate_record(c,v_patch) r)
        where c.id=v_target returning to_jsonb(c)-'user_id'-'location' into v_after;
      -- Restoring a hidden spot supersedes the "gone" votes that hid it;
      -- otherwise the next vote recounts them and hides it again.
      if v_before->>'status'='hidden' and v_after->>'status'<>'hidden' then
        delete from spot_votes where spot_id=v_target and vote='gone';
      end if;
    else
      select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      -- Only the fields this patch writes count: votes or other edits that
      -- leave them alone must not train admins to force every decision.
      -- A plan edit stands for the fee it changes: compared as the fee.
      -- The plans themselves must be the ones the admin was shown.
      v_conflict:=(v_report.base_spot is not null and exists(
          select 1 from jsonb_object_keys(v_patch) k
          -- A vehicle's flag and its not_stated count together (#201): writing
          -- one clears the other.
          cross join lateral (select unnest(case
            when k in ('scooter_allowed','scooter_not_stated') then array['scooter_allowed','scooter_not_stated']
            when k in ('heavy_allowed','heavy_not_stated') then array['heavy_allowed','heavy_not_stated']
            when k in ('fee_plans','fee_plan') then array['fee'] else array[k] end) f) m
          where case when m.f in ('parking_zones','parking_segments') then
            -- Zones and segments by id (#188): only the entries the patch
            -- names count; a report whose snapshot lacks the list falls back
            -- to the version it was made on.
            case when v_report.base_spot ? m.f
              then public.entries_patch_conflict(v_report.base_spot->m.f,v_before->m.f,v_patch->m.f)
              else v_report.base_updated_at is distinct from (v_before->>'updated_at')::timestamptz end
          else (case when m.f='facility_types' and not (v_report.base_spot ? 'facility_types')
            -- A report from before the set existed: its one type as the set.
            then case when v_report.base_spot->>'facility_type' is null then 'null'::jsonb
              else jsonb_build_array(v_report.base_spot->>'facility_type') end
            -- Snapshots from before not_stated existed read it as false.
            when m.f like '%\_not\_stated' then coalesce(v_report.base_spot->m.f,'false'::jsonb)
            else v_report.base_spot->m.f end) is distinct from (v_before->m.f) end))
        or (v_seen is not null and (v_seen->'plans') is distinct from (v_before->'fee_plans'));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
      end if;
      -- A zone or segment patch names entries by id (#188): applied to the
      -- current list, so entries it leaves alone stay as they are.
      foreach v_list in array array['parking_zones','parking_segments'] loop
        continue when not v_patch ? v_list;
        v_merged:=public.entries_patch(v_before->v_list,v_patch->v_list);
        if v_merged is null then
          raise exception '% names an entry the spot does not have',v_list using errcode='22023';
        end if;
        -- Each zone the patch adds or changes states both vehicles (#201).
        if v_list='parking_zones' and not public.zone_patch_stated(v_patch->v_list,v_merged) then
          raise exception 'a zone this patch changes needs both vehicles stated' using errcode='22023';
        end if;
        -- A segment's charge follows the rates the patch changes (#369).
        if v_list='parking_segments' then
          v_merged:=public.segments_charge_follow_fee(v_merged,v_patch->v_list,(v_before||v_patch)->'fee');
        end if;
        v_patch:=jsonb_set(v_patch,array[v_list],v_merged);
      end loop;
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,parking_zones,parking_segments,hidden,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.condition,r.fee_plans,r.fee_plan,r.closure,r.parking_zones,r.parking_segments,r.hidden,now()
          from jsonb_populate_record(o,v_patch) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    end if;
  end if;

  perform set_config('app.admin_vehicle_fields','',true);
  update moderation_queue set status=p_decision,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note,
    resolution_kind=v_kind
    where id=p_id;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'resolve_report','moderation_queue',p_id::text,
    jsonb_build_object('report',to_jsonb(v_report),'spot',v_before),
    jsonb_build_object('status',p_decision,'resolution_kind',v_kind,'spot_table',v_table,'spot',v_after,'forced',v_conflict),
    v_note);
  return jsonb_build_object('id',p_id,'status',p_decision,'resolution_kind',v_kind,'spot',v_after);
end;
$function$;
