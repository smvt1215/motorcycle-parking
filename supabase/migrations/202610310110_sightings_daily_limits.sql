-- 騎士回報的每日上限改依 App Check 階段（#203，使用者 2026-10-31）：
--
-- 1. The day resets at midnight in Taiwan, not UTC.
-- 2. 30 sightings a day per account, as before.
-- 3. Per network 200 a day while App Check only logs; the Edge Function
--    passes p_ip_capped=false once it enforces App Check, and then a
--    network past 200 is a risk signal: the sighting is kept, marked
--    ip_busy, and lowers the rider's weight like the flood rules.
-- Networks are only ever stored as keyed hashes (ip_hash).

alter table public.rider_sightings add column ip_busy boolean not null default false;
comment on column public.rider_sightings.ip_busy is
  '送出時同一網路當日已逾 200 筆（App Check 強制後的風險訊號，#203）。';

drop function public.apply_sighting(uuid,text,text,text,text,text,smallint,text,text);
create function public.apply_sighting(p_user uuid,p_ip text,p_device text,p_spot text,p_kind text,
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
revoke all on function public.apply_sighting(uuid,text,text,text,text,text,smallint,text,text,boolean) from public,anon,authenticated;
grant execute on function public.apply_sighting(uuid,text,text,text,text,text,smallint,text,text,boolean) to service_role;
