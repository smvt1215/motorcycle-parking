begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

insert into auth.users(id,email) values
  ('30000000-0000-4000-8000-000000000001','rider@example.test'),
  ('30000000-0000-4000-8000-000000000002','admin@example.test');

-- Clients never reach the table or function; only the Edge Function does.
select ok(not has_table_privilege('anon','public.geocode_events','select'),'anon cannot read search counts');
select ok(not has_table_privilege('authenticated','public.geocode_events','select'),'riders cannot read search counts');
select ok(not has_function_privilege('authenticated','public.geocode_count(uuid,boolean)','execute'),'riders cannot count searches themselves');
select ok(has_function_privilege('service_role','public.geocode_count(uuid,boolean)','execute'),'the Edge Function counts searches');

-- #411: no search result is kept (Service Specific Terms 6.3.2).
select hasnt_table('public','geocode_cache','address search results are not cached');
select hasnt_function('public','geocode_store',array['text','jsonb'],'nothing writes a search cache');
select hasnt_function('public','geocode_begin',array['uuid','boolean','text'],'nothing reads a search cache');

select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false)$$,'a search is counted');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001'),1,'one search, one count');

select public.geocode_count('30000000-0000-4000-8000-000000000001',false);

-- Riders get 30 a day, admins 200.
insert into geocode_events(user_id) select '30000000-0000-4000-8000-000000000001' from generate_series(1,28);
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false)$$,'P0001','daily search limit reached','the 31st search of the day is refused');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001'),30,'a refused search is not counted');
insert into geocode_events(user_id) select '30000000-0000-4000-8000-000000000002' from generate_series(1,30);
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000002',true)$$,'an admin may search past 30');
-- Yesterday's searches (Taipei time) do not count.
update geocode_events set created_at=date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei'-interval '1 second'
  where user_id='30000000-0000-4000-8000-000000000001';
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false)$$,'the limit resets at Taipei midnight');

select * from finish();
rollback;
