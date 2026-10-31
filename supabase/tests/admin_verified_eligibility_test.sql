begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'admin_aal1' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}'
  when 'none' then ''
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;
create function pg_temp.spot(p_id uuid) returns community_spots language sql as $$
  select * from community_spots where id=p_id;
$$;

create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;

-- Rows written outside an admin JWT (riders' reports, the importer) start
-- unverified, whatever the write itself says.
select pg_temp.act('none');
with s as (insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,scooter_allowed,heavy_allowed,
    status,scooter_verified_at,heavy_verified_at)
  values('10000000-0000-4000-8000-000000000001','import','核驗測試停車場',25.083,121.557,'臺北市','中山區','offStreet',null,true,
    'confirmed',now(),now()) returning id)
  insert into fx select 'lot',id from s;
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'an import cannot claim verification');

-- The columns are public through the view but never writable by a client.
select ok(has_column_privilege('anon','public.community_spots','heavy_verified_at','SELECT'),'anon reads the verification time');
select pg_temp.act('user');
set local role authenticated;
update community_spots set heavy_verified_at=now() where id=(select id from fx where name='lot');
reset role;
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'a rider cannot write it');
select ok(not has_function_privilege('authenticated','public.community_spots_vehicle_verification()','EXECUTE'),'the trigger function is private');
select has_column('public','public_spots','scooter_verified_at','the public view carries scooter verification');
select has_column('public','public_spots','heavy_verified_at','the public view carries heavy verification');

-- A rider-side change of anything else keeps no verification it never had,
-- and an admin without a second factor cannot verify.
select pg_temp.act('admin_aal1');
update community_spots set scooter_allowed=true where id=(select id from fx where name='lot');
select is((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'aal1 is not an admin write');

-- An admin setting a vehicle's access in Admin Web verifies that vehicle.
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),'{"scooter_allowed":false}',
  (select updated_at from community_spots where id=(select id from fx where name='lot')))$$,'an admin sets scooter access');
reset role;
select isnt((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'the scooter flag is verified');
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'the untouched heavy flag is not');
-- parking_access states both vehicles.
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),'{"parking_access":"scooterHeavy","scooter_allowed":true}',
  (select updated_at from community_spots where id=(select id from fx where name='lot')))$$,'an admin sets shared access');
reset role;
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'shared access verifies the heavy flag');
select is((select heavy_verified_at is not null and scooter_verified_at is not null from public_spots where id=(select id from fx where name='lot')),
  true,'the public view shows both times');

-- A client write cannot move the times; an unrelated non-admin edit keeps them.
select pg_temp.act('none');
update community_spots set heavy_verified_at='2000-01-01',note='騎士補充' where id=(select id from fx where name='lot');
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,'2000-01-01'::timestamptz,'a write cannot set the time');
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'unrelated edits keep verification');
-- Votes confirming the spot keep it too.
update community_spots set status='confirmed',last_confirmed_at=now() where id=(select id from fx where name='lot');
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'confirmation votes keep verification');

-- A non-admin change of one flag voids that vehicle only.
update community_spots set heavy_allowed=false where id=(select id from fx where name='lot');
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'a rider-side flag change voids it');
select isnt((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'the other vehicle stays verified');
-- Moving the spot or changing its bay voids both.
update community_spots set space_type='car' where id=(select id from fx where name='lot');
select is((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'a rider-side bay change voids both');

-- An accepted report applied by an admin verifies the flag it sets.
select pg_temp.act('none');
insert into moderation_queue(source_id,reason,field,proposed) values((select id::text from fx where name='lot'),'重機可停','heavy_allowed','{"heavy_allowed":true}');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_resolve_report((select id from moderation_queue where source_id=(select id::text from fx where name='lot') and status='pending'),
  'accepted','{"heavy_allowed":true}','',true)$$,'an admin adopts a report');
reset role;
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'adopting the flag verifies it');

-- Restating a value already stored verifies it too.
select pg_temp.act('none');
update community_spots set space_type='offStreet' where id=(select id from fx where name='lot');
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'unverified again before the restatement');
insert into moderation_queue(source_id,reason,field,proposed) values((select id::text from fx where name='lot'),'重機可停','heavy_allowed','{"heavy_allowed":true}');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_resolve_report((select id from moderation_queue where source_id=(select id::text from fx where name='lot') and status='pending'),
  'accepted','{"heavy_allowed":true}','',true)$$,'an admin adopts a report that agrees with the row');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),'{"scooter_allowed":true}',
  (select updated_at from community_spots where id=(select id from fx where name='lot')))$$,'an admin restates scooter access');
reset role;
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'adopting an unchanged flag verifies it');
select isnt((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'restating an unchanged flag verifies it');
select is(current_setting('app.admin_vehicle_fields',true),'','the RPCs leave no stated fields behind');

-- An admin moving the spot without restating access voids the old check;
-- restating one vehicle keeps only that one.
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),'{"lat":25.084,"heavy_allowed":true}',
  (select updated_at from community_spots where id=(select id from fx where name='lot')))$$,'an admin moves the spot and restates heavy access');
reset role;
select is((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'a move voids the vehicle not restated');
select isnt((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'the restated vehicle stays verified');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),'{"facility_type":"multiStorey"}',
  (select updated_at from community_spots where id=(select id from fx where name='lot')))$$,'an admin changes the lot type only');
reset role;
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'a lot type change voids the old check');

-- Outside an admin JWT, naming fields grants nothing.
select pg_temp.act('none');
select set_config('app.admin_vehicle_fields','scooter_allowed,heavy_allowed',true);
update community_spots set note='偽造' where id=(select id from fx where name='lot');
select is((pg_temp.spot((select id from fx where name='lot'))).scooter_verified_at,null,'a forged field list does not verify');
select set_config('app.admin_vehicle_fields','',true);
-- Clearing a flag clears its verification.
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),'{"heavy_not_stated":true}',
  (select updated_at from community_spots where id=(select id from fx where name='lot')))$$,'an admin marks heavy access not stated');
reset role;
select is((pg_temp.spot((select id from fx where name='lot'))).heavy_verified_at,null,'an unknown flag is not verified');

-- An admin-created spot is verified for the flags it sets.
select pg_temp.act('admin');
set local role authenticated;
select is((admin_upsert_spot(null,'{"scooter_not_stated":true,"kind":"community","name":"核驗新增點","lat":25.05,"lng":121.55,"city":"臺北市","space_type":"offStreet","heavy_allowed":true}')
  ->>'heavy_verified_at') is not null,true,'an admin-created flag is verified');
reset role;
select is((select scooter_verified_at from community_spots where name='核驗新增點'),null,'an unset flag on create is not');

-- The audit-log backfill: only admin writes that set a flag (or the shared
-- access) and whose result the row still holds.
select pg_temp.act('none');
with s as (insert into community_spots(user_id,source,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,parking_access)
  values('10000000-0000-4000-8000-000000000001','import','回填測試',25.1,121.5,'臺北市','offStreet',true,true,'scooterHeavy') returning id)
  insert into fx select 'backfill',id from s;
with s as (insert into community_spots(user_id,source,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed)
  values('10000000-0000-4000-8000-000000000001','import','回填移動',25.2,121.5,'臺北市','offStreet',true,true) returning id)
  insert into fx select 'moved',id from s;
create function pg_temp.row_of(p_id uuid) returns jsonb language sql as $$
  select to_jsonb(c)-'location' from community_spots c where c.id=p_id;
$$;
insert into admin_audit_log(actor,action,target_table,target_id,before,after,created_at) values
  -- Set parking_access (both vehicles) on a row that still matches.
  ('10000000-0000-4000-8000-000000000005','update_spot','community_spots',(select id::text from fx where name='backfill'),
    pg_temp.row_of((select id from fx where name='backfill'))||'{"parking_access":null}',
    pg_temp.row_of((select id from fx where name='backfill')),'2026-10-20 01:00+00'),
  -- A later edit of something else does not verify, nor undo the earlier one.
  ('10000000-0000-4000-8000-000000000005','update_spot','community_spots',(select id::text from fx where name='backfill'),
    pg_temp.row_of((select id from fx where name='backfill')),
    pg_temp.row_of((select id from fx where name='backfill'))||'{"note":"x"}','2026-10-21 01:00+00'),
  -- Set heavy access, but the spot has moved since.
  ('10000000-0000-4000-8000-000000000005','update_spot','community_spots',(select id::text from fx where name='moved'),
    pg_temp.row_of((select id from fx where name='moved'))||'{"heavy_allowed":null,"lat":25.3}',
    pg_temp.row_of((select id from fx where name='moved'))||'{"lat":25.3}','2026-10-20 01:00+00');
select is((select count(*)::integer from vehicle_verification_backfill() b where b.id=(select id from fx where name='backfill')),2,
  'a shared-access edit the row still holds backfills both vehicles');
select is((select verified_at from vehicle_verification_backfill() b where b.id=(select id from fx where name='backfill') and flag='heavy_allowed'),
  '2026-10-20 01:00+00'::timestamptz,'the backfill keeps the audit time');
select is((select count(*)::integer from vehicle_verification_backfill() b where b.id=(select id from fx where name='moved')),0,
  'a spot changed since the admin write is not backfilled');
select ok(not has_function_privilege('authenticated','public.vehicle_verification_backfill()','EXECUTE'),'the backfill is private');

select * from finish();
rollback;
