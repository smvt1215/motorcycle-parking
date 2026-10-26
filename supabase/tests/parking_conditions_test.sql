begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- 202610270010_parking_conditions.sql: condition and zones_complete, their
-- checks, viewport v3 and the projection older builds get.

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;

-- Bounds around every fixture below.
create function pg_temp.v(fn text) returns setof jsonb language plpgsql as $$
begin return query execute format('select to_jsonb(r) from public.%I(25.20,121.40,25.30,121.50) r',fn); end;
$$;
grant execute on function pg_temp.v(text) to anon,authenticated;

create temporary table fx(name text primary key,id uuid);
grant select on fx to anon,authenticated;
create function pg_temp.c(p_name text,p_space text,p_condition jsonb,p_extra jsonb default '{}') returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into community_spots(user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,condition,
      facility_type,parking_zones,zones_complete)
    select '10000000-0000-4000-8000-000000000001',p_name,25.25,121.45,'臺北市',p_space,true,true,'confirmed',p_condition,
      r.facility_type,coalesce(r.parking_zones,'[]'),coalesce(r.zones_complete,false)
    from jsonb_populate_record(null::community_spots,p_extra) r returning id into v;
  insert into fx values(p_name,v);
  return v;
end;
$$;

-- ===== Defaults: existing writes are unchanged =====
select pg_temp.c('舊資料','paidMotorcycle',null);
select is((select condition from community_spots where id=(select id from fx where name='舊資料')),null,'condition defaults to null');
select is((select zones_complete from community_spots where id=(select id from fx where name='舊資料')),false,'zones_complete defaults to false');
select is(legacy_projection((select to_jsonb(c) from community_spots c where id=(select id from fx where name='舊資料'))),
  '{}'::jsonb,'a row without conditions needs no projection');

-- ===== Table checks: allowed =====
select lives_ok($$select pg_temp.c('收費格','paidMotorcycle','{"bay":"motorcycle","use":"usual","charge":"toll"}')$$,
  'a street condition stored under its space_type');
select lives_ok($$select pg_temp.c('臺北限時格','timedMotorcycle',
  '{"bay":"motorcycle","use":"usual","charge":"toll","limits":[{"kind":"time_limit","max_minutes":20}]}')$$,
  'a timed bay with its minutes (§2.4)');
select lives_ok($$select pg_temp.c('時段重機格','heavyOnly',
  '{"bay":"heavy","use":"usual","schedule":[{"days":"all","from":"07:00","to":"20:00","vehicles":["heavy"]}]}')$$,
  'a heavy bay with a schedule');
select lives_ok($$select pg_temp.c('免費限時格','timedMotorcycle',
  '{"bay":"motorcycle","use":"usual","charge":"free","limits":[{"kind":"time_limit"}]}')$$,
  'a free timed bay');
select lives_ok($$select pg_temp.c('汽機共用時段','flexShared',
  '{"bay":"car","use":"share","share":"car_motorcycle","schedule":[{"days":"weekday","from":"20:00","to":"07:00","vehicles":["car","scooter"]}]}')$$,
  'a flex bay with posted hours');
select lives_ok($$select pg_temp.c('試辦場站','offStreet',null,
  '{"facility_type":"underground","zones_complete":true,"parking_zones":[
    {"name":"機車區","area":"motorcycle","access":"scooterHeavy",
     "condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"toll",
       "basis":{"source_url":"https://pma.gov.taipei/x","effective_date":"2026-04-06","expires_on":"2026-10-05"}},
     "fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
    {"name":"汽車區","area":"car","access":"heavyCar",
     "condition":{"bay":"car","use":"usual","charge":"toll","allow":{"scooter":false,"heavy":true}}},
    {"name":"舊分區","access":"scooterOnly","guide":"B2"}]}')$$,
  'a lot with zone conditions, areas and zones_complete (§2.4)');
select lives_ok($$select pg_temp.c('安全場站','offStreet',null,
  '{"facility_type":"surface","parking_zones":[{"name":"汽車區","area":"car","access":"heavyCar",
    "condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]}')$$,
  'a lot whose zone condition matches its access');
select lives_ok($$select pg_temp.c('無access分區','offStreet',null,
  '{"parking_zones":[{"name":"機車區","condition":{"bay":"motorcycle","use":"usual","allow":{"scooter":true}}}]}')$$,
  'a zone condition no access matches stores no access');

-- ===== Table checks: refused =====
select throws_ok($$select pg_temp.c('x1','offStreet','{"bay":"motorcycle","use":"usual","charge":"toll"}')$$,
  '23514',null,'a lot has no top-level condition');
select throws_ok($$select pg_temp.c('x2','paidMotorcycle','{"bay":"motorcycle","use":"usual","charge":"toll"}','{"facility_type":"multiStorey"}')$$,
  '23514',null,'an off-street facility type also places the spot off the street');
select throws_ok($$select pg_temp.c('x3','paidMotorcycle',null,'{"parking_zones":[{"name":"B1"}]}')$$,
  '23514',null,'a street spot has no zones');
select throws_ok($$select pg_temp.c('x4','paidMotorcycle',null,'{"zones_complete":true}')$$,
  '23514',null,'a street spot has no zones_complete');
select throws_ok($$select pg_temp.c('x5','freeMotorcycle','{"bay":"motorcycle","use":"usual","charge":"toll"}')$$,
  '23514',null,'space_type must be the condition''s legacy space type');
select throws_ok($$select pg_temp.c('x6','paidMotorcycle','{"bay":"motorcycle","use":"share","charge":"toll"}')$$,
  '23514',null,'a shared use names its kind');
select throws_ok($$select pg_temp.c('x7','paidMotorcycle','{"bay":"motorcycle","use":"usual"}')$$,
  '23514',null,'a motorcycle bay says toll or free');
select throws_ok($$select pg_temp.c('x8','car','{"bay":"car","use":"usual","allow":{"heavy":true}}')$$,
  '23514',null,'allow belongs to zones');
select throws_ok($$select pg_temp.c('x9','paidMotorcycle','{"bay":"motorcycle","use":"usual","charge":"toll",
  "basis":{"source_url":"https://example.test/a","evidence_id":"00000000-0000-4000-8000-000000000001"}}')$$,
  '23514',null,'evidence_id is refused until photo evidence ships');
select throws_ok($$select pg_temp.c('x10','paidMotorcycle','null')$$,
  '23514',null,'a JSON null condition is not a condition');
-- Stored, but not legacy-safe: old builds read only access (see below).
select lives_ok($$select pg_temp.c('不一致分區','offStreet',null,
  '{"parking_zones":[{"name":"汽車區","access":"scooterHeavy","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]}')$$,
  'a zone access other than the one its condition writes back is stored');
select throws_ok($$select pg_temp.c('x13','offStreet',null,'{"parking_zones":[{"name":"B1","area":"roof"}]}')$$,
  '23514',null,'area is one of the listed areas');
select throws_ok($$select pg_temp.c('x14','offStreet',null,'{"parking_zones":[{"name":"B1","condition":{}}]}')$$,
  '23514',null,'a zone never stores an empty condition');
select throws_ok($$select pg_temp.c('x15','offStreet',null,'{"parking_zones":[{"name":"B1","fee":{"bus":{"mode":"free"}}}]}')$$,
  '23514',null,'zone fees keep the live fee check');
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,effective_date,condition)
  values('x16',25.25,121.45,'臺北市','heavyOnly','https://example.test/o',current_date,'{"bay":"car","use":"usual"}')$$,
  '23514',null,'the official table holds the same checks');

-- ===== legacy_projection() =====
select is(legacy_projection((select to_jsonb(c) from community_spots c where id=(select id from fx where name='收費格'))),
  '{}'::jsonb,'a legacy-safe condition needs no projection');
select is(legacy_projection((select to_jsonb(c) from community_spots c where id=(select id from fx where name='臺北限時格'))),
  '{}'::jsonb,'the minutes of a timed toll bay may be lost');
select is(legacy_projection((select to_jsonb(c) from community_spots c where id=(select id from fx where name='時段重機格'))),
  '{"space_type":"offStreet","scooter_allowed":null,"heavy_allowed":null,"condition":null,"parking_zones":[],"status":"pending"}'::jsonb,
  'an unsafe street spot becomes an unverified lot');
select is(legacy_projection((select to_jsonb(o)-'status' from community_spots o where id=(select id from fx where name='時段重機格')))?'status',
  false,'rows without status (official) get no status');

-- Inserted as an admin would (official spots need a source and date).
insert into official_heavy_spots(id,name,lat,lng,city,space_type,source_url,effective_date,heavy_allowed,scooter_allowed,condition)
values('74100000-0000-4000-8000-000000000001','官方免費限時格',25.26,121.46,'臺北市','timedMotorcycle','https://example.test/o',current_date,true,true,
  '{"bay":"motorcycle","use":"usual","charge":"free","limits":[{"kind":"time_limit"}]}'),
('74100000-0000-4000-8000-000000000002','官方收費格',25.26,121.46,'臺北市','paidMotorcycle','https://example.test/o',current_date,true,true,
  '{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"toll"}'),
('74100000-0000-4000-8000-000000000003','官方未生效',25.26,121.46,'臺北市','paidMotorcycle','https://example.test/o',current_date+1,true,true,
  '{"bay":"motorcycle","use":"usual","charge":"toll"}');
insert into official_heavy_spots(id,name,lat,lng,city,space_type,facility_type,source_url,effective_date,heavy_allowed,zones_complete,parking_zones)
values('74100000-0000-4000-8000-000000000004','官方試辦場站',25.26,121.46,'臺北市','offStreet','underground','https://example.test/o',current_date,true,true,
  '[{"name":"機車區","area":"motorcycle","access":"scooterHeavy",
     "condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"toll",
       "basis":{"source_url":"https://pma.gov.taipei/x","expires_on":"2026-10-05"}}},
    {"name":"汽車區","area":"car","access":"heavyCar","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]');
update community_spots set status='hidden' where id=(select id from fx where name='汽機共用時段');

-- ===== Viewports as anon (RLS applies) =====
set local role anon;
create temporary table vw as
  select 'v3' as fn,j from pg_temp.v('viewport_spots_v3') j
  union all select 'v2',j from pg_temp.v('viewport_spots_v2') j
  union all select 'v1',j from pg_temp.v('viewport_spots') j
  union all select 'ov3',j from pg_temp.v('official_viewport_spots_v3') j
  union all select 'ov2',j from pg_temp.v('official_viewport_spots_v2') j
  union all select 'ov1',j from pg_temp.v('official_viewport_spots') j;
reset role;
create function pg_temp.row(p_fn text,p_name text) returns jsonb language sql as $$
  select j from vw where fn=p_fn and j->>'name'=p_name;
$$;

-- v3: everything as stored.
select is(pg_temp.row('v3','時段重機格')->'condition',
  '{"bay":"heavy","use":"usual","schedule":[{"days":"all","from":"07:00","to":"20:00","vehicles":["heavy"]}]}'::jsonb,
  'v3 returns the condition');
select is(pg_temp.row('v3','時段重機格')->>'space_type','heavyOnly','v3 keeps the space type');
select is(pg_temp.row('v3','時段重機格')->>'heavy_allowed','true','v3 keeps the flags');
select is(pg_temp.row('v3','試辦場站')->'zones_complete','true'::jsonb,'v3 returns zones_complete');
select is(pg_temp.row('v3','試辦場站')->'parking_zones'->0->>'access','scooterHeavy','v3 keeps every zone access');
select is(pg_temp.row('v3','試辦場站')->'parking_zones'->0->>'area','motorcycle','v3 keeps zone areas');
select is(pg_temp.row('ov3','官方免費限時格')->'condition'->>'charge','free','official v3 returns the condition');
select is(pg_temp.row('ov3','官方試辦場站')->'zones_complete','true'::jsonb,'official v3 returns zones_complete');
select is(pg_temp.row('ov3','官方免費限時格')->>'scooter_allowed','true','official v3 keeps the flags');
-- RLS and visibility rules hold in v3.
select is((select count(*)::integer from vw where fn='v3' and j->>'name'='汽機共用時段'),0,'v3 hides hidden community spots');
select is((select count(*)::integer from vw where fn='ov3' and j->>'name'='官方未生效'),0,'official v3 hides spots not yet in effect');
select is((select count(*)::integer from vw where fn='v3' and j ? 'user_id'),0,'v3 never exposes contributor ids');

-- v2 and the original: unsafe rows projected, safe rows unchanged.
select is(pg_temp.row('v2','時段重機格')->>'space_type','offStreet','v2 projects an unsafe bay to a lot');
select is(pg_temp.row('v2','時段重機格')->'heavy_allowed','null'::jsonb,'v2 drops its heavy flag');
select is(pg_temp.row('v2','時段重機格')->'scooter_allowed','null'::jsonb,'v2 drops its scooter flag');
select is(pg_temp.row('v2','時段重機格')->>'status','pending','v2 shows it pending');
select is(pg_temp.row('v2','時段重機格')->'condition','null'::jsonb,'v2 drops the condition the row no longer matches');
select is(pg_temp.row('v1','時段重機格')->>'space_type','offStreet','the original viewport projects it too');
select is(pg_temp.row('v1','時段重機格')->'heavy_allowed','null'::jsonb,'the original viewport drops its flags');
select is(pg_temp.row('v2','免費限時格')->>'space_type','offStreet','v2 projects a free timed bay');
select is((select count(*)::integer from vw where fn='v1' and j->>'name' in ('免費限時格','臺北限時格')),0,
  'the original viewport still leaves out the newer kinds');
select is(pg_temp.row('v2','臺北限時格')->>'space_type','timedMotorcycle','v2 leaves a safe row alone');
select is(pg_temp.row('v2','臺北限時格')->>'status','confirmed','v2 keeps a safe row''s status');
select is(pg_temp.row('v2','收費格'),pg_temp.row('v3','收費格'),'a safe row reads the same in v2 and v3');
select is(pg_temp.row('v1','收費格'),pg_temp.row('v3','收費格'),'a safe row reads the same in the original and v3');
select is(pg_temp.row('v2','舊資料'),pg_temp.row('v3','舊資料'),'a row without a condition reads the same everywhere');
-- An unsafe lot: the unsafe zone loses its access, the safe one keeps it.
select is(pg_temp.row('v2','試辦場站')->>'space_type','offStreet','v2 keeps a lot a lot');
select is(pg_temp.row('v2','試辦場站')->'heavy_allowed','null'::jsonb,'v2 drops an unsafe lot''s flags');
select is(pg_temp.row('v2','試辦場站')->'parking_zones'->0 ? 'access',false,'v2 drops the access of a zone with an expiry');
select is(pg_temp.row('v2','試辦場站')->'parking_zones'->0->>'name','機車區','the zone itself stays');
select is(pg_temp.row('v2','試辦場站')->'parking_zones'->1->>'access','heavyCar','a safe zone keeps its access');
select is(pg_temp.row('v2','試辦場站')->'parking_zones'->2->>'access','scooterOnly','a zone without a condition keeps its access');
select is(pg_temp.row('v2','安全場站'),pg_temp.row('v3','安全場站'),'a safe lot reads the same in v2 and v3');
select is(pg_temp.row('v2','不一致分區')->'parking_zones'->0 ? 'access',false,
  'v2 drops an access its zone condition contradicts');
select is(pg_temp.row('v3','不一致分區')->'parking_zones'->0->>'access','scooterHeavy','v3 returns it as stored');
select is(pg_temp.row('v2','無access分區')->>'status','pending',
  'a zone condition no access expresses makes the lot unverified in v2');
-- Official rows have no status to lower; the flags drop.
select is(pg_temp.row('ov2','官方免費限時格')->>'space_type','offStreet','official v2 projects an unsafe bay');
select is(pg_temp.row('ov2','官方免費限時格')->'heavy_allowed','null'::jsonb,'official v2 drops its flags');
select is(pg_temp.row('ov2','官方免費限時格')->>'status','confirmed','official rows stay official');
select is((select count(*)::integer from vw where fn='ov1' and j->>'name'='官方免費限時格'),0,'the original official viewport leaves out timed bays');
select is(pg_temp.row('ov2','官方收費格')->>'heavy_allowed','true','official v2 leaves a safe row alone');
select is(pg_temp.row('ov1','官方收費格')->>'space_type','paidMotorcycle','the original official viewport leaves a safe row alone');
select is(pg_temp.row('ov1','官方試辦場站')->'parking_zones'->0 ? 'access',false,'the original official viewport drops an unsafe zone''s access');
select is(pg_temp.row('ov1','官方試辦場站')->'heavy_allowed','null'::jsonb,'and the unsafe lot''s flags');
select is(pg_temp.row('ov2','官方試辦場站')->'parking_zones'->1->>'access','heavyCar','official v2 keeps a safe zone''s access');

-- ===== Column grants =====
set local role anon;
select lives_ok($$select condition,zones_complete from community_spots limit 1$$,'anon reads the new columns');
select lives_ok($$select condition,zones_complete from public_spots limit 1$$,'the public view carries them');
update community_spots set condition=null;
reset role;
select isnt((select condition from community_spots where id=(select id from fx where name='收費格')),null,'anon cannot write them (RLS)');
select ok(has_function_privilege('anon','public.viewport_spots_v3(double precision,double precision,double precision,double precision)','EXECUTE'),'anon may call v3');
select ok(has_function_privilege('anon','public.official_viewport_spots_v3(double precision,double precision,double precision,double precision)','EXECUTE'),'anon may call official v3');

-- ===== apply_report =====
create temporary table rep as
  select 'free' as name,public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
    '{"action":"create","spot":{"name":"回報免費限時格","lat":25.27,"lng":121.47,"city":"臺北市","space_type":"timedMotorcycle",
      "condition":{"bay":"motorcycle","use":"usual","charge":"free","limits":[{"kind":"time_limit","max_minutes":30}]}}}') as r;
insert into rep select 'legacy',public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"舊版回報","lat":25.271,"lng":121.471,"city":"臺北市","space_type":"paidMotorcycle"}}');
select is((select condition->>'charge' from community_spots where id=(select (r->>'id')::uuid from rep where name='free')),
  'free','a new spot stores its condition');
select is((select condition from community_spots where id=(select (r->>'id')::uuid from rep where name='legacy')),
  null,'a build without conditions stores none');
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"附依據","lat":25.272,"lng":121.472,"city":"臺北市","space_type":"paidMotorcycle",
    "condition":{"bay":"motorcycle","use":"usual","charge":"toll","basis":{"source_url":"https://example.test/n"}}}}')$$,
  '22023','a report cannot set a condition basis','riders cannot write a basis');
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"分區附依據","lat":25.273,"lng":121.473,"city":"臺北市","space_type":"offStreet",
    "parking_zones":[{"name":"B1","access":"heavyCar","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true},
      "basis":{"source_url":"https://example.test/n"}}}]}}')$$,
  '22023','a report cannot set a condition basis','nor a zone basis');
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"不一致","lat":25.274,"lng":121.474,"city":"臺北市","space_type":"paidMotorcycle",
    "condition":{"bay":"heavy","use":"usual"}}}')$$,
  '23514',null,'a condition must match the space type it is sent with');
-- An owner's edit from any build leaves the condition alone (§5.4).
select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  jsonb_build_object('action','update','spot_id',(select id from community_spots where name='回報免費限時格'),
    'spot',jsonb_build_object('name','回報免費限時格（改名）')));
select is((select condition->>'charge' from community_spots where name='回報免費限時格（改名）'),'free','an owner''s update keeps the condition');

-- ===== Admin RPCs =====
select ok('condition'=any(admin_spot_fields(false)) and 'zones_complete'=any(admin_spot_fields(false)),'community spots list the new fields');
select ok('condition'=any(admin_spot_fields(true)) and 'zones_complete'=any(admin_spot_fields(true)),'official spots list the new fields');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='收費格'),
  '{"condition":{"bay":"motorcycle","use":"share","charge":"toll"}}',(select updated_at from community_spots where id=(select id from fx where name='收費格')))$$,
  '22023','invalid condition','an invalid condition is named before the table check');
select is(admin_upsert_spot((select id::text from fx where name='收費格'),
  '{"space_type":"freeMotorcycle","condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"free",
    "basis":{"source_url":"https://example.test/free"}}}',
  (select updated_at from community_spots where id=(select id from fx where name='收費格')))->'condition'->>'share',
  'scooter_heavy','an admin writes a condition with its space type and basis');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='收費格'),
  '{"condition":{"bay":"heavy","use":"usual"}}',(select updated_at from community_spots where id=(select id from fx where name='收費格')))$$,
  '23514',null,'the table check holds the condition to space_type');
select is(admin_upsert_spot((select id::text from fx where name='安全場站'),'{"zones_complete":true}',
  (select updated_at from community_spots where id=(select id from fx where name='安全場站')))->>'zones_complete',
  'true','an admin marks a lot''s zones complete');
select is((admin_upsert_spot(null,'{"kind":"official","name":"新官方格","lat":25.28,"lng":121.48,"city":"臺北市","space_type":"heavyOnly",
    "source_name":"臺北市政府","source_url":"https://example.test/new","effective_date":"2026-10-27",
    "condition":{"bay":"heavy","use":"usual","charge":"toll"}}')->'condition'->>'charge'),'toll','an admin creates an official spot with a condition');
select is((admin_upsert_spot(null,'{"kind":"community","name":"新社群場站","lat":25.281,"lng":121.481,"city":"臺北市","space_type":"offStreet",
    "zones_complete":true}')->>'zones_complete'),'true','an admin creates a lot with zones_complete');
reset role;

-- Adopting a suggested condition.
insert into moderation_queue(source_id,reason,field,proposed) values
  ((select id::text from fx where name='時段重機格'),'格位條件','space_type','{"condition":{"bay":"heavy","use":"usual","charge":"toll"}}');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from moderation_queue where reason='格位條件'),'accepted',
  '{"condition":{"bay":"heavy","use":"usual","charge":"toll"}}')->'spot'->'condition'->>'charge','toll','an admin adopts a condition');
reset role;
select is(legacy_projection((select to_jsonb(c) from community_spots c where id=(select id from fx where name='時段重機格'))),
  '{}'::jsonb,'without its schedule the bay is legacy-safe again');

-- Promotion keeps the condition with its space type.
select pg_temp.act('admin');
set local role authenticated;
select is((admin_promote_spot((select id::text from fx where name='臺北限時格'),
  '{"source_name":"臺北市政府","source_url":"https://example.test/promote","effective_date":"2026-10-27"}',
  (select updated_at from community_spots where id=(select id from fx where name='臺北限時格')))->'condition'->'limits'->0->>'max_minutes'),
  '20','promotion keeps the condition');
select is((admin_promote_spot((select id::text from fx where name='試辦場站'),
  '{"source_name":"臺北市政府","source_url":"https://example.test/promote","effective_date":"2026-10-27"}',
  (select updated_at from community_spots where id=(select id from fx where name='試辦場站')))->>'zones_complete'),
  'true','promotion keeps zones_complete');
reset role;

select * from finish();
rollback;
