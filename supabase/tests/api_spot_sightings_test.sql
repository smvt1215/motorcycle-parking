-- api_v1.spot_sightings (#189; 202611090100_api_spot_sightings.sql): the time
-- window, the limits, the id formats, one row per spot, zone or segment and
-- vehicle, count and 說法不一, and public.spot_sightings left as it was.
-- Levels: 0 很多空位, 1 還有一些, 2 快滿了, 3 已停滿.
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Riders 101–120, signed in with Google, created a month ago.
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
  select ('21000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  'api-sighting'||n||'@example.test',now()-interval '30 days',now(),false,
  '{"provider":"google","role":"user"}'::jsonb,'{}'::jsonb
from generate_series(101,120) n;
insert into auth.identities(id,user_id,provider_id,provider,identity_data,created_at,updated_at)
select gen_random_uuid(),pg_temp.uid(n),pg_temp.uid(n)::text,'google',
  jsonb_build_object('sub',pg_temp.uid(n)::text),now(),now()
from generate_series(101,120) n;

-- Spots 1–5 are community spots; 6 is official.
create function pg_temp.spot(n integer) returns text language sql immutable as $$
  select '7b000000-0000-4000-8000-00000000000'||n;
$$;
grant execute on function pg_temp.spot(integer) to anon,authenticated;
insert into community_spots(id,user_id,name,lat,lng,city,space_type,status)
select pg_temp.spot(n)::uuid,'10000000-0000-4000-8000-000000000001','API 目擊測試'||n,25.05+n*0.0003,121.52,'臺北市','paidMotorcycle','confirmed'
from generate_series(1,3) n;
insert into community_spots(id,user_id,name,lat,lng,city,space_type,parking_zones)
values(pg_temp.spot(4)::uuid,'10000000-0000-4000-8000-000000000001','API 目擊分區測試',25.0505,121.5205,'臺北市','offStreet',
  '[{"id":"b1","name":"B1","area":"motorcycle"},{"id":"b2","name":"B2","area":"heavy"}]');
insert into community_spots(id,user_id,name,lat,lng,city,space_type,condition,parking_segments)
values(pg_temp.spot(5)::uuid,'10000000-0000-4000-8000-000000000001','API 目擊路段測試',25.0506,121.5206,'臺北市','paidMotorcycle',
  '{"bay":"motorcycle","use":"usual","charge":"toll"}',
  '[{"id":"north","name":"北側","side":"north"},{"id":"south","name":"南側","side":"south"}]');
insert into official_heavy_spots(id,name,lat,lng,city,space_type,source_name,source_url,effective_date)
values(pg_temp.spot(6)::uuid,'API 目擊官方',25.051,121.521,'臺北市','offStreet','臺北市政府','https://example.test/s','2026-01-01');

create function pg_temp.past(n integer,spot text,level integer,ago interval,dev text default null,
  vehicle text default 'scooter',zone text default null,segment text default null)
returns void language sql as $$
  insert into rider_sightings(user_id,spot_id,kind,level,zone_id,segment_id,vehicle,ip_hash,device_hash,created_at)
  values(pg_temp.uid(n),spot,'level',level,zone,segment,vehicle,
    repeat(lpad(n::text,4,'0'),16),repeat(coalesce(dev,lpad(n::text,4,'0')),16),now()-ago);
$$;
-- The rows for ids, as 'zone/segment/vehicle:level:count' in response order.
create function pg_temp.rows(ids text[],mins integer default 30) returns text language sql stable as $$
  select string_agg(coalesce(e->>'zone_id','-')||'/'||coalesce(e->>'segment_id','-')||'/'||(e->>'vehicle')||':'||
    (e->>'level')||':'||(e->>'count'),',' order by n)
  from jsonb_array_elements(api_v1.spot_sightings(ids,mins)->'sightings') with ordinality x(e,n);
$$;
grant execute on function pg_temp.rows(text[],integer) to anon,authenticated;

-- ===== 權限 =====
select ok(has_function_privilege('anon','api_v1.spot_sightings(text[],integer)','execute'),'anon can call it');
select ok(has_function_privilege('authenticated','api_v1.spot_sightings(text[],integer)','execute'),'authenticated can call it');
select ok(not has_function_privilege('anon','private.rider_sighting_summary(text[],integer)','execute'),'the helper is not for clients');
select ok(not has_function_privilege('authenticated','private.rider_sighting_summary(text[],integer)','execute'),'for no client');
select ok((select prosecdef and proconfig=array['search_path=""'] from pg_proc where oid='api_v1.spot_sightings(text[],integer)'::regprocedure),
  'security definer with an empty search_path');

-- ===== 時間窗 =====
select pg_temp.past(101,pg_temp.spot(1),0,'20 minutes');
select pg_temp.past(102,pg_temp.spot(1),0,'5 minutes');
select pg_temp.past(103,pg_temp.spot(2),3,'20 minutes');
select pg_temp.past(104,pg_temp.spot(3),3,'31 minutes');
select pg_temp.past(105,pg_temp.spot(3),3,'14 minutes 59 seconds');
set local role anon;
select is(pg_temp.rows(array[pg_temp.spot(1)],30),'-/-/scooter:0:2','30 minutes takes both riders');
select is(pg_temp.rows(array[pg_temp.spot(1)],15),'-/-/scooter:0:1','15 minutes only the recent one');
select is(pg_temp.rows(array[pg_temp.spot(2)],15),null,'a spot with nothing recent has no row');
select is(pg_temp.rows(array[pg_temp.spot(2)],30),'-/-/scooter:3:1','which 30 minutes has');
select is(pg_temp.rows(array[pg_temp.spot(3)],30),'-/-/scooter:3:1','older than 30 minutes is left out');
select is(pg_temp.rows(array[pg_temp.spot(3)],15),'-/-/scooter:3:1','as is a sighting inside 15 minutes kept');
select is(api_v1.spot_sightings(array[pg_temp.spot(1)]),api_v1.spot_sightings(array[pg_temp.spot(1)],30),'the default is 30');
select is((select e->>'latest_at' from jsonb_array_elements(api_v1.spot_sightings(array[pg_temp.spot(1)])->'sightings') e),
  to_jsonb(now()-interval '5 minutes')#>>'{}','latest_at is the newest sighting');
select throws_ok($$select api_v1.spot_sightings('{}',0)$$,'PT400','request.invalid','0 minutes is refused');
select throws_ok($$select api_v1.spot_sightings('{}',14)$$,'PT400','request.invalid','as is 14');
select throws_ok($$select api_v1.spot_sightings('{}',60)$$,'PT400','request.invalid','as is 60');
select throws_ok($$select api_v1.spot_sightings('{}',-15)$$,'PT400','request.invalid','as is a negative window');
select throws_ok($$select api_v1.spot_sightings('{}',null)$$,'PT400','request.invalid','as is null');

-- ===== id =====
select is(api_v1.spot_sightings('{}'),'{"sightings":[]}'::jsonb,'no ids, no rows');
select is(api_v1.spot_sightings(null),'{"sightings":[]}'::jsonb,'null is none');
select is(jsonb_array_length(api_v1.spot_sightings((select array_agg(gen_random_uuid()::text) from generate_series(1,600)))->'sightings'),0,
  '600 ids are allowed');
select throws_ok($$select api_v1.spot_sightings((select array_agg(gen_random_uuid()::text) from generate_series(1,601)))$$,
  'PT400','request.too_many_ids','601 are not');
select is(api_v1.spot_sightings(array['nope','tdx:Taipei:1','official:nope','',null,'7b000000-0000-4000-8000']),
  '{"sightings":[]}'::jsonb,'ids of another format are skipped, as spots_by_ids does');
select is(pg_temp.rows(array['nope',pg_temp.spot(1)]),'-/-/scooter:0:2','without affecting the good ones');
select is(pg_temp.rows(array[pg_temp.spot(1),pg_temp.spot(1),upper(pg_temp.spot(1))]),'-/-/scooter:0:2',
  'a repeated id, in either case, comes back once');
reset role;
select pg_temp.past(106,'official:'||pg_temp.spot(6),1,'3 minutes',vehicle=>'heavy');
set local role anon;
select is((select e->>'spot_id' from jsonb_array_elements(api_v1.spot_sightings(array['OFFICIAL:'||pg_temp.spot(6)])->'sightings') e),
  'official:'||pg_temp.spot(6),'official ids work and keep their prefix');
reset role;

-- ===== 分區、路段、車種分開彙整 =====
select pg_temp.past(107,pg_temp.spot(4),0,'3 minutes',zone=>'b1');
select pg_temp.past(108,pg_temp.spot(4),3,'3 minutes',zone=>'b2');
select pg_temp.past(109,pg_temp.spot(4),2,'3 minutes');
select pg_temp.past(110,pg_temp.spot(4),1,'3 minutes',zone=>'b2',vehicle=>'heavy');
select pg_temp.past(111,pg_temp.spot(5),1,'3 minutes',segment=>'north');
select pg_temp.past(112,pg_temp.spot(5),2,'3 minutes',segment=>'south');
set local role anon;
select is(pg_temp.rows(array[pg_temp.spot(4)]),'b1/-/scooter:0:1,b2/-/heavy:1:1,b2/-/scooter:3:1,-/-/scooter:2:1',
  'each zone and each vehicle has its own row, the whole spot too');
select is(pg_temp.rows(array[pg_temp.spot(5)]),'-/north/scooter:1:1,-/south/scooter:2:1','each segment has its own row');
select is((select array_agg(k order by k) from jsonb_array_elements(api_v1.spot_sightings(array[pg_temp.spot(4)])->'sightings') e,jsonb_object_keys(e) k
    where e->>'zone_id'='b1'),
  array['conflicting','count','high','high_riders','latest_at','level','low','low_riders','segment_id','spot_id','vehicle','zone_id'],
  'the row has these keys and no rider, device or single sighting');
select ok((select bool_and(e ? 'segment_id' and e->'segment_id'='null'::jsonb) from jsonb_array_elements(api_v1.spot_sightings(array[pg_temp.spot(4)])->'sightings') e),
  'a key without a value is null, not missing');
select is((select string_agg(e->>'spot_id',',' order by n) from jsonb_array_elements(api_v1.spot_sightings(array[pg_temp.spot(5),pg_temp.spot(1)])->'sightings') with ordinality x(e,n)),
  pg_temp.spot(1)||','||pg_temp.spot(5)||','||pg_temp.spot(5),'rows come in spot order');
reset role;

-- ===== 說法不一與人數 =====
delete from rider_sightings;
select pg_temp.past(n,pg_temp.spot(1),case when n<=106 then 0 else 3 end,'5 minutes') from generate_series(101,109) n;
select pg_temp.past(n,pg_temp.spot(2),case when n=101 then 0 else 1 end,'5 minutes') from generate_series(101,105) n;
set local role anon;
create temporary table conflict as select api_v1.spot_sightings(array[pg_temp.spot(1),pg_temp.spot(2)]) r;
select is((select string_agg((e->>'conflicting')||':'||(e->>'level')||':'||(e->>'count'),',' order by e->>'spot_id') from conflict,jsonb_array_elements(r->'sightings') e),
  'true:0:9,false:1:5','6 against 3 is 說法不一 with the weighted median; neighbouring levels agree');
select is((select e->>'low'||'/'||(e->>'high')||'/'||(e->>'low_riders')||'/'||(e->>'high_riders') from conflict,jsonb_array_elements(r->'sightings') e
    where (e->>'conflicting')::boolean),'0/3/6/3','說法不一 gives both extremes and how many riders said each');
select is((select e->>'low'||'/'||(e->>'high')||'/'||(e->>'low_riders')||'/'||(e->>'high_riders') from conflict,jsonb_array_elements(r->'sightings') e
    where not (e->>'conflicting')::boolean),'0/1/1/4','so does a row without a dispute');
reset role;
drop table conflict;
-- Each rider and each device counts once; those left out are not counted.
select pg_temp.past(110,pg_temp.spot(3),3,'25 minutes');
select pg_temp.past(110,pg_temp.spot(3),0,'3 minutes');
select pg_temp.past(111,pg_temp.spot(3),0,'3 minutes','eeee');
select pg_temp.past(112,pg_temp.spot(3),3,'4 minutes','eeee');
insert into rider_sighting_scores(user_id,disagree) values(pg_temp.uid(113),3);
select pg_temp.past(113,pg_temp.spot(3),3,'2 minutes');
select is(pg_temp.rows(array[pg_temp.spot(3)]),'-/-/scooter:0:2','count is riders summed up, not sightings');
-- With the same riders, what the old App reads and this answer agree.
select is((select string_agg(state||':'||level,',' order by spot_id) from public.spot_sightings(array[pg_temp.spot(1),pg_temp.spot(2)])),
  'conflict:0,level:1','public.spot_sightings reads the same result');

-- ===== public.spot_sightings 不變 =====
delete from rider_sightings;
select pg_temp.past(101,pg_temp.spot(1),0,'20 minutes');
select pg_temp.past(102,pg_temp.spot(2),0,'31 minutes');
select is((select string_agg(spot_id,',') from public.spot_sightings(array[pg_temp.spot(1),pg_temp.spot(2)])),pg_temp.spot(1),
  'it stays at 30 minutes');
select is((select count(*)::integer from public.spot_sightings(array_fill('nope'::text,array[700])||array[pg_temp.spot(1)])),0,
  'and takes the first 600 ids without an error');
select is((select count(*)::integer from public.spot_sightings(array[pg_temp.spot(1)]||array_fill('nope'::text,array[700]))),1,
  'whatever follows them');

select * from finish();
rollback;
