-- Riders' on-site sightings, 即時車位 P3 (#154, #189; REALTIME_AVAILABILITY_UI_PLAN
-- §5.2, §9 P3; decisions 40 and 50; design Ver.143 A6, A7, A7b, A11, A12).
-- A signed-in rider says how full a spot's zone (off-street) or segment
-- (roadside) is now for their vehicle, on a four-level scale — 很多空位 (0),
-- 還有一些 (1), 快滿了 (2), 已停滿 (3) — or that it is 無法停車／施工中
-- (closed). Judged by rules on the server, never by an LLM, and never shown
-- as an official count: no 「剩 N」 comes from here.
--
-- 1. rider_sightings: who, which spot, what, when. Only the spot is stored,
--    never where the rider was; raw rows go after 7 days (pg_cron).
--    Riders read only their own rows; nobody reads anyone else's.
-- 2. rider_sighting_scores: one row per rider, sums only (no sightings), so
--    the score outlives the 7-day rows. Credibility is how well a rider's
--    sightings agreed with the official count at that spot at that time
--    (P2 snapshot) and with other riders' sightings that followed.
-- 3. apply_sighting(): the submit-sighting Edge Function's write (service
--    role). Same sign-in as reports, its own limits (30 a day per account,
--    100 per network, one per spot per 10 minutes), scoring, flood rules
--    (suspend 7 days or lower the weight) and the automatic closure
--    suggestion (two riders within 2 hours, nobody saying otherwise).
-- 4. spot_sightings(): what the app shows per spot, zone or segment and
--    vehicle for the last 30 minutes: the weighted median level when the
--    riders agree (70% of the weight within one level of it), else
--    說法不一 with the two extremes and how many riders said each. No
--    names, no single sightings.

-- ===== 1. 目擊紀錄 =====
create table public.rider_sightings (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- The app's spot id: 'official:<uuid>' or a community spot's uuid.
  spot_id text not null check (spot_id ~ '^(official:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  -- A level of the scale, or closed (the whole spot, no level).
  kind text not null check (kind in ('level','closed')),
  -- 0 很多空位, 1 還有一些, 2 快滿了, 3 已停滿.
  level smallint check (level between 0 and 3),
  -- The zone (off-street) or segment (roadside) the rider saw, by its
  -- stable id (#188); neither for a spot without them or the whole spot.
  zone_id text check (zone_id ~ '^[a-z0-9_-]{1,32}$'),
  segment_id text check (segment_id ~ '^[a-z0-9_-]{1,32}$'),
  -- The vehicle the rider had chosen, to compare with that vehicle's count.
  vehicle text not null check (vehicle in ('scooter','heavy')),
  -- The official count's level at that moment, when there was a fresh one
  -- for the whole facility: share of free spaces > 50% is 0, 20–50% is 1,
  -- above 0 is 2, none is 3.
  official smallint check (official between 0 and 3),
  -- The jump from the rider's previous sighting was faster than a scooter
  -- can travel (flood rule).
  jump boolean not null default false,
  -- Keyed hashes, as in report_identities; for limits and independence.
  ip_hash text not null check (char_length(ip_hash)=64),
  device_hash text not null check (char_length(device_hash)=64),
  created_at timestamptz not null default now(),
  check ((kind='level')=(level is not null)),
  check (kind='level' or (zone_id is null and segment_id is null)),
  check (zone_id is null or segment_id is null)
);
create index rider_sightings_spot_idx on public.rider_sightings(spot_id,created_at desc);
create index rider_sightings_user_idx on public.rider_sightings(user_id,created_at desc);
create index rider_sightings_ip_idx on public.rider_sightings(ip_hash,created_at);
comment on table public.rider_sightings is
  '騎士回報現場狀況（#154）：只存點位不存回報者位置；7 天後由 rider_sightings_prune() 刪除。';

-- ===== 2. 可信度 =====
create table public.rider_sighting_scores (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- Weighted agreements and disagreements with the official count and with
  -- later riders; penalty is added by the flood rules (降權).
  agree numeric not null default 0 check (agree>=0),
  disagree numeric not null default 0 check (disagree>=0),
  penalty numeric not null default 0 check (penalty>=0),
  -- Set by the flood rule; the Edge Function also bans the account.
  suspended_until timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.rider_sightings enable row level security;
alter table public.rider_sighting_scores enable row level security;
revoke all on public.rider_sightings,public.rider_sighting_scores from anon,authenticated;
-- A rider may see their own sightings (what they sent, never anyone else's).
grant select (id,user_id,spot_id,kind,level,zone_id,segment_id,vehicle,created_at) on public.rider_sightings to authenticated;
create policy rider_sightings_own on public.rider_sightings for select to authenticated
  using(user_id=(select auth.uid()));

-- Below this a rider's sightings are not shown (低分不顯示).
create function public.rider_min_credibility() returns numeric
language sql immutable set search_path='' as $$ select 0.3::numeric $$;

-- (agree+2)/(agree+disagree+penalty+4): a new rider starts at 0.5; three
-- disagreements with nothing in their favour drop them below 0.3.
create function public.rider_credibility(p_user uuid) returns numeric
language sql stable set search_path='' as $$
  select coalesce((select (s.agree+2)/(s.agree+s.disagree+s.penalty+4)
    from public.rider_sighting_scores s where s.user_id=p_user),0.5);
$$;

-- Suspended by the flood rule or banned by an admin.
create function public.rider_suspended(p_user uuid) returns boolean
language sql stable set search_path='' as $$
  select exists(select 1 from public.rider_sighting_scores s where s.user_id=p_user and s.suspended_until>now())
    or exists(select 1 from auth.users u where u.id=p_user and u.banned_until>now());
$$;

-- Adds to a rider's sums.
create function public.rider_score_add(p_user uuid,p_agree numeric,p_disagree numeric,p_penalty numeric)
returns void language sql set search_path='' as $$
  insert into public.rider_sighting_scores as s(user_id,agree,disagree,penalty)
  values(p_user,p_agree,p_disagree,p_penalty)
  on conflict(user_id) do update set agree=s.agree+excluded.agree,disagree=s.disagree+excluded.disagree,
    penalty=s.penalty+excluded.penalty,updated_at=now();
$$;

-- Where a spot a rider can see is; null for a hidden, not yet effective or
-- unknown one.
create function public.sighting_spot_location(p_spot text) returns extensions.geography
language plpgsql stable set search_path='' as $$
begin
  if p_spot ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return (select extensions.st_setsrid(extensions.st_makepoint(o.lng,o.lat),4326)::extensions.geography
      from public.official_heavy_spots o
      where o.id=substr(p_spot,10)::uuid and not o.hidden and o.effective_date<=current_date);
  elsif p_spot ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return (select c.location from public.community_spots c where c.id=p_spot::uuid and c.status<>'hidden');
  end if;
  return null;
end $$;

-- The zones and segments of a spot a rider can see (#188), as stored:
-- arrays of objects with an id; null for a hidden or unknown spot.
create function public.sighting_spot_entries(p_spot text,out zones jsonb,out segments jsonb)
language plpgsql stable set search_path='' as $$
begin
  if p_spot ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select o.parking_zones,o.parking_segments into zones,segments from public.official_heavy_spots o
      where o.id=substr(p_spot,10)::uuid and not o.hidden and o.effective_date<=current_date;
  elsif p_spot ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select c.parking_zones,c.parking_segments into zones,segments from public.community_spots c
      where c.id=p_spot::uuid and c.status<>'hidden';
  end if;
end $$;

-- The scale's level of an official count: the share of free spaces above
-- 50% is 0 (很多空位), 20–50% is 1 (還有一些), above 0 is 2 (快滿了), none
-- is 3 (已停滿); null without a total.
create function public.sighting_official_level(p_available integer,p_total integer) returns smallint
language sql immutable set search_path='' as $$
  select case when p_available is null or p_total is null or p_total<=0 then null
    when p_available<=0 then 3
    when p_available::numeric/p_total>0.5 then 0
    when p_available::numeric/p_total>=0.2 then 1
    else 2 end::smallint;
$$;

-- ===== 3. 寫入 =====
-- The thresholds of decision 50 and Ver.143 in one place:
--   shown           credibility >= 0.3, last 30 minutes, map badge 15
--   agreement       70% of the weight within one level of the weighted
--                   median, else 說法不一
--   match           two levels match when they differ by at most one
--   peer judgement  a later sighting within 10 minutes by another rider
--                   and device, of the same zone or segment and vehicle,
--                   judges an earlier one (weight = its rider's credibility)
--   official        a fresh count for the rider's vehicle, compared only
--                   when it covers what the rider saw (the whole spot, or
--                   a spot with at most one zone and no segments)
--   flood           6+ in 10 minutes or a jump (> 3 km at > 150 km/h):
--                   weight lowered; 12+ in 10 minutes or 3 jumps in 24
--                   hours: suspended 7 days (admins are only lowered)
--   closure         2 riders (and devices) within 2 hours say closed and
--                   no credible rider gives a level: a closure suggestion
--                   for review (#116)
create function public.apply_sighting(p_user uuid,p_ip text,p_device text,p_spot text,p_kind text,
  p_vehicle text,p_level smallint default null,p_zone text default null,p_segment text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_day timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
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
     or (p_kind='closed' and (p_zone is not null or p_segment is not null))
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
  if (select count(*) from public.rider_sightings where user_id=p_user and created_at>=v_day)>=30 or
     (select count(*) from public.rider_sightings where ip_hash=p_ip and created_at>=v_day)>=100 then
    raise exception 'daily sighting limit reached' using errcode='P0001';
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

  insert into public.rider_sightings(user_id,spot_id,kind,level,zone_id,segment_id,vehicle,official,jump,ip_hash,device_hash)
  values(p_user,p_spot,p_kind,p_level,p_zone,p_segment,p_vehicle,v_official,v_jump,p_ip,p_device)
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
  elsif v_recent>=6 or v_jump then
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
    -- Evidence an admin already judged does not count again: only sightings
    -- after the latest resolved 已不存在／封閉 case of the spot, as
    -- apply_report() does for 這裡已經不能停車 votes.
    select greatest(now()-interval '2 hours',coalesce(max(q.resolved_at),'-infinity')) into v_since
      from public.moderation_queue q where q.source_id=p_spot and q.field='gone' and q.resolved_at is not null;
    if public.closure_state(v_closure) is distinct from 'active'
       and not exists(select 1 from public.moderation_queue q where q.source_id=p_spot and q.field='gone' and q.resolved_at is null)
       and (select least(count(distinct s.user_id),count(distinct s.device_hash)) from public.rider_sightings s
         where s.spot_id=p_spot and s.kind='closed' and s.created_at>v_since
           and not public.rider_suspended(s.user_id)
           and public.rider_credibility(s.user_id)>=public.rider_min_credibility())>=2
       and not exists(select 1 from public.rider_sightings s
         where s.spot_id=p_spot and s.kind='level' and s.created_at>now()-interval '2 hours'
           and not public.rider_suspended(s.user_id)
           and public.rider_credibility(s.user_id)>=public.rider_min_credibility()) then
      -- Held for review like a rider's 這裡已經不能停車 report for works or
      -- a closure: an admin applies it with a date or rejects it (#116).
      insert into public.moderation_queue(source_id,reason,field,proposed,note)
      values(p_spot,'騎士回報：2 位車友 2 小時內回報無法停車／施工中','gone',
        '{"closure":{"reason":"closed"}}'::jsonb,
        '規則評分自動建立（決定 50）：2 小時內 2 位不同車友回報「無法停車／施工中」，沒有相反回報。')
      on conflict do nothing;
      v_suggested:=found;
    end if;
  end if;

  return jsonb_build_object('id',v_id,'accepted',true,'closure_suggested',v_suggested,
    'suspended_until',v_suspend);
end $$;
revoke all on function public.apply_sighting(uuid,text,text,text,text,text,smallint,text,text) from public,anon,authenticated;
grant execute on function public.apply_sighting(uuid,text,text,text,text,text,smallint,text,text) to service_role;

-- ===== 4. 讀取（App） =====
-- Per spot of p_spot_ids (at most 600), zone or segment (both null for the
-- whole spot) and vehicle, with a level sighting in the last 30 minutes.
-- Each rider and each device counts once (its latest); suspended and
-- low-credibility riders are left out; each counts by its credibility.
--   level      the weighted median level (the lowest level whose
--              cumulative weight reaches half)
--   state      'level' when 70% of the weight is within one level of it,
--              else 'conflict'
--   low, high  the lowest and highest level said, and low_riders,
--              high_riders how many riders said each (for 說法不一)
--   latest_at  the newest sighting, since the oldest one considered
-- Closed sightings feed the closure suggestion, not this.
create function public.spot_sightings(p_spot_ids text[])
returns table(spot_id text,zone_id text,segment_id text,vehicle text,state text,level smallint,
  low smallint,high smallint,low_riders integer,high_riders integer,latest_at timestamptz,since timestamptz)
language sql stable security definer set search_path='' as $$
  with ids as (
    select distinct lower(i) i from unnest(p_spot_ids[1:600]) i where i is not null
  ), recent as (
    select s.spot_id,s.zone_id,s.segment_id,s.vehicle,s.user_id,s.device_hash,s.level,s.created_at
    from public.rider_sightings s join ids on ids.i=s.spot_id
    where s.created_at>now()-interval '30 minutes' and s.created_at<=now() and s.kind='level'
  ), per_user as (
    select distinct on (r.spot_id,r.zone_id,r.segment_id,r.vehicle,r.user_id) r.* from recent r
    order by r.spot_id,r.zone_id,r.segment_id,r.vehicle,r.user_id,r.created_at desc
  ), per_device as (
    select distinct on (p.spot_id,p.zone_id,p.segment_id,p.vehicle,p.device_hash) p.* from per_user p
    order by p.spot_id,p.zone_id,p.segment_id,p.vehicle,p.device_hash,p.created_at desc
  ), weighted as (
    select d.*,public.rider_credibility(d.user_id) w from per_device d
    where not public.rider_suspended(d.user_id)
  ), shown as (
    select w.* from weighted w where w.w>=public.rider_min_credibility()
  ), cumulative as (
    select s.*,
      sum(s.w) over (partition by s.spot_id,s.zone_id,s.segment_id,s.vehicle order by s.level
        range between unbounded preceding and current row) cum,
      sum(s.w) over (partition by s.spot_id,s.zone_id,s.segment_id,s.vehicle) total
    from shown s
  ), medians as (
    select c.spot_id,c.zone_id,c.segment_id,c.vehicle,min(c.level) filter (where c.cum>=c.total/2) median
    from cumulative c group by 1,2,3,4
  ), groups as (
    select s.spot_id,s.zone_id,s.segment_id,s.vehicle,m.median,
      sum(s.w) filter (where abs(s.level-m.median)<=1)/sum(s.w) share,
      min(s.level) low,max(s.level) high,
      max(s.created_at) latest,min(s.created_at) oldest
    from shown s join medians m using (spot_id,vehicle)
    where s.zone_id is not distinct from m.zone_id and s.segment_id is not distinct from m.segment_id
    group by 1,2,3,4,5
  )
  select g.spot_id,g.zone_id,g.segment_id,g.vehicle,
    case when g.share>=0.7 then 'level' else 'conflict' end,
    g.median::smallint,g.low::smallint,g.high::smallint,
    (select count(distinct s.user_id) from shown s where s.spot_id=g.spot_id and s.vehicle=g.vehicle
      and s.zone_id is not distinct from g.zone_id and s.segment_id is not distinct from g.segment_id
      and s.level=g.low)::integer,
    (select count(distinct s.user_id) from shown s where s.spot_id=g.spot_id and s.vehicle=g.vehicle
      and s.zone_id is not distinct from g.zone_id and s.segment_id is not distinct from g.segment_id
      and s.level=g.high)::integer,
    g.latest,g.oldest
  from groups g
  order by 1,2,3,4;
$$;
revoke all on function public.spot_sightings(text[]) from public;
grant execute on function public.spot_sightings(text[]) to anon,authenticated;

-- ===== 4b. 解除停權 =====
-- An admin lifting a ban (Auth banned_until back to none or the past) also
-- lifts the flood rule's suspension, which the same rule set with the ban.
create function public.rider_sightings_unban() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  update public.rider_sighting_scores set suspended_until=null,updated_at=now()
    where user_id=new.id and suspended_until is not null;
  return new;
end $$;
revoke all on function public.rider_sightings_unban() from public,anon,authenticated;
create trigger rider_sightings_unban after update of banned_until on auth.users
  for each row when (old.banned_until>now() and (new.banned_until is null or new.banned_until<=now()))
  execute function public.rider_sightings_unban();

-- ===== 5. 保存期限 =====
-- Raw sightings last 7 days; the scores keep only sums.
create function public.rider_sightings_prune() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  delete from public.rider_sightings where created_at<now()-interval '7 days';
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke all on function public.rider_sightings_prune() from public,anon,authenticated;
revoke all on function public.rider_credibility(uuid),public.rider_suspended(uuid),
  public.rider_score_add(uuid,numeric,numeric,numeric),public.sighting_spot_location(text),
  public.sighting_spot_entries(text) from public,anon,authenticated;

create extension if not exists pg_cron;
select cron.schedule('rider-sightings-prune','17 * * * *','select public.rider_sightings_prune()');
