-- Live counts, P2 (202610270140_availability_p2.sql; REALTIME_AVAILABILITY_UI_PLAN.md §10).
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create temporary table fx(name text primary key,id uuid);
grant select on fx to anon,authenticated;
create function pg_temp.spot(text) returns text language sql as $$ select 'official:'||id from fx where name=$1 $$;
grant execute on function pg_temp.spot(text) to anon,authenticated;

-- Three Taipei lots and one community spot.
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_name,source_url,effective_date,source_id)
  values('即時測試一',25.041,121.541,'臺北市','offStreet','臺北市政府','https://example.test/a','2026-01-01','TPEX001'),
        ('即時測試二',25.042,121.542,'臺北市','offStreet','臺北市政府','https://example.test/b','2026-01-01','TPEX002'),
        ('即時測試三',25.043,121.543,'臺北市','offStreet','臺北市政府','https://example.test/c','2026-01-01','TPEX003')
  returning id,source_id)
insert into fx select lower(source_id),id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','社群即時測試',25.044,121.544,'臺北市','paidMotorcycle') returning id)
insert into fx select 'community',id from s;

-- ===== 分類 =====
select is(availability_classify(24,0),'ok','0 is a count (已滿)');
select is(availability_classify(24,-9),'unavailable','-9 is no data, never 0');
select is(availability_classify(24,-1),'unavailable','-1 is no data');
select is(availability_classify(24,null),'unavailable','a missing value is no data');
select is(availability_classify(0,5),'unavailable','no capacity for the vehicle is no data, not 已滿');
select is(availability_classify(null,5),'unavailable','an unknown capacity too');
select is(availability_classify(24,-4),'invalid','another negative code is invalid');
select is(availability_classify(24,25),'invalid','more free than total is invalid');
select is(availability_int('12'),12,'an integer');
select is(availability_int('"12"'),null,'text is not a count');
select is(availability_int('1.5'),null,'a fraction is not a count');

-- ===== 權限 =====
set local role anon;
select throws_ok($$select * from parking_availability_latest$$,'42501',null,'anon cannot read snapshots');
select throws_ok($$select * from availability_mappings$$,'42501',null,'anon cannot read mappings');
select throws_ok($$insert into parking_availability_latest(source_key,facility_id,vehicle,status,source_updated_at,fetched_at)
  values('taipei_tcmsv','TPEX001','scooter','unavailable',now(),now())$$,'42501',null,'anon cannot write snapshots');
select throws_ok($$select availability_ingest('taipei_tcmsv',now(),'[]')$$,'42501',null,'anon cannot ingest');
select throws_ok($$select availability_store_capacities('taipei_tcmsv','[]')$$,'42501',null,'anon cannot store capacities');
select throws_ok($$select availability_ingest_tick()$$,'42501',null,'anon cannot call out');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","app_metadata":{"role":"user"}}',true);
select throws_ok($$select * from parking_availability_latest$$,'42501',null,'a rider cannot read snapshots');
select is((select count(*)::integer from availability_sources),0,'nor sources (admins only)');
select throws_ok($$update availability_sources set enabled=false$$,'42501',null,'nor change a source');
reset role;

-- ===== 擷取 =====
select is(availability_store_capacities('taipei_tcmsv',
  '[{"id":"TPEX001","scooter":24,"heavy":6,"car":40},{"id":"TPEX002","scooter":30,"heavy":0,"car":10},
    {"id":"TPEX003","scooter":10,"heavy":null,"car":0}]'),3,'capacities stored');

create temporary table t(at timestamptz);
insert into t values(date_trunc('minute',now())-interval '3 minutes');
select is(availability_ingest('taipei_tcmsv',(select at from t),
  '[{"id":"TPEX001","scooter":12,"heavy":-9,"car":5},
    {"id":"TPEX002","scooter":0,"heavy":-9,"car":11},
    {"id":"TPEX003","scooter":-4,"car":-9},
    {"id":"TPEUNMAPPED","scooter":3}]')->>'outcome','ok','a feed is stored');
select is((select count(*)::integer from availability_mappings where match='exact_id'),3,'exact ID matches map themselves');
select is((select status from parking_availability_latest where facility_id='TPEX002' and vehicle='car'),'invalid',
  'more free car spaces than car bays is invalid');
select is((select raw_available from parking_availability_latest where facility_id='TPEX003' and vehicle='scooter'),-4,
  'the raw code is kept for audit');

set local role anon;
select is((select available from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),12,
  'a fresh scooter count');
select is((select status from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),'fresh',
  'judged fresh from the source time');
select is((select total from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),24,'with its capacity');
select is((select provider from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),'臺北市停管處',
  'and its publisher');
select is((select status from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='heavy'),'unavailable',
  'scooter 12 but heavy -9: heavy is no data');
select is((select available from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='heavy'),null,
  'and no number');
select is((select available from viewport_availability(array[pg_temp.spot('tpex002')]) where vehicle='scooter'),0,
  '0 stays a count: 已滿');
select is((select status from viewport_availability(array[pg_temp.spot('tpex002')]) where vehicle='heavy'),'unavailable',
  'no heavy bays is no data, never 已滿');
select is((select status from viewport_availability(array[pg_temp.spot('tpex003')]) where vehicle='scooter'),'invalid',
  'an odd negative never reaches the app as a count');
select is((select available from viewport_availability(array[pg_temp.spot('tpex003')]) where vehicle='scooter'),null,
  'its value is withheld');
select is((select status from viewport_availability(array[pg_temp.spot('tpex003')]) where vehicle='heavy'),'unavailable',
  'a missing field is no data');
select is((select count(*)::integer from viewport_availability(array[pg_temp.spot('community'),'official:x','TPEX001'])),0,
  'community spots and junk ids get no official count');
select is((select count(*)::integer from viewport_availability(array[(select 'official:'||id from fx where name='community')])),0,
  'not even with an official-looking id');
reset role;

-- ===== 順序與時間 =====
select is(availability_ingest('taipei_tcmsv',(select at from t)-interval '5 minutes',
  '[{"id":"TPEX001","scooter":1}]')->>'outcome','out_of_order','an older feed is out of order');
select is((select available from parking_availability_latest where facility_id='TPEX001' and vehicle='scooter'),12,
  'and not written');
select is(availability_ingest('taipei_tcmsv',(select at from t),'[{"id":"TPEX001","scooter":1}]')->>'outcome','unchanged',
  'the same feed again changes nothing');
select is(availability_ingest('taipei_tcmsv',now()+interval '10 minutes','[{"id":"TPEX001","scooter":1}]')->>'outcome','error',
  'a future time is refused');
select is((select available from parking_availability_latest where facility_id='TPEX001' and vehicle='scooter'),12,
  'and not written');
select is((select outcome from availability_ingest_runs order by id desc limit 1),'error','the refusal is logged');

-- A feed 30 minutes old fetched just now is stale: fetching never makes it fresh.
update parking_availability_latest set source_updated_at=now()-interval '30 minutes',fetched_at=now()
  where facility_id='TPEX001';
select is((select status from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),'stale',
  '30 minutes without a source update is stale');
select is((select available from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),12,
  'the last number stays for the details');
update parking_availability_latest set source_updated_at=now()-interval '15 minutes' where facility_id='TPEX001';
select is((select status from viewport_availability(array[pg_temp.spot('tpex001')]) where vehicle='scooter'),'delayed',
  '15 minutes is delayed');

-- ===== 長時間為 0 =====
update availability_sources set last_source_updated_at=null;
delete from parking_availability_latest where facility_id='TPEX002';
select is(availability_ingest('taipei_tcmsv',now()-interval '3 hours','[{"id":"TPEX002","scooter":0}]')->>'outcome','ok','zero');
select is(availability_ingest('taipei_tcmsv',now()-interval '30 seconds','[{"id":"TPEX002","scooter":0}]')->>'outcome','ok',
  'still zero');
select is((select zero_since from parking_availability_latest where facility_id='TPEX002' and vehicle='scooter')
  < now()-interval '2 hours',true,'the zero keeps its start');
select is((select status from viewport_availability(array[pg_temp.spot('tpex002')]) where vehicle='scooter'),'invalid',
  'zero for two hours is suspect, not 已滿');
select is(availability_ingest('taipei_tcmsv',now(),'[{"id":"TPEX002","scooter":4}]')->>'outcome','ok','space again');
select is((select zero_since from parking_availability_latest where facility_id='TPEX002' and vehicle='scooter'),null,
  'clears the zero');

-- ===== 兩個來源 =====
insert into availability_sources(key,provider,feed_url,vehicles,expected_interval,fresh_within,delayed_within,priority)
values('test_tdx','測試來源','https://example.test/feed',array['scooter'],'1 minute','3 minutes','10 minutes',50);
insert into availability_facilities(source_key,facility_id,scooter_total) values('test_tdx','T-1',24);
insert into availability_mappings(source_key,facility_id,spot_id,match,review_status)
  values('test_tdx','T-1',(select id from fx where name='tpex002'),'manual','approved');
select is(availability_ingest('test_tdx',now(),'[{"id":"T-1","scooter":20}]')->>'outcome','ok','a second source');
set local role anon;
select is((select count(*)::integer from viewport_availability(array[pg_temp.spot('tpex002')]) where vehicle='scooter'),1,
  'one count per spot and vehicle, never a sum');
select is((select available from viewport_availability(array[pg_temp.spot('tpex002')]) where vehicle='scooter'),4,
  'the higher-priority source wins');
reset role;
update availability_mappings set review_status='rejected' where source_key='taipei_tcmsv' and facility_id='TPEX002';
set local role anon;
select is((select available from viewport_availability(array[pg_temp.spot('tpex002')]) where vehicle='scooter'),20,
  'a rejected mapping is not used');
reset role;

-- ===== 隱藏點 =====
update official_heavy_spots set hidden=true where id=(select id from fx where name='tpex003');
set local role anon;
select is((select count(*)::integer from viewport_availability(array[pg_temp.spot('tpex003')])),0,'a hidden spot has no counts');
reset role;

-- ===== 退避 =====
update availability_sources set failures=0,next_attempt_at=null where key='taipei_tcmsv';
select availability_record_run('taipei_tcmsv','error','fetch failed');
select is((select next_attempt_at from availability_sources where key='taipei_tcmsv'),null,'the first failure retries next tick');
select availability_record_run('taipei_tcmsv','error','fetch failed');
select ok((select next_attempt_at between now()+interval '8 minutes' and now()+interval '10 minutes'
  from availability_sources where key='taipei_tcmsv'),'the second waits about ten minutes');
select availability_record_run('taipei_tcmsv','error','x');
select availability_record_run('taipei_tcmsv','error','x');
select availability_record_run('taipei_tcmsv','error','x');
select availability_record_run('taipei_tcmsv','error','x');
select ok((select next_attempt_at <= now()+interval '60 minutes' from availability_sources where key='taipei_tcmsv'),
  'never more than an hour');
select availability_record_run('taipei_tcmsv','ok','');
select is((select failures from availability_sources where key='taipei_tcmsv'),0,'a success clears the backoff');

-- ===== 不觸發全域重載 =====
select is((select count(*)::integer from pg_trigger where tgrelid='public.parking_availability_latest'::regclass and not tgisinternal),
  0,'snapshots bump no data version');
select is(availability_ingest_tick(),null,'without Vault secrets the tick does nothing');
select is((select count(*)::integer from cron.job where jobname='availability-ingest'),1,'scheduled');

select * from finish();
rollback;
