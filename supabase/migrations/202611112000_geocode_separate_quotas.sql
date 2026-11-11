-- #434: address searches and approximate-door (reverse) lookups get their
-- own daily limits (user decision 2026-11-11). A search stays at 30 a Taipei
-- day for riders and 200 for admins; reverse lookups, which the report form
-- makes on its own as the marker moves, get 100 for riders and 200 for
-- admins. Using one never takes from the other.
--
-- Rows already in geocode_events were written before the two were told
-- apart and are kept as searches. On the day this ships a rider's earlier
-- reverse lookups that day therefore still count towards that day's 30
-- searches, while reverse lookups start the day afresh at 100; from the next
-- Taipei midnight each limit counts only its own kind.
alter table public.geocode_events
  add column kind text not null default 'search'
    check (kind in ('search','reverse'));
comment on column public.geocode_events.kind is
  '哪一份每日額度：search 地址搜尋、reverse 約略門牌（#434）。不含查詢內容。';

-- Each count reads one user's rows of one kind since Taipei midnight.
create index geocode_events_user_kind_idx
  on public.geocode_events(user_id,kind,created_at);
drop index public.geocode_events_user_idx;

-- Replaces geocode_count(uuid,boolean). p_kind defaults to 'search' so the
-- Edge Function deployed before this migration, which calls
-- geocode_count(p_user, p_admin) for both, keeps working until the new one
-- is live: in that gap both count against the search limit of 30, as they
-- did before.
drop function public.geocode_count(uuid,boolean);

-- Counts one search or reverse lookup for p_user against that kind's limit.
-- Admins (aal2, decided by the caller from the verified token) get 200 of
-- each. Raises P0001 once the day's are used. Counts older than 30 days are
-- deleted by the daily usage_events_prune() (#267), whatever their kind.
create function public.geocode_count(p_user uuid,p_admin boolean,p_kind text default 'search')
returns void language plpgsql security definer set search_path='' as $$
declare
  v_day timestamptz:=date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
  v_limit integer;
begin
  if p_kind is null or p_kind not in ('search','reverse') then
    raise exception 'unknown geocode kind' using errcode='22023';
  end if;
  v_limit:=case when p_admin then 200 when p_kind='search' then 30 else 100 end;
  -- One caller's parallel requests of a kind must not all pass the count.
  -- The limits are separate, so the two kinds do not wait for each other.
  perform pg_advisory_xact_lock(hashtextextended('geocode:'||p_kind||':'||p_user::text,0));
  if (select count(*) from public.geocode_events
      where user_id=p_user and kind=p_kind and created_at>=v_day)>=v_limit then
    raise exception 'daily % limit reached',p_kind using errcode='P0001';
  end if;
  insert into public.geocode_events(user_id,kind) values(p_user,p_kind);
end;
$$;

revoke execute on function public.geocode_count(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.geocode_count(uuid,boolean,text) to service_role;
