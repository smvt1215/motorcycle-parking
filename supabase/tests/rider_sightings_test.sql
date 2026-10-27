-- Riders' on-site sightings (#154; 202610270160_rider_sightings.sql;
-- decisions 40 and 50): permissions, scoring, the 70% agreement, conflicts,
-- 7-day deletion, the automatic closure suggestion and the flood rules.
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Riders 101–140, signed in with Google, created a month ago.
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
  select ('20000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  'sighting'||n||'@example.test',now()-interval '30 days',now(),false,
  case when n=140 then '{"provider":"google","role":"admin"}' else '{"provider":"google","role":"user"}' end::jsonb,'{}'::jsonb
from generate_series(101,140) n;
insert into auth.identities(id,user_id,provider_id,provider,identity_data,created_at,updated_at)
select gen_random_uuid(),pg_temp.uid(n),pg_temp.uid(n)::text,'google',
  jsonb_build_object('sub',pg_temp.uid(n)::text),now(),now()
from generate_series(101,140) n;
-- An anonymous rider.
insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
values(pg_temp.uid(199),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',null,now(),now(),true,
  '{"provider":"anonymous"}','{}');

-- Spots: Taipei street bays close together, one far away in Kaohsiung,
-- a hidden one, and a Taipei lot with an official count.
create temporary table fx(name text primary key,id text);
grant select on fx to anon,authenticated;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status)
  select '10000000-0000-4000-8000-000000000001','目擊測試'||n,25.05+n*0.0003,121.52,'臺北市','paidMotorcycle','confirmed'
  from generate_series(1,20) n returning id,name)
insert into fx select replace(name,'目擊測試','t'),id::text from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status)
  values('10000000-0000-4000-8000-000000000001','高雄目擊測試',22.63,120.30,'高雄市','paidMotorcycle','confirmed'),
        ('10000000-0000-4000-8000-000000000001','隱藏目擊測試',25.06,121.53,'臺北市','paidMotorcycle','hidden')
  returning id,name)
insert into fx select case when name like '高雄%' then 'far' else 'hidden' end,id::text from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_name,source_url,effective_date,source_id)
  values('目擊官方場站',25.051,121.521,'臺北市','offStreet','臺北市政府','https://example.test/s','2026-01-01','TPSIGHT1')
  returning id)
insert into fx select 'lot','official:'||id from s;
create function pg_temp.spot(text) returns text language sql stable as $$ select id from fx where name=$1 $$;
grant execute on function pg_temp.spot(text) to anon,authenticated;

select availability_store_capacities('taipei_tcmsv','[{"id":"TPSIGHT1","scooter":40,"heavy":4}]');
select availability_ingest('taipei_tcmsv',date_trunc('minute',now())-interval '2 minutes',
  '[{"id":"TPSIGHT1","scooter":15,"heavy":0}]');

-- The Edge Function's call: device and network are keyed hashes.
create function pg_temp.sight(n integer,spot text,kind text,vehicle text default 'scooter',dev text default null,ip text default null)
returns jsonb language sql as $$
  select apply_sighting(pg_temp.uid(n),repeat(coalesce(ip,lpad(n::text,4,'0')),16),
    repeat(coalesce(dev,lpad(n::text,4,'0')),16),pg_temp.spot(spot),kind,vehicle);
$$;
-- A sighting made earlier (the clock is fixed inside the transaction).
create function pg_temp.past(n integer,spot text,kind text,ago interval,dev text default null)
returns void language sql as $$
  insert into rider_sightings(user_id,spot_id,kind,vehicle,ip_hash,device_hash,created_at)
  values(pg_temp.uid(n),pg_temp.spot(spot),kind,'scooter',repeat(lpad(n::text,4,'0'),16),
    repeat(coalesce(dev,lpad(n::text,4,'0')),16),now()-ago);
$$;
create function pg_temp.shown(spot text) returns text language sql stable as $$
  select coalesce((select state from spot_sightings(array[pg_temp.spot(spot)])),'none');
$$;
grant execute on function pg_temp.shown(text) to anon,authenticated;
create function pg_temp.cred(n integer) returns numeric language sql stable as $$
  select round(rider_credibility(pg_temp.uid(n)),3);
$$;

-- ===== 權限 =====
select pg_temp.sight(101,'t1','available');
set local role anon;
select throws_ok($$select * from rider_sightings$$,'42501',null,'anon cannot read sightings');
select throws_ok($$select * from rider_sighting_scores$$,'42501',null,'anon cannot read scores');
select throws_ok($$select apply_sighting('20000000-0000-4000-8000-000000000101',repeat('a',64),repeat('a',64),'x','available','scooter')$$,
  '42501',null,'anon cannot write a sighting');
select throws_ok($$select rider_sightings_prune()$$,'42501',null,'anon cannot prune');
select is(pg_temp.shown('t1'),'available','anyone reads the per-spot result');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"20000000-0000-4000-8000-000000000102","role":"authenticated"}',true);
select is((select count(*)::integer from rider_sightings),0,'a rider cannot read another rider''s sightings');
select throws_ok($$insert into rider_sightings(user_id,spot_id,kind,vehicle,ip_hash,device_hash)
  values('20000000-0000-4000-8000-000000000102','00000000-0000-4000-8000-000000000001','full','scooter',repeat('a',64),repeat('a',64))$$,
  '42501',null,'nor write one directly');
select throws_ok($$select apply_sighting('20000000-0000-4000-8000-000000000102',repeat('a',64),repeat('a',64),'x','full','scooter')$$,
  '42501',null,'nor call the write function');
select throws_ok($$select ip_hash from rider_sightings$$,'42501',null,'nor read network hashes, even their own');
select is(pg_temp.shown('t1'),'available','but reads the per-spot result');
select set_config('request.jwt.claims','{"sub":"20000000-0000-4000-8000-000000000101","role":"authenticated"}',true);
select is((select count(*)::integer from rider_sightings),1,'a rider reads their own sighting');
reset role;
select is((select string_agg(a,',' order by a) from unnest(
  (select proargnames from pg_proc where proname='spot_sightings')) a where a not like 'p\_%'),
  'latest_at,since,spot_id,state','the result has no rider, no device and no single sighting');

-- ===== 回報與限流 =====
select throws_ok($$select apply_sighting('20000000-0000-4000-8000-000000000199',repeat('a',64),repeat('a',64),pg_temp.spot('t2'),'full','scooter')$$,
  '42501','Google or Apple sign-in required','an anonymous rider cannot report');
select throws_ok($$select pg_temp.sight(102,'hidden','full')$$,'22023','spot not found','a hidden spot cannot be sighted');
select throws_ok($$select apply_sighting('20000000-0000-4000-8000-000000000102',repeat('a',64),repeat('a',64),'not-a-spot','full','scooter')$$,
  '22023','spot not found','nor an unknown one');
select throws_ok($$select pg_temp.sight(102,'t2','gone')$$,'22023','invalid sighting','only the three kinds');
select throws_ok($$select pg_temp.sight(102,'t2','full','car')$$,'22023','invalid sighting','scooter or heavy only');
select throws_ok($$select apply_sighting('20000000-0000-4000-8000-000000000102','short',repeat('a',64),pg_temp.spot('t2'),'full','scooter')$$,
  '22023','missing trusted identity','hashed identities are required');
select throws_ok($$select pg_temp.sight(101,'t1','full')$$,'P0001','spot sighted within 10 minutes',
  'the same rider, the same spot: once per 10 minutes');
select is((select count(*)::integer from rider_sightings where user_id=pg_temp.uid(101)),1,'nothing stored when refused');
-- 30 a day per account (UTC day).
insert into rider_sightings(user_id,spot_id,kind,vehicle,ip_hash,device_hash,created_at)
select pg_temp.uid(103),'00000000-0000-4000-8000-'||lpad(n::text,12,'0'),'available','scooter',repeat('0103',16),repeat('0103',16),
  greatest(date_trunc('day',now() at time zone 'UTC') at time zone 'UTC',now()-interval '20 minutes')
from generate_series(1,30) n;
select throws_ok($$select pg_temp.sight(103,'t3','full')$$,'P0001','daily sighting limit reached','30 sightings a day per account');
-- 100 a day per network.
insert into rider_sightings(user_id,spot_id,kind,vehicle,ip_hash,device_hash,created_at)
select pg_temp.uid(104),'00000000-0000-4000-8000-'||lpad(n::text,12,'0'),'available','scooter',repeat('beef',16),repeat('0104',16),
  greatest(date_trunc('day',now() at time zone 'UTC') at time zone 'UTC',now()-interval '20 minutes')
from generate_series(1,100) n;
select throws_ok($$select pg_temp.sight(105,'t3','full',ip=>'beef')$$,'P0001','daily sighting limit reached','100 a day per network');
delete from rider_sightings where user_id in (pg_temp.uid(103),pg_temp.uid(104));

-- ===== 規則評分：官方即時資料 =====
select pg_temp.sight(106,'lot','full');
select is((select official from rider_sightings where user_id=pg_temp.uid(106)),'available',
  'the official count at that moment is kept (15 of 40 free)');
select is(pg_temp.cred(106),round(2/5.0,3),'停滿 against 15 free official spaces: one disagreement');
select pg_temp.sight(107,'lot','available');
select is(pg_temp.cred(107),round(3/5.0,3),'有空位 with 15 free: one agreement');
select pg_temp.sight(108,'lot','full','heavy');
select is(pg_temp.cred(108),round(3/5.0,3),'compared with the rider''s own vehicle (heavy 0 = full)');
-- The rider who said 停滿 at the lot was judged by 107's later 有空位 too.
select is((select disagree from rider_sighting_scores where user_id=pg_temp.uid(106)),1+0.6,
  'a later rider''s sighting judges an earlier one by the later rider''s credibility');

-- ===== 規則評分：後續目擊 =====
select pg_temp.past(109,'t4','available','5 minutes');
select pg_temp.past(110,'t4','full','8 minutes');
select pg_temp.past(111,'t4','available','15 minutes');
select pg_temp.sight(112,'t4','available');
select is((select agree from rider_sighting_scores where user_id=pg_temp.uid(109)),0.5,'an earlier match within 10 minutes agrees');
select is((select disagree from rider_sighting_scores where user_id=pg_temp.uid(110)),0.5,'an earlier mismatch disagrees');
select ok(not exists(select 1 from rider_sighting_scores where user_id=pg_temp.uid(111)),
  'a sighting older than 10 minutes is not judged (spaces change)');
select is((select agree+disagree from rider_sighting_scores where user_id=pg_temp.uid(112)),null,
  'the later rider is not judged by the earlier ones');
-- A rider below the bar judges nobody.
insert into rider_sighting_scores(user_id,disagree) values(pg_temp.uid(113),20);
select pg_temp.past(114,'t5','available','3 minutes');
select pg_temp.sight(113,'t5','full');
select ok(not exists(select 1 from rider_sighting_scores where user_id=pg_temp.uid(114)),'a low-scored rider judges nobody');
-- The same device under another account is not an independent judge.
select pg_temp.past(115,'t6','available','3 minutes','dddd');
select pg_temp.sight(116,'t6','full',dev=>'dddd');
select ok(not exists(select 1 from rider_sighting_scores where user_id=pg_temp.uid(115)),'nor the same device');

-- ===== 加權門檻與衝突 =====
-- 7 against 3 at equal weight: exactly 70% shows 有空位.
select pg_temp.past(n,'t7',case when n<=107+7 then 'available' else 'full' end,'5 minutes') from generate_series(108,117) n;
delete from rider_sighting_scores;
select is(pg_temp.shown('t7'),'available','70% agreement shows 有空位');
select pg_temp.past(n,'t8',case when n<=113 then 'available' else 'full' end,'5 minutes') from generate_series(108,116) n;
select is(pg_temp.shown('t8'),'conflict','6 against 3 (67%) is 近期回報不一致');
select pg_temp.past(n,'t9',case when n=108 then 'available' else 'full' end,'5 minutes') from generate_series(108,111) n;
select is(pg_temp.shown('t9'),'full','1 against 3 shows 停滿');
-- Weighted by credibility: 2 trusted riders against 1 new one (equal
-- weights would be 67%, a conflict).
insert into rider_sighting_scores(user_id,agree) values(pg_temp.uid(120),26),(pg_temp.uid(121),26);
select pg_temp.past(120,'t10','available','4 minutes');
select pg_temp.past(121,'t10','available','6 minutes');
select pg_temp.past(122,'t10','full','2 minutes');
select is(pg_temp.shown('t10'),'available','trusted riders weigh more');
select is((select latest_at from spot_sightings(array[pg_temp.spot('t10')])),now()-interval '4 minutes',
  'the time shown is the newest sighting behind the state');
select is((select since from spot_sightings(array[pg_temp.spot('t10')])),now()-interval '6 minutes',
  'and since when riders reported');
-- Low scores are not shown.
insert into rider_sighting_scores(user_id,disagree) values(pg_temp.uid(123),3);
select pg_temp.past(123,'t11','full','2 minutes');
select is(pg_temp.shown('t11'),'none','a rider below 0.3 is not shown');
select pg_temp.past(124,'t11','available','5 minutes');
select is(pg_temp.shown('t11'),'available','nor weighed against others');
-- One rider counts once (their latest), and so does one device.
select pg_temp.past(125,'t12','full','25 minutes');
select pg_temp.past(125,'t12','available','3 minutes');
select is(pg_temp.shown('t12'),'available','a rider''s latest sighting stands');
select pg_temp.past(126,'t13','available','3 minutes','eeee');
select pg_temp.past(127,'t13','full','4 minutes','eeee');
select pg_temp.past(128,'t13','full','5 minutes','eeee');
select pg_temp.past(129,'t13','available','6 minutes');
select is(pg_temp.shown('t13'),'available','three accounts on one device count once');
-- 30 minutes, then nothing; 無法停車 is not a space state.
select pg_temp.past(130,'t14','available','31 minutes');
select is(pg_temp.shown('t14'),'none','older than 30 minutes is not shown');
select pg_temp.past(130,'t15','closed','2 minutes');
select is(pg_temp.shown('t15'),'none','無法停車／施工中 never shows as a space state');
select is((select count(*)::integer from spot_sightings(array[pg_temp.spot('t7'),pg_temp.spot('t9'),pg_temp.spot('t14')])),2,
  'one row per spot with recent sightings');

-- ===== 7 天刪除 =====
select pg_temp.past(131,'t16','available','8 days');
select pg_temp.past(131,'t17','available','6 days');
select cmp_ok(rider_sightings_prune(),'>=',1,'the prune removes old rows');
select is((select count(*)::integer from rider_sightings where user_id=pg_temp.uid(131)),1,
  'older than 7 days deleted, newer kept');
select ok(exists(select 1 from cron.job where jobname='rider-sightings-prune'),'and runs on a schedule');

-- ===== 自動暫時封閉建議 =====
select pg_temp.past(132,'t18','closed','90 minutes');
select is((pg_temp.sight(133,'t18','closed'))->>'closure_suggested','true','2 riders within 2 hours: a closure suggestion');
select is((select proposed from moderation_queue where source_id=pg_temp.spot('t18') and resolved_at is null),
  '{"closure":{"reason":"closed"}}'::jsonb,'proposed as a temporary closure for review (#116)');
select is((select field||'/'||status||'/'||coalesce(reporter_id::text,'-') from moderation_queue where source_id=pg_temp.spot('t18')),
  'gone/pending/-','held for an admin, from no single rider');
select is((pg_temp.sight(134,'t18','closed'))->>'closure_suggested','false','an open suggestion is not repeated');
-- Somebody saw spaces or a full bay: no suggestion.
select pg_temp.past(132,'t19','closed','60 minutes');
select pg_temp.past(135,'t19','full','30 minutes');
select is((pg_temp.sight(133,'t19','closed'))->>'closure_suggested','false','a contrary sighting blocks it');
-- One rider twice, or two accounts on one device, are not two riders.
select pg_temp.past(136,'t17','closed','150 minutes');
select is((pg_temp.sight(139,'t17','closed'))->>'closure_suggested','false','older than 2 hours does not count');
select pg_temp.past(137,'t20','closed','30 minutes','ffff');
select is((pg_temp.sight(138,'t20','closed',dev=>'ffff'))->>'closure_suggested','false','the same device is one rider');

-- ===== 洗版 =====
delete from rider_sightings;
delete from rider_sighting_scores;
-- 6 in 10 minutes: weight lowered.
select pg_temp.past(101,'t'||n,'available',(n||' minutes')::interval) from generate_series(1,5) n;
select is((pg_temp.sight(101,'t6','available'))->>'suspended_until',null,'6 in 10 minutes is not suspended');
select is((select penalty from rider_sighting_scores where user_id=pg_temp.uid(101)),1::numeric,'but weighs less (降權)');
-- 12 in 10 minutes: suspended 7 days.
select pg_temp.past(102,'t'||n,'available',(n*40||' seconds')::interval) from generate_series(1,11) n;
select ok(((pg_temp.sight(102,'t12','available'))->>'suspended_until')::timestamptz=now()+interval '7 days',
  '12 in 10 minutes: suspended for 7 days');
select throws_ok($$select pg_temp.sight(102,'t13','available')$$,'42501','sighting suspended','a suspended rider cannot report');
select pg_temp.past(139,'t14','available','2 minutes');
select pg_temp.past(102,'t14','full','1 minute');
select is(pg_temp.shown('t14'),'available','nor is shown');
-- Taipei to Kaohsiung in a minute: a jump lowers the weight; three in a
-- day suspend.
select pg_temp.past(103,'t1','available','1 minute');
select pg_temp.sight(103,'far','available');
select is((select jump from rider_sightings where user_id=pg_temp.uid(103) and spot_id=pg_temp.spot('far')),true,'an impossible jump is noted');
select is((select penalty from rider_sighting_scores where user_id=pg_temp.uid(103)),1::numeric,'and lowers the weight');
insert into rider_sightings(user_id,spot_id,kind,vehicle,ip_hash,device_hash,jump,created_at)
values(pg_temp.uid(104),pg_temp.spot('t2'),'available','scooter',repeat('0104',16),repeat('0104',16),true,now()-interval '5 hours'),
      (pg_temp.uid(104),pg_temp.spot('far'),'available','scooter',repeat('0104',16),repeat('0104',16),true,now()-interval '3 hours');
select pg_temp.past(104,'t3','available','1 minute');
-- That last one was in Taipei a minute ago; Kaohsiung now is the third jump.
select pg_temp.sight(104,'far','full');
select ok(exists(select 1 from rider_sighting_scores where user_id=pg_temp.uid(104) and suspended_until>now()),
  'three jumps in 24 hours: suspended');
-- A walk between nearby bays is no jump.
select pg_temp.past(105,'t1','available','1 minute');
select pg_temp.sight(105,'t20','available');
select is((select jump from rider_sightings where user_id=pg_temp.uid(105) and spot_id=pg_temp.spot('t20')),false,
  'nearby spots a minute apart are fine');
-- An admin is only lowered, never suspended here.
select pg_temp.past(140,'t'||n,'available',(n*40||' seconds')::interval) from generate_series(1,11) n;
select is((pg_temp.sight(140,'t12','available'))->>'suspended_until',null,'an admin is not suspended');
-- An account an admin banned cannot report either.
update auth.users set banned_until=now()+interval '1 day' where id=pg_temp.uid(106);
select throws_ok($$select pg_temp.sight(106,'t1','available')$$,'42501','sighting suspended','a banned account cannot report');

select * from finish();
rollback;
