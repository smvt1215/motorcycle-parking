-- #326（使用者 2026-11-11 決定方案 B）：舊審核頁不能結案內容檢舉。
--
-- 舊 Flutter 審核頁讀所有處理中的回報，field='inappropriate' 的內容檢舉也會
-- 列出來；在那頁以任何方式結案（結案不修改、修改後套用、駁回）都經
-- admin_resolve_report 寫入 resolved_at，moderation_inappropriate_resolved
-- 就把遮蔽的原文放回——「成立」一則檢舉，被檢舉的內容反而重新公開。
--
-- 內容檢舉只由 admin_v1.resolve_content_report（restore／keep／edit）結案。
-- admin_resolve_report 遇到內容檢舉一律拒絕：P0421
-- 「content reports are resolved on the pending cases page」，回報維持處理中、
-- 點位與遮蔽不變，也不寫稽核。P0421 取 HTTP 421 Misdirected Request 的意思
-- （送錯入口），不與既有的 40001（點位已變更）、22023（參數）、55000（有檢舉
-- 擋升級）、P0409／P0410（submit-report）混淆；PostgREST 對 P0 開頭回 400。
--
-- 觸發器本身不改：點位刪除時的自動結案（spot_deleted_close_reports、
-- purge_deleted_spots）照舊不放回，復原時重新送審
-- （community_spots_content_hold_restored）。
--
-- 函式本體照抄 202611091000_segment_charge_follows_fee.sql，只在鎖定回報、
-- 確認處理中之後多一個檢查；簽名不變，權限沿用。

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
  -- A content report closes only through admin_v1.resolve_content_report
  -- (#326): resolving it here would put the hidden text back on show.
  if v_report.field='inappropriate' then
    raise exception 'content reports are resolved on the pending cases page' using errcode='P0421';
  end if;
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
