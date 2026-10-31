-- Fetching when the source is due (202610310500_availability_next_update.sql).
-- now() is fixed inside the transaction, so times are exact.
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create temporary table fx(name text primary key,id uuid);
grant select on fx to anon;
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_name,source_url,effective_date,source_id)
  values('排程測試一',25.051,121.551,'臺北市','offStreet','臺北市政府','https://example.test/a','2026-01-01','TPSCH01')
  returning id)
insert into fx select 'lot',id from s;
select availability_store_capacities('taipei_tcmsv','[{"id":"TPSCH01","scooter":24}]');
delete from availability_ingest_runs;
update availability_sources set last_source_updated_at=null,next_expected_at=null,same_batch_retries=0,failures=0,
  next_attempt_at=null,polling_until=null,publish_delay='2 minutes' where key='taipei_tcmsv';

create temporary table t(u timestamptz);
insert into t values(date_trunc('minute',now())-interval '30 minutes');
create function pg_temp.src() returns availability_sources language sql as $$
  select * from availability_sources where key='taipei_tcmsv' $$;

-- ===== 延遲學習 =====
select is(availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,
  (select u+interval '72 seconds' from t))->>'outcome','ok','a new batch');
select is((select publish_delay from availability_ingest_runs order by id desc limit 1),interval '72 seconds',
  'its delay is Last-Modified − UPDATETIME');
select is((pg_temp.src()).publish_delay,interval '72 seconds','and becomes the learned delay');
select is((pg_temp.src()).next_expected_at,(select u+interval '6 minutes 12 seconds' from t),
  'the next batch is expected at UPDATETIME + interval + delay');

update t set u=u+interval '5 minutes';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,
  (select u+interval '60 seconds' from t));
update t set u=u+interval '5 seconds';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,
  (select u+interval '80 seconds' from t));
update t set u=u+interval '5 seconds';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,
  (select u+interval '9 minutes' from t));
select is((pg_temp.src()).publish_delay,interval '76 seconds','the median of the samples: one slow batch does not move it');

update t set u=u+interval '5 seconds';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,
  (select u-interval '1 minute' from t));
select is((select publish_delay from availability_ingest_runs order by id desc limit 1),null,
  'a Last-Modified before UPDATETIME is no sample');
update t set u=u+interval '5 seconds';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]');
select is((select publish_delay from availability_ingest_runs order by id desc limit 1),null,
  'nor is a batch fetched on plan without one: it may have been public for a while');
select is((pg_temp.src()).publish_delay,interval '76 seconds','the learned delay stays');

-- Retried every minute, the first fetch that sees the batch measures it.
update t set u=now()-interval '3 minutes';
update availability_sources set same_batch_retries=2 where key='taipei_tcmsv';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]');
select is((select publish_delay from availability_ingest_runs order by id desc limit 1),interval '3 minutes',
  'without Last-Modified, a batch found on a retry measures now − UPDATETIME');
select is((pg_temp.src()).same_batch_retries,0,'and clears the retries');

update t set u=now()-interval '40 minutes';
update availability_sources set last_source_updated_at=null where key='taipei_tcmsv';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,now());
select is((select publish_delay from availability_ingest_runs order by id desc limit 1),null,
  'longer than half an hour is an outage, not a delay');

delete from availability_ingest_runs;
update t set u=now()-interval '25 minutes';
update availability_sources set last_source_updated_at=null where key='taipei_tcmsv';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,now());
select is((pg_temp.src()).publish_delay,interval '10 minutes','the learned delay is capped at ten minutes');
update availability_ingest_runs set publish_delay='0';
update t set u=now()-interval '1 minute';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]',null,(select u from t));
select is((pg_temp.src()).publish_delay,interval '0','and never below zero');

-- ===== 同一批重試 =====
delete from availability_ingest_runs;
update t set u=now()-interval '6 minutes 30 seconds';
update availability_sources set last_source_updated_at=null,publish_delay='72 seconds' where key='taipei_tcmsv';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]');
-- Due 18 s ago, and the source still has the batch.
select is((pg_temp.src()).next_expected_at,now()-interval '18 seconds','due');
create temporary table f as select fetched_at from parking_availability_latest where facility_id='TPSCH01' and vehicle='scooter';

select is(availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":9}]')->>'outcome','unchanged',
  'the same batch again');
select is((select fetched_at from parking_availability_latest where facility_id='TPSCH01' and vehicle='scooter'),
  (select fetched_at from f),'is not written again');
select is((pg_temp.src()).same_batch_retries,1,'counts one retry');
select is((pg_temp.src()).next_expected_at,now()+interval '30 seconds','and tries again next tick');
select is((pg_temp.src()).failures,0,'without counting a failure');
select is((pg_temp.src()).next_attempt_at,null,'or backing off');
-- A 304 from the Edge Function is the same batch too.
select availability_record_run('taipei_tcmsv','unchanged','not modified');
select availability_record_run('taipei_tcmsv','out_of_order','older');
select availability_record_run('taipei_tcmsv','unchanged','not modified');
select is((pg_temp.src()).same_batch_retries,4,'up to four retries');
select is((pg_temp.src()).failures,0,'still no failure');
select availability_record_run('taipei_tcmsv','unchanged','not modified');
select is((pg_temp.src()).failures,1,'the fifth same batch is a failure');
select is((select outcome from availability_ingest_runs order by id desc limit 1),'unchanged','logged as unchanged');
select ok((select message like 'no new batch after 4 retries%' from availability_ingest_runs order by id desc limit 1),
  'saying why');
select is((pg_temp.src()).same_batch_retries,0,'the retries start over');
select is((pg_temp.src()).next_expected_at,(select u+interval '10 minutes 72 seconds' from t),
  'and the source waits for its next slot');
select is((pg_temp.src()).next_attempt_at,null,'the first failure has no backoff');
do $$ begin for i in 1..5 loop perform availability_record_run('taipei_tcmsv','unchanged',''); end loop; end $$;
select is((pg_temp.src()).failures,2,'a second stall in a row');
select ok((select next_attempt_at between now()+interval '8 minutes' and now()+interval '10 minutes' from pg_temp.src() x),
  'backs off as an error does');
update t set u=u+interval '5 minutes';
select availability_ingest('taipei_tcmsv',(select u from t),'[{"id":"TPSCH01","scooter":5}]');
select is((pg_temp.src()).failures,0,'a new batch clears it');
select is((pg_temp.src()).next_attempt_at,null,'and the backoff');

-- Without a plan (just migrated), the same batch waits for the next slot.
update availability_sources set next_expected_at=null where key='taipei_tcmsv';
select availability_record_run('taipei_tcmsv','unchanged','not modified');
select is((pg_temp.src()).next_expected_at,(select u+interval '5 minutes 72 seconds' from t),
  'with no plan the next slot is the plan');
select is((pg_temp.src()).same_batch_retries,0,'not a retry');

select is(availability_next_slot(now()-interval '12 minutes','5 minutes','1 minute'),now()+interval '4 minutes',
  'next slot: the first one after now');
select is(availability_next_slot(now()-interval '1 minute','5 minutes','1 minute'),now()+interval '5 minutes',
  'never one already passed');
select is(availability_next_slot(null,'5 minutes','1 minute'),now()+interval '5 minutes','no batch yet: one interval');

-- ===== 未到時間不呼叫 =====
delete from vault.secrets where name in ('project_url','availability_ingest_secret');
select vault.create_secret('https://example.test','project_url');
select vault.create_secret('test-secret','availability_ingest_secret');
create temporary table q as select count(*) n from net.http_request_queue;
update availability_sources set next_expected_at=now()+interval '1 minute',next_attempt_at=null,polling_until=null
  where key='taipei_tcmsv';
select is(availability_ingest_tick(),null,'before the expected batch the tick does nothing');
select is((select count(*) from net.http_request_queue),(select n from q),'and sends nothing');
update availability_sources set next_expected_at=now(),next_attempt_at=now()+interval '5 minutes' where key='taipei_tcmsv';
select is(availability_ingest_tick(),null,'nor during backoff');
update availability_sources set next_attempt_at=null,enabled=false where key='taipei_tcmsv';
select is(availability_ingest_tick(),null,'nor for a disabled source');
update availability_sources set enabled=true where key='taipei_tcmsv';
select isnt(availability_ingest_tick(),null,'when due, it calls the function');
select is((select count(*) from net.http_request_queue),(select n+1 from q),'once');
select is((pg_temp.src()).polling_until,now()+interval '3 minutes','marking the call in flight');
select is(availability_ingest_tick(),null,'the next tick waits for it');
select availability_record_run('taipei_tcmsv','skipped','backoff');
select is((pg_temp.src()).polling_until,null,'its run frees the source');
select is((select schedule from cron.job where jobname='availability-ingest'),'* * * * *','the tick runs every minute');

-- ===== 新鮮度 =====
-- Delay 72 s: fresh for 5 min + 72 s + 4 min grace = 612 s after the source time.
update availability_sources set publish_delay='72 seconds' where key='taipei_tcmsv';
update parking_availability_latest set source_updated_at=now()-interval '10 minutes',status='ok',available=5,zero_since=null
  where facility_id='TPSCH01';
set local role anon;
select is((select status from viewport_availability(array[(select 'official:'||id from fx)]) where vehicle='scooter'),'fresh',
  'ten minutes old, before the next batch is due plus grace: fresh (was delayed past 10 minutes)');
select is((select fresh_seconds from viewport_availability(array[(select 'official:'||id from fx)]) where vehicle='scooter'),612,
  'the app gets the same window');
reset role;
update parking_availability_latest set source_updated_at=now()-interval '10 minutes 30 seconds' where facility_id='TPSCH01';
set local role anon;
select is((select status from viewport_availability(array[(select 'official:'||id from fx)]) where vehicle='scooter'),'delayed',
  'past it: delayed');
reset role;
update parking_availability_latest set source_updated_at=now()-interval '25 minutes' where facility_id='TPSCH01';
set local role anon;
select is((select status from viewport_availability(array[(select 'official:'||id from fx)]) where vehicle='scooter'),'stale',
  'a source that stopped goes stale');
reset role;
update parking_availability_latest set source_updated_at=now()-interval '1 minute',status='invalid',available=null
  where facility_id='TPSCH01';
set local role anon;
select is((select status from viewport_availability(array[(select 'official:'||id from fx)]) where vehicle='scooter'),'invalid',
  'invalid stays invalid');
reset role;
update availability_sources set delayed_within='8 minutes' where key='taipei_tcmsv';
set local role anon;
select is((select fresh_seconds from viewport_availability(array[(select 'official:'||id from fx)]) where vehicle='scooter'),479,
  'the fresh window stays below delayed_within');
reset role;

-- ===== 權限 =====
set local role anon;
select throws_ok($$select availability_ingest_tick()$$,'42501',null,'anon cannot tick');
select throws_ok($$select availability_record_run('taipei_tcmsv','ok')$$,'42501',null,'nor log a run');
reset role;

select * from finish();
rollback;
