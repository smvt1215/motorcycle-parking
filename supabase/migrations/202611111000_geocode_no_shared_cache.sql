-- #411: address search results are no longer cached (Google Maps Platform
-- Service Specific Terms, 2026-10-28, Geocoding API 6.3). 6.3.1 allows a
-- 30-day cache of latitude and longitude only; the labels a search returns
-- are formatted and structured address values, which 6.3.2 lets a cache hold
-- only for the rider who asked, and never in place of another call to
-- Google. A cache that answers a repeated search is exactly that, and the
-- coordinates alone cannot fill the result list, so nothing is kept: every
-- search asks Google. The daily limits are unchanged.
--
-- The Edge Function deployed before this migration calls the old
-- functions; between `db push` and `functions deploy` its searches answer
-- `unavailable` until the new version is live.
drop function public.geocode_begin(uuid,boolean,text);
drop function public.geocode_store(text,jsonb);
-- Deletes every cached result, including those still within 30 days.
drop table public.geocode_cache;

-- Counts one search or reverse lookup for p_user. Riders get 30 a Taipei
-- day, admins (aal2, decided by the caller from the verified token) 200.
-- Raises P0001 once the day's are used. Counts older than 30 days are
-- deleted by the daily usage_events_prune() (#267), which until now
-- geocode_store also did on every cache write.
create function public.geocode_count(p_user uuid,p_admin boolean)
returns void language plpgsql security definer set search_path='' as $$
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
end;
$$;

revoke execute on function public.geocode_count(uuid,boolean) from public,anon,authenticated;
grant execute on function public.geocode_count(uuid,boolean) to service_role;
