-- Gamification stage 0 (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §9):
-- 1. Every rejection says why (resolution_kind), so later scoring can tell a
--    wrong proposal from a duplicate or one that could not be checked.
-- 2. Every report carries the risk class of §5.1, derived on the server from
--    what it proposes, never sent by the client.
-- 3. A baseline of monthly volume, admin turnaround and reporters, readable
--    by admins only, to measure the community share against later.
-- All columns are nullable; older app builds and the Dashboard keep working.

alter table public.moderation_queue
  -- Why a report was rejected (required) or closed (optional); six kinds,
  -- decided by the owner on 2026-10-25. resolution_note stays admin-only:
  -- reporters only ever see a fixed text per kind.
  --   wrong        the proposal does not match the spot (counts against the reporter later)
  --   duplicate    repeats an existing case or a suggestion already handled
  --   insufficient cannot be checked from what was sent
  --   outdated     the spot changed since, the proposal no longer applies
  --   abuse        spam, insults or deliberate false data
  --   other        none of the above; resolution_note says what
  add column resolution_kind text check (resolution_kind in ('wrong','duplicate','insufficient','outdated','abuse','other')),
  -- §5.1 risk class: low (text), medium (fees, type within street bays,
  -- moves up to 150 m, gone), high (vehicle access, type into or out of
  -- off-street, moves over 150 m, anything not recognised).
  add column risk text check (risk in ('low','medium','high'));

-- Risk of one proposed column. space_type and lat/lng need the spot as the
-- rider saw it (base_spot); without it they count as high.
create function public.moderation_key_risk(p_key text,p_proposed jsonb,p_base jsonb)
returns int language sql immutable set search_path='' as $$
  select case
    when p_key in ('name','note','entrance_note','parking_guide','address','road_segment','special_rules') then 1
    when p_key in ('fee_note','fee','facility_type','status','hidden') then 2
    -- Restating the current type (the app sends it with facility_type) is
    -- no change at all.
    when p_key='space_type' and p_base->>'space_type' is not null
      and p_proposed->>'space_type' is not distinct from p_base->>'space_type' then 1
    when p_key='space_type' then
      case when p_base->>'space_type' is not null and p_proposed->>'space_type' is not null
        and p_base->>'space_type'<>'offStreet' and p_proposed->>'space_type'<>'offStreet' then 2 else 3 end
    when p_key in ('lat','lng') then
      -- A value that is not a number cannot be measured: high, never an error
      -- that would drop the report.
      case when jsonb_typeof(p_base->'lat')='number' and jsonb_typeof(p_base->'lng')='number'
        and coalesce(jsonb_typeof(p_proposed->'lat'),'number') in ('number','null')
        and coalesce(jsonb_typeof(p_proposed->'lng'),'number') in ('number','null') then
        case when 111320*sqrt(power(coalesce((p_proposed->>'lat')::float8,(p_base->>'lat')::float8)-(p_base->>'lat')::float8,2)
            +power((coalesce((p_proposed->>'lng')::float8,(p_base->>'lng')::float8)-(p_base->>'lng')::float8)
              *cos(radians((p_base->>'lat')::float8)),2))<=150 then 2 else 3 end
      else 3 end
    else 3
  end;
$$;

-- Risk of a whole report: the riskiest of its category and of every column
-- it proposes. Older builds sent a Chinese label, or only a reason.
create function public.moderation_risk(p_field text,p_reason text,p_proposed jsonb,p_base jsonb)
returns text language plpgsql immutable set search_path='' as $$
declare
  v_key text:=case p_field
    when '停車點名稱' then 'name' when '格位類型' then 'space_type' when '收費資訊' then 'fee_note'
    when '機車停放資格' then 'eligibility' when '位置或其他備註' then 'note' when '點位已不存在' then 'gone'
    else coalesce(p_field,case when p_reason='加權負向回報達門檻' then 'gone' end) end;
  v_level int;
  v_keys int;
begin
  v_level:=case
    when v_key in ('name','note','guide') then 1
    when v_key in ('fee_note','gone') then 2
    -- These depend on the value; with nothing proposed the direction is unknown.
    when v_key in ('space_type','location') then case when p_proposed is null then 3 else 1 end
    else 3
  end;
  if jsonb_typeof(p_proposed)='object' then
    select max(public.moderation_key_risk(k,p_proposed,p_base)) into v_keys from jsonb_object_keys(p_proposed) k;
    v_level:=greatest(v_level,coalesce(v_keys,1));
  end if;
  return (array['low','medium','high'])[v_level];
end;
$$;
revoke execute on function public.moderation_key_risk(text,jsonb,jsonb) from public,anon,authenticated;
revoke execute on function public.moderation_risk(text,text,jsonb,jsonb) from public,anon,authenticated;

-- Runs after moderation_base_version (triggers fire in name order), so the
-- snapshot it takes is available here.
create function public.moderation_set_risk() returns trigger
language plpgsql set search_path='' as $$
begin
  new.risk:=public.moderation_risk(new.field,new.reason,new.proposed,new.base_spot);
  return new;
end;
$$;
revoke execute on function public.moderation_set_risk() from public,anon,authenticated;
create trigger moderation_set_risk before insert on public.moderation_queue
  for each row execute function public.moderation_set_risk();

-- Existing rows: the same derivation. Rows queued before base_spot existed
-- have no snapshot, so their type and location changes count as high.
update public.moderation_queue set risk=public.moderation_risk(field,reason,proposed,base_spot);
-- Existing rejections keep resolution_kind null: their cause is unknown and
-- guessing would skew the baseline. Metrics list them as unclassified.

-- A rejection written any way (the RPC, the Dashboard, the service role)
-- must carry its kind. Only the change into rejected is checked, so older
-- rejected rows stay valid.
create function public.moderation_reject_kind() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.status='rejected' and old.status is distinct from 'rejected' and new.resolution_kind is null then
    raise exception 'a rejection needs a resolution kind' using errcode='22023';
  end if;
  return new;
end;
$$;
revoke execute on function public.moderation_reject_kind() from public,anon,authenticated;
create trigger moderation_reject_kind before update on public.moderation_queue
  for each row execute function public.moderation_reject_kind();

-- Based on 202610260010_admin_spot_fee.sql's definition (vehicle
-- verification set_config, field-level version conflicts, and fee_note
-- matching fee checked after the conflict check, p_force included).
-- p_resolution_kind is new, so the old signature goes. Callers using named
-- arguments keep working for accepting and closing; a rejection without a
-- kind is refused (22023) and the report stays pending, so an older admin
-- build cannot reject until it is redeployed with this migration.
drop function public.admin_resolve_report(uuid,text,jsonb,text,boolean);
create function public.admin_resolve_report(p_id uuid,p_decision text,p_patch jsonb default '{}',p_note text default '',
  p_force boolean default false,p_resolution_kind text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_kind text:=nullif(btrim(coalesce(p_resolution_kind,'')),'');
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
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
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
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
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
revoke execute on function public.admin_resolve_report(uuid,text,jsonb,text,boolean,text) from public,anon;
grant execute on function public.admin_resolve_report(uuid,text,jsonb,text,boolean,text) to authenticated;

-- Baseline (§2.1, §9 stage 0), one row per Asia/Taipei month, newest first.
-- Security invoker: the admin_read_moderation policy limits the rows, and
-- the explicit check refuses everyone else instead of returning zeros.
--   reports           queued that month
--   reporters         distinct riders among them (vote-triggered reports have none)
--   auto_reports      queued by votes, without a reporter
--   resolved          resolved that month, any way
--   admin_resolved    resolved that month through admin_resolve_report (resolved_by set)
--   median_hours      median queued-to-resolved hours of admin_resolved
--   by_status         resolved that month by status (accepted/rejected/closed)
--   by_resolution_kind resolved that month by kind; 'unclassified' = none recorded
--   by_risk           queued that month by risk; 'unclassified' = none derived
create function public.admin_review_baseline(p_months int default 12)
returns table(month date,reports int,reporters int,auto_reports int,resolved int,admin_resolved int,
  median_hours numeric,by_status jsonb,by_resolution_kind jsonb,by_risk jsonb)
language plpgsql stable security invoker set search_path='' as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_months is null or p_months not between 1 and 60 then
    raise exception 'p_months must be between 1 and 60' using errcode='22023';
  end if;
  return query
  with months as (
    select (date_trunc('month',now() at time zone 'Asia/Taipei')-make_interval(months=>g))::date as m
    from generate_series(0,p_months-1) g
  ), q as (
    select q.*,(date_trunc('month',q.created_at at time zone 'Asia/Taipei'))::date as created_m,
      (date_trunc('month',q.resolved_at at time zone 'Asia/Taipei'))::date as resolved_m
    from public.moderation_queue q
    where q.created_at>=(select min(m) from months)::timestamp at time zone 'Asia/Taipei'
       or q.resolved_at>=(select min(m) from months)::timestamp at time zone 'Asia/Taipei'
  )
  select mo.m,
    (select count(*)::int from q where q.created_m=mo.m),
    (select count(distinct q.reporter_id)::int from q where q.created_m=mo.m),
    (select count(*)::int from q where q.created_m=mo.m and q.reporter_id is null),
    (select count(*)::int from q where q.resolved_m=mo.m),
    (select count(*)::int from q where q.resolved_m=mo.m and q.resolved_by is not null),
    (select round((percentile_cont(0.5) within group (order by extract(epoch from q.resolved_at-q.created_at)/3600))::numeric,1)
      from q where q.resolved_m=mo.m and q.resolved_by is not null),
    (select coalesce(jsonb_object_agg(s,n),'{}') from(select q.status s,count(*) n from q where q.resolved_m=mo.m group by 1) x),
    (select coalesce(jsonb_object_agg(s,n),'{}') from(select coalesce(q.resolution_kind,'unclassified') s,count(*) n
      from q where q.resolved_m=mo.m group by 1) x),
    (select coalesce(jsonb_object_agg(s,n),'{}') from(select coalesce(q.risk,'unclassified') s,count(*) n
      from q where q.created_m=mo.m group by 1) x)
  from months mo
  order by mo.m desc;
end;
$$;
revoke execute on function public.admin_review_baseline(int) from public,anon;
grant execute on function public.admin_review_baseline(int) to authenticated;
