-- Riders' on-site sightings, 即時車位 P3 (#154; REALTIME_AVAILABILITY_UI_PLAN
-- §5.2, §9 P3; decisions 40 and 50). A signed-in rider says what they see at
-- a spot now: 剛看到有空位 (available), 現場停滿 (full) or 無法停車／施工中
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
-- 4. spot_sightings(): what the app shows per spot — available, full or
--    conflict, and when — for the last 30 minutes. No names, no single
--    sightings, no counts.

-- ===== 1. 目擊紀錄 =====
create table public.rider_sightings (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- The app's spot id: 'official:<uuid>' or a community spot's uuid.
  spot_id text not null check (spot_id ~* '^(official:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  kind text not null check (kind in ('available','full','closed')),
  -- The vehicle the rider had chosen, to compare with that vehicle's count.
  vehicle text not null check (vehicle in ('scooter','heavy')),
  -- The official count's reading at that moment, when there was a fresh
  -- one: 3 or more free is available, 0 is full; 1–2 compares with neither.
  official text check (official in ('available','full')),
  -- The jump from the rider's previous sighting was faster than a scooter
  -- can travel (flood rule).
  jump boolean not null default false,
  -- Keyed hashes, as in report_identities; for limits and independence.
  ip_hash text not null check (char_length(ip_hash)=64),
  device_hash text not null check (char_length(device_hash)=64),
  created_at timestamptz not null default now()
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
grant select (id,user_id,spot_id,kind,vehicle,created_at) on public.rider_sightings to authenticated;
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

-- ===== 3. 寫入 =====
-- The thresholds of decision 50 in one place:
--   shown           credibility >= 0.3, last 30 minutes, map badge 15
--   agreement       weighted share >= 70% for 有空位／停滿, else 不一致
--   peer judgement  a later sighting within 10 minutes by another rider
--                   and device judges an earlier one (weight = its
--                   rider's credibility)
--   official        a fresh count at the time: >= 3 free or 0 free
--   flood           6+ in 10 minutes or a jump (> 3 km at > 150 km/h):
--                   weight lowered; 12+ in 10 minutes or 3 jumps in 24
--                   hours: suspended 7 days (admins are only lowered)
--   closure         2 riders (and devices) within 2 hours say closed and
--                   no credible rider says available or full: a closure
--                   suggestion for review (#116)
create function public.apply_sighting(p_user uuid,p_ip text,p_device text,p_spot text,p_kind text,p_vehicle text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_day timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_at extensions.geography;
  v_prev record;
  v_prev_at extensions.geography;
  v_jump boolean:=false;
  v_recent integer;
  v_jumps integer;
  v_official text;
  v_id bigint;
  v_weight numeric;
  v_admin boolean;
  v_suspend timestamptz;
  v_closure jsonb;
  v_suggested boolean:=false;
  v_meters float8;
begin
  if p_ip is null or char_length(p_ip)<>64 or p_device is null or char_length(p_device)<>64 then
    raise exception 'missing trusted identity' using errcode='22023';
  end if;
  if p_kind is null or p_kind not in ('available','full','closed')
     or p_vehicle is null or p_vehicle not in ('scooter','heavy') then
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

  -- Same order as apply_report: IP, then account.
  perform pg_advisory_xact_lock(hashtextextended('sighting-ip:'||p_ip,0));
  perform pg_advisory_xact_lock(hashtextextended('sighting-user:'||p_user::text,0));
  if (select count(*) from public.rider_sightings where user_id=p_user and created_at>=v_day)>=30 or
     (select count(*) from public.rider_sightings where ip_hash=p_ip and created_at>=v_day)>=100 then
    raise exception 'daily sighting limit reached' using errcode='P0001';
  end if;
  if exists(select 1 from public.rider_sightings where user_id=p_user and spot_id=p_spot
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

  -- The official count for the rider's vehicle at this moment, if fresh.
  if p_spot like 'official:%' then
    select case when a.available>=3 then 'available' when a.available=0 then 'full' end into v_official
      from public.viewport_availability(array[p_spot]) a
      where a.vehicle=p_vehicle and a.status='fresh';
  end if;

  insert into public.rider_sightings(user_id,spot_id,kind,vehicle,official,jump,ip_hash,device_hash)
  values(p_user,p_spot,p_kind,p_vehicle,v_official,v_jump,p_ip,p_device) returning id into v_id;

  -- ===== 評分 =====
  if p_kind<>'closed' and v_official is not null then
    perform public.rider_score_add(p_user,case when p_kind=v_official then 1 else 0 end,
      case when p_kind=v_official then 0 else 1 end,0);
  end if;
  -- This sighting judges the earlier ones of other riders on other devices
  -- in the last 10 minutes, each once (a rider sights a spot at most every
  -- 10 minutes), by this rider's credibility; a rider not shown judges no one.
  v_weight:=public.rider_credibility(p_user);
  if p_kind<>'closed' and v_weight>=public.rider_min_credibility() then
    perform public.rider_score_add(e.user_id,case when e.kind=p_kind then v_weight else 0 end,
        case when e.kind=p_kind then 0 else v_weight end,0)
      from (select distinct on (s.user_id) s.user_id,s.kind from public.rider_sightings s
        where s.spot_id=p_spot and s.id<>v_id and s.user_id<>p_user and s.device_hash<>p_device
          and s.kind in ('available','full') and s.created_at>now()-interval '10 minutes'
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
    if p_spot like 'official:%' then
      select o.closure into v_closure from public.official_heavy_spots o where o.id=substr(p_spot,10)::uuid;
    else
      select c.closure into v_closure from public.community_spots c where c.id=p_spot::uuid;
    end if;
    if public.closure_state(v_closure) is distinct from 'active'
       and not exists(select 1 from public.moderation_queue q where q.source_id=p_spot and q.field='gone' and q.resolved_at is null)
       and (select least(count(distinct s.user_id),count(distinct s.device_hash)) from public.rider_sightings s
         where s.spot_id=p_spot and s.kind='closed' and s.created_at>now()-interval '2 hours'
           and not public.rider_suspended(s.user_id)
           and public.rider_credibility(s.user_id)>=public.rider_min_credibility())>=2
       and not exists(select 1 from public.rider_sightings s
         where s.spot_id=p_spot and s.kind in ('available','full') and s.created_at>now()-interval '2 hours'
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
revoke all on function public.apply_sighting(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.apply_sighting(uuid,text,text,text,text,text) to service_role;

-- ===== 4. 讀取（App） =====
-- Per spot of p_spot_ids (at most 600) with a sighting in the last 30
-- minutes: 'available' or 'full' when credible riders agree by weight
-- (>= 70%), else 'conflict'; latest_at is the newest sighting behind the
-- state, since the oldest one considered. Each rider and each device counts
-- once (its latest); suspended and low-credibility riders are left out.
-- Closed sightings feed the closure suggestion, not this.
create function public.spot_sightings(p_spot_ids text[])
returns table(spot_id text,state text,latest_at timestamptz,since timestamptz)
language sql stable security definer set search_path='' as $$
  with ids as (
    select distinct i from unnest(p_spot_ids[1:600]) i where i is not null
  ), recent as (
    select s.spot_id,s.user_id,s.device_hash,s.kind,s.created_at
    from public.rider_sightings s join ids on ids.i=s.spot_id
    where s.created_at>now()-interval '30 minutes' and s.created_at<=now()
      and s.kind in ('available','full')
  ), per_user as (
    select distinct on (r.spot_id,r.user_id) r.* from recent r
    order by r.spot_id,r.user_id,r.created_at desc
  ), per_device as (
    select distinct on (p.spot_id,p.device_hash) p.* from per_user p
    order by p.spot_id,p.device_hash,p.created_at desc
  ), weighted as (
    select d.*,public.rider_credibility(d.user_id) w from per_device d
    where not public.rider_suspended(d.user_id)
  ), shares as (
    select w.spot_id,
      sum(w.w) filter (where w.kind='available')/sum(w.w) share,
      max(w.created_at) filter (where w.kind='available') available_at,
      max(w.created_at) filter (where w.kind='full') full_at,
      max(w.created_at) latest,min(w.created_at) oldest
    from weighted w where w.w>=public.rider_min_credibility()
    group by w.spot_id
  )
  select s.spot_id,
    case when s.share>=0.7 then 'available' when s.share<=0.3 then 'full' else 'conflict' end,
    case when s.share>=0.7 then s.available_at when s.share<=0.3 then s.full_at else s.latest end,
    s.oldest
  from shares s
  order by 1;
$$;
revoke all on function public.spot_sightings(text[]) from public;
grant execute on function public.spot_sightings(text[]) to anon,authenticated;

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
  public.rider_score_add(uuid,numeric,numeric,numeric),public.sighting_spot_location(text) from public,anon,authenticated;

create extension if not exists pg_cron;
select cron.schedule('rider-sightings-prune','17 * * * *','select public.rider_sightings_prune()');
