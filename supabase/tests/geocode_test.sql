begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

insert into auth.users(id,email) values
  ('30000000-0000-4000-8000-000000000001','rider@example.test'),
  ('30000000-0000-4000-8000-000000000002','admin@example.test'),
  ('30000000-0000-4000-8000-000000000003','door@example.test');

-- Clients never reach the table or function; only the Edge Function does.
select ok(not has_table_privilege('anon','public.geocode_events','select'),'anon cannot read search counts');
select ok(not has_table_privilege('authenticated','public.geocode_events','select'),'riders cannot read search counts');
select ok(not has_function_privilege('anon','public.geocode_count(uuid,boolean,text)','execute'),'anon cannot count searches');
select ok(not has_function_privilege('authenticated','public.geocode_count(uuid,boolean,text)','execute'),'riders cannot count searches themselves');
select ok(has_function_privilege('service_role','public.geocode_count(uuid,boolean,text)','execute'),'the Edge Function counts searches');
-- #434: one function, whose kind defaults for the Edge Function deployed
-- before the migration.
select hasnt_function('public','geocode_count',array['uuid','boolean'],'the two-argument count is replaced');

-- #411: no search result is kept (Service Specific Terms 6.3.2).
select hasnt_table('public','geocode_cache','address search results are not cached');
select hasnt_function('public','geocode_store',array['text','jsonb'],'nothing writes a search cache');
select hasnt_function('public','geocode_begin',array['uuid','boolean','text'],'nothing reads a search cache');

-- #434: rows written before the kinds were told apart are searches.
select col_not_null('public','geocode_events','kind','every count has a kind');
select col_default_is('public','geocode_events','kind','search','rows without a kind count as searches');
insert into geocode_events(user_id) values('30000000-0000-4000-8000-000000000003');
select is((select kind from geocode_events where user_id='30000000-0000-4000-8000-000000000003'),'search','an earlier count is a search');
select throws_ok($$insert into geocode_events(user_id,kind) values('30000000-0000-4000-8000-000000000003','other')$$,'23514',null,'only search and reverse are kinds');
delete from geocode_events where user_id='30000000-0000-4000-8000-000000000003';

select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'search')$$,'a search is counted');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001' and kind='search'),1,'one search, one count');
-- The Edge Function deployed before #434 leaves the kind out.
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false)$$,'a count without a kind still works');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001' and kind='search'),2,'and counts as a search');
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'other')$$,'22023',null,'an unknown kind is refused');
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,null)$$,'22023',null,'a missing kind is refused');

-- Parallel requests of a kind wait on one lock per user and kind, held to
-- the end of the transaction, so they cannot all pass the count; the two
-- kinds use different locks.
create function pg_temp.holds(p_key text) returns boolean language sql as $$
  select exists(select 1 from pg_locks l,
      (select hashtextextended(p_key,0) h) k
    where l.locktype='advisory' and l.pid=pg_backend_pid() and l.granted
      and l.objsubid=1
      and l.classid=((k.h>>32)&4294967295)::oid
      and l.objid=(k.h&4294967295)::oid)
$$;
select ok(pg_temp.holds('geocode:search:30000000-0000-4000-8000-000000000001'),'a search holds the search lock');
select ok(not pg_temp.holds('geocode:reverse:30000000-0000-4000-8000-000000000001'),'a search leaves the reverse lock free');
select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'reverse');
select ok(pg_temp.holds('geocode:reverse:30000000-0000-4000-8000-000000000001'),'a reverse lookup holds its own lock');
delete from geocode_events where user_id='30000000-0000-4000-8000-000000000001';

-- Riders get 30 searches a day.
insert into geocode_events(user_id,kind) select '30000000-0000-4000-8000-000000000001','search' from generate_series(1,29);
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'search')$$,'the 30th search of the day passes');
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'search')$$,'P0001','daily search limit reached','the 31st search of the day is refused');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001' and kind='search'),30,'a refused search is not counted');
-- #434: and 100 reverse lookups, untouched by the searches.
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'reverse')$$,'used-up searches leave reverse lookups');
insert into geocode_events(user_id,kind) select '30000000-0000-4000-8000-000000000001','reverse' from generate_series(1,98);
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'reverse')$$,'the 100th reverse lookup of the day passes');
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'reverse')$$,'P0001','daily reverse limit reached','the 101st reverse lookup of the day is refused');
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001' and kind='reverse'),100,'a refused reverse lookup is not counted');

-- Used-up reverse lookups leave searches.
insert into geocode_events(user_id,kind) select '30000000-0000-4000-8000-000000000003','reverse' from generate_series(1,100);
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000003',false,'reverse')$$,'P0001','daily reverse limit reached','another rider has used the reverse lookups');
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000003',false,'search')$$,'used-up reverse lookups leave searches');

-- Admins get 200 of each.
insert into geocode_events(user_id,kind)
  select '30000000-0000-4000-8000-000000000002',k from generate_series(1,199),unnest(array['search','reverse']) k;
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000002',true,'search')$$,'an admin may search past 30, up to 200');
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000002',true,'search')$$,'P0001','daily search limit reached','the 201st admin search is refused');
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000002',true,'reverse')$$,'an admin may look up past 100, up to 200');
select throws_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000002',true,'reverse')$$,'P0001','daily reverse limit reached','the 201st admin reverse lookup is refused');

-- Yesterday's counts (Taipei time) do not count.
update geocode_events set created_at=date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei'-interval '1 second'
  where user_id='30000000-0000-4000-8000-000000000001';
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'search')$$,'the search limit resets at Taipei midnight');
select lives_ok($$select public.geocode_count('30000000-0000-4000-8000-000000000001',false,'reverse')$$,'the reverse limit resets at Taipei midnight');

-- The daily prune still deletes counts of either kind after 30 days (#267).
update geocode_events set created_at=now()-interval '31 days'
  where user_id='30000000-0000-4000-8000-000000000001';
select usage_events_prune();
select is((select count(*)::integer from geocode_events where user_id='30000000-0000-4000-8000-000000000001'),0,'old searches and reverse lookups are pruned');
select ok((select count(*) from geocode_events where user_id='30000000-0000-4000-8000-000000000003')>0,'today''s counts stay');

select * from finish();
rollback;
