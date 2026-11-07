-- #189：api_v1.spot_sightings。App 改走統一 API 後讀不到 public 函式，這裡
-- 提供有版本的讀取入口，並把時間窗改成參數：地圖 15 分、詳情 30 分。
--
-- 彙整本體移到 private.rider_sighting_summary()，public.spot_sightings() 與
-- api_v1 共用同一份規則。舊版 App 呼叫的 public 版本維持 30 分鐘、最多取前
-- 600 個 id、回傳欄位不變。

-- Per spot of p_spot_ids, zone or segment (both null for the whole spot) and
-- vehicle, with a level sighting in the last p_window_minutes. The columns
-- and rules are those of 202610310100_rider_sightings.sql section 4; riders
-- is how many riders the row sums up (each rider and each device once, the
-- left out not counted). Callers bound p_spot_ids.
create function private.rider_sighting_summary(p_spot_ids text[],p_window_minutes integer)
returns table(spot_id text,zone_id text,segment_id text,vehicle text,state text,level smallint,
  low smallint,high smallint,low_riders integer,high_riders integer,latest_at timestamptz,since timestamptz,
  riders integer)
language sql stable security definer set search_path='' as $$
  with ids as (
    select distinct lower(i) i from unnest(p_spot_ids) i where i is not null
  ), recent as (
    select s.spot_id,s.zone_id,s.segment_id,s.vehicle,s.user_id,s.device_hash,s.level,s.created_at
    from public.rider_sightings s join ids on ids.i=s.spot_id
    where s.created_at>now()-make_interval(mins=>p_window_minutes) and s.created_at<=now() and s.kind='level'
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
      max(s.created_at) latest,min(s.created_at) oldest,
      count(distinct s.user_id) riders
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
    g.latest,g.oldest,g.riders::integer
  from groups g
  order by 1,2,3,4;
$$;
revoke all on function private.rider_sighting_summary(text[],integer) from public,anon,authenticated;

-- 舊版 App：行為不變，規則改由上面的函式提供。
create or replace function public.spot_sightings(p_spot_ids text[])
returns table(spot_id text,zone_id text,segment_id text,vehicle text,state text,level smallint,
  low smallint,high smallint,low_riders integer,high_riders integer,latest_at timestamptz,since timestamptz)
language sql stable security definer set search_path='' as $$
  select s.spot_id,s.zone_id,s.segment_id,s.vehicle,s.state,s.level,s.low,s.high,s.low_riders,s.high_riders,
    s.latest_at,s.since
  from private.rider_sighting_summary(p_spot_ids[1:600],30) s
  order by 1,2,3,4;
$$;

-- security definer：rider_sightings 不開放 anon 讀取，彙整結果才是公開內容。
-- level 的刻度同 rider_sightings：0 很多空位、1 還有一些、2 快滿了、3 已停滿。
-- level 是加權中位數；說法不一時 App 依 low、high、low_riders、high_riders 顯示兩端。
-- 格式不符的 id（例如舊版 tdx: 收藏）同 spots_by_ids，略過不報錯。
create function api_v1.spot_sightings(p_spot_ids text[],p_window_minutes integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_window_minutes is null or p_window_minutes not in (15, 30) then
    raise sqlstate 'PT400' using message = 'request.invalid', detail = '{"field":"p_window_minutes"}';
  end if;
  if coalesce(cardinality(p_spot_ids), 0) > 600 then
    raise sqlstate 'PT400' using message = 'request.too_many_ids', detail = '{"limit":600}';
  end if;
  return jsonb_build_object('sightings', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'spot_id', s.spot_id, 'zone_id', s.zone_id, 'segment_id', s.segment_id, 'vehicle', s.vehicle,
        'level', s.level, 'count', s.riders, 'low', s.low, 'high', s.high,
        'low_riders', s.low_riders, 'high_riders', s.high_riders,
        'latest_at', s.latest_at, 'conflicting', s.state = 'conflict'
      ) order by s.spot_id, s.zone_id, s.segment_id, s.vehicle), '[]'::jsonb)
    from private.rider_sighting_summary(array(
      select i from unnest(p_spot_ids) i
      where i ~* '^(official:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ), p_window_minutes) s
  ));
end;
$$;
revoke execute on function api_v1.spot_sightings(text[],integer) from public;
grant execute on function api_v1.spot_sightings(text[],integer) to anon, authenticated, service_role;
