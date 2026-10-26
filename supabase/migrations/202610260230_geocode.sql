-- Address, road and intersection search (docs/ADMIN_WEB.md 後端變更 7, P4b).
-- Only the `geocode` Edge Function (service role) reaches these: it counts
-- each search against the caller's daily limit and caches what the provider
-- found. Report limits in rate_limit_events stay separate.

create table public.geocode_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index geocode_events_user_idx on public.geocode_events(user_id,created_at);
create index geocode_events_created_idx on public.geocode_events(created_at);

-- Shared between riders, so a provider's terms may cap how long a point is
-- kept: entries older than 30 days are never served and are deleted on the
-- next write (Google Maps Platform Service Specific Terms 6.3.1).
create table public.geocode_cache (
  key text primary key check (length(key) between 1 and 300),
  candidates jsonb not null check (jsonb_typeof(candidates)='array'),
  fetched_at timestamptz not null default now()
);
create index geocode_cache_fetched_idx on public.geocode_cache(fetched_at);

alter table public.geocode_events enable row level security;
alter table public.geocode_cache enable row level security;
revoke all on public.geocode_events,public.geocode_cache from public,anon,authenticated;

-- Counts one search for p_user and returns fresh cached candidates, or null.
-- Riders get 30 searches a Taipei day, admins (aal2, decided by the caller
-- from the verified token) 200. Raises P0001 once the day's searches are used.
create function public.geocode_begin(p_user uuid,p_admin boolean,p_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_day timestamptz:=date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
  v_limit integer:=case when p_admin then 200 else 30 end;
begin
  -- One caller's parallel searches must not all pass the count.
  perform pg_advisory_xact_lock(hashtextextended('geocode:'||p_user::text,0));
  if (select count(*) from public.geocode_events
      where user_id=p_user and created_at>=v_day)>=v_limit then
    raise exception 'daily search limit reached' using errcode='P0001';
  end if;
  insert into public.geocode_events(user_id) values(p_user);
  return (select candidates from public.geocode_cache
          where key=p_key and fetched_at>now()-interval '30 days');
end;
$$;

create function public.geocode_store(p_key text,p_candidates jsonb)
returns void language sql security definer set search_path='' as $$
  delete from public.geocode_cache where fetched_at<=now()-interval '30 days';
  -- Only today's count matters; a month of history is enough for P7.
  delete from public.geocode_events where created_at<=now()-interval '30 days';
  insert into public.geocode_cache(key,candidates) values(p_key,p_candidates)
  on conflict (key) do update set candidates=excluded.candidates,fetched_at=now();
$$;

revoke execute on function public.geocode_begin(uuid,boolean,text),public.geocode_store(text,jsonb)
  from public,anon,authenticated;
grant execute on function public.geocode_begin(uuid,boolean,text),public.geocode_store(text,jsonb)
  to service_role;
