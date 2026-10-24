-- Admin web backend (docs/ADMIN_WEB.md, P1): one admin role that must have
-- passed MFA, structured suggestions, an append-only audit log and an RPC
-- that applies a suggestion and closes it in one transaction.

-- Admin = app_metadata role set by the service role, plus a second factor.
create function public.is_admin() returns boolean
language sql stable security invoker set search_path='' as $$
  select coalesce(auth.jwt()->'app_metadata'->>'role','')='admin'
     and coalesce(auth.jwt()->>'aal','')='aal2';
$$;
revoke execute on function public.is_admin() from public,anon;
grant execute on function public.is_admin() to authenticated,service_role;

drop policy admin_rules on public.city_rules;
create policy admin_rules on public.city_rules for all to authenticated
  using((select public.is_admin())) with check((select public.is_admin()));

-- Structured suggestions. reason stays the readable summary for old app
-- versions and rows written before these columns existed.
alter table public.moderation_queue
  add column field text check (char_length(field) between 1 and 40),
  add column proposed jsonb check (proposed is null or (jsonb_typeof(proposed)='object' and pg_column_size(proposed)<=4096)),
  add column note text not null default '' check (char_length(note)<=500),
  add column status text not null default 'pending' check (status in ('pending','accepted','rejected','closed')),
  add column resolved_by uuid,
  add column resolution_note text not null default '' check (char_length(resolution_note)<=500);
-- Rows resolved in the Dashboard carry no decision.
update public.moderation_queue set status='closed' where resolved_at is not null;
create index moderation_pending_idx on public.moderation_queue(created_at) where status='pending';

-- The Dashboard still resolves by setting resolved_at alone until the admin
-- web ships; keep status in step so the admin queue never lists those rows.
create function public.moderation_close_legacy() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.resolved_at is not null and new.status='pending' then new.status:='closed'; end if;
  return new;
end;
$$;
create trigger moderation_close_legacy before update on public.moderation_queue
  for each row execute function public.moderation_close_legacy();

grant select on public.moderation_queue to authenticated;
create policy admin_read_moderation on public.moderation_queue for select to authenticated
  using((select public.is_admin()));
-- Hidden community spots are invisible to the public policy; admins see them.
create policy admin_read_spots on public.community_spots for select to authenticated
  using((select public.is_admin()));

-- Append-only: no user may change or remove an entry, the service role included.
-- actor has no foreign key so entries outlive deleted accounts.
create table public.admin_audit_log (
  id bigint generated always as identity primary key,
  actor uuid not null,
  action text not null check (char_length(action) between 1 and 60),
  target_table text not null check (char_length(target_table) between 1 and 60),
  target_id text not null check (char_length(target_id) between 1 and 160),
  before jsonb,
  after jsonb,
  note text not null default '' check (char_length(note)<=500),
  created_at timestamptz not null default now()
);
create index admin_audit_target_idx on public.admin_audit_log(target_table,target_id,created_at desc);
alter table public.admin_audit_log enable row level security;
revoke all on public.admin_audit_log from anon,authenticated;
grant select on public.admin_audit_log to authenticated;
create policy admin_read_audit on public.admin_audit_log for select to authenticated
  using((select public.is_admin()));
create function public.admin_audit_log_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
  raise exception 'audit log entries cannot be changed' using errcode='42501';
end;
$$;
create trigger admin_audit_log_immutable before update or delete on public.admin_audit_log
  for each row execute function public.admin_audit_log_immutable();
create trigger admin_audit_log_no_truncate before truncate on public.admin_audit_log
  for each statement execute function public.admin_audit_log_immutable();

-- Accept or reject one pending report. On accept, p_patch (column -> value)
-- is applied to the reported spot first; the report closes and the audit
-- entry is written in the same transaction.
create function public.admin_resolve_report(p_id uuid,p_decision text,p_patch jsonb default '{}',p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_fields text[]:=array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules'];
  v_table text; v_target uuid; v_bad text; v_before jsonb; v_after jsonb;
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
      v_target:=case when substr(v_report.source_id,10) ~* '^[0-9a-f-]{36}$' then substr(v_report.source_id,10)::uuid end;
    else
      v_table:='community_spots';
      -- Community spots can also be hidden or restored; official spots have no status.
      v_fields:=v_fields||'status'::text;
      v_target:=case when v_report.source_id ~* '^[0-9a-f-]{36}$' then v_report.source_id::uuid end;
    end if;
    select k into v_bad from jsonb_object_keys(v_patch) k where k<>all(v_fields) limit 1;
    if v_bad is not null then raise exception 'field % cannot be changed here',v_bad using errcode='22023'; end if;

    if v_table='community_spots' then
      select to_jsonb(c)-'user_id'-'location' into v_before from community_spots c where c.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.status,now()
          from jsonb_populate_record(c,v_patch) r)
        where c.id=v_target returning to_jsonb(c)-'user_id'-'location' into v_after;
    else
      select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,now()
          from jsonb_populate_record(o,v_patch) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    end if;
  end if;

  update moderation_queue set status=p_decision,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note
    where id=p_id;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'resolve_report','moderation_queue',p_id::text,
    jsonb_build_object('report',to_jsonb(v_report),'spot',v_before),
    jsonb_build_object('status',p_decision,'spot_table',v_table,'spot',v_after),
    v_note);
  return jsonb_build_object('id',p_id,'status',p_decision,'spot',v_after);
end;
$$;
revoke execute on function public.admin_resolve_report(uuid,text,jsonb,text) from public,anon;
grant execute on function public.admin_resolve_report(uuid,text,jsonb,text) to authenticated;

-- Flags may carry the suggested field and value; reason stays required.
create or replace function public.apply_report(p_user uuid,p_ip text,p_device text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_action text:=p_payload->>'action'; v_spot jsonb:=p_payload->'spot';
  v_id uuid; v_existing uuid; v_owner uuid; v_qualified boolean; v_score numeric; v_count integer;
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
    insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed)
    values(p_user,btrim(v_spot->>'name'),(v_spot->>'lat')::float8,(v_spot->>'lng')::float8,v_spot->>'city',coalesce(v_spot->>'district',''),v_spot->>'space_type',coalesce(v_spot->>'fee_note','請依現場公告'),coalesce(v_spot->>'note',''),(v_spot->>'scooter_allowed')::boolean,(v_spot->>'heavy_allowed')::boolean) returning id into v_id;
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
    select coalesce(sum(weight),0) into v_score from(select max(weight) as weight from spot_votes where spot_id=v_id and vote='gone' group by ip_hash) x;
    if v_score>=3 then
      update community_spots set status='hidden',updated_at=now() where id=v_id;
      insert into moderation_queue(source_id,reason) values(v_id::text,'加權負向回報達門檻') on conflict do nothing;
    else
      update community_spots set status=case when v_count>=2 then 'confirmed' else 'pending' end,
        last_confirmed_at=case when v_count>=2 then now() else last_confirmed_at end,updated_at=now() where id=v_id;
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
