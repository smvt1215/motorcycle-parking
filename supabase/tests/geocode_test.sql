begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

insert into auth.users(id,email) values
  ('30000000-0000-4000-8000-000000000001','rider@example.test'),
  ('30000000-0000-4000-8000-000000000002','admin@example.test');

-- Clients never reach the tables or functions; only the Edge Function does.
select ok(not has_table_privilege('authenticated','public.geocode_cache','select'),'riders cannot read the cache');
select ok(not has_table_privilege('anon','public.geocode_events','select'),'anon cannot read search counts');
select ok(not has_function_privilege('authenticated','public.geocode_begin(uuid,boolean,text)','execute'),'riders cannot count searches themselves');
select ok(not has_function_privilege('authenticated','public.geocode_store(text,jsonb)','execute'),'riders cannot write the cache');
select ok(has_function_privilege('service_role','public.geocode_begin(uuid,boolean,text)','execute'),'the Edge Function counts searches');

select is(public.geocode_begin('30000000-0000-4000-8000-000000000001',false,'text|a|-'),null,'a miss returns null');
select public.geocode_store('text|a|-','[{"kind":"address","label":"臺北市中正區忠孝西路一段49號","lat":25.0478,"lng":121.517,"precision":"exact"}]');
select is(public.geocode_begin('30000000-0000-4000-8000-000000000001',false,'text|a|-')->0->>'label','臺北市中正區忠孝西路一段49號','a hit returns the cached candidates');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001'),2,'hits count against the limit too');

-- Entries older than 30 days are neither served nor kept.
update geocode_cache set fetched_at=now()-interval '31 days' where key='text|a|-';
select is(public.geocode_begin('30000000-0000-4000-8000-000000000001',false,'text|a|-'),null,'an expired entry is not served');
select public.geocode_store('text|b|-','[]');
select ok(not exists(select 1 from geocode_cache where key='text|a|-'),'the next write deletes expired entries');
select is(public.geocode_begin('30000000-0000-4000-8000-000000000001',false,'text|b|-'),'[]'::jsonb,'an empty result is cached as well');

-- Riders get 30 a day, admins 200.
insert into geocode_events(user_id) select '30000000-0000-4000-8000-000000000001' from generate_series(1,26);
select throws_ok($$select public.geocode_begin('30000000-0000-4000-8000-000000000001',false,'text|c|-')$$,'P0001','daily search limit reached','the 31st search of the day is refused');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001'),30,'a refused search is not counted');
insert into geocode_events(user_id) select '30000000-0000-4000-8000-000000000002' from generate_series(1,30);
select lives_ok($$select public.geocode_begin('30000000-0000-4000-8000-000000000002',true,'text|c|-')$$,'an admin may search past 30');
-- Yesterday's searches (Taipei time) do not count.
update geocode_events set created_at=date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei'-interval '1 second'
  where user_id='30000000-0000-4000-8000-000000000001';
select lives_ok($$select public.geocode_begin('30000000-0000-4000-8000-000000000001',false,'text|c|-')$$,'the limit resets at Taipei midnight');

select * from finish();
rollback;
