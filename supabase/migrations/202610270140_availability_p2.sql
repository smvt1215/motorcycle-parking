-- Live space counts, P2 (REALTIME_AVAILABILITY_UI_PLAN.md §7.2, §9 P2;
-- availability-coverage.md §2, §9). The first source is the Taipei parking
-- office's TCMSV_allavailable.xml (V2), with capacities from
-- TCMSV_alldesc.json.
--
-- Counts live apart from official_heavy_spots and community_spots, and no
-- trigger here bumps data_versions('spots'): a count that changes every
-- five minutes must not make every open app reload the whole viewport.
--
-- Nothing here is readable or writable by anon or authenticated except
-- viewport_availability(), which returns only display fields. The
-- availability-ingest Edge Function writes with the service role, through
-- the functions below.

-- ===== 來源 =====
create table public.availability_sources (
  key text primary key check (key ~ '^[a-z0-9_]{1,40}$'),
  -- Shown beside the time: 「17:02 更新 ・ 臺北市停管處」.
  provider text not null check (char_length(provider) between 1 and 40),
  feed_url text not null check (feed_url ~ '^https://'),
  capacity_url text check (capacity_url ~ '^https://'),
  license_note text not null default '' check (char_length(license_note) <= 300),
  cities text[] not null default '{}',
  vehicles text[] not null check (vehicles <@ array['scooter','heavy','car']),
  -- How often the source writes; the schedule follows it.
  expected_interval interval not null,
  -- Fresh up to fresh_within of the source time, delayed up to
  -- delayed_within, stale after (coverage §2).
  fresh_within interval not null,
  delayed_within interval not null,
  -- Lower wins when two sources cover the same spot: counts are never added.
  priority smallint not null default 100,
  enabled boolean not null default true,
  -- The newest source time stored; an older feed is out of order.
  last_source_updated_at timestamptz,
  last_fetched_at timestamptz,
  capacity_updated_at timestamptz,
  etag text check (char_length(etag) <= 200),
  failures integer not null default 0 check (failures >= 0),
  -- Backoff: the function skips the source until then.
  next_attempt_at timestamptz,
  last_error text check (char_length(last_error) <= 500),
  check (fresh_within > interval '0' and fresh_within < delayed_within)
);

insert into public.availability_sources(key,provider,feed_url,capacity_url,license_note,cities,vehicles,
  expected_interval,fresh_within,delayed_within,priority)
values('taipei_tcmsv','臺北市停管處',
  'https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_allavailable.xml',
  'https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_alldesc.json',
  '臺北市停車管理工程處 剩餘停車位數 V2（政府資料開放授權條款－第1版）',
  array['臺北市'],array['scooter','heavy','car'],
  interval '5 minutes',interval '10 minutes',interval '20 minutes',10);

-- Capacities per source facility (TCMSV_alldesc.json totalmotor,
-- totallargemotor, totalcar); refreshed a few times a day.
create table public.availability_facilities (
  source_key text not null references public.availability_sources(key) on delete cascade,
  facility_id text not null check (char_length(facility_id) between 1 and 100),
  scooter_total integer check (scooter_total >= 0),
  heavy_total integer check (heavy_total >= 0),
  car_total integer check (car_total >= 0),
  updated_at timestamptz not null default now(),
  primary key (source_key,facility_id)
);

-- ===== 對應 =====
-- Source facility ↔ official spot. Only an exact ID match (the facility ID
-- equals official_heavy_spots.source_id) is added automatically; anything
-- looser is entered by hand. A rejected row blocks a wrong match for good.
create table public.availability_mappings (
  source_key text not null references public.availability_sources(key) on delete cascade,
  facility_id text not null check (char_length(facility_id) between 1 and 100),
  spot_id uuid not null references public.official_heavy_spots(id) on delete cascade,
  match text not null check (match in ('exact_id','manual')),
  review_status text not null default 'auto' check (review_status in ('auto','approved','rejected')),
  created_at timestamptz not null default now(),
  primary key (source_key,facility_id),
  unique (source_key,spot_id)
);
create index availability_mappings_spot_idx on public.availability_mappings(spot_id);

-- ===== 最新快照 =====
-- One row per source facility and vehicle. status is what the ingest made
-- of the raw value; freshness is judged at read time from source time.
create table public.parking_availability_latest (
  source_key text not null references public.availability_sources(key) on delete cascade,
  facility_id text not null check (char_length(facility_id) between 1 and 100),
  vehicle text not null check (vehicle in ('scooter','heavy','car')),
  granularity text not null default 'facility' check (granularity in ('facility')),
  total integer check (total >= 0),
  -- Null unless status is ok.
  available integer,
  -- The value as sent (-9 and other codes kept for audit).
  raw_available integer,
  status text not null check (status in ('ok','unavailable','invalid')),
  source_updated_at timestamptz not null,
  fetched_at timestamptz not null,
  -- Since when an ok count has read zero without a break (coverage §2 rule 4).
  zero_since timestamptz,
  primary key (source_key,facility_id,vehicle),
  check ((status = 'ok') = (available is not null)),
  check (status <> 'ok' or (total > 0 and available between 0 and total)),
  check (zero_since is null or available = 0)
);

-- ===== 擷取紀錄 =====
create table public.availability_ingest_runs (
  id bigint generated always as identity primary key,
  source_key text not null references public.availability_sources(key) on delete cascade,
  ran_at timestamptz not null default now(),
  outcome text not null check (outcome in ('ok','unchanged','skipped','out_of_order','error')),
  source_updated_at timestamptz,
  rows integer,
  message text not null default '' check (char_length(message) <= 500)
);
create index availability_ingest_runs_idx on public.availability_ingest_runs(source_key,ran_at desc);

alter table public.availability_sources enable row level security;
alter table public.availability_facilities enable row level security;
alter table public.availability_mappings enable row level security;
alter table public.parking_availability_latest enable row level security;
alter table public.availability_ingest_runs enable row level security;
revoke all on public.availability_sources,public.availability_facilities,public.availability_mappings,
  public.parking_availability_latest,public.availability_ingest_runs from anon,authenticated;
-- Admins may inspect the pipeline (read only).
create policy availability_sources_admin on public.availability_sources for select to authenticated
  using((select public.is_admin()));
create policy availability_runs_admin on public.availability_ingest_runs for select to authenticated
  using((select public.is_admin()));
grant select on public.availability_sources,public.availability_ingest_runs to authenticated;

-- ===== 寫入（service role） =====

-- Logs one run and keeps the backoff: after the n-th failure in a row the
-- source waits 5·2^(n-1) minutes (at most an hour) before the next try;
-- any other outcome clears it. Runs older than a week are dropped.
create function public.availability_record_run(p_source text,p_outcome text,p_message text default '',
  p_source_updated_at timestamptz default null,p_rows integer default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_failures integer;
begin
  insert into public.availability_ingest_runs(source_key,outcome,source_updated_at,rows,message)
  values(p_source,p_outcome,p_source_updated_at,p_rows,left(coalesce(p_message,''),500));
  if p_outcome = 'error' then
    update public.availability_sources set failures=failures+1,last_error=left(coalesce(p_message,''),500)
      where key=p_source returning failures into v_failures;
    update public.availability_sources
      set next_attempt_at=case when v_failures <= 1 then null
        -- A minute early, so the cron tick that lands on the boundary runs.
        else now()+least(interval '60 minutes',interval '5 minutes'*power(2,v_failures-1))-interval '1 minute' end
      where key=p_source;
  elsif p_outcome <> 'skipped' then
    update public.availability_sources set failures=0,next_attempt_at=null,last_error=null,last_fetched_at=now()
      where key=p_source;
  end if;
  delete from public.availability_ingest_runs where source_key=p_source and ran_at < now()-interval '7 days';
end $$;

-- A JSON integer, or null for anything else (missing, text, fractions).
create function public.availability_int(p jsonb) returns integer
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p)='number' and (p::text)::numeric = trunc((p::text)::numeric)
    and abs((p::text)::numeric) < 1000000 then (p::text)::integer end;
$$;

-- What a raw count means for a facility with [total] spaces of the vehicle
-- (coverage §2 rules 1–3): -1/-9 or no value is no data, no capacity is no
-- data (never 「已滿」), other negatives and more free than total are invalid.
create function public.availability_classify(p_total integer,p_available integer) returns text
language sql immutable set search_path='' as $$
  select case
    when p_available is null or p_available in (-1,-9) then 'unavailable'
    when p_available < 0 then 'invalid'
    when p_total is null or p_total = 0 then 'unavailable'
    when p_available > p_total then 'invalid'
    else 'ok' end;
$$;

-- Replaces the source's capacities. p_rows: [{"id","scooter","heavy","car"}]
-- with non-negative integers or null.
create function public.availability_store_capacities(p_source text,p_rows jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception 'capacities must be an array of at most 5000 rows';
  end if;
  insert into public.availability_facilities(source_key,facility_id,scooter_total,heavy_total,car_total,updated_at)
  select distinct on (r->>'id') p_source,r->>'id',
    public.availability_int(r->'scooter'),public.availability_int(r->'heavy'),public.availability_int(r->'car'),now()
  from jsonb_array_elements(p_rows) r
  where char_length(r->>'id') between 1 and 100
  order by r->>'id'
  on conflict(source_key,facility_id) do update
    set scooter_total=excluded.scooter_total,heavy_total=excluded.heavy_total,car_total=excluded.car_total,
      updated_at=excluded.updated_at;
  get diagnostics v_count=row_count;
  update public.availability_sources set capacity_updated_at=now() where key=p_source;
  return v_count;
end $$;

-- Stores one feed. p_parks: [{"id","scooter","heavy","car"}] as the source
-- sent them (codes included). A feed older than the newest stored one is
-- out of order and the same one is unchanged: neither is written. A time in
-- the future is refused. Returns {"outcome","rows"}.
create function public.availability_ingest(p_source text,p_source_updated_at timestamptz,p_parks jsonb,
  p_etag text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_source public.availability_sources; v_rows integer;
begin
  select * into v_source from public.availability_sources where key=p_source for update;
  if not found then raise exception 'unknown availability source %',p_source; end if;
  if jsonb_typeof(p_parks) is distinct from 'array' or jsonb_array_length(p_parks) > 5000 then
    raise exception 'parks must be an array of at most 5000 rows';
  end if;
  if p_source_updated_at is null or p_source_updated_at > now()+interval '1 minute' then
    perform public.availability_record_run(p_source,'error','source time missing or in the future',p_source_updated_at);
    return jsonb_build_object('outcome','error','rows',0);
  end if;
  if v_source.last_source_updated_at is not null and p_source_updated_at < v_source.last_source_updated_at then
    perform public.availability_record_run(p_source,'out_of_order','older than '||v_source.last_source_updated_at,p_source_updated_at);
    return jsonb_build_object('outcome','out_of_order','rows',0);
  end if;
  if p_source_updated_at = v_source.last_source_updated_at then
    update public.availability_sources set etag=coalesce(p_etag,etag) where key=p_source;
    perform public.availability_record_run(p_source,'unchanged','',p_source_updated_at);
    return jsonb_build_object('outcome','unchanged','rows',0);
  end if;

  -- Exact ID matches map themselves; a rejected or manual row stays.
  insert into public.availability_mappings(source_key,facility_id,spot_id,match)
  select distinct on (o.id) p_source,o.source_id,o.id,'exact_id'
  from public.official_heavy_spots o
  where o.source_id in (select r->>'id' from jsonb_array_elements(p_parks) r)
    and (cardinality(v_source.cities) = 0 or o.city = any(v_source.cities))
  order by o.id
  on conflict do nothing;

  with parks as (
    select distinct on (r->>'id') r->>'id' id,r from jsonb_array_elements(p_parks) r
    where char_length(r->>'id') between 1 and 100 order by r->>'id'
  ), feed as (
    select p.id facility_id,v.vehicle,v.raw,v.total,public.availability_classify(v.total,v.raw) status
    from parks p
    left join public.availability_facilities f on f.source_key=p_source and f.facility_id=p.id
    cross join lateral (values
      ('scooter',public.availability_int(p.r->'scooter'),f.scooter_total),
      ('heavy',public.availability_int(p.r->'heavy'),f.heavy_total),
      ('car',public.availability_int(p.r->'car'),f.car_total)) v(vehicle,raw,total)
    where v.vehicle = any(v_source.vehicles)
  )
  insert into public.parking_availability_latest as l(source_key,facility_id,vehicle,total,available,raw_available,
    status,source_updated_at,fetched_at,zero_since)
  select p_source,a.facility_id,a.vehicle,a.total,
    case when a.status='ok' then a.raw end,a.raw,a.status,p_source_updated_at,now(),
    case when a.status='ok' and a.raw=0 then p_source_updated_at end
  from feed a
  on conflict(source_key,facility_id,vehicle) do update
    set total=excluded.total,available=excluded.available,raw_available=excluded.raw_available,
      status=excluded.status,source_updated_at=excluded.source_updated_at,fetched_at=excluded.fetched_at,
      -- A zero that follows a zero keeps its start.
      zero_since=case when excluded.zero_since is null then null
        else coalesce(l.zero_since,excluded.zero_since) end;
  get diagnostics v_rows=row_count;

  update public.availability_sources set last_source_updated_at=p_source_updated_at,etag=p_etag where key=p_source;
  perform public.availability_record_run(p_source,'ok','',p_source_updated_at,v_rows);
  return jsonb_build_object('outcome','ok','rows',v_rows);
end $$;

revoke all on function public.availability_record_run(text,text,text,timestamptz,integer) from public,anon,authenticated;
revoke all on function public.availability_store_capacities(text,jsonb) from public,anon,authenticated;
revoke all on function public.availability_ingest(text,timestamptz,jsonb,text) from public,anon,authenticated;
grant execute on function public.availability_record_run(text,text,text,timestamptz,integer) to service_role;
grant execute on function public.availability_store_capacities(text,jsonb) to service_role;
grant execute on function public.availability_ingest(text,timestamptz,jsonb,text) to service_role;

-- ===== 讀取（App） =====

-- The counts for the app's spot ids ('official:<uuid>'; others have none:
-- community spots never get an official count). One row per spot and
-- vehicle, from the source with the lowest priority number; counts from
-- two sources are never added. status is judged now from the source time:
-- fresh / delayed / stale / unavailable / invalid. available is null for
-- unavailable and invalid rows; a zero held for two hours is invalid.
create function public.viewport_availability(p_spot_ids text[])
returns table(spot_id text,vehicle text,total integer,available integer,status text,
  source_updated_at timestamptz,fetched_at timestamptz,zero_since timestamptz,provider text,
  fresh_seconds integer,delayed_seconds integer)
language sql stable security definer set search_path='' as $$
  with ids as (
    select substr(i,10)::uuid id from unnest(p_spot_ids[1:600]) i
    where i ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ), rows as (
    select distinct on (m.spot_id,l.vehicle) m.spot_id,l.vehicle,l.total,l.available,l.status,
      l.source_updated_at,l.fetched_at,l.zero_since,s.provider,s.fresh_within,s.delayed_within
    from ids
    join public.availability_mappings m on m.spot_id=ids.id and m.review_status<>'rejected'
    join public.official_heavy_spots o on o.id=m.spot_id and not o.hidden and o.effective_date<=current_date
    join public.availability_sources s on s.key=m.source_key and s.enabled
    join public.parking_availability_latest l on l.source_key=m.source_key and l.facility_id=m.facility_id
    order by m.spot_id,l.vehicle,s.priority,s.key
  ), judged as (
    select r.*,case
      when r.status<>'ok' then r.status
      when r.source_updated_at > now()+interval '1 minute' then 'invalid'
      when r.available=0 and r.zero_since <= r.source_updated_at-interval '2 hours' then 'invalid'
      when now()-r.source_updated_at <= r.fresh_within then 'fresh'
      when now()-r.source_updated_at <= r.delayed_within then 'delayed'
      else 'stale' end judged
    from rows r
  )
  select 'official:'||j.spot_id,j.vehicle,j.total,
    case when j.judged in ('fresh','delayed','stale') then j.available end,
    j.judged,j.source_updated_at,j.fetched_at,j.zero_since,j.provider,
    extract(epoch from j.fresh_within)::integer,extract(epoch from j.delayed_within)::integer
  from judged j
  order by 1,2;
$$;
revoke all on function public.viewport_availability(text[]) from public;
grant execute on function public.viewport_availability(text[]) to anon,authenticated;

-- ===== 排程 =====
-- pg_cron calls the Edge Function a minute after each five-minute mark
-- (the Taipei file is written on the mark). The function URL and the shared
-- secret come from Vault ('project_url', 'availability_ingest_secret');
-- until both are set the tick does nothing, so a fresh database or CI never
-- calls out. The same secret is the function's AVAILABILITY_INGEST_SECRET.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create function public.availability_ingest_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='availability_ingest_secret';
  if v_url is null or v_secret is null or v_url !~ '^https://' then return null; end if;
  return net.http_post(
    url:=rtrim(v_url,'/')||'/functions/v1/availability-ingest',
    headers:=jsonb_build_object('Content-Type','application/json','x-ingest-secret',v_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=60000);
end $$;
revoke all on function public.availability_ingest_tick() from public,anon,authenticated;

select cron.schedule('availability-ingest','1-59/5 * * * *','select public.availability_ingest_tick()');
