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
select is(jsonb_array_length(api_v1.spot_sightings(array[pg_temp.spot('lot1')])->'sightings'),0,'closed stays out of sightings');

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

-- ===== api_v1 closures =====
-- 'zone or -:riders:c/u:d/u' per row, c for confirmed, d for derived.
create function pg_temp.closures(spot text,minutes integer default 30) returns text language sql stable as $$
  select coalesce(string_agg(coalesce(c->>'zone_id',c->>'segment_id','-')||':'||(c->>'riders')||':'
      ||case when (c->>'confirmed')::boolean then 'c' else 'u' end||case when (c->>'derived')::boolean then 'd' else '' end,
      ',' order by c->>'zone_id',c->>'segment_id'),'none')
  from jsonb_array_elements(api_v1.spot_sightings(array[pg_temp.spot(spot)],minutes)->'closures') c;
$$;
-- A sighting made earlier (the clock is fixed inside the transaction).
create function pg_temp.past(n integer,spot text,ago interval,what text default 'closed',zone text default null,
  segment text default null) returns void language sql as $$
  insert into rider_sightings(user_id,spot_id,kind,level,zone_id,segment_id,vehicle,ip_hash,device_hash,created_at)
  values(pg_temp.uid(n),pg_temp.spot(spot),case when what='closed' then 'closed' else 'level' end,
    case when what='closed' then null else what::smallint end,zone,segment,'scooter',
    repeat(lpad(n::text,4,'0'),16),repeat(lpad(n::text,4,'0'),16),now()-ago);
$$;
create function pg_temp.fresh(name text,spec text) returns void language plpgsql as $$
declare v uuid;
begin
  insert into community_spots(user_id,name,lat,lng,city,space_type,status,parking_zones)
  values('10000000-0000-4000-8000-000000000001',name,25.055,121.522,'臺北市','offStreet','confirmed',spec::jsonb)
  returning id into v;
  insert into fx values(name,v::text);
end $$;
select pg_temp.fresh('c1','[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]');
select pg_temp.fresh('c2','[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]');
select pg_temp.fresh('c3','[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]');
select pg_temp.fresh('c4','[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]');
select pg_temp.fresh('c5','[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]');
select pg_temp.fresh('c6','[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]');

select is(pg_temp.closures('lot2'),'b1:1:u','one rider on one zone: named, not confirmed');
select is(pg_temp.closures('lot3'),'b1:2:c,b2:2:c,-:4:cd','every zone confirmed: a derived whole-spot row, all riders');
select is(pg_temp.closures('lot4'),'-:2:c','the whole spot said directly');
select is(pg_temp.closures('plain'),'-:1:u','a spot without zones');
select is(pg_temp.closures('street'),'north:2:c,south:2:c,-:4:cd','segments the same');
select is(pg_temp.closures('one'),'b1:2:c,-:2:cd','the only zone closed');
select is(jsonb_array_length(api_v1.spot_sightings(array[pg_temp.spot('lot1'),pg_temp.spot('lot1')])->'closures'),2,
  'a repeated id gives its rows once');
select is(pg_temp.closures('lot3',15),pg_temp.closures('lot3',30),'p_window_minutes does not touch closures');
select is((select array_agg(k order by k) from jsonb_object_keys(api_v1.spot_sightings(array[pg_temp.spot('lot2')])->'closures'->0) k),
  array['confirmed','derived','latest_at','riders','segment_id','spot_id','zone_id'],'only these keys: nothing about who');

-- One row per place: a direct whole-spot row takes the derived one in.
select pg_temp.past(201,'c1','100 minutes');
select pg_temp.past(202,'c1','90 minutes',zone=>'b1');
select pg_temp.past(203,'c1','80 minutes',zone=>'b1');
select pg_temp.past(204,'c1','70 minutes',zone=>'b2');
select pg_temp.past(205,'c1','60 minutes',zone=>'b2');
select is(pg_temp.closures('c1'),'b1:3:c,b2:3:c,-:5:c','said directly and derived: one row, not derived, all riders');
select is((select count(*)::integer from jsonb_array_elements(api_v1.spot_sightings(array[pg_temp.spot('c1')])->'closures') c
    where c->>'zone_id' is null and c->>'segment_id' is null),1,'one whole-spot row');
select is((api_v1.spot_sightings(array[pg_temp.spot('c1')])->'closures'->2->>'latest_at')::timestamptz,now()-interval '60 minutes',
  'its latest_at is the newest of them all');
-- The same rider on two places counts once.
select pg_temp.past(206,'c2','50 minutes',zone=>'b1');
select pg_temp.past(206,'c2','40 minutes',zone=>'b2');
select pg_temp.past(207,'c2','30 minutes',zone=>'b1');
select pg_temp.past(207,'c2','20 minutes',zone=>'b2');
select is(pg_temp.closures('c2'),'b1:2:c,b2:2:c,-:2:cd','each rider once in the whole-spot row');
-- A whole-spot rider alone does not make a zone's row.
select pg_temp.past(208,'c3','50 minutes');
select pg_temp.past(209,'c3','40 minutes',zone=>'b1');
select is(pg_temp.closures('c3'),'b1:2:c,-:1:u','the zone counts the whole-spot rider, b2 has no row');

-- Older than the window.
select pg_temp.past(210,'c4','121 minutes',zone=>'b1');
select pg_temp.past(211,'c4','119 minutes',zone=>'b2');
select is(pg_temp.closures('c4'),'b2:1:u','two hours, whatever the request''s window');

-- Taken back by a later credible level: of the same place or the whole spot.
select pg_temp.past(212,'c5','60 minutes',zone=>'b1');
select pg_temp.past(213,'c5','50 minutes',zone=>'b1');
select pg_temp.past(214,'c5','60 minutes',zone=>'b2');
select pg_temp.past(215,'c5','50 minutes',zone=>'b2');
select pg_temp.past(216,'c5','40 minutes','1',zone=>'b1');
select is(pg_temp.closures('c5'),'b2:2:c','a level of b1 takes b1 back, not b2, and the spot is no longer all closed');
select pg_temp.past(217,'c5','30 minutes');
delete from rider_sightings where user_id=pg_temp.uid(217);
select pg_temp.past(218,'c5','30 minutes','0');
select is(pg_temp.closures('c5'),'none','a whole-spot level takes back every zone');
select pg_temp.past(219,'c5','20 minutes',zone=>'b2');
select is(pg_temp.closures('c5'),'b2:1:u','a closed sighting after the level holds');
-- A level before the closed sightings takes nothing back; a low-credit one neither.
select pg_temp.past(220,'c6','70 minutes','2',zone=>'b1');
select pg_temp.past(221,'c6','60 minutes',zone=>'b1');
insert into rider_sighting_scores(user_id,disagree) values(pg_temp.uid(222),10);
select pg_temp.past(222,'c6','50 minutes','0',zone=>'b1');
select is(pg_temp.closures('c6'),'b1:1:u','only a later, credible level takes it back');
-- A level of a part takes back a whole-spot sighting.
select pg_temp.past(223,'c6','40 minutes');
select pg_temp.past(224,'c6','30 minutes','1',zone=>'b2');
select is(pg_temp.closures('c6'),'b1:2:c','the whole spot''s row goes once a part has a level; for b1 the sighting still counts');

-- Suspended and low-credit riders are left out.
insert into rider_sighting_scores(user_id,disagree) values(pg_temp.uid(225),10);
select pg_temp.past(225,'c6','10 minutes',zone=>'b1');
select is(pg_temp.closures('c6'),'b1:2:c','a low-credit rider does not count');

-- A zone removed or renamed: its rows go, and the rest may complete the spot.
update community_spots set parking_zones='[{"id":"b2","name":"B2","access":"heavyOnly"}]' where id=pg_temp.spot('c2')::uuid;
select is(pg_temp.closures('c2'),'b2:2:c,-:2:cd','a removed zone has no row');
update community_spots set parking_zones='[{"id":"b3","name":"B2","access":"heavyOnly"}]' where id=pg_temp.spot('c2')::uuid;
select is(pg_temp.closures('c2'),'none','nor has an old id after a rename, and the new one says nothing');
update community_spots set status='hidden' where id=pg_temp.spot('lot4')::uuid;
select is(pg_temp.closures('lot4'),'none','a hidden spot has none');

-- ===== 權限 =====
grant select on fx to anon,authenticated;
grant execute on function pg_temp.spot(text) to anon,authenticated;
set local role anon;
select lives_ok($$select api_v1.spot_sightings(array[pg_temp.spot('lot3')])$$,'anon reads closures through api_v1');
select throws_ok($$select * from private.rider_closure_summary(array[pg_temp.spot('lot3')])$$,'42501',null,'not the summary itself');
select throws_ok($$select private.sighting_closed_window()$$,'42501',null,'nor the window');
reset role;
set local role authenticated;
select throws_ok($$select * from private.rider_closure_summary(array[pg_temp.spot('lot3')])$$,'42501',null,'nor a signed-in rider');
reset role;
select is((select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace,
    unnest(array['rider_closure_summary','sighting_spot_closed','sighting_closed_window','sighting_closed_min_riders']) f
    where n.nspname='private' and p.proname=f and (has_function_privilege('anon',p.oid,'execute')
      or has_function_privilege('authenticated',p.oid,'execute'))),0,'the private helpers are closed to clients');

select * from finish();
rollback;
