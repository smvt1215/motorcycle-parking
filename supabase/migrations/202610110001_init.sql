create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table public.community_spots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  source text not null default 'community' check (source in ('community','import')),
  source_name text not null default '', source_url text not null default '', license_note text not null default '',
  name text not null check (char_length(name) between 1 and 100),
  lat double precision not null check (lat between 20 and 27),
  lng double precision not null check (lng between 118 and 123),
  location extensions.geography(Point,4326) generated always as
    (extensions.st_setsrid(extensions.st_makepoint(lng,lat),4326)::extensions.geography) stored,
  city text not null check (char_length(city) between 1 and 30), district text not null default '',
  space_type text not null check (space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet')),
  fee_note text not null default '請依現場公告' check (char_length(fee_note)<=200),
  note text not null default '' check (char_length(note)<=500),
  scooter_total integer check (scooter_total>=0), available integer check (available>=0),
  scooter_allowed boolean, heavy_allowed boolean,
  status text not null default 'pending' check (status in ('pending','confirmed','hidden')),
  updated_at timestamptz not null default now(), last_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);
create index community_location_idx on public.community_spots using gist(location);
create table public.report_identities (
  spot_id uuid primary key references public.community_spots(id) on delete cascade,
  ip_hash text not null, device_hash text not null
);
create table public.spot_votes (
  spot_id uuid not null references public.community_spots(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  vote text not null check (vote in ('still_there','gone')),
  qualified boolean not null, weight numeric not null check (weight in (0.25,1)),
  ip_hash text not null, device_hash text not null, created_at timestamptz not null default now(),
  primary key (spot_id,user_id)
);
create table public.favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  spot_id text not null check (char_length(spot_id)<=160), spot jsonb not null,
  created_at timestamptz not null default now(), primary key(user_id,spot_id),
  check (jsonb_typeof(spot)='object' and spot->>'id'=spot_id)
);
create table public.city_rules (
  city text not null, vehicle text not null check (vehicle in ('scooter','heavy')),
  allowed_space_types jsonb not null, conditional_space_types jsonb not null default '[]', districts jsonb not null default '[]',
  fee_note text not null, exceptions text not null, can_use_two_spaces boolean not null default false,
  effective_date date not null, source_url text not null, version integer not null check(version>0),
  primary key(city,vehicle)
);
create table public.spot_annotations (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
  source text not null default 'tdx' check (source='tdx'), source_id text not null,
  heavy_access text not null check (heavy_access in ('allowed','denied','car_space')),
  note text not null default '' check(char_length(note)<=500),
  status text not null default 'pending' check(status in ('pending','confirmed','hidden')),
  updated_at timestamptz not null default now(), unique(user_id,source,source_id)
);
create table public.moderation_queue (
  id uuid primary key default gen_random_uuid(), source_id text not null, reporter_id uuid references auth.users(id),
  reason text not null, resolved_at timestamptz, created_at timestamptz not null default now()
);
create unique index moderation_unresolved_idx on public.moderation_queue(source_id,reason) where resolved_at is null;
create table public.official_heavy_spots (
  id uuid primary key default gen_random_uuid(), spot jsonb not null,
  source_url text not null, effective_date date not null, updated_at timestamptz not null default now()
);
create table public.rate_limit_events (
  id bigint generated always as identity primary key, user_id uuid not null references auth.users(id),
  ip_hash text not null, created_at timestamptz not null default now()
);
create index rate_limit_user_idx on public.rate_limit_events(user_id,created_at);
create index rate_limit_ip_idx on public.rate_limit_events(ip_hash,created_at);

alter table public.community_spots enable row level security;
alter table public.report_identities enable row level security;
alter table public.spot_votes enable row level security;
alter table public.favorites enable row level security;
alter table public.city_rules enable row level security;
alter table public.spot_annotations enable row level security;
alter table public.moderation_queue enable row level security;
alter table public.official_heavy_spots enable row level security;
alter table public.rate_limit_events enable row level security;
create policy public_spots on public.community_spots for select to anon,authenticated using(status<>'hidden');
create policy own_favorites on public.favorites for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
create policy public_rules on public.city_rules for select to anon,authenticated using(true);
create policy admin_rules on public.city_rules for all to authenticated using((select auth.jwt())->'app_metadata'->>'role'='admin') with check((select auth.jwt())->'app_metadata'->>'role'='admin');
create policy public_annotations on public.spot_annotations for select to anon,authenticated using(status<>'hidden');
create policy official_read on public.official_heavy_spots for select to anon,authenticated using(true);
-- No client write policies on community_spots/votes. Private identities, moderation and rate events have no public policy.
revoke all on public.report_identities,public.spot_votes,public.moderation_queue,public.rate_limit_events from anon,authenticated;
grant select on public.community_spots,public.city_rules,public.spot_annotations,public.official_heavy_spots to anon,authenticated;
grant select,insert,update,delete on public.favorites to authenticated;
grant insert,update,delete on public.city_rules to authenticated;

create function public.nearby_spots(lat double precision,lng double precision,radius_m double precision default 3000)
returns setof public.community_spots language sql stable security invoker
set search_path=public,extensions as $$
  select * from public.community_spots s
  where $3 between 1 and 20000 and $1 between 20 and 27 and $2 between 118 and 123
  and extensions.st_dwithin(s.location,extensions.st_setsrid(extensions.st_makepoint($2,$1),4326)::extensions.geography,$3)
  order by extensions.st_distance(s.location,extensions.st_setsrid(extensions.st_makepoint($2,$1),4326)::extensions.geography)
  limit 500;
$$;
grant execute on function public.nearby_spots(double precision,double precision,double precision) to anon,authenticated;

-- Single transaction for limits, de-duplication, vote scoring and moderation.
-- Only Edge Functions using the service role may call this RPC.
create function public.apply_report(p_user uuid,p_ip text,p_device text,p_payload jsonb)
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
  elsif v_action='annotation' then
    insert into spot_annotations(user_id,source_id,heavy_access,note) values(p_user,p_payload->>'source_id',p_payload->>'heavy_access',coalesce(p_payload->>'note',''))
      on conflict(user_id,source,source_id) do update set heavy_access=excluded.heavy_access,note=excluded.note,status='pending',updated_at=now() returning id into v_id;
  elsif v_action='flag' then
    insert into moderation_queue(source_id,reporter_id,reason) values(p_payload->>'source_id',p_user,p_payload->>'reason') on conflict do nothing;
  elsif v_action in ('update','delete') then
    v_id:=(p_payload->>'spot_id')::uuid;
    select user_id into v_owner from community_spots where id=v_id for update;
    if v_owner is distinct from p_user then raise exception 'only owner can edit' using errcode='42501';end if;
    if v_action='delete' then delete from community_spots where id=v_id;
    else
      update community_spots set name=btrim(v_spot->>'name'),fee_note=coalesce(v_spot->>'fee_note','請依現場公告'),note=coalesce(v_spot->>'note',''),status='pending',last_confirmed_at=null,updated_at=now() where id=v_id;
      delete from spot_votes where spot_id=v_id;
    end if;
  else raise exception 'invalid report action' using errcode='22023';
  end if;
  return jsonb_build_object('id',v_id,'accepted',true);
end;
$$;
revoke all on function public.apply_report(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_report(uuid,text,text,jsonb) to service_role;
