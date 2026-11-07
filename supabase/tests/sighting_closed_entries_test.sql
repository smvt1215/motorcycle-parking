-- 無法停車／施工中 by zone or segment (#189;
-- 202611090600_sighting_closed_entries.sql): ids are checked as for levels,
-- closed stays out of what the app reads, and the whole spot is suggested
-- only once all of it is closed.
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Riders 201–230, signed in with Google, created a month ago.
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
  select ('20000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
  'closed'||n||'@example.test',now()-interval '30 days',now(),false,'{"provider":"google","role":"user"}'::jsonb,'{}'::jsonb
from generate_series(201,230) n;
insert into auth.identities(id,user_id,provider_id,provider,identity_data,created_at,updated_at)
select gen_random_uuid(),pg_temp.uid(n),pg_temp.uid(n)::text,'google',
  jsonb_build_object('sub',pg_temp.uid(n)::text),now(),now()
from generate_series(201,230) n;

-- Lots with zones, street spots with segments, and a plain spot, close
-- together so no sighting is a jump.
create temporary table fx(name text primary key,id text);
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status,parking_zones)
  select '10000000-0000-4000-8000-000000000001',n,25.05+o*0.0003,121.52,'臺北市','offStreet','confirmed',
    '[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]'
  from unnest(array['lot1','lot2','lot3','lot4','lot5','lot6']) with ordinality t(n,o) returning id,name)
insert into fx select name,id::text from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status,parking_zones)
  values('10000000-0000-4000-8000-000000000001','one',25.052,121.521,'臺北市','offStreet','confirmed',
    '[{"id":"b1","name":"B1","access":"scooterOnly"}]') returning id,name)
insert into fx select name,id::text from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status,parking_segments)
  values('10000000-0000-4000-8000-000000000001','street',25.053,121.521,'臺北市','paidMotorcycle','confirmed',
    '[{"id":"north","name":"北側"},{"id":"south","name":"南側"}]') returning id,name)
insert into fx select name,id::text from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status)
  values('10000000-0000-4000-8000-000000000001','plain',25.054,121.521,'臺北市','paidMotorcycle','confirmed') returning id,name)
insert into fx select name,id::text from s;
create function pg_temp.spot(text) returns text language sql stable as $$ select id from fx where name=$1 $$;

-- The Edge Function's call. what is 'closed' or a level.
create function pg_temp.sight(n integer,spot text,what text default 'closed',zone text default null,segment text default null,
  dev text default null) returns jsonb language sql as $$
  select apply_sighting(pg_temp.uid(n),repeat(lpad(n::text,4,'0'),16),repeat(coalesce(dev,lpad(n::text,4,'0')),16),
    pg_temp.spot(spot),case when what='closed' then 'closed' else 'level' end,'scooter',
    case when what='closed' then null else what::smallint end,zone,segment);
$$;
create function pg_temp.queued(spot text) returns integer language sql stable as $$
  select count(*)::integer from moderation_queue where source_id=pg_temp.spot(spot) and field='gone';
$$;

-- ===== 分區、路段 id =====
select is((pg_temp.sight(201,'lot1',zone=>'b1'))->>'accepted','true','closed names a zone of the spot');
select is((select zone_id from rider_sightings where user_id=pg_temp.uid(201)),'b1','and it is kept');
select is((pg_temp.sight(201,'street',segment=>'north'))->>'accepted','true','or a segment of a street spot');
select is((pg_temp.sight(201,'plain'))->>'accepted','true','or neither, for the whole spot');
select throws_ok($$select pg_temp.sight(202,'lot1',zone=>'b9')$$,'22023','area not found','an unknown zone is refused');
select throws_ok($$select pg_temp.sight(202,'lot1',segment=>'north')$$,'22023','area not found','a lot has no segments');
select throws_ok($$select pg_temp.sight(202,'street',zone=>'b1')$$,'22023','area not found','a street spot has no zones');
select throws_ok($$select pg_temp.sight(202,'plain',zone=>'b1')$$,'22023','area not found','nor has a spot without either');
select throws_ok($$select pg_temp.sight(202,'lot1',zone=>'b1',segment=>'north')$$,'22023','invalid sighting','a zone or a segment, not both');
select throws_ok($$insert into rider_sightings(user_id,spot_id,kind,zone_id,segment_id,vehicle,ip_hash,device_hash)
  values(pg_temp.uid(202),pg_temp.spot('lot1'),'closed','b1','north','scooter',repeat('0202',16),repeat('0202',16))$$,
  '23514',null,'the table refuses both as well');

-- ===== 上限與評分 =====
select throws_ok($$select pg_temp.sight(201,'lot1',zone=>'b1')$$,'P0001','spot sighted within 10 minutes','once per zone every 10 minutes');
select throws_ok($$select pg_temp.sight(201,'lot1','2',zone=>'b1')$$,'P0001','spot sighted within 10 minutes','a level of that zone too');
select is((pg_temp.sight(201,'lot1',zone=>'b2'))->>'accepted','true','another zone of the same lot is fine');
select is((select count(*)::integer from rider_sighting_scores where user_id=pg_temp.uid(201) and agree+disagree+penalty>0),0,
  'closed neither scores nor is scored');

-- ===== 回傳不變 =====
select pg_temp.sight(203,'lot2','1',zone=>'b1');
select pg_temp.sight(204,'lot2',zone=>'b1');
select is((select string_agg(coalesce(zone_id,'-')||':'||level,',') from spot_sightings(array[pg_temp.spot('lot2')])),'b1:1',
  'the old read shows the level only');
select is(api_v1.spot_sightings(array[pg_temp.spot('lot2')])->'sightings'->0->>'level','1','and so does api_v1');
select is(jsonb_array_length(api_v1.spot_sightings(array[pg_temp.spot('lot1')])->'sightings'),0,'closed alone shows nothing');

-- ===== 整點只有全部關閉才算 =====
-- lot3: b1 by two riders is not the spot; b2 by two more is.
select is((pg_temp.sight(205,'lot3',zone=>'b1'))->>'closure_suggested','false','one rider on one zone');
select is((pg_temp.sight(206,'lot3',zone=>'b1'))->>'closure_suggested','false','two riders on one zone of two');
select is(pg_temp.queued('lot3'),0,'nothing to review yet');
select is((pg_temp.sight(207,'lot3',zone=>'b2'))->>'closure_suggested','false','one rider on the other');
select is((pg_temp.sight(208,'lot3',zone=>'b2'))->>'closure_suggested','true','two riders on every zone: the whole spot');
select is(pg_temp.queued('lot3'),1,'for review');
select is((select proposed from moderation_queue where source_id=pg_temp.spot('lot3') and field='gone'),
  '{"closure":{"reason":"closed"}}'::jsonb,'as a closure of the spot');
-- lot4: the whole spot's sightings count for every zone.
select is((pg_temp.sight(209,'lot4'))->>'closure_suggested','false','one rider on the whole spot');
select is((pg_temp.sight(210,'lot4'))->>'closure_suggested','true','two on the whole spot, as before');
-- lot5: one whole, then one on each zone.
select pg_temp.sight(211,'lot5');
select is((pg_temp.sight(212,'lot5',zone=>'b1'))->>'closure_suggested','false','b2 has only the whole-spot rider');
select is((pg_temp.sight(213,'lot5',zone=>'b2'))->>'closure_suggested','true','the whole-spot rider counts for each zone');
-- lot6: one rider on each zone is not two; a level anywhere blocks.
select pg_temp.sight(214,'lot6',zone=>'b1');
select is((pg_temp.sight(214,'lot6',zone=>'b2'))->>'closure_suggested','false','the same rider on both zones');
select pg_temp.sight(215,'lot6','1',segment=>null,zone=>null);
select pg_temp.sight(216,'lot6',zone=>'b1');
select is((pg_temp.sight(216,'lot6',zone=>'b2'))->>'closure_suggested','false','a credible level of any part blocks it');
-- A one-zone lot: closed zone, closed spot.
select pg_temp.sight(217,'one',zone=>'b1');
select is((pg_temp.sight(218,'one',zone=>'b1',dev=>'0217'))->>'closure_suggested','false','the same device is one rider');
select is((pg_temp.sight(219,'one',zone=>'b1'))->>'closure_suggested','true','the only zone closed closes the lot');
-- Segments work the same.
select pg_temp.sight(220,'street',segment=>'north');
select pg_temp.sight(221,'street',segment=>'south');
select is((pg_temp.sight(222,'street',segment=>'south'))->>'closure_suggested','true','north by 201 and 220, south by 221 and 222');
select is(pg_temp.queued('street'),1,'one case to review');

select * from finish();
rollback;
