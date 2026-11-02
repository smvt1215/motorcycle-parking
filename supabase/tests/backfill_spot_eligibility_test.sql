-- 依條目回填點位層資格旗標（202611020200_backfill_spot_eligibility.sql，#188）：
-- 和條目不一致的旗標改成觸發器會算出的值，一致的與沒有條目的點位不動，
-- 重跑不再改任何東西；有改到才推進 spots 資料版本、寫一筆稽核摘要。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select ok(not has_function_privilege('anon','private.backfill_spot_eligibility()','execute')
  and not has_function_privilege('authenticated','private.backfill_spot_eligibility()','execute')
  and not has_function_privilege('service_role','private.backfill_spot_eligibility()','execute'),
  'only the owner runs the backfill');

-- Whatever this database already had out of step is put right first, so the
-- counts below are the fixtures'.
select private.backfill_spot_eligibility();

insert into auth.users(id,instance_id,aud,role,email) values
  ('10000000-0000-4000-8000-0000000000b1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b1@example.test')
  on conflict do nothing;
create temporary table fx(name text primary key,id uuid);
with s as (insert into community_spots(user_id,source,name,lat,lng,city,space_type,status,parking_zones) values
  ('10000000-0000-4000-8000-0000000000b1','import','舊旗標停車場',25.0,121.5,'臺北市','offStreet','pending',
   '[{"name":"機車區","access":"scooterHeavy"}]') returning id) insert into fx select 'lot',id from s;
with s as (insert into community_spots(user_id,source,name,lat,lng,city,space_type,status,parking_zones) values
  ('10000000-0000-4000-8000-0000000000b1','import','一致停車場',25.001,121.501,'臺北市','offStreet','pending',
   '[{"name":"機車區","access":"scooterOnly"}]') returning id) insert into fx select 'same',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,parking_segments) values
  ('10000000-0000-4000-8000-0000000000b1','舊旗標路段',25.002,121.502,'臺北市','paidMotorcycle',true,false,
   '[{"name":"南側","condition":{"allow":{"scooter":false,"heavy":"not_stated"}}}]') returning id) insert into fx select 'street',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed) values
  ('10000000-0000-4000-8000-0000000000b1','沒有條目',25.003,121.503,'臺北市','paidMotorcycle',true,true) returning id)
  insert into fx select 'bare',id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,facility_type,source_url,effective_date,heavy_allowed,parking_zones)
  values('舊旗標官方場',25.004,121.504,'臺北市','offStreet','underground','https://example.test/o',current_date,true,
   '[{"name":"機車區","access":"scooterHeavy"}]') returning id) insert into fx select 'official',id from s;

-- Put the flags out of step the way rows written before the trigger are.
alter table community_spots disable trigger user;
alter table official_heavy_spots disable trigger user;
update community_spots set scooter_allowed=null,scooter_not_stated=false,scooter_verified_at=now(),heavy_verified_at=now()
  where id=(select id from fx where name='lot');
update community_spots set scooter_allowed=true,heavy_allowed=false,heavy_not_stated=false
  where id=(select id from fx where name='street');
update community_spots set scooter_allowed=false,heavy_allowed=null,heavy_not_stated=false
  where id=(select id from fx where name='bare');
update official_heavy_spots set scooter_allowed=null,scooter_not_stated=false where id=(select id from fx where name='official');
alter table community_spots enable trigger user;
alter table official_heavy_spots enable trigger user;

create temporary table before_rows as
  select 'c' tbl,id,to_jsonb(c) r from community_spots c where id in (select id from fx)
  union all select 'o',id,to_jsonb(o) from official_heavy_spots o where id in (select id from fx);
create temporary table v0 as select version from data_versions where key='spots';
create temporary table a0 as select count(*) n from admin_audit_log where action='backfill_eligibility';

select is(private.backfill_spot_eligibility(),'{"community_spots":2,"official_heavy_spots":1}'::jsonb,
  'the out-of-step spots are the ones updated');

select is((select array[coalesce(scooter_allowed::text,'null'),scooter_not_stated::text,heavy_allowed::text,heavy_not_stated::text]
  from community_spots where id=(select id from fx where name='lot')),array['true','false','true','false'],
  'a lot takes what its zones say');
select is((select array[coalesce(scooter_verified_at::text,'null'),(heavy_verified_at is not null)::text]
  from community_spots where id=(select id from fx where name='lot')),array['null','true'],
  'a changed flag loses its check, an unchanged one keeps it');
select is((select array[scooter_allowed::text,coalesce(heavy_allowed::text,'null'),heavy_not_stated::text]
  from community_spots where id=(select id from fx where name='street')),array['false','null','true'],
  'a street spot takes what its segments say, not_stated included');
select is((select coalesce(scooter_allowed::text,'null') from official_heavy_spots where id=(select id from fx where name='official')),
  'true','an official spot too');
select is((select to_jsonb(c)-'scooter_allowed'-'scooter_not_stated'-'heavy_allowed'-'heavy_not_stated'
    -'scooter_verified_at'-'heavy_verified_at' from community_spots c where id=(select id from fx where name='lot')),
  (select r-'scooter_allowed'-'scooter_not_stated'-'heavy_allowed'-'heavy_not_stated'
    -'scooter_verified_at'-'heavy_verified_at' from before_rows where id=(select id from fx where name='lot')),
  'nothing but the flags changes (text, entries, updated_at)');
select is((select to_jsonb(c) from community_spots c where id=(select id from fx where name='same')),
  (select r from before_rows where id=(select id from fx where name='same')),'a spot in step is left alone');
select is((select to_jsonb(c) from community_spots c where id=(select id from fx where name='bare')),
  (select r from before_rows where id=(select id from fx where name='bare')),'a spot without entries is left alone');

select is((select version from data_versions where key='spots'),(select version+1 from v0),'the spots version moves once');
select is((select count(*) from admin_audit_log where action='backfill_eligibility'),(select n+1 from a0),'one audit entry');
select is((select after from admin_audit_log where action='backfill_eligibility' order by id desc limit 1),
  '{"community_spots":2,"official_heavy_spots":1}'::jsonb,'that records the counts only');
select is((select count(*)::int from pg_trigger where tgrelid in ('community_spots'::regclass,'official_heavy_spots'::regclass)
  and not tgisinternal and tgenabled<>'O'),0,'the triggers are enabled again');

-- Again: nothing to do.
select is(private.backfill_spot_eligibility(),'{"community_spots":0,"official_heavy_spots":0}'::jsonb,'a second run changes nothing');
select is((select version from data_versions where key='spots'),(select version+1 from v0),'nor the spots version');
select is((select count(*) from admin_audit_log where action='backfill_eligibility'),(select n+1 from a0),'nor writes an audit entry');

-- The result is what the trigger keeps: an ordinary update leaves the flags.
update community_spots set note='車道較窄' where id=(select id from fx where name='lot');
select is((select scooter_allowed from community_spots where id=(select id from fx where name='lot')),true,
  'the trigger agrees with the backfill');

select * from finish();
rollback;
