-- Structured fees (docs/PLAN.md, 費率結構): fee_note stays the text people
-- read; fee holds the same rate per vehicle so it can be edited as choices
-- and later compared. submit-report/validate.ts checks the same shape where
-- reports enter; the table check below holds for admin writes too.
--
-- fee = {"scooter": rate, "heavy": rate | same_as_scooter | same_as_car};
-- a missing vehicle is unconfirmed. A rate is one of
--   {"mode":"free"} | {"mode":"posted"}
--   {"mode":"hourly","amount":n,"per_minutes":m[,"daily_cap":n]}
--   {"mode":"per_visit","amount":n[,"max_minutes":m]}
--   {"mode":"daily","amount":n}
-- with whole yuan 0–10000 and whole minutes 1–1440.

create function public.fee_whole(p_value jsonb,p_min integer,p_max integer) returns boolean
language sql immutable set search_path='' as $$
  -- CASE, not AND: SQL may evaluate either side first, and a string must
  -- return false rather than fail the cast.
  select case when jsonb_typeof(p_value)='number'
    then (p_value::text)::numeric=trunc((p_value::text)::numeric)
      and (p_value::text)::numeric between p_min and p_max
    else false end;
$$;

create function public.valid_fee_rate(p_rate jsonb,p_heavy boolean) returns boolean
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_rate) is distinct from 'object' then false else coalesce(case p_rate->>'mode'
    when 'free' then true
    when 'posted' then true
    when 'same_as_scooter' then p_heavy
    when 'same_as_car' then p_heavy
    when 'hourly' then public.fee_whole(p_rate->'amount',0,10000) and public.fee_whole(p_rate->'per_minutes',1,1440)
      and (not (p_rate ? 'daily_cap') or public.fee_whole(p_rate->'daily_cap',0,10000))
    when 'per_visit' then public.fee_whole(p_rate->'amount',0,10000)
      and (not (p_rate ? 'max_minutes') or public.fee_whole(p_rate->'max_minutes',1,1440))
    when 'daily' then public.fee_whole(p_rate->'amount',0,10000)
  end,false)
  -- Only the keys a mode uses, so nothing unchecked rides along.
  and not exists(select 1 from jsonb_object_keys(p_rate) k
    where k<>all(case p_rate->>'mode'
      when 'hourly' then array['mode','amount','per_minutes','daily_cap']
      when 'per_visit' then array['mode','amount','max_minutes']
      when 'daily' then array['mode','amount']
      else array['mode'] end)) end;
$$;

create function public.valid_fee(p_fee jsonb) returns boolean
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_fee) is distinct from 'object' then false else
    pg_column_size(p_fee)<=1024
    and not exists(select 1 from jsonb_object_keys(p_fee) k where k<>all(array['scooter','heavy']))
    and (not (p_fee ? 'scooter') or public.valid_fee_rate(p_fee->'scooter',false))
    and (not (p_fee ? 'heavy') or public.valid_fee_rate(p_fee->'heavy',true)) end;
$$;

alter table public.community_spots
  add column fee jsonb check (fee is null or public.valid_fee(fee));
alter table public.official_heavy_spots
  add column fee jsonb check (fee is null or public.valid_fee(fee));
-- community_spots grants columns one by one (contributor ids stay private).
grant select (fee) on public.community_spots to anon,authenticated;

-- New reports may carry the fee they describe.
create or replace function public.apply_report(p_user uuid,p_ip text,p_device text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_action text:=p_payload->>'action'; v_spot jsonb:=p_payload->'spot';
  v_id uuid; v_existing uuid; v_owner uuid; v_qualified boolean; v_score numeric; v_count integer; v_decided timestamptz;
  v_day timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
begin
  if p_ip is null or char_length(p_ip)<>64 or p_device is null or char_length(p_device)<>64 then
    raise exception 'missing trusted identity' using errcode='22023';
  end if;
  if not exists(select 1 from auth.users u join auth.identities i on i.user_id=u.id
      where u.id=p_user and not u.is_anonymous and i.provider in ('google','apple')) then
    raise exception 'Google or Apple sign-in required' using errcode='42501';
  end if;
  select created_at<=now()-interval '7 days' into v_qualified from auth.users where id=p_user;
  -- Order is always IP then account: serializes competing requests without deadlocks.
  perform pg_advisory_xact_lock(hashtextextended('ip:'||p_ip,0));
  perform pg_advisory_xact_lock(hashtextextended('user:'||p_user::text,0));
  if (select count(*) from rate_limit_events where user_id=p_user and created_at>=v_day)>=10 or
     (select count(*) from rate_limit_events where ip_hash=p_ip and created_at>=v_day)>=30 then
    raise exception 'daily report limit reached' using errcode='P0001';
  end if;
  insert into rate_limit_events(user_id,ip_hash) values(p_user,p_ip);
  if v_action='create' then
    -- One lock per space type prevents duplicate inserts racing from separate IPs.
    perform pg_advisory_xact_lock(hashtextextended('create:'||(v_spot->>'space_type'),0));
    select id into v_existing from community_spots where status<>'hidden' and space_type=v_spot->>'space_type'
      and extensions.st_dwithin(location,extensions.st_setsrid(extensions.st_makepoint((v_spot->>'lng')::float8,(v_spot->>'lat')::float8),4326)::extensions.geography,15) limit 1;
    if v_existing is not null then return jsonb_build_object('duplicate_id',v_existing);end if;
    insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,fee)
    values(p_user,btrim(v_spot->>'name'),(v_spot->>'lat')::float8,(v_spot->>'lng')::float8,v_spot->>'city',coalesce(v_spot->>'district',''),v_spot->>'space_type',coalesce(v_spot->>'fee_note','請依現場公告'),coalesce(v_spot->>'note',''),(v_spot->>'scooter_allowed')::boolean,(v_spot->>'heavy_allowed')::boolean,
      case when jsonb_typeof(v_spot->'fee')='object' then v_spot->'fee' end) returning id into v_id;
    insert into report_identities values(v_id,p_ip,p_device);
  elsif v_action='vote' then
    v_id:=(p_payload->>'spot_id')::uuid;
    select user_id into v_owner from community_spots where id=v_id and status<>'hidden' for update;
    if v_owner is null then raise exception 'spot not found' using errcode='22023';end if;
    if v_owner=p_user then raise exception 'cannot confirm own report' using errcode='42501';end if;
    if exists(select 1 from report_identities where spot_id=v_id and (ip_hash=p_ip or device_hash=p_device)) then v_qualified:=false;end if;
    insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
      values(v_id,p_user,p_payload->>'vote',v_qualified,case when v_qualified then 1 else 0.25 end,p_ip,p_device)
      on conflict(spot_id,user_id) do update set vote=excluded.vote,qualified=excluded.qualified,weight=excluded.weight,ip_hash=excluded.ip_hash,device_hash=excluded.device_hash,created_at=now();
    -- Distinct IP AND device, and two qualified users. Network/device sameness cannot inflate confirmations.
    select least(count(distinct ip_hash),count(distinct device_hash)) into v_count from spot_votes where spot_id=v_id and vote='still_there' and qualified;
    -- Once an admin has decided a dispute, the "gone" votes before that
    -- decision are spent: only later ones can reopen it.
    select max(resolved_at) into v_decided from moderation_queue
      where source_id=v_id::text and reason='加權負向回報達門檻' and status<>'pending';
    select coalesce(sum(weight),0) into v_score from(select max(weight) as weight from spot_votes where spot_id=v_id and vote='gone'
      and created_at>coalesce(v_decided,'-infinity') group by ip_hash) x;
    if v_score>=3 then
      -- Votes alone never take a spot off the map: it drops back to pending
      -- (unverified everywhere) and waits for an admin to hide or keep it.
      update community_spots set status='pending',updated_at=now() where id=v_id;
      insert into moderation_queue(source_id,reason) values(v_id::text,'加權負向回報達門檻') on conflict do nothing;
    else
      -- Only a qualified "still there" is a fresh sighting; other votes keep
      -- the last confirmation time.
      -- A spot an admin kept after a dispute stays confirmed; only a new
      -- dispute can demote it.
      update community_spots set status=case when v_count>=2 or (status='confirmed' and v_decided is not null) then 'confirmed' else 'pending' end,
        last_confirmed_at=case when v_count>=2 and p_payload->>'vote'='still_there' and v_qualified then now() else last_confirmed_at end,
        updated_at=now() where id=v_id;
    end if;
  elsif v_action='flag' then
    insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note)
    values(p_payload->>'source_id',p_user,p_payload->>'reason',nullif(btrim(coalesce(p_payload->>'field','')),''),
      case when jsonb_typeof(p_payload->'proposed')='object' then p_payload->'proposed' end,
      coalesce(p_payload->>'note',''))
    on conflict do nothing;
  elsif v_action in ('update','delete') then
    v_id:=(p_payload->>'spot_id')::uuid;
    select user_id into v_owner from community_spots where id=v_id for update;
    if v_owner is distinct from p_user then raise exception 'only owner can edit' using errcode='42501';end if;
    if v_action='delete' then delete from community_spots where id=v_id;
    else
      update community_spots set name=btrim(v_spot->>'name'),fee_note=coalesce(v_spot->>'fee_note',fee_note),note=coalesce(v_spot->>'note',note),status='pending',last_confirmed_at=null,updated_at=now() where id=v_id;
      delete from spot_votes where spot_id=v_id;
    end if;
  else raise exception 'invalid report action' using errcode='22023';
  end if;
  return jsonb_build_object('id',v_id,'accepted',true);
end;
$$;

-- Admins may apply a suggested fee like any other field; the rest is the
-- function from 202610240011_admin_review.sql unchanged.
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

-- Promoting a community spot keeps its fee beside the fee_note it already
-- copies; the rest is the function from 202610250001_admin_spots.sql unchanged.
create or replace function public.admin_promote_spot(p_source_id text,p_values jsonb,p_base_updated_at timestamptz,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
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
  select * into v_community from community_spots where id=p_source_id::uuid for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  if v_community.updated_at<>p_base_updated_at then
    raise exception 'spot changed since it was opened' using errcode='40001';
  end if;
  if v_community.status='hidden' then
    raise exception 'restore the spot before promoting it' using errcode='22023';
  end if;

  insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
      facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,parking_zones,
      source_name,source_url,effective_date,license_note,fee)
    select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
      -- Only what the admin states in this call; never the rider's values.
      case when v_values ? 'scooter_allowed' then (v_values->>'scooter_allowed')::boolean end,
      case when v_values ? 'heavy_allowed' then (v_values->>'heavy_allowed')::boolean end,
      r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
      v_community.parking_zones,r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),
      -- The fee moves with its fee_note text, so the two stay in step.
      r.fee
    from jsonb_populate_record(
      null::official_heavy_spots,
      (to_jsonb(v_community)-'id'-'user_id'-'location'-'source'-'source_name'-'source_url'-'license_note'
        -'status'-'last_confirmed_at'-'created_at'-'available'-'photo_urls'-'updated_at')||v_values) r
    returning to_jsonb(official_heavy_spots.*) into v_after;

  update community_spots set status='hidden',updated_at=now() where id=v_community.id;
  -- Open reports follow the spot; their snapshots still flag changed fields.
  update moderation_queue set source_id='official:'||(v_after->>'id')
   where source_id=v_community.id::text and status='pending';

  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'promote_spot','community_spots',v_community.id::text,
    to_jsonb(v_community)-'location',jsonb_build_object('official',v_after),v_note);
  return v_after||jsonb_build_object('source_id','official:'||(v_after->>'id'));
end;
$$;
