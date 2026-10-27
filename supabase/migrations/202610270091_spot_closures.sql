-- Temporary closures (#116, decision 41; closure canvas, C6 canvas
-- ClosureAdmin) and the admin map's row limit (#133). Stack C, C6b.
--
-- 1. `closure` on both spot tables: {reason, since, until?, basis?}.
--    reason is works (施工中) or closed (暫時封閉); since the date it began;
--    until the date the notice gives for reopening, optional — without one
--    the closure ends 7 days after since; basis what it rests on (a rider's
--    report and their words, or the admin's), at most 200 characters.
--    valid_closure() holds the shape. The spot itself is never deleted.
-- 2. closure_state(): the server judges by date (Asia/Taipei) whether a
--    closure is 'active' (can't park) or 'expired' (shown again, awaiting a
--    rider's confirmation). public_spots and official_viewport_spots_v3
--    return both, so the app reads the server's judgement.
-- 3. The admin form, the review page and riders' reports carry it:
--    admin_spot_fields()/admin_upsert_spot() and admin_resolve_report()
--    take closure (applying a gone report for works or a closure sets it;
--    「已經可以停」 clears it).
-- 4. admin_viewport_spots_v2(): the three layers in one jsonb value — never
--    cut by the API's max_rows (1,000) the way rows are — at most 1,000
--    spots in all, filled community, official, hidden in that order, with
--    each layer's count in view and whether any was left out.

-- ===== 1. 欄位 =====

-- p as a date, or null when it is not a real one (2026-02-30).
create function public.closure_date(p text) returns date
language plpgsql immutable set search_path='' as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}$' or to_char(p::date,'YYYY-MM-DD')<>p then return null; end if;
  return p::date;
exception when others then return null;
end;
$$;

create function public.valid_closure(p jsonb) returns boolean
language sql immutable set search_path='' as $$
  select p is null or jsonb_typeof(p)='null' or (
    jsonb_typeof(p)='object'
    and not exists(select 1 from jsonb_object_keys(p) k where k not in ('reason','since','until','basis'))
    and p->>'reason' in ('works','closed')
    and jsonb_typeof(p->'since')='string' and (p->>'since') ~ '^\d{4}-\d{2}-\d{2}$'
    and public.closure_date(p->>'since') is not null
    and (not p ? 'until' or (jsonb_typeof(p->'until')='string' and (p->>'until') ~ '^\d{4}-\d{2}-\d{2}$'
      and public.closure_date(p->>'until') is not null
      and public.closure_date(p->>'until')>=public.closure_date(p->>'since')))
    and (not p ? 'basis' or (jsonb_typeof(p->'basis')='string' and char_length(p->>'basis')<=200)));
$$;

alter table public.community_spots add column closure jsonb
  constraint community_spots_closure_check check (public.valid_closure(closure));
alter table public.official_heavy_spots add column closure jsonb
  constraint official_heavy_spots_closure_check check (public.valid_closure(closure));
comment on column public.community_spots.closure is
  '暫時封閉／施工中（#116）：{reason: works|closed, since, until?, basis?}；沒有 until 時 since 後 7 天到期。';
comment on column public.official_heavy_spots.closure is
  '暫時封閉／施工中（#116）：{reason: works|closed, since, until?, basis?}；沒有 until 時 since 後 7 天到期。';

-- ===== 2. 到期判斷 =====

-- The last day p holds: its until, or 7 days after since.
create function public.closure_ends_on(p jsonb) returns date
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p)='object'
    then coalesce(public.closure_date(p->>'until'),public.closure_date(p->>'since')+7) end;
$$;

-- 'active' until the day after closure_ends_on() in Taiwan, then 'expired';
-- null without a closure.
create function public.closure_state(p jsonb) returns text
language sql stable set search_path='' as $$
  select case when jsonb_typeof(p) is distinct from 'object' then null
    when (now() at time zone 'Asia/Taipei')::date<=public.closure_ends_on(p) then 'active'
    else 'expired' end;
$$;

grant select (closure) on public.community_spots to anon,authenticated;

-- 202610270010_parking_conditions.sql's view plus the closure and its state.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at,
    condition,zones_complete,closure,public.closure_state(closure) as closure_state
  from public.community_spots;

-- 202610270010_parking_conditions.sql's official v3 plus the two columns;
-- its return type changes, so it is dropped and created again.
drop function public.official_viewport_spots_v3(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots_v3(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb,
  contributor_name text,contributor_role text,condition jsonb,zones_complete boolean,
  closure jsonb,closure_state text
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee,
    ''::text,'admin'::text,o.condition,o.zones_complete,o.closure,public.closure_state(o.closure)
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id limit 501;
$$;
grant execute on function public.official_viewport_spots_v3(double precision,double precision,double precision,double precision) to anon,authenticated;

-- ===== 3. 管理站讀寫 =====

-- 202610270090_admin_spot_plans.sql's admin_spot_rows with each closure's
-- state as the server judges it, so the admin form tags it as the app does.
create or replace function public.admin_spot_rows(p_source_ids text[]) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_ids text[]:=coalesce(p_source_ids,'{}'); v_out jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if cardinality(v_ids)>200 then raise exception 'too many spots' using errcode='22023'; end if;
  select coalesce(jsonb_agg(r),'[]'::jsonb) into v_out from (
    select to_jsonb(c)-'location'-'user_id'||jsonb_build_object('source_id',c.id::text,
        'closure_state',public.closure_state(c.closure)) r
      from community_spots c
      where c.id::text=any(select i from unnest(v_ids) i where i ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    union all
    select to_jsonb(o)||jsonb_build_object('source_id','official:'||o.id,'closure_state',public.closure_state(o.closure)) r
      from official_heavy_spots o
      where 'official:'||o.id=any(v_ids)
  ) s;
  return v_out;
end;
$$;

-- 202610270090_admin_spot_plans.sql's list plus closure.
create or replace function public.admin_spot_fields(p_official boolean) returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','scooter_total','fee','condition','zones_complete',
    'parking_zones','fee_plans','fee_plan','closure']
  || case when p_official then array['source_name','source_url','effective_date','license_note']
     else array['status'] end;
$$;

-- 202610270090_admin_spot_plans.sql's admin_upsert_spot, writing closure
-- too. Same signature, so its grants stay.
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
  -- The table check holds too; this names the problem for the admin site.
  if jsonb_typeof(v_values->'fee')<>'null' and not public.valid_fee(v_values->'fee') then
    raise exception 'invalid fee' using errcode='22023';
  end if;
  if jsonb_typeof(v_values->'condition')<>'null' and not public.valid_condition(v_values->'condition') then
    raise exception 'invalid condition' using errcode='22023';
  end if;
  if v_values ? 'parking_zones' and not public.valid_zones(v_values->'parking_zones') then
    raise exception 'invalid parking_zones' using errcode='22023';
  end if;
  if v_values ? 'closure' and not public.valid_closure(v_values->'closure') then
    raise exception 'invalid closure' using errcode='22023';
  end if;
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
    if not public.fee_note_matches(v_values) then
      raise exception 'fee_note must be the text of fee' using errcode='22023';
    end if;
    if v_official then
      if v_values->>'effective_date' is null then
        raise exception 'official spots need an effective_date' using errcode='22023';
      end if;
      insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,condition,zones_complete,parking_zones,fee_plans,fee_plan,closure)
        select r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),coalesce(r.note,''),
          r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),coalesce(r.road_segment,''),
          coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),r.scooter_total,
          r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),r.fee,
          r.condition,coalesce(r.zones_complete,false),coalesce(r.parking_zones,'[]'::jsonb),r.fee_plans,r.fee_plan,r.closure
        from jsonb_populate_record(null::official_heavy_spots,v_values) r
        returning to_jsonb(official_heavy_spots.*) into v_after;
    else
      insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,condition,zones_complete,parking_zones,fee_plans,fee_plan,closure)
        select auth.uid(),'community',r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),
          coalesce(r.note,''),r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),
          coalesce(r.road_segment,''),coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),
          r.scooter_total,coalesce(r.status,'pending'),r.fee,r.condition,coalesce(r.zones_complete,false),
          coalesce(r.parking_zones,'[]'::jsonb),r.fee_plans,r.fee_plan,r.closure
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
    -- Checked on the row as it will be, and only when this edit touches the
    -- fee or its text: an untouched imported row never blocks other edits.
    if (v_values ? 'fee' or v_values ? 'fee_note') and not public.fee_note_matches(v_before||v_values) then
      raise exception 'fee_note must be the text of fee' using errcode='22023';
    end if;
    if v_official then
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,condition,zones_complete,parking_zones,fee_plans,fee_plan,closure,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.source_name,r.source_url,r.effective_date,r.license_note,r.fee,r.condition,r.zones_complete,
          r.parking_zones,r.fee_plans,r.fee_plan,r.closure,now()
          from jsonb_populate_record(o,v_values) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    else
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,condition,zones_complete,parking_zones,fee_plans,fee_plan,closure,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.status,r.fee,r.condition,r.zones_complete,r.parking_zones,r.fee_plans,r.fee_plan,r.closure,now()
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

-- 202610270090_admin_spot_plans.sql's admin_resolve_report, adopting a
-- closure too: a gone report for works or a closure sets one, 「已經可以停」
-- clears it (null). Same signature, so its grants stay.
create or replace function public.admin_resolve_report(p_id uuid,p_decision text,p_patch jsonb default '{}',p_note text default '',
  p_force boolean default false,p_resolution_kind text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_kind text:=nullif(btrim(coalesce(p_resolution_kind,'')),'');
  v_fields text[]:=array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','fee','condition','fee_plans','fee_plan','closure'];
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
  if p_decision='rejected' and v_patch<>'{}'::jsonb then
    raise exception 'a rejected report changes no spot' using errcode='22023';
  end if;

  if v_patch ? 'closure' and not public.valid_closure(v_patch->'closure') then
    raise exception 'invalid closure' using errcode='22023';
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
        select 1 from jsonb_object_keys(v_patch) k where k not in ('fee_plans','fee_plan')
          and (v_report.base_spot->k) is distinct from (v_before->k));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
      end if;
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.condition,r.fee_plans,r.fee_plan,r.closure,r.status,now()
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
        select 1 from jsonb_object_keys(v_patch) k where k not in ('fee_plans','fee_plan')
          and (v_report.base_spot->k) is distinct from (v_before->k));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
      end if;
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,hidden,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.condition,r.fee_plans,r.fee_plan,r.closure,r.hidden,now()
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
$$;

-- ===== 4. 管理站地圖上限（#133） =====

-- admin_viewport_spots() in one jsonb value: {rows, counts, truncated}.
-- At most 1,000 rows in all (the API's max_rows), each layer at most 500,
-- filled community, official, hidden in that order; counts gives each
-- chosen layer's spots in view ({shown, total}); truncated says any was
-- left out. A set of rows past max_rows would be cut at the API without
-- saying so, which is #133.
create function public.admin_viewport_spots_v2(south double precision,west double precision,north double precision,east double precision,
  p_community boolean default true,p_official boolean default true,p_hidden boolean default false)
returns jsonb language plpgsql stable security invoker set search_path=public,extensions,pg_temp as $$
declare
  v_left integer:=1000; v_rows jsonb:='[]'; v_counts jsonb:='{}'; v_part jsonb; v_total integer; v_take integer;
  v_cut boolean:=false; l text;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if not (south >= -90 and north <= 90 and west >= -180 and east <= 180
          and north > south and east > west and north-south <= 0.5 and east-west <= 0.5) then
    raise exception 'invalid viewport' using errcode='22023';
  end if;
  foreach l in array array['community','official','hidden'] loop
    continue when not case l when 'community' then p_community when 'official' then p_official else p_hidden end;
    v_total:=case l
      when 'community' then (select count(*) from community_spots c where c.status<>'hidden'
        and c.location operator(extensions.&&) extensions.st_makeenvelope(west,south,east,north,4326)::extensions.geography
        and c.lat between south and north and c.lng between west and east)
      when 'official' then (select count(*) from official_heavy_spots o where not o.hidden
        and o.lat between south and north and o.lng between west and east)
      else (select count(*) from community_spots c where c.status='hidden'
          and c.location operator(extensions.&&) extensions.st_makeenvelope(west,south,east,north,4326)::extensions.geography
          and c.lat between south and north and c.lng between west and east)
        +(select count(*) from official_heavy_spots o where o.hidden
          and o.lat between south and north and o.lng between west and east) end;
    v_take:=least(v_total,500,v_left);
    select coalesce(jsonb_agg(to_jsonb(r)),'[]') into v_part from (
      select * from public.admin_viewport_spots(south,west,north,east,l='community',l='official',l='hidden') limit v_take) r;
    v_rows:=v_rows||v_part;
    v_left:=v_left-jsonb_array_length(v_part);
    v_cut:=v_cut or v_total>jsonb_array_length(v_part);
    v_counts:=v_counts||jsonb_build_object(l,jsonb_build_object('shown',jsonb_array_length(v_part),'total',v_total));
  end loop;
  return jsonb_build_object('rows',v_rows,'counts',v_counts,'truncated',v_cut);
end;
$$;
revoke execute on function public.admin_viewport_spots_v2(double precision,double precision,double precision,double precision,boolean,boolean,boolean) from public,anon;
grant execute on function public.admin_viewport_spots_v2(double precision,double precision,double precision,double precision,boolean,boolean,boolean) to authenticated;
