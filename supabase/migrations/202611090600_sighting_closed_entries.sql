-- #189：「無法停車／施工中」可以回報分區或路段（使用者 2026-11-07）。
--
-- 原本 kind='closed' 只接受整個點。現在和 level 一樣可帶 zone_id 或 segment_id
-- （二選一，都不帶表示整點），id 一樣由 sighting_spot_entries() 驗證，查無就拒絕。
--
-- 影響範圍：
-- 1. 分區或路段的 closed 只算該區該段。整點的暫時封閉建議（#116）要等到所有
--    分區或路段都有 2 位不同車友與裝置回報；整點的 closed 算進每一區每一段。
--    沒有分區或路段的點位，規則和原本相同。
-- 2. 每日上限、10 分鐘限制、洗版規則本來就依 zone_id、segment_id 或全部
--    kind 計算，不用改。closed 不評分、不被評分，也不改。
-- 3. public.spot_sightings() 只算 kind='level'，舊版 App 的行為不變。
-- 4. api_v1.spot_sightings() 的 sightings 不變，新增 closures：哪一區、哪一段
--    或整點被回報關閉，見 private.rider_closure_summary()。

alter table public.rider_sightings drop constraint rider_sightings_check1;
comment on column public.rider_sightings.kind is
  'level：四級量表；closed：無法停車／施工中。兩者都可帶 zone_id 或 segment_id，都不帶表示整點（#189）。';

-- 關閉回報的兩個門檻集中在這裡。
-- How long a closed sighting holds in what the app reads.
create function private.sighting_closed_window() returns interval
language sql immutable set search_path='' as $$ select interval '2 hours' $$;
-- How many independent riders confirm a closure.
create function private.sighting_closed_min_riders() returns integer
language sql immutable set search_path='' as $$ select 2 $$;
revoke all on function private.sighting_closed_window(),private.sighting_closed_min_riders() from public,anon,authenticated;

-- Whether all of a spot is closed by what riders said since p_since: every
-- zone and segment it has now (or the spot itself when it has neither) has
-- two independent riders — as many users as devices count, credible and not
-- suspended — saying closed for it or for the whole spot. A zone removed
-- since no longer counts.
create function private.sighting_spot_closed(p_spot text,p_zones jsonb,p_segments jsonb,p_since timestamptz)
returns boolean language sql stable set search_path='' as $$
  with entries as (
    select z->>'id' zone_id,null::text segment_id from jsonb_array_elements(coalesce(p_zones,'[]')) z
    union all
    select null,g->>'id' from jsonb_array_elements(coalesce(p_segments,'[]')) g
  ), targets as (
    select e.zone_id,e.segment_id from entries e
    union all
    select null,null where not exists(select 1 from entries)
  ), said as (
    select s.user_id,s.device_hash,s.zone_id,s.segment_id from public.rider_sightings s
    where s.spot_id=p_spot and s.kind='closed' and s.created_at>p_since
      and not public.rider_suspended(s.user_id)
      and public.rider_credibility(s.user_id)>=public.rider_min_credibility()
  )
  select bool_and(n.riders>=private.sighting_closed_min_riders()) from targets t
  cross join lateral (
    select least(count(distinct a.user_id),count(distinct a.device_hash)) riders from said a
    where (a.zone_id is null and a.segment_id is null)
      or (a.zone_id is not distinct from t.zone_id and a.segment_id is not distinct from t.segment_id)
  ) n;
$$;
revoke all on function private.sighting_spot_closed(text,jsonb,jsonb,timestamptz) from public,anon,authenticated;

-- Same signature and grants; only what closed may name and when the whole
-- spot is suggested change (202610310110_sightings_daily_limits.sql).
create or replace function public.apply_sighting(p_user uuid,p_ip text,p_device text,p_spot text,p_kind text,
  p_vehicle text,p_level smallint default null,p_zone text default null,p_segment text default null,
  p_ip_capped boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  -- The day resets at midnight in Taiwan.
  v_day timestamptz:=date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
  v_ip_busy boolean:=false;
  v_at extensions.geography;
  v_entries record;
  v_prev record;
  v_prev_at extensions.geography;
  v_jump boolean:=false;
  v_recent integer;
  v_jumps integer;
  v_official smallint;
  v_id bigint;
  v_weight numeric;
  v_admin boolean;
  v_suspend timestamptz;
  v_closure jsonb;
  v_suggested boolean:=false;
  v_meters float8;
  v_scored uuid;
  v_since timestamptz;
begin
  if p_ip is null or char_length(p_ip)<>64 or p_device is null or char_length(p_device)<>64 then
    raise exception 'missing trusted identity' using errcode='22023';
  end if;
  -- One spelling per spot: ids are compared as text everywhere below.
  p_spot:=lower(p_spot);
  if p_kind is null or p_kind not in ('level','closed')
     or p_vehicle is null or p_vehicle not in ('scooter','heavy')
     or (p_kind='level') is distinct from (p_level is not null)
     or (p_level is not null and p_level not between 0 and 3)
     or (p_zone is not null and p_segment is not null) then
    raise exception 'invalid sighting' using errcode='22023';
  end if;
  if not exists(select 1 from auth.users u join auth.identities i on i.user_id=u.id
      where u.id=p_user and not u.is_anonymous and i.provider in ('google','apple')) then
    raise exception 'Google or Apple sign-in required' using errcode='42501';
  end if;
  if public.rider_suspended(p_user) then
    raise exception 'sighting suspended' using errcode='42501';
  end if;
  v_at:=public.sighting_spot_location(p_spot);
  if v_at is null then raise exception 'spot not found' using errcode='22023'; end if;
  -- The zone or segment must be one of the spot's own, by its stable id.
  select * into v_entries from public.sighting_spot_entries(p_spot);
  if (p_zone is not null and not exists(select 1 from jsonb_array_elements(coalesce(v_entries.zones,'[]')) z
        where z->>'id'=p_zone))
     or (p_segment is not null and not exists(select 1 from jsonb_array_elements(coalesce(v_entries.segments,'[]')) g
        where g->>'id'=p_segment)) then
    raise exception 'area not found' using errcode='22023';
  end if;

  -- Same order as apply_report: IP, then account.
  perform pg_advisory_xact_lock(hashtextextended('sighting-ip:'||p_ip,0));
  perform pg_advisory_xact_lock(hashtextextended('sighting-user:'||p_user::text,0));
  -- Checked again under the account lock: a sighting waiting here behind the
  -- one that set the suspension must not write or judge anyone.
  if public.rider_suspended(p_user) then
    raise exception 'sighting suspended' using errcode='42501';
  end if;
  -- 30 a day per account. Per network 200 a day while App Check only logs
  -- (p_ip_capped); once it is enforced the network count is a risk signal
  -- instead: past 200 the sighting is kept but weighs less (#203).
  if (select count(*) from public.rider_sightings where user_id=p_user and created_at>=v_day)>=30 then
    raise exception 'daily sighting limit reached' using errcode='P0001';
  end if;
  if (select count(*) from public.rider_sightings where ip_hash=p_ip and created_at>=v_day)>=200 then
    if p_ip_capped is not false then
      raise exception 'daily sighting limit reached' using errcode='P0001';
    end if;
    v_ip_busy:=true;
  end if;
  -- One sighting per zone or segment every 10 minutes, so a rider can tell
  -- each zone of a car park in one visit.
  if exists(select 1 from public.rider_sightings where user_id=p_user and spot_id=p_spot
      and zone_id is not distinct from p_zone and segment_id is not distinct from p_segment
      and created_at>now()-interval '10 minutes') then
    raise exception 'spot sighted within 10 minutes' using errcode='P0001';
  end if;

  -- 位置不合理: from the previous spot to this one faster than 150 km/h,
  -- more than 3 km apart.
  select s.spot_id,s.created_at into v_prev from public.rider_sightings s
    where s.user_id=p_user order by s.created_at desc limit 1;
  if v_prev.spot_id is not null and v_prev.spot_id<>p_spot then
    v_prev_at:=public.sighting_spot_location(v_prev.spot_id);
    if v_prev_at is not null then
      v_meters:=extensions.st_distance(v_prev_at,v_at);
      v_jump:=v_meters>3000 and v_meters/greatest(extract(epoch from now()-v_prev.created_at),1)>150/3.6;
    end if;
  end if;

  -- The official count for the rider's vehicle at this moment, if fresh and
  -- for what the rider saw: the count is per facility, so only a sighting
  -- of the whole spot, or of a spot with at most one zone, compares.
  if p_kind='level' and p_spot like 'official:%' and p_segment is null
     and jsonb_array_length(coalesce(v_entries.segments,'[]'))=0
     and (p_zone is null or jsonb_array_length(coalesce(v_entries.zones,'[]'))<=1) then
    select public.sighting_official_level(a.available,a.total) into v_official
      from public.viewport_availability(array[p_spot]) a
      where a.vehicle=p_vehicle and a.status='fresh';
  end if;

  insert into public.rider_sightings(user_id,spot_id,kind,level,zone_id,segment_id,vehicle,official,jump,ip_busy,ip_hash,device_hash)
  values(p_user,p_spot,p_kind,p_level,p_zone,p_segment,p_vehicle,v_official,v_jump,v_ip_busy,p_ip,p_device)
  returning id into v_id;

  -- ===== 評分 =====
  -- Every score this sighting may change — the rider's own (official
  -- count, flood rules) and the earlier riders it judges — is locked first,
  -- in one order, so two riders judging each other at once wait instead of
  -- deadlocking on each other's score rows.
  for v_scored in
    select x.u from (
      select p_user u
      union
      select s.user_id from public.rider_sightings s
        where p_kind='level' and s.spot_id=p_spot and s.id<>v_id and s.user_id<>p_user
          and s.device_hash<>p_device and s.kind='level' and s.vehicle=p_vehicle
          and s.zone_id is not distinct from p_zone and s.segment_id is not distinct from p_segment
          and s.created_at>now()-interval '10 minutes'
    ) x order by x.u
  loop
    perform pg_advisory_xact_lock(hashtextextended('sighting-score:'||v_scored::text,0));
  end loop;
  if p_kind='level' and v_official is not null then
    perform public.rider_score_add(p_user,case when abs(p_level-v_official)<=1 then 1 else 0 end,
      case when abs(p_level-v_official)<=1 then 0 else 1 end,0);
  end if;
  -- This sighting judges the earlier ones of other riders on other devices
  -- in the last 10 minutes, of the same zone or segment and vehicle, each
  -- once, by this rider's credibility; a rider not shown judges no one.
  v_weight:=public.rider_credibility(p_user);
  if p_kind='level' and v_weight>=public.rider_min_credibility() then
    perform public.rider_score_add(e.user_id,case when abs(e.level-p_level)<=1 then v_weight else 0 end,
        case when abs(e.level-p_level)<=1 then 0 else v_weight end,0)
      from (select distinct on (s.user_id) s.user_id,s.level from public.rider_sightings s
        where s.spot_id=p_spot and s.id<>v_id and s.user_id<>p_user and s.device_hash<>p_device
          and s.kind='level' and s.vehicle=p_vehicle
          and s.zone_id is not distinct from p_zone and s.segment_id is not distinct from p_segment
          and s.created_at>now()-interval '10 minutes'
        order by s.user_id,s.created_at desc) e;
  end if;

  -- ===== 洗版 =====
  select count(*) into v_recent from public.rider_sightings
    where user_id=p_user and created_at>now()-interval '10 minutes';
  select count(*) into v_jumps from public.rider_sightings
    where user_id=p_user and jump and created_at>now()-interval '24 hours';
  select coalesce(u.raw_app_meta_data->>'role','')='admin' into v_admin from auth.users u where u.id=p_user;
  if (v_recent>=12 or v_jumps>=3) and not v_admin then
    v_suspend:=now()+interval '7 days';
    perform public.rider_score_add(p_user,0,0,4);
    update public.rider_sighting_scores set suspended_until=v_suspend where user_id=p_user;
  elsif v_recent>=6 or v_jump or v_ip_busy then
    perform public.rider_score_add(p_user,0,0,1);
  end if;

  -- ===== 自動暫時封閉建議 =====
  if p_kind='closed' and v_suspend is null then
    -- Two riders at once: the later waits here and then sees the earlier
    -- one's committed sighting, so the second report meets the threshold.
    perform pg_advisory_xact_lock(hashtextextended('sighting-closure:'||p_spot,0));
    if p_spot like 'official:%' then
      select o.closure into v_closure from public.official_heavy_spots o where o.id=substr(p_spot,10)::uuid;
    else
      select c.closure into v_closure from public.community_spots c where c.id=p_spot::uuid;
    end if;
    -- The whole spot is suggested only once all of it is closed: every zone
    -- or segment, see sighting_spot_closed(). A rider's level for any part
    -- of it within 2 hours still blocks the suggestion.
    -- Evidence an admin already judged does not count again: only sightings
    -- after the latest resolved 已不存在／封閉 case of the spot, as
    -- apply_report() does for 這裡已經不能停車 votes.
    select greatest(now()-interval '2 hours',coalesce(max(q.resolved_at),'-infinity')) into v_since
      from public.moderation_queue q where q.source_id=p_spot and q.field='gone' and q.resolved_at is not null;
    if public.closure_state(v_closure) is distinct from 'active'
       and not exists(select 1 from public.moderation_queue q where q.source_id=p_spot and q.field='gone' and q.resolved_at is null)
       and private.sighting_spot_closed(p_spot,v_entries.zones,v_entries.segments,v_since)
       and not exists(select 1 from public.rider_sightings s
         where s.spot_id=p_spot and s.kind='level' and s.created_at>now()-interval '2 hours'
           and not public.rider_suspended(s.user_id)
           and public.rider_credibility(s.user_id)>=public.rider_min_credibility()) then
      -- Held for review like a rider's 這裡已經不能停車 report for works or
      -- a closure: an admin applies it with a date or rejects it (#116).
      insert into public.moderation_queue(source_id,reason,field,proposed,note)
      values(p_spot,'騎士回報：2 位車友 2 小時內回報無法停車／施工中','gone',
        '{"closure":{"reason":"closed"}}'::jsonb,
        '規則評分自動建立（決定 50）：2 小時內 2 位不同車友回報「無法停車／施工中」（有分區或路段時，每一區或每一段都達到），沒有相反回報。')
      on conflict do nothing;
      v_suggested:=found;
    end if;
  end if;

  return jsonb_build_object('id',v_id,'accepted',true,'closure_suggested',v_suggested,
    'suspended_until',v_suspend);
end $$;

-- What is reported closed now, per spot of p_spot_ids (visible ones), zone or
-- segment, both null for the whole spot. One row per place:
--   counted    closed sightings in sighting_closed_window(), credible and not
--              suspended, of a zone or segment the spot still has, or of the
--              whole spot; a later credible level of the same place or of
--              the whole spot takes one back, and a level of any part takes
--              back a sighting of the whole spot
--   a zone's or segment's row exists when a sighting names it; riders counts
--              those and the whole-spot ones, as sighting_spot_closed() does
--   the whole spot's row exists when a sighting names it (derived false) or
--              every zone and segment is confirmed (derived true when none
--              names it); with every part confirmed it sums up all of them
--   riders     users or devices, whichever is fewer
--   confirmed  riders reach sighting_closed_min_riders()
-- Callers bound p_spot_ids.
create function private.rider_closure_summary(p_spot_ids text[])
returns table(spot_id text,zone_id text,segment_id text,riders integer,confirmed boolean,
  latest_at timestamptz,derived boolean)
language sql stable security definer set search_path='' as $$
  with ids as (
    select distinct lower(i) i from unnest(p_spot_ids) i where i is not null
  ), said as (
    select s.spot_id,s.kind,s.zone_id,s.segment_id,s.user_id,s.device_hash,s.created_at
    from public.rider_sightings s join ids on ids.i=s.spot_id
    where s.created_at>now()-private.sighting_closed_window() and s.created_at<=now()
      and not public.rider_suspended(s.user_id)
      and public.rider_credibility(s.user_id)>=public.rider_min_credibility()
  ), spots as (
    select p.spot_id,e.zones,e.segments
    from (select distinct d.spot_id from said d where d.kind='closed') p
    cross join lateral public.sighting_spot_entries(p.spot_id) e
    where e.zones is not null
  ), places as (
    select p.spot_id,z->>'id' zone_id,null::text segment_id from spots p
      cross join lateral jsonb_array_elements(p.zones) z
    union all
    select p.spot_id,null,g->>'id' from spots p
      cross join lateral jsonb_array_elements(p.segments) g
    union all
    select p.spot_id,null,null from spots p
  ), counted as (
    -- Each place with the closed sightings that hold for it.
    select t.spot_id,t.zone_id,t.segment_id,c.user_id,c.device_hash,c.created_at,
      c.zone_id is not distinct from t.zone_id and c.segment_id is not distinct from t.segment_id own
    from places t join said c on c.spot_id=t.spot_id and c.kind='closed'
      and ((c.zone_id is null and c.segment_id is null)
        or (c.zone_id is not distinct from t.zone_id and c.segment_id is not distinct from t.segment_id))
    where not exists(select 1 from said l
      where l.spot_id=c.spot_id and l.kind='level' and l.created_at>c.created_at
        and ((t.zone_id is null and t.segment_id is null)
          or (l.zone_id is null and l.segment_id is null)
          or (l.zone_id is not distinct from t.zone_id and l.segment_id is not distinct from t.segment_id)))
  ), per_place as (
    select c.spot_id,c.zone_id,c.segment_id,
      least(count(distinct c.user_id),count(distinct c.device_hash))::integer riders,
      max(c.created_at) latest_at,bool_or(c.own) named
    from counted c group by 1,2,3
  ), per_spot as (
    -- Every zone and segment confirmed, and all that was said of the spot.
    select p.spot_id,
      not exists(select 1 from places t
        left join per_place r on r.spot_id=t.spot_id and r.zone_id is not distinct from t.zone_id
          and r.segment_id is not distinct from t.segment_id
        where t.spot_id=p.spot_id and (t.zone_id is not null or t.segment_id is not null)
          and coalesce(r.riders,0)<private.sighting_closed_min_riders())
      and exists(select 1 from places t where t.spot_id=p.spot_id
        and (t.zone_id is not null or t.segment_id is not null)) all_closed,
      (select least(count(distinct c.user_id),count(distinct c.device_hash))::integer from counted c where c.spot_id=p.spot_id) riders,
      (select max(c.created_at) from counted c where c.spot_id=p.spot_id) latest_at
    from spots p
  )
  select r.spot_id,r.zone_id,r.segment_id,r.riders,r.riders>=private.sighting_closed_min_riders(),r.latest_at,false
  from per_place r
  where r.named and (r.zone_id is not null or r.segment_id is not null)
  union all
  select p.spot_id,null,null,
    case when p.all_closed then p.riders else w.riders end,
    p.all_closed or w.riders>=private.sighting_closed_min_riders(),
    case when p.all_closed then p.latest_at else w.latest_at end,
    p.all_closed and not coalesce(w.named,false)
  from per_spot p
  left join per_place w on w.spot_id=p.spot_id and w.zone_id is null and w.segment_id is null
  where p.all_closed or coalesce(w.named,false)
  order by 1,2,3;
$$;
revoke all on function private.rider_closure_summary(text[]) from public,anon,authenticated;

-- sightings 與時間窗不變（202611090100_api_spot_sightings.sql）；closures 固定看
-- sighting_closed_window()，不受 p_window_minutes 影響。
create or replace function api_v1.spot_sightings(p_spot_ids text[],p_window_minutes integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids text[];
begin
  if p_window_minutes is null or p_window_minutes not in (15, 30) then
    raise sqlstate 'PT400' using message = 'request.invalid', detail = '{"field":"p_window_minutes"}';
  end if;
  if coalesce(cardinality(p_spot_ids), 0) > 600 then
    raise sqlstate 'PT400' using message = 'request.too_many_ids', detail = '{"limit":600}';
  end if;
  v_ids := array(
    select i from unnest(p_spot_ids) i
    where i ~* '^(official:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  );
  return jsonb_build_object('sightings', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'spot_id', s.spot_id, 'zone_id', s.zone_id, 'segment_id', s.segment_id, 'vehicle', s.vehicle,
        'level', s.level, 'count', s.riders, 'low', s.low, 'high', s.high,
        'low_riders', s.low_riders, 'high_riders', s.high_riders,
        'latest_at', s.latest_at, 'conflicting', s.state = 'conflict'
      ) order by s.spot_id, s.zone_id, s.segment_id, s.vehicle), '[]'::jsonb)
    from private.rider_sighting_summary(v_ids, p_window_minutes) s
  ), 'closures', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'spot_id', c.spot_id, 'zone_id', c.zone_id, 'segment_id', c.segment_id,
        'riders', c.riders, 'confirmed', c.confirmed, 'latest_at', c.latest_at, 'derived', c.derived
      ) order by c.spot_id, c.zone_id, c.segment_id), '[]'::jsonb)
    from private.rider_closure_summary(v_ids) c
  ));
end;
$$;
