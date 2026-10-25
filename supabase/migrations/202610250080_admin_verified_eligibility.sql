-- Admin-verified vehicle access on community spots.
--
-- A confirmed community spot proves the place exists (two riders may confirm
-- it by voting "still there"), not that its vehicle fields are right, so the
-- app keeps a community lot "unverified" for every vehicle. An administrator
-- who sets those fields in Admin Web has checked them, and the app may then
-- trust them like official data. Each vehicle keeps its own time:
--   scooter_verified_at / heavy_verified_at = when an admin last set or
--   restated that vehicle's access (its *_allowed flag, or parking_access,
--   which states both), and null when no admin ever did, a later non-admin
--   write changed what was verified, or a later admin write moved the spot
--   or changed its bay without restating the access.
-- Only this trigger writes the columns. Nothing a rider sends (reports, votes,
-- the service role's import) can set them, because the trigger takes them
-- from the old row and only an admin JWT with a second factor
-- (public.is_admin()) records a new time.

alter table public.community_spots
  add column scooter_verified_at timestamptz,
  add column heavy_verified_at timestamptz;

-- Backfill from the audit log, conservatively. A vehicle counts as verified
-- only when an admin write (create_spot / update_spot, or an accepted report
-- applied to the spot) set its flag or parking_access to a non-null value,
-- and the row still holds exactly what that write left in every field the
-- verification covers. The time is the audit entry's, so the app's 180-day
-- freshness rule counts from the real check. Runs before the trigger exists.
with entries as (
  select a.created_at,
    case when a.action='resolve_report' then a.before->'spot' else a.before end as old_row,
    case when a.action='resolve_report' then a.after->'spot' else a.after end as new_row
  from public.admin_audit_log a
  where (a.action in ('create_spot','update_spot') and a.target_table='community_spots')
     or (a.action='resolve_report' and a.after->>'spot_table'='community_spots'
         and a.after->>'status'='accepted')
),
current_rows as (
  select c.id,jsonb_build_object('scooter_allowed',c.scooter_allowed,'heavy_allowed',c.heavy_allowed,
    'parking_access',c.parking_access,'space_type',c.space_type,'facility_type',c.facility_type,
    'lat',c.lat,'lng',c.lng) as now_row
  from public.community_spots c
),
verified as (
  select cur.id,v.flag,max(e.created_at) as at
  from entries e
  join current_rows cur on cur.id::text=e.new_row->>'id'
  cross join (values('scooter_allowed'),('heavy_allowed')) v(flag)
  where jsonb_typeof(e.new_row->v.flag)='boolean'
    and (e.old_row is null
      or (e.old_row->v.flag) is distinct from (e.new_row->v.flag)
      or (e.old_row->'parking_access') is distinct from (e.new_row->'parking_access'))
    -- The row still holds what the admin left.
    and not exists(select 1 from jsonb_object_keys(cur.now_row) k
      where (e.new_row->k) is distinct from (cur.now_row->k))
    -- No later admin write left something else there (a non-admin path
    -- must have restored the values since, so the check no longer holds).
    and not exists(select 1 from entries later
      where later.new_row->>'id'=e.new_row->>'id' and later.created_at>e.created_at
        and exists(select 1 from jsonb_object_keys(cur.now_row) k
          where (later.new_row->k) is distinct from (cur.now_row->k)))
  group by cur.id,v.flag
)
update public.community_spots c
  set scooter_verified_at=(select at from verified where verified.id=c.id and flag='scooter_allowed'),
      heavy_verified_at=(select at from verified where verified.id=c.id and flag='heavy_allowed')
  where c.id in (select id from verified);

create function public.community_spots_vehicle_verification() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_admin boolean:=coalesce(public.is_admin(),false);
  -- Vehicle fields the admin RPC was given, set by admin_upsert_spot and
  -- admin_resolve_report below for the length of the call. It only adds to
  -- what an admin JWT may do, so a value set any other way grants nothing.
  v_stated text[]:=string_to_array(coalesce(current_setting('app.admin_vehicle_fields',true),''),',');
  v_place boolean; v_scooter boolean; v_heavy boolean;
begin
  if tg_op='INSERT' then
    new.scooter_verified_at:=case when v_admin then now() end;
    new.heavy_verified_at:=case when v_admin then now() end;
  else
    -- Never taken from the write itself.
    new.scooter_verified_at:=old.scooter_verified_at;
    new.heavy_verified_at:=old.heavy_verified_at;
    -- Which bay or place the access describes.
    v_place:=new.space_type is distinct from old.space_type
      or new.facility_type is distinct from old.facility_type
      or new.lat is distinct from old.lat or new.lng is distinct from old.lng;
    if v_admin then
      -- Setting or restating a vehicle's access, or the shared access that
      -- states both, verifies it. Moving the spot or changing its bay
      -- without restating the access voids the old check, which was made
      -- for the old place.
      v_scooter:=new.scooter_allowed is distinct from old.scooter_allowed
        or new.parking_access is distinct from old.parking_access
        or v_stated && array['scooter_allowed','parking_access'];
      v_heavy:=new.heavy_allowed is distinct from old.heavy_allowed
        or new.parking_access is distinct from old.parking_access
        or v_stated && array['heavy_allowed','parking_access'];
      if v_scooter then new.scooter_verified_at:=now();
      elsif v_place then new.scooter_verified_at:=null;
      end if;
      if v_heavy then new.heavy_verified_at:=now();
      elsif v_place then new.heavy_verified_at:=null;
      end if;
    else
      -- Anything else that changes what was verified voids it: the flag
      -- itself, the shared access, or which bay or place it describes.
      v_place:=v_place or new.parking_access is distinct from old.parking_access;
      if v_place or new.scooter_allowed is distinct from old.scooter_allowed then
        new.scooter_verified_at:=null;
      end if;
      if v_place or new.heavy_allowed is distinct from old.heavy_allowed then
        new.heavy_verified_at:=null;
      end if;
    end if;
  end if;
  -- An unknown flag has nothing to verify.
  if new.scooter_allowed is null then new.scooter_verified_at:=null; end if;
  if new.heavy_allowed is null then new.heavy_verified_at:=null; end if;
  return new;
end;
$$;
revoke execute on function public.community_spots_vehicle_verification() from public,anon,authenticated,service_role;
create trigger community_spots_vehicle_verification before insert or update on public.community_spots
  for each row execute function public.community_spots_vehicle_verification();

grant select (scooter_verified_at,heavy_verified_at) on public.community_spots to anon,authenticated;
-- 202610250050_contributor_attribution.sql's view plus the two times. The
-- viewport RPCs return setof this view, so they carry them too; older builds
-- ignore the extra keys and keep judging these spots unverified.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at
  from public.community_spots;

-- The admin RPCs name the vehicle fields they were given, so restating a
-- value that is already stored (an admin checking it on site, or adopting a
-- report that agrees with it) verifies it too. Each body is the latest one
-- (admin_upsert_spot from 202610250001_admin_spots.sql, admin_resolve_report
-- from 202610250010_spot_fee.sql) with only the set_config calls added.
create or replace function public.admin_upsert_spot(p_source_id text,p_values jsonb,p_base_updated_at timestamptz default null,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_values jsonb:=coalesce(p_values,'{}'::jsonb)-'kind';
  v_note text:=coalesce(p_note,'');
  v_official boolean; v_target uuid; v_bad text; v_before jsonb; v_after jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_values,'{}'::jsonb))<>'object' or char_length(v_note)>500 then
    raise exception 'invalid spot change' using errcode='22023';
  end if;
  if p_source_id is null then
    v_official:=p_values->>'kind'='official';
    if coalesce(p_values->>'kind','') not in ('community','official') then
      raise exception 'kind must be community or official' using errcode='22023';
    end if;
  else
    v_official:=p_source_id like 'official:%';
    v_target:=case when v_official and substr(p_source_id,10) ~* '^[0-9a-f-]{36}$' then substr(p_source_id,10)::uuid
                   when not v_official and p_source_id ~* '^[0-9a-f-]{36}$' then p_source_id::uuid end;
    if v_target is null then raise exception 'invalid spot id' using errcode='22023'; end if;
  end if;
  select k into v_bad from jsonb_object_keys(v_values) k where k<>all(public.admin_spot_fields(v_official)) limit 1;
  if v_bad is not null then raise exception 'field % cannot be changed here',v_bad using errcode='22023'; end if;
  -- Hiding has its own audited RPC; community status here is only existence.
  if not v_official and v_values ? 'status' and v_values->>'status' not in ('pending','confirmed') then
    raise exception 'use admin_set_spot_hidden to hide or restore' using errcode='22023';
  end if;
  -- Tell the verification trigger which vehicle fields this edit states,
  -- even when a value equals the stored one.
  perform set_config('app.admin_vehicle_fields',(select coalesce(string_agg(k,','),'') from jsonb_object_keys(v_values) k
    where k in ('scooter_allowed','heavy_allowed','parking_access')),true);
  if v_official and (v_values ? 'source_url' or p_source_id is null)
     and coalesce(v_values->>'source_url','') !~ '^https://' then
    raise exception 'official spots need an https source_url' using errcode='22023';
  end if;
  if v_official and (v_values ? 'source_name' or p_source_id is null)
     and btrim(coalesce(v_values->>'source_name',''))='' then
    raise exception 'official spots need a source_name' using errcode='22023';
  end if;

  if p_source_id is null then
    if v_official then
      if v_values->>'effective_date' is null then
        raise exception 'official spots need an effective_date' using errcode='22023';
      end if;
      insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note)
        select r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),coalesce(r.note,''),
          r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),coalesce(r.road_segment,''),
          coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),r.scooter_total,
          r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,'')
        from jsonb_populate_record(null::official_heavy_spots,v_values) r
        returning to_jsonb(official_heavy_spots.*) into v_after;
    else
      insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status)
        select auth.uid(),'community',r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),
          coalesce(r.note,''),r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),
          coalesce(r.road_segment,''),coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),
          r.scooter_total,coalesce(r.status,'pending')
        from jsonb_populate_record(null::community_spots,v_values) r
        returning to_jsonb(community_spots.*)-'location' into v_after;
    end if;
  else
    if p_base_updated_at is null then
      raise exception 'an edit needs the version it was opened with' using errcode='22023';
    end if;
    if v_official then
      select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_target for update;
    else
      select to_jsonb(c)-'location' into v_before from community_spots c where c.id=v_target for update;
    end if;
    if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
    if (v_before->>'updated_at')::timestamptz<>p_base_updated_at then
      raise exception 'spot changed since it was opened' using errcode='40001';
    end if;
    if v_official then
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.source_name,r.source_url,r.effective_date,r.license_note,now()
          from jsonb_populate_record(o,v_values) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    else
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.status,now()
          from jsonb_populate_record(c,v_values) r)
        where c.id=v_target returning to_jsonb(c)-'location' into v_after;
    end if;
  end if;

  perform set_config('app.admin_vehicle_fields','',true);
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),case when p_source_id is null then 'create_spot' else 'update_spot' end,
    case when v_official then 'official_heavy_spots' else 'community_spots' end,v_after->>'id',v_before,v_after,v_note);
  return v_after||jsonb_build_object('source_id',case when v_official then 'official:' else '' end||(v_after->>'id'));
end;
$$;

create or replace function public.admin_resolve_report(p_id uuid,p_decision text,p_patch jsonb default '{}',p_note text default '',p_force boolean default false)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_fields text[]:=array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','fee'];
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
    -- Adopting a vehicle field verifies it even when the value is unchanged.
    perform set_config('app.admin_vehicle_fields',(select coalesce(string_agg(k,','),'') from jsonb_object_keys(v_patch) k
      where k in ('scooter_allowed','heavy_allowed','parking_access')),true);

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
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.status,now()
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
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,hidden,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.hidden,now()
          from jsonb_populate_record(o,v_patch) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    end if;
  end if;

  perform set_config('app.admin_vehicle_fields','',true);
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
