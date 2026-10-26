begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.version_of(k text) returns bigint language sql as $$
  select version from public.data_versions where key=k
$$;
create temporary table v0 as select key,version from data_versions;
create function pg_temp.started_at(k text) returns bigint language sql as $$
  select version from v0 where key=k
$$;

select is((select count(*)::integer from data_versions),2,'one version row per dataset');
select is((select count(*)::integer from data_versions where key in ('spots','rules')),2,'datasets are spots and rules');

-- Community spots: one bump per statement, however many rows it touches.
insert into community_spots(user_id,name,lat,lng,city,space_type) values
('10000000-0000-4000-8000-000000000001','[測試] 版本A',25.00,121.50,'臺北市','paidMotorcycle'),
('10000000-0000-4000-8000-000000000001','[測試] 版本B',25.001,121.501,'臺北市','paidMotorcycle');
select is(pg_temp.version_of('spots'),pg_temp.started_at('spots')+1,'a two-row community insert bumps spots once');
select is(pg_temp.version_of('rules'),pg_temp.started_at('rules'),'a community insert leaves rules alone');
update community_spots set status='hidden' where name='[測試] 版本A';
select is(pg_temp.version_of('spots'),pg_temp.started_at('spots')+2,'moderating a community spot bumps spots');
delete from community_spots where name='[測試] 版本B';
select is(pg_temp.version_of('spots'),pg_temp.started_at('spots')+3,'deleting a community spot bumps spots');

-- Official spots.
insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date)
  values('[測試] 官方版本',25.05,121.57,'臺北市','https://example.test/notice',current_date);
select is(pg_temp.version_of('spots'),pg_temp.started_at('spots')+4,'an official spot insert bumps spots');
update official_heavy_spots set note='改過' where name='[測試] 官方版本';
select is(pg_temp.version_of('spots'),pg_temp.started_at('spots')+5,'an official spot edit bumps spots');
select ok((select updated_at>now()-interval '1 minute' from data_versions where key='spots'),'spots updated_at follows the bump');

-- Rules bump their own key only.
update city_rules set fee_note=fee_note where vehicle='heavy';
select is(pg_temp.version_of('rules'),pg_temp.started_at('rules')+1,'a rules edit bumps rules');
select is(pg_temp.version_of('spots'),pg_temp.started_at('spots')+5,'a rules edit leaves spots alone');

-- Apps subscribe anonymously: they read every row, write nothing, and get
-- the row through Realtime.
select ok(exists(select 1 from pg_publication_tables
  where pubname='supabase_realtime' and schemaname='public' and tablename='data_versions'),
  'data_versions is in the Realtime publication');
select ok(not has_function_privilege('anon','public.bump_data_version()','execute'),'anon cannot execute the bump function');
select ok(not has_function_privilege('authenticated','public.bump_data_version()','execute'),'authenticated cannot execute the bump function');
set local role anon;
select is((select count(*)::integer from data_versions),2,'anon reads both versions');
select throws_ok($$update data_versions set version=version+1 where key='spots'$$,'42501','permission denied for table data_versions','anon cannot bump a version');
select throws_ok($$insert into data_versions(key) values('spots')$$,'42501','permission denied for table data_versions','anon cannot add a version row');

select * from finish();
rollback;
