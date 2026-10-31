-- Live counts are fetched when the source is due, not on a fixed clock.
--
-- The Taipei file carries UPDATETIME on each five-minute mark but goes
-- public a minute or more later (Last-Modified about 70 s after it on
-- staging), so the fixed tick a minute after each mark kept reading the
-- batch before: counts were 6–11 minutes old and flipped between fresh
-- and delayed around the 10-minute line.
--
-- Now, after each new batch the source gets next_expected_at =
-- UPDATETIME + expected_interval + publish_delay, where publish_delay is
-- learned from the batches seen. pg_cron ticks every minute, but the tick
-- only reads this table: nothing is called until the source is due. A
-- fetch that still finds the same batch tries again a minute later, at
-- most availability_same_batch_retries() times; then it counts as a
-- failure and waits for the next slot under the usual backoff. Freshness
-- is judged against the expected next batch plus a grace, so a source on
-- its rhythm stays fresh and only a source that stops goes delayed.

-- ===== 欄位 =====
alter table public.availability_sources
  -- How long after UPDATETIME a batch goes public: the median of the last
  -- samples, kept between 0 and 10 minutes. 2 minutes until learned.
  add column publish_delay interval not null default interval '2 minutes'
    check (publish_delay between interval '0' and interval '10 minutes'),
  -- How long past the expected next batch a count stays fresh: one cron
  -- tick, one app poll (two minutes) and a minute to spare.
  add column fresh_grace interval not null default interval '4 minutes'
    check (fresh_grace > interval '0'),
  -- When the next batch should be public; the tick calls out from then on.
  -- Null calls out on the next tick.
  add column next_expected_at timestamptz,
  -- Fetches in a row that found the batch already stored.
  add column same_batch_retries integer not null default 0 check (same_batch_retries >= 0),
  -- Set by the tick when it calls out, cleared by the run it starts; a
  -- call that never logs frees the source when it lapses.
  add column polling_until timestamptz;

-- The fresh window is now interval + delay + grace (viewport_availability).
alter table public.availability_sources drop column fresh_within;

-- A publish delay measured on the run that first saw the batch.
alter table public.availability_ingest_runs
  add column publish_delay interval check (publish_delay >= interval '0');

-- ===== 時間推算 =====

create function public.availability_same_batch_retries() returns integer
language sql immutable set search_path='' as $$ select 4 $$;

-- The first batch slot after now: [p_last] + [p_delay] + n·[p_interval].
create function public.availability_next_slot(p_last timestamptz,p_interval interval,p_delay interval)
returns timestamptz language sql stable set search_path='' as $$
  select case when p_last is null then now()+p_interval
    else p_last+p_delay+p_interval*greatest(1,
      floor(extract(epoch from now()-(p_last+p_delay))/extract(epoch from p_interval))+1) end;
$$;

-- How long a count of the source stays fresh after its source time.
-- Always below delayed_within, so the app's window stays valid.
create function public.availability_fresh_window(p_source public.availability_sources)
returns interval language sql immutable set search_path='' as $$
  select least(p_source.expected_interval+p_source.publish_delay+p_source.fresh_grace,
    p_source.delayed_within-interval '1 second');
$$;

-- ===== 寫入（service role） =====

drop function public.availability_record_run(text,text,text,timestamptz,integer);
drop function public.availability_ingest(text,timestamptz,jsonb,text);

-- Logs one run and plans the next.
--   ok: clears failures and retries (availability_ingest plans the next
--     batch).
--   unchanged / out_of_order: the source has no new batch yet. With a
--     plan, try again next tick, up to availability_same_batch_retries()
--     times; past that it is a failure (backoff as below) and the source
--     waits for its next slot. Without a plan, wait for the next slot.
--   error: after the n-th failure in a row the source waits
--     5·2^(n-1) minutes (at most an hour) before the next try.
--   skipped: only frees the source.
-- Runs older than a week are dropped.
create function public.availability_record_run(p_source text,p_outcome text,p_message text default '',
  p_source_updated_at timestamptz default null,p_rows integer default null,p_publish_delay interval default null)
returns void language plpgsql security definer set search_path='' as $$
declare v public.availability_sources; v_fail boolean := p_outcome = 'error'; v_message text := coalesce(p_message,'');
begin
  select * into v from public.availability_sources where key=p_source for update;
  if p_outcome in ('unchanged','out_of_order') then
    update public.availability_sources set last_fetched_at=now() where key=p_source;
    if v.next_expected_at is null then
      update public.availability_sources set same_batch_retries=0,
        next_expected_at=public.availability_next_slot(v.last_source_updated_at,v.expected_interval,v.publish_delay)
        where key=p_source;
    elsif v.same_batch_retries < public.availability_same_batch_retries() then
      -- Half a minute on: the next tick, not this one.
      update public.availability_sources set same_batch_retries=same_batch_retries+1,
        next_expected_at=now()+interval '30 seconds' where key=p_source;
    else
      v_fail := true;
      v_message := left(concat_ws('; ','no new batch after '||public.availability_same_batch_retries()||' retries',
        nullif(v_message,'')),500);
      update public.availability_sources set same_batch_retries=0,
        next_expected_at=public.availability_next_slot(v.last_source_updated_at,v.expected_interval,v.publish_delay)
        where key=p_source;
    end if;
  end if;

  insert into public.availability_ingest_runs(source_key,outcome,source_updated_at,rows,message,publish_delay)
  values(p_source,p_outcome,p_source_updated_at,p_rows,left(v_message,500),p_publish_delay);
  update public.availability_sources set polling_until=null where key=p_source;

  if v_fail then
    update public.availability_sources set failures=failures+1,last_error=left(v_message,500)
      where key=p_source returning failures into v.failures;
    update public.availability_sources
      set next_attempt_at=case when v.failures <= 1 then null
        -- A minute early, so the cron tick that lands on the boundary runs.
        else now()+least(interval '60 minutes',interval '5 minutes'*power(2,v.failures-1))-interval '1 minute' end
      where key=p_source;
  elsif p_outcome = 'ok' then
    update public.availability_sources set failures=0,next_attempt_at=null,last_error=null,last_fetched_at=now(),
      same_batch_retries=0 where key=p_source;
  end if;
  delete from public.availability_ingest_runs where source_key=p_source and ran_at < now()-interval '7 days';
end $$;

-- Stores one feed. p_parks: [{"id","scooter","heavy","car"}] as the source
-- sent them (codes included). A feed older than the newest stored one is
-- out of order and the same one is unchanged: neither is written. A time in
-- the future is refused. p_published_at is when the file went public (its
-- Last-Modified), if known. Returns {"outcome","rows"}.
--
-- A new batch teaches the publish delay: Last-Modified − UPDATETIME, or,
-- without a usable Last-Modified, now − UPDATETIME when the source was
-- being retried every minute (so the batch went public within the last
-- one). The delay is the median of the last 12 samples, and the next
-- batch is expected at UPDATETIME + expected_interval + delay.
create function public.availability_ingest(p_source text,p_source_updated_at timestamptz,p_parks jsonb,
  p_etag text default null,p_published_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_source public.availability_sources; v_rows integer; v_sample interval; v_delay interval;
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

  -- A Last-Modified before the batch's own time or ahead of now is not one.
  v_sample := case
    when p_published_at between p_source_updated_at and now()+interval '1 minute'
      then least(p_published_at,now())-p_source_updated_at
    when v_source.same_batch_retries > 0 then now()-p_source_updated_at end;
  -- Longer than half an hour is an outage, not a delay.
  if v_sample > interval '30 minutes' then v_sample := null; end if;

  update public.availability_sources set last_source_updated_at=p_source_updated_at,etag=p_etag where key=p_source;
  perform public.availability_record_run(p_source,'ok','',p_source_updated_at,v_rows,v_sample);

  select percentile_cont(0.5) within group (order by r.publish_delay) into v_delay
  from (select publish_delay from public.availability_ingest_runs
    where source_key=p_source and publish_delay is not null order by id desc limit 12) r;
  update public.availability_sources s
    set publish_delay=least(interval '10 minutes',greatest(interval '0',coalesce(v_delay,s.publish_delay))),
      next_expected_at=p_source_updated_at+s.expected_interval
        +least(interval '10 minutes',greatest(interval '0',coalesce(v_delay,s.publish_delay)))
    where key=p_source;
  return jsonb_build_object('outcome','ok','rows',v_rows);
end $$;

revoke all on function public.availability_record_run(text,text,text,timestamptz,integer,interval) from public,anon,authenticated;
revoke all on function public.availability_ingest(text,timestamptz,jsonb,text,timestamptz) from public,anon,authenticated;
revoke all on function public.availability_same_batch_retries() from public,anon,authenticated;
revoke all on function public.availability_next_slot(timestamptz,interval,interval) from public,anon,authenticated;
revoke all on function public.availability_fresh_window(public.availability_sources) from public,anon,authenticated;
grant execute on function public.availability_record_run(text,text,text,timestamptz,integer,interval) to service_role;
grant execute on function public.availability_ingest(text,timestamptz,jsonb,text,timestamptz) to service_role;

-- ===== 讀取（App） =====

-- As in 202610270140, but a count is fresh until the source's expected
-- next batch plus its grace (availability_fresh_window), returned as
-- fresh_seconds so the app ages it on screen the same way.
create or replace function public.viewport_availability(p_spot_ids text[])
returns table(spot_id text,vehicle text,total integer,available integer,status text,
  source_updated_at timestamptz,fetched_at timestamptz,zero_since timestamptz,provider text,
  fresh_seconds integer,delayed_seconds integer)
language sql stable security definer set search_path='' as $$
  with ids as (
    select substr(i,10)::uuid id from unnest(p_spot_ids[1:600]) i
    where i ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ), rows as (
    select distinct on (m.spot_id,l.vehicle) m.spot_id,l.vehicle,l.total,l.available,l.status,
      l.source_updated_at,l.fetched_at,l.zero_since,s.provider,
      public.availability_fresh_window(s) fresh_within,s.delayed_within
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

-- ===== 排程 =====
-- Every minute, but the tick only reads availability_sources: it calls the
-- Edge Function (which serves taipei_tcmsv) only when the source is due —
-- next_expected_at reached, out of backoff, no call in flight — and Vault
-- holds 'project_url' and 'availability_ingest_secret'. Otherwise nothing
-- leaves the database.
create or replace function public.availability_ingest_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare v public.availability_sources; v_url text; v_secret text;
begin
  select * into v from public.availability_sources where key='taipei_tcmsv' and enabled for update skip locked;
  if not found or v.next_expected_at > now() or v.next_attempt_at > now() or v.polling_until > now() then
    return null;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='availability_ingest_secret';
  if v_url is null or v_secret is null or v_url !~ '^https://' then return null; end if;
  -- The function fetches for at most about a minute (two 20 s tries and
  -- the capacities); its run clears this.
  update public.availability_sources set polling_until=now()+interval '3 minutes' where key=v.key;
  return net.http_post(
    url:=rtrim(v_url,'/')||'/functions/v1/availability-ingest',
    headers:=jsonb_build_object('Content-Type','application/json','x-ingest-secret',v_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=60000);
end $$;
revoke all on function public.availability_ingest_tick() from public,anon,authenticated;

select cron.schedule('availability-ingest','* * * * *','select public.availability_ingest_tick()');
