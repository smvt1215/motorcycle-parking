-- 點位刪除改軟刪除：保留 14 天可復原，之後永久刪除（#200）。
--
-- 1. Both spot tables get deleted_at and deleted_by. A spot is deleted when
--    it is hidden from riders (community status 'hidden', official hidden),
--    whichever way: admin_set_spot_hidden (the admin site's 刪除點位), or a
--    review adopting a 點位已不存在 report. A trigger stamps the time and the
--    admin; restoring (unhiding) clears both. A promoted community spot is
--    hidden but not deleted: its record stays with the official copy.
-- 2. Deleting closes the spot's open reports (點位已刪除); restoring does
--    not reopen them. Deleting, restoring and purging are audited.
-- 3. public_spots and the public read policies leave deleted spots out, so
--    every viewport, favourite check and search drops them at once; so do
--    the rider sightings' spot checks (#199).
-- 4. purge_deleted_spots() (pg_cron, daily) deletes spots deleted more than
--    14 days ago. A purged official spot's id and source_id are kept in
--    purged_official_spots, and an import skips them until an admin
--    releases one (admin_release_purged_official).
-- 5. Old hidden rows: deleted as of this migration (14 days from now),
--    except promoted community spots.

alter table public.community_spots add column deleted_at timestamptz, add column deleted_by uuid;
alter table public.official_heavy_spots add column deleted_at timestamptz, add column deleted_by uuid;
create index community_spots_deleted_idx on public.community_spots(deleted_at) where deleted_at is not null;
create index official_heavy_spots_deleted_idx on public.official_heavy_spots(deleted_at) where deleted_at is not null;

-- How long a deleted spot can be restored.
create function public.spot_delete_grace() returns interval
language sql immutable set search_path='' as $$ select interval '14 days' $$;

-- Hidden from riders, newly: deleted now, by whoever is signed in (an
-- admin; the review or the RPC). Unhidden: restored. A promotion hides the
-- community row without deleting it (app.promote).
create function public.spot_soft_delete_mark(p_was boolean,p_is boolean,inout p_at timestamptz,inout p_by uuid)
language plpgsql security definer set search_path='' as $$
begin
  if p_is and not p_was and coalesce(current_setting('app.promote',true),'')<>'on' then
    p_at:=now(); p_by:=auth.uid();
  elsif not p_is then
    -- Past the grace period nothing brings it back, whichever writer tries.
    if p_was and p_at<now()-public.spot_delete_grace() then
      raise exception 'deleted more than 14 days ago' using errcode='22023';
    end if;
    p_at:=null; p_by:=null;
  end if;
end;
$$;
revoke execute on function public.spot_soft_delete_mark(boolean,boolean,timestamptz,uuid) from public,anon,authenticated;
create function public.community_spots_soft_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  select m.p_at,m.p_by into new.deleted_at,new.deleted_by
    from public.spot_soft_delete_mark(old.status='hidden',new.status='hidden',new.deleted_at,new.deleted_by) m;
  return new;
end;
$$;
create function public.official_heavy_spots_soft_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  select m.p_at,m.p_by into new.deleted_at,new.deleted_by
    from public.spot_soft_delete_mark(old.hidden,new.hidden,new.deleted_at,new.deleted_by) m;
  return new;
end;
$$;
revoke execute on function public.community_spots_soft_delete() from public,anon,authenticated;
revoke execute on function public.official_heavy_spots_soft_delete() from public,anon,authenticated;
create trigger community_spots_soft_delete before update on public.community_spots
  for each row execute function public.community_spots_soft_delete();
create trigger official_heavy_spots_soft_delete before update on public.official_heavy_spots
  for each row execute function public.official_heavy_spots_soft_delete();

-- Deleting closes the spot's open reports, with the reason 點位已刪除. The
-- report a review is adopting is closed too, then marked as decided by it.
create function public.spot_deleted_close_reports() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_source text:=case when tg_table_name='official_heavy_spots' then 'official:' else '' end||new.id::text;
begin
  if new.deleted_at is not null and old.deleted_at is null then
    -- A report another admin is resolving right now is left to them: it
    -- holds that row and waits for this spot, so waiting here would
    -- deadlock (their RPC locks the report before the spot).
    update public.moderation_queue q set status='rejected',resolution_kind='other',resolution_note='點位已刪除',
      resolved_at=now(),resolved_by=coalesce(auth.uid(),new.deleted_by)
      where q.id in (select m.id from public.moderation_queue m
        where m.source_id=v_source and m.status='pending' for update skip locked);
  end if;
  return null;
end;
$$;
revoke execute on function public.spot_deleted_close_reports() from public,anon,authenticated;
-- After any update: deleted_at is set by the BEFORE trigger, never named
-- in the statement, so an `update of deleted_at` trigger would not fire.
create trigger community_spots_deleted_reports after update on public.community_spots
  for each row execute function public.spot_deleted_close_reports();
create trigger official_heavy_spots_deleted_reports after update on public.official_heavy_spots
  for each row execute function public.spot_deleted_close_reports();

-- Old hidden rows are deleted as of now; a promoted community spot is not.
alter table public.community_spots disable trigger user;
alter table public.official_heavy_spots disable trigger user;
update public.community_spots c set deleted_at=now()
  where c.status='hidden' and not exists(select 1 from public.admin_audit_log a
    where a.action='promote_spot' and a.target_id=c.id::text);
update public.official_heavy_spots set deleted_at=now() where hidden;
alter table public.community_spots enable trigger user;
alter table public.official_heavy_spots enable trigger user;
-- Their open reports close as a deletion's do (the trigger was off).
update public.moderation_queue q set status='rejected',resolution_kind='other',resolution_note='點位已刪除',resolved_at=now()
  where q.status='pending' and (
    exists(select 1 from public.community_spots c where c.deleted_at is not null and q.source_id=c.id::text)
    or exists(select 1 from public.official_heavy_spots o where o.deleted_at is not null and q.source_id='official:'||o.id));

-- ---- Riders never see a deleted spot.
grant select (deleted_at) on public.community_spots to anon,authenticated;
drop policy public_spots on public.community_spots;
create policy public_spots on public.community_spots for select to anon,authenticated
  using(status<>'hidden' and deleted_at is null);
drop policy official_read on public.official_heavy_spots;
create policy official_read on public.official_heavy_spots
  for select to anon,authenticated using(effective_date<=current_date and not hidden and deleted_at is null);

-- 202610310200_eligibility_not_stated.sql's view, without deleted spots.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at,
    condition,zones_complete,closure,public.closure_state(closure) as closure_state,facility_types,parking_segments,
    scooter_not_stated,heavy_not_stated
  from public.community_spots
  -- Admins read every row (admin_read_spots); the app never shows them a
  -- deleted one either.
  where deleted_at is null;

-- 202610310100_rider_sightings.sql's spot checks, without deleted spots.
create or replace function public.sighting_spot_location(p_spot text) returns extensions.geography
language plpgsql stable set search_path='' as $$
begin
  if p_spot ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return (select extensions.st_setsrid(extensions.st_makepoint(o.lng,o.lat),4326)::extensions.geography
      from public.official_heavy_spots o
      where o.id=substr(p_spot,10)::uuid and not o.hidden and o.deleted_at is null and o.effective_date<=current_date);
  elsif p_spot ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return (select c.location from public.community_spots c where c.id=p_spot::uuid and c.status<>'hidden' and c.deleted_at is null);
  end if;
  return null;
end $$;

create or replace function public.sighting_spot_entries(p_spot text,out zones jsonb,out segments jsonb)
language plpgsql stable set search_path='' as $$
begin
  if p_spot ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select o.parking_zones,o.parking_segments into zones,segments from public.official_heavy_spots o
      where o.id=substr(p_spot,10)::uuid and not o.hidden and o.deleted_at is null and o.effective_date<=current_date;
  elsif p_spot ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select c.parking_zones,c.parking_segments into zones,segments from public.community_spots c
      where c.id=p_spot::uuid and c.status<>'hidden' and c.deleted_at is null;
  end if;
end $$;

-- ---- 刪除點位 and 復原 (the admin site), audited. Hiding is deleting.
create or replace function public.admin_set_spot_hidden(p_source_id text,p_hidden boolean,p_note text default '')
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
  else
    select to_jsonb(c)-'user_id'-'location' into v_before from community_spots c where c.id=v_target for update;
  end if;
  if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
  -- Only a deleted spot is restored: a promoted community spot stays with
  -- its official copy.
  if not p_hidden and v_before->>'deleted_at' is null then
    raise exception 'only a deleted spot can be restored' using errcode='22023';
  end if;
  if not p_hidden and (v_before->>'deleted_at')::timestamptz<now()-public.spot_delete_grace() then
    raise exception 'deleted more than 14 days ago' using errcode='22023';
  end if;
  if p_hidden and v_before->>'deleted_at' is not null then
    raise exception 'spot already deleted' using errcode='22023';
  end if;
  if v_official then
    update official_heavy_spots set hidden=p_hidden,updated_at=now() where id=v_target
      returning to_jsonb(official_heavy_spots.*) into v_after;
  else
    -- A restored spot starts over as pending, like one edited by its owner.
    update community_spots set status=case when p_hidden then 'hidden' else 'pending' end,updated_at=now() where id=v_target
      returning to_jsonb(community_spots.*)-'user_id'-'location' into v_after;
    -- The "gone" votes that hid it would hide it again on the next vote.
    if not p_hidden then delete from spot_votes where spot_id=v_target and vote='gone'; end if;
  end if;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),case when p_hidden then 'delete_spot' else 'restore_spot' end,
    case when v_official then 'official_heavy_spots' else 'community_spots' end,v_target::text,v_before,v_after,v_note);
  return v_after;
end;
$$;

-- ---- A promotion hides the community row without deleting it.

CREATE OR REPLACE FUNCTION public.admin_promote_spot(p_source_id text, p_values jsonb, p_base_updated_at timestamp with time zone, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_values jsonb:=coalesce(p_values,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_community community_spots; v_bad text; v_after jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_source_id is null or p_source_id !~* '^[0-9a-f-]{36}$' or jsonb_typeof(v_values)<>'object' or char_length(v_note)>500 then
    raise exception 'invalid promotion' using errcode='22023';
  end if;
  select k into v_bad from jsonb_object_keys(v_values) k where k<>all(public.admin_spot_fields(true)) limit 1;
  if v_bad is not null then raise exception 'field % cannot be set here',v_bad using errcode='22023'; end if;
  if coalesce(v_values->>'source_url','') !~ '^https://' or btrim(coalesce(v_values->>'source_name',''))=''
     or v_values->>'effective_date' is null then
    raise exception 'promotion needs source_name, an https source_url and effective_date' using errcode='22023';
  end if;
  -- An official spot states both vehicles (#201): the admin's call, never
  -- the rider's values, and never reset to unconfirmed.
  if not public.eligibility_values_ok(v_values) or not public.eligibility_stated(v_values) then
    raise exception 'promotion states both vehicles: true, false or not_stated' using errcode='22023';
  end if;
  select * into v_community from community_spots where id=p_source_id::uuid for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  if v_community.updated_at<>p_base_updated_at then
    raise exception 'spot changed since it was opened' using errcode='40001';
  end if;
  if v_community.status='hidden' then
    raise exception 'restore the spot before promoting it' using errcode='22023';
  end if;

  insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
      facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,parking_zones,parking_segments,
      source_name,source_url,effective_date,license_note,fee,condition,zones_complete,closure)
    select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
      -- Only what the admin states in this call; never the rider's values.
      case when v_values ? 'scooter_allowed' then (v_values->>'scooter_allowed')::boolean end,
      case when v_values ? 'heavy_allowed' then (v_values->>'heavy_allowed')::boolean end,
      coalesce((v_values->>'scooter_not_stated')::boolean,false),coalesce((v_values->>'heavy_not_stated')::boolean,false),
      r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
      v_community.parking_zones,r.parking_segments,r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),
      -- The fee moves with its fee_note text, so the two stay in step.
      r.fee,r.condition,coalesce(r.zones_complete,false),
      -- Works or a closure moves with the spot, as it stands (#116).
      r.closure
    from jsonb_populate_record(
      null::official_heavy_spots,
      (to_jsonb(v_community)-'id'-'user_id'-'location'-'source'-'source_name'-'source_url'-'license_note'
        -'status'-'last_confirmed_at'-'created_at'-'available'-'photo_urls'-'updated_at')||v_values) r
    returning to_jsonb(official_heavy_spots.*) into v_after;

  perform set_config('app.promote','on',true);
  update community_spots set status='hidden',updated_at=now() where id=v_community.id;
  perform set_config('app.promote','',true);
  -- Open reports follow the spot; their snapshots still flag changed fields.
  update moderation_queue set source_id='official:'||(v_after->>'id')
   where source_id=v_community.id::text and status='pending';

  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'promote_spot','community_spots',v_community.id::text,
    to_jsonb(v_community)-'location',jsonb_build_object('official',v_after),v_note);
  return v_after||jsonb_build_object('source_id','official:'||(v_after->>'id'));
end;
$function$;

-- ---- 202610270120_history_owner_votes.sql's history entries, with the new
-- delete and purge actions (restore_spot keeps its name).
create or replace function public.spot_history_entries(p_source_id text)
returns table(at timestamptz,kind text,action text,actor uuid,created boolean,changes jsonb,
  note text,source_name text,report jsonb)
language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare
  v_official boolean:=p_source_id like 'official:%';
  v_raw text:=case when p_source_id like 'official:%' then substr(p_source_id,10) else p_source_id end;
  v_table text:=case when p_source_id like 'official:%' then 'official_heavy_spots' else 'community_spots' end;
  v_id uuid;
begin
  if v_raw is null or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return; end if;
  v_id:=v_raw::uuid;
  return query
  with audited as (
    -- Writes to the spot row itself.
    select a.created_at,a.action,a.actor,a.before,a.after,a.note from admin_audit_log a
    where a.target_table=v_table and a.target_id=v_id::text
      and a.action in ('create_spot','update_spot','import_spot','convert_fee','hide_spot','delete_spot','restore_spot','purge_spot',
        'clear_contributor_name','promote_spot')
    union all
    -- The official spot a community spot was promoted into starts there.
    select a.created_at,'promoted_from',a.actor,null,a.after->'official',a.note from admin_audit_log a
    where v_official and a.action='promote_spot' and a.after->'official'->>'id'=v_id::text
  ),
  decided as (
    -- Reports an administrator accepted or rejected, with what the
    -- acceptance changed. Reports resolved in the Dashboard before the
    -- admin site ('closed') carry no decision and are left out.
    select coalesce(q.resolved_at,r.created_at) as at,q.status,r.actor,r.before->'spot' as before,
      r.after->'spot' as after,q.resolution_note,
      jsonb_build_object('id',q.id,'status',q.status,'reason',q.reason,'field',q.field,'proposed',q.proposed,
        'note',q.note,'evidence_url',q.evidence_url,'resolution_note',q.resolution_note,
        'resolution_kind',q.resolution_kind,'created_at',q.created_at,'resolved_at',q.resolved_at) as report
    from moderation_queue q
    left join lateral (select a.created_at,a.actor,a.before,a.after from admin_audit_log a
      where a.action='resolve_report' and a.target_table='moderation_queue' and a.target_id=q.id::text
      order by a.created_at desc limit 1) r on true
    where q.source_id=p_source_id and q.status in ('accepted','rejected')
  )
  select x.created_at,
    case when x.action in ('import_spot','convert_fee') then 'import' else 'admin' end,
    x.action,x.actor,
    x.action in ('create_spot','promoted_from') or (x.action='import_spot' and x.before is null),
    case when x.action in ('create_spot','promoted_from') or (x.action='import_spot' and x.before is null)
      then '[]'::jsonb else public.spot_history_changes(x.before,x.after) end,
    x.note,
    case when x.action='import_spot' then nullif(x.after->>'source_name','') end,
    null::jsonb
  from audited x
  union all
  select d.at,'report','resolve_report',d.actor,false,
    case when d.status='accepted' then public.spot_history_changes(d.before,d.after) else '[]'::jsonb end,
    d.resolution_note,null,d.report
  from decided d
  union all
  -- A spot a rider added through the app has no audit entry for its creation.
  select c.created_at,case when c.contributor_role='import' then 'import' else 'report' end,'create',
    null::uuid,true,'[]'::jsonb,'',null,null
  from community_spots c
  where not v_official and c.id=v_id and not exists(select 1 from admin_audit_log a
    where a.target_table='community_spots' and a.target_id=v_id::text and a.action in ('create_spot','import_spot')
      and a.before is null)
  union all
  -- Riders' own edits and votes (decision 56).
  select e.at,case when e.kind='vote' then 'vote' else 'owner' end,
    case when e.kind='vote' then 'vote_'||e.vote else 'owner_update' end,
    e.actor,false,
    case when e.after is null then '[]'::jsonb else public.spot_history_changes(e.before,e.after) end,
    '',null,null
  from spot_rider_events e
  where not v_official and e.spot_id=v_id
  order by 1 desc;
end;
$$;

-- ---- 永久刪除: 14 days after deletion.
create table public.purged_official_spots (
  official_id uuid primary key,
  source_id text not null default '',
  -- The dataset the source id belongs to: ids repeat across datasets.
  source_url text not null default '',
  name text not null default '',
  deleted_at timestamptz,
  purged_at timestamptz not null default now()
);
alter table public.purged_official_spots enable row level security;
create policy admin_read_purged on public.purged_official_spots for select to authenticated
  using((select public.is_admin()));
grant select on public.purged_official_spots to authenticated;

-- Deletes the spots deleted more than spot_delete_grace() ago, each audited
-- with its last row as the admin who deleted it; an official spot's ids are
-- kept so an import skips it. Run daily by pg_cron.
create function public.purge_deleted_spots() returns integer
language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; n integer:=0;
begin
  for r in select c.id,to_jsonb(c)-'user_id'-'location' as row,c.deleted_by from community_spots c
      where c.deleted_at<now()-public.spot_delete_grace() for update skip locked loop
    if r.deleted_by is not null then
      insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
      values(r.deleted_by,'purge_spot','community_spots',r.id::text,r.row,null,'刪除滿 14 天，永久刪除');
    end if;
    delete from community_spots where id=r.id;
    n:=n+1;
  end loop;
  for r in select o.id,to_jsonb(o) as row,o.deleted_by,o.source_id,o.source_url,o.name,o.deleted_at from official_heavy_spots o
      where o.deleted_at<now()-public.spot_delete_grace() for update skip locked loop
    insert into purged_official_spots(official_id,source_id,source_url,name,deleted_at)
      values(r.id,coalesce(r.source_id,''),coalesce(r.source_url,''),coalesce(r.name,''),r.deleted_at)
      on conflict (official_id) do update set source_id=excluded.source_id,source_url=excluded.source_url,name=excluded.name,
        deleted_at=excluded.deleted_at,purged_at=now();
    if r.deleted_by is not null then
      insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
      values(r.deleted_by,'purge_spot','official_heavy_spots',r.id::text,r.row,null,'刪除滿 14 天，永久刪除');
    end if;
    delete from official_heavy_spots where id=r.id;
    n:=n+1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.purge_deleted_spots() from public,anon,authenticated;

create extension if not exists pg_cron;
select cron.schedule('purge-deleted-spots','23 3 * * *','select public.purge_deleted_spots()');

-- An admin lets an import bring a purged official spot back.
create function public.admin_release_purged_official(p_official_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_before jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if char_length(coalesce(p_note,''))>500 then raise exception 'invalid note' using errcode='22023'; end if;
  delete from purged_official_spots where official_id=p_official_id returning to_jsonb(purged_official_spots.*) into v_before;
  if v_before is null then raise exception 'not a purged official spot' using errcode='22023'; end if;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'release_purged_spot','purged_official_spots',p_official_id::text,v_before,null,coalesce(p_note,''));
  return v_before;
end;
$$;
revoke execute on function public.admin_release_purged_official(uuid,text) from public,anon;
grant execute on function public.admin_release_purged_official(uuid,text) to authenticated;

-- ---- Imports skip a purged official spot, by its id or by its source's id
-- within the same dataset (source_url).

CREATE OR REPLACE FUNCTION public.admin_import_plan(p_spots jsonb)
 RETURNS TABLE(source_id text, kind text, target uuid, status text, reason text, name text, city text, district text, base_updated_at timestamp with time zone, hidden boolean, incoming jsonb, changes jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_spot jsonb; v_index integer:=0; v_seen text[]:='{}';
  v_official boolean; v_raw text; v_current jsonb; v_owned jsonb; k text;
  v_change jsonb;
begin
  for v_spot in select value from jsonb_array_elements(p_spots) loop
    v_index:=v_index+1;
    source_id:=coalesce(v_spot->>'id',''); kind:=null; target:=null; status:=null; reason:='';
    name:=coalesce(v_spot->>'name',''); city:=coalesce(v_spot->>'city',''); district:=coalesce(v_spot->>'district','');
    base_updated_at:=null; hidden:=false; incoming:=null; changes:='[]';
    v_official:=source_id like 'official:%';
    kind:=case when v_official then 'official' else 'community' end;
    v_raw:=case when v_official then substr(source_id,10) else source_id end;
    if jsonb_typeof(v_spot) is distinct from 'object' or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      status:='invalid'; reason:=format('第 %s 筆沒有可辨識的 id',v_index); return next; continue;
    end if;
    target:=v_raw::uuid;
    if source_id=any(v_seen) then
      status:='invalid'; reason:='檔案中重複的 id'; return next; continue;
    end if;
    v_seen:=v_seen||source_id;
    if coalesce(v_spot->>'source','')<>(case when v_official then 'official' else 'import' end) then
      status:='invalid'; reason:='來源與 id 不符（官方點 id 以 official: 開頭，社群點 source 為 import）'; return next; continue;
    end if;
    begin
      incoming:=public.admin_import_row(v_spot,v_official);
    exception when others then
      status:='invalid'; reason:='欄位型別錯誤：'||sqlerrm; return next; continue;
    end;
    if btrim(coalesce(incoming->>'name',''))='' or char_length(incoming->>'name')>100 then
      reason:='名稱需為 1–100 字';
    elsif (incoming->>'lat') is null or (incoming->>'lng') is null
       or (incoming->>'lat')::float8 not between 20 and 27 or (incoming->>'lng')::float8 not between 118 and 123 then
      reason:='座標不在台灣範圍內';
    elsif btrim(coalesce(incoming->>'city',''))='' then
      reason:='缺少縣市';
    elsif v_official and (coalesce(incoming->>'source_url','') !~ '^https://' or btrim(coalesce(incoming->>'source_name',''))='') then
      reason:='官方點需要資料來源與 https 官方資料網址';
    elsif jsonb_typeof(incoming->'fee')='object' and not public.valid_fee(incoming->'fee') then
      reason:='費率格式不符';
    end if;
    if reason<>'' then status:='invalid'; return next; continue; end if;

    if not v_official then
      select to_jsonb(c)-'location' into v_current from community_spots c where c.id=target;
      if v_current is null then status:='new';
      else
        status:='existing'; reason:='社群點已存在，匯入不更新';
        base_updated_at:=(v_current->>'updated_at')::timestamptz;
        hidden:=v_current->>'status'='hidden';
      end if;
      return next; continue;
    end if;

    select to_jsonb(o) into v_current from official_heavy_spots o where o.id=target;
    if v_current is null and exists(select 1 from purged_official_spots p where p.official_id=target
        or (p.source_id<>'' and p.source_id=incoming->>'source_id' and p.source_url=incoming->>'source_url')) then
      status:='invalid'; reason:='這個官方點已永久刪除，匯入時跳過；要匯回請先在管理站「已刪除」解除'; return next; continue;
    end if;
    if v_current is null then status:='new'; return next; continue; end if;
    -- Zones as files write them: a plan reference is the database's own
    -- (fee_plans_sync() puts it back on write), so it is no change.
    v_current:=jsonb_set(v_current,'{parking_zones}',public.zones_without_plans(v_current->'parking_zones'));
    base_updated_at:=(v_current->>'updated_at')::timestamptz;
    hidden:=(v_current->>'hidden')::boolean;
    -- A file without a fee leaves the stored one while the note it
    -- describes stays the same.
    if incoming->'fee'='null'::jsonb and incoming->'fee_note'=v_current->'fee_note' then
      incoming:=jsonb_set(incoming,'{fee}',v_current->'fee');
    end if;
    -- A note that is the stored fee's source text, beside no fee or the
    -- stored fee, describes the same fee: the stored fee and its sentence
    -- stay (202610270022 moved such notes to fee_source_text). The source
    -- text always describes the stored fee: spot_fee_source_text() clears
    -- it whenever the fee changes without one.
    if v_current->>'fee_source_text'<>'' and incoming->>'fee_note'=v_current->>'fee_source_text'
       and (incoming->'fee'='null'::jsonb or incoming->'fee'=v_current->'fee') then
      incoming:=jsonb_set(jsonb_set(incoming,'{fee}',v_current->'fee'),'{fee_note}',v_current->'fee_note');
    end if;

    -- Files written before the set (decision 58) carry facility_type alone:
    -- the stored set stays while the type is the stored first one, else
    -- the file's type becomes the set. A file with the set gives its first
    -- as facility_type, as the table keeps it.
    if incoming->'facility_types'='null'::jsonb then
      incoming:=jsonb_set(incoming,'{facility_types}',case
        when incoming->'facility_type'='null'::jsonb then 'null'::jsonb
        when incoming->'facility_type'=v_current->'facility_type'
          then coalesce(v_current->'facility_types','null'::jsonb)
        else jsonb_build_array(incoming->'facility_type') end);
    elsif jsonb_typeof(incoming->'facility_types')='array'
        and public.valid_facility_types(array(select jsonb_array_elements_text(incoming->'facility_types'))) then
      incoming:=jsonb_set(jsonb_set(incoming,'{facility_types}',to_jsonb(public.facility_types_ordered(
          array(select jsonb_array_elements_text(incoming->'facility_types'))))),
        '{facility_type}',to_jsonb(public.facility_types_ordered(
          array(select jsonb_array_elements_text(incoming->'facility_types'))))->0);
    end if;

    -- For each field, the latest audited write that changed it, if that
    -- was an administrator's and the row still holds its value.
    with entries as (
      select a.created_at,a.action,a.before as old_row,a.after as new_row
      from admin_audit_log a
      where a.target_table='official_heavy_spots' and a.target_id=target::text
        and a.action in ('create_spot','update_spot','import_spot','convert_fee')
      union all
      select a.created_at,a.action,a.before->'spot',a.after->'spot' from admin_audit_log a
      where a.action='resolve_report' and a.after->'spot'->>'id'=target::text
        and a.after->>'spot_table'='official_heavy_spots' and a.after->>'status'='accepted'
      union all
      select a.created_at,a.action,null,a.after->'official' from admin_audit_log a
      where a.action='promote_spot' and a.after->'official'->>'id'=target::text
    ),
    writes as (
      select distinct on (f) f,e.action,e.created_at,e.new_row->f as value
      from entries e cross join unnest(public.admin_import_fields()) f
      where e.new_row ? f and (e.old_row is null or (e.old_row->f) is distinct from (e.new_row->f))
      order by f,e.created_at desc
    )
    select coalesce(jsonb_object_agg(w.f,jsonb_build_object('at',w.created_at,'action',w.action)),'{}')
      into v_owned from writes w
      -- Stored zones are compared without plan references, the audited
      -- values too, so a promoted or edited zone stays the administrator's.
      where w.action<>'import_spot' and (case when w.f='parking_zones' then public.zones_without_plans(w.value)
        else w.value end) is not distinct from v_current->w.f;

    foreach k in array public.admin_import_fields() loop
      if (incoming->k) is distinct from (v_current->k) then
        v_change:=jsonb_build_object('field',k,'current',v_current->k,'incoming',incoming->k,'admin',v_owned->k);
        changes:=changes||jsonb_build_array(v_change);
      end if;
    end loop;
    -- A fee is read from its text: when either is the administrator's, both
    -- are kept or replaced together, never a file fee beside a kept text.
    -- So are a vehicle's flag and its not_stated (#201): the table clears
    -- one whenever the other is written.
    select coalesce(jsonb_agg(case
        when public.admin_import_pair(c->>'field') is not null and jsonb_typeof(c->'admin') is distinct from 'object'
        then c||jsonb_build_object('admin',(select p->'admin' from jsonb_array_elements(changes) p
          where public.admin_import_pair(p->>'field')=public.admin_import_pair(c->>'field')
            and jsonb_typeof(p->'admin')='object' limit 1))
        else c end order by o),'[]')
      into changes from jsonb_array_elements(changes) with ordinality as e(c,o);
    status:=case when changes='[]'::jsonb then 'unchanged'
      when exists(select 1 from jsonb_array_elements(changes) c where jsonb_typeof(c->'admin')='object') then 'conflict'
      else 'update' end;
    return next;
  end loop;
end;
$function$;
