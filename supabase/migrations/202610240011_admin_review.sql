-- Admin review (docs/ADMIN_WEB.md, P3):
-- 1. Admins hide an official spot reported gone and restore it later.
--    Riders cannot hide official data themselves.
-- 2. A suggestion remembers the spot it was made against; accepting it after
--    a field it changes was edited is refused unless the admin forces it.

alter table public.official_heavy_spots add column hidden boolean not null default false;

-- Every public read goes through this policy: direct reads (favorite checks)
-- and both security-invoker viewport functions. Imports never write hidden,
-- so a re-import keeps a hidden spot hidden.
drop policy official_read on public.official_heavy_spots;
create policy official_read on public.official_heavy_spots
  for select to anon,authenticated using(effective_date<=current_date and not hidden);
-- Admins (aal2) also see hidden and future-dated rows, to review and restore them.
create policy admin_read_official on public.official_heavy_spots for select to authenticated
  using((select public.is_admin()));

-- The spot as it was when the report arrived: its version and values, so a
-- conflict can show what the rider saw. A trigger fills both, so apply_report
-- (redefined elsewhere) needs no change and older app builds are covered.
-- Rows queued before this migration stay null and never count as conflicts.
alter table public.moderation_queue
  add column base_updated_at timestamptz,
  add column base_spot jsonb;
create function public.moderation_base_version() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.base_updated_at is null then
    if new.source_id like 'official:%' and substr(new.source_id,10) ~* '^[0-9a-f-]{36}$' then
      select o.updated_at,to_jsonb(o)-'photo_urls'-'parking_zones' into new.base_updated_at,new.base_spot
        from public.official_heavy_spots o where o.id=substr(new.source_id,10)::uuid;
    elsif new.source_id ~* '^[0-9a-f-]{36}$' then
      select c.updated_at,to_jsonb(c)-'user_id'-'location'-'photo_urls'-'parking_zones' into new.base_updated_at,new.base_spot
        from public.community_spots c where c.id=new.source_id::uuid;
    end if;
  end if;
  return new;
end;
$$;
create trigger moderation_base_version before insert on public.moderation_queue
  for each row execute function public.moderation_base_version();

-- p_force is new, so the old signature goes; callers using named arguments
-- keep working. Official spots now accept hidden in the patch.
drop function public.admin_resolve_report(uuid,text,jsonb,text);
create function public.admin_resolve_report(p_id uuid,p_decision text,p_patch jsonb default '{}',p_note text default '',p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_fields text[]:=array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules'];
  v_table text; v_target uuid; v_bad text; v_before jsonb; v_after jsonb;
  v_conflict boolean:=false;
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
  select * into v_report from moderation_queue where id=p_id for update;
  if not found then raise exception 'report not found' using errcode='22023'; end if;
  if v_report.status<>'pending' then raise exception 'report already resolved' using errcode='22023'; end if;
  if p_decision='rejected' and v_patch<>'{}'::jsonb then
    raise exception 'a rejected report changes no spot' using errcode='22023';
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

    if v_table='community_spots' then
      select to_jsonb(c)-'user_id'-'location' into v_before from community_spots c where c.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      -- Only the fields this patch writes count: votes or other edits that
      -- leave them alone must not train admins to force every decision.
      v_conflict:=v_report.base_spot is not null and exists(
        select 1 from jsonb_object_keys(v_patch) k where (v_report.base_spot->k) is distinct from (v_before->k));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.status,now()
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
      v_conflict:=v_report.base_spot is not null and exists(
        select 1 from jsonb_object_keys(v_patch) k where (v_report.base_spot->k) is distinct from (v_before->k));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,hidden,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.hidden,now()
          from jsonb_populate_record(o,v_patch) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    end if;
  end if;

  update moderation_queue set status=p_decision,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note
    where id=p_id;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'resolve_report','moderation_queue',p_id::text,
    jsonb_build_object('report',to_jsonb(v_report),'spot',v_before),
    jsonb_build_object('status',p_decision,'spot_table',v_table,'spot',v_after,'forced',v_conflict),
    v_note);
  return jsonb_build_object('id',p_id,'status',p_decision,'spot',v_after);
end;
$$;

-- Hide or restore one spot outside a report, e.g. from the review page's
-- hidden list. p_source_id uses the queue's form: community uuid or official:<uuid>.
revoke execute on function public.admin_resolve_report(uuid,text,jsonb,text,boolean) from public,anon;
grant execute on function public.admin_resolve_report(uuid,text,jsonb,text,boolean) to authenticated;

create function public.admin_set_spot_hidden(p_source_id text,p_hidden boolean,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_note text:=coalesce(p_note,'');
  v_official boolean:=p_source_id like 'official:%';
  v_raw text:=case when p_source_id like 'official:%' then substr(p_source_id,10) else p_source_id end;
  v_target uuid; v_before jsonb; v_after jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_hidden is null or char_length(v_note)>500 or v_raw is null or v_raw !~* '^[0-9a-f-]{36}$' then
    raise exception 'invalid spot change' using errcode='22023';
  end if;
  v_target:=v_raw::uuid;
  if v_official then
    select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_target for update;
    if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
    update official_heavy_spots set hidden=p_hidden,updated_at=now() where id=v_target
      returning to_jsonb(official_heavy_spots.*) into v_after;
  else
    select to_jsonb(c)-'user_id'-'location' into v_before from community_spots c where c.id=v_target for update;
    if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
    -- A restored spot starts over as pending, like one edited by its owner.
    update community_spots set status=case when p_hidden then 'hidden' else 'pending' end,updated_at=now() where id=v_target
      returning to_jsonb(community_spots.*)-'user_id'-'location' into v_after;
    -- The "gone" votes that hid it would hide it again on the next vote.
    if not p_hidden then delete from spot_votes where spot_id=v_target and vote='gone'; end if;
  end if;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),case when p_hidden then 'hide_spot' else 'restore_spot' end,
    case when v_official then 'official_heavy_spots' else 'community_spots' end,v_target::text,v_before,v_after,v_note);
  return v_after;
end;
$$;
revoke execute on function public.admin_set_spot_hidden(text,boolean,text) from public,anon;
grant execute on function public.admin_set_spot_hidden(text,boolean,text) to authenticated;
