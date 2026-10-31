begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'admin_aal1' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;

create temporary table fx(name text primary key,id uuid,at timestamptz);
grant select on fx to authenticated,anon;
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,scooter_allowed,heavy_allowed,address)
  values('10000000-0000-4000-8000-000000000001','點位頁測試社群點',25.051,121.571,'臺北市','松山區','offStreet',true,true,'民生東路四段 1 號') returning id,updated_at)
  insert into fx select 'community',id,updated_at from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date,scooter_allowed,heavy_allowed)
  values('點位頁測試官方點',25.052,121.572,'臺北市','https://example.test/notice','臺北市政府',current_date,true,true) returning id,updated_at)
  insert into fx select 'official',id,updated_at from s;

-- Only an admin with a second factor.
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select * from admin_spots('點位頁')$$,'42501',null,'admin without a second factor cannot search');
select throws_ok($$select admin_upsert_spot(null,'{"scooter_allowed":true,"heavy_allowed":true,"kind":"community","name":"x","lat":25,"lng":121,"city":"臺北市","space_type":"car"}')$$,'42501',null,'admin without a second factor cannot create');
reset role;
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_promote_spot((select id::text from fx where name='community'),'{}',now())$$,'42501',null,'ordinary user cannot promote');
reset role;
select ok(not has_function_privilege('anon','public.admin_upsert_spot(text,jsonb,timestamptz,text)','EXECUTE'),'anon cannot call upsert');
select ok(not has_function_privilege('anon','public.admin_promote_spot(text,jsonb,timestamptz,text)','EXECUTE'),'anon cannot call promote');

-- Search spans both tables and filters by kind and state.
select pg_temp.act('admin');
set local role authenticated;
select is((select count(*)::integer from admin_spots('點位頁測試')),2,'search finds community and official spots');
select is((select kind from admin_spots('點位頁測試','official')),'official','kind filter');
select is((select source_id from admin_spots('民生東路四段')),(select id::text from fx where name='community'),'search covers addresses');
select is((select count(*)::integer from admin_spots('100%')),0,'wildcards in the query are literal');
select throws_ok($$select * from admin_spots('',null,'gone')$$,'22023',null,'unknown state is refused');

-- Edits name the version they were opened with.
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),'{"name":"新名"}',now()-interval '1 day')$$,
  '40001','spot changed since it was opened','an edit over a newer version is refused');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),'{"user_id":"10000000-0000-4000-8000-000000000005"}',(select at from fx where name='community'))$$,
  '22023',null,'fields outside the edit list are refused');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),'{"status":"hidden"}',(select at from fx where name='community'))$$,
  '22023',null,'hiding goes through its own RPC');
select throws_ok($$select admin_upsert_spot('official:'||(select id from fx where name='official'),'{"source_url":"http://x"}',(select at from fx where name='official'))$$,
  '22023',null,'official sources stay https');
select is(admin_upsert_spot((select id::text from fx where name='community'),'{"name":"點位頁測試社群點（改）","fee_note":"每次 20 元"}',(select at from fx where name='community'),'現場確認')->>'name',
  '點位頁測試社群點（改）','an admin edits a community spot');
select throws_ok($$select admin_upsert_spot('official:'||(select id from fx where name='official'),'{"heavy_allowed":null}',(select at from fx where name='official'))$$,
  '22023',null,'an edit never clears a vehicle (#201)');
select is(admin_upsert_spot('official:'||(select id from fx where name='official'),'{"heavy_not_stated":true,"source_name":"臺北市停管處"}',(select at from fx where name='official'))->>'source_name',
  '臺北市停管處','an admin edits an official spot');
reset role;
select is((select fee_note from community_spots where id=(select id from fx where name='community')),'每次 20 元','the edit reached the row');
select is((select heavy_allowed from official_heavy_spots where id=(select id from fx where name='official')),null::boolean,'official eligibility can be not stated');
select is((select heavy_not_stated from official_heavy_spots where id=(select id from fx where name='official')),true,'官方未標示 is stored');
select is((select note from admin_audit_log where action='update_spot' and target_id=(select id::text from fx where name='community')),'現場確認','edits are audited');

-- Creating.
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_upsert_spot(null,'{"scooter_allowed":true,"heavy_allowed":true,"kind":"official","name":"新官方點","lat":25.06,"lng":121.58,"city":"臺北市","space_type":"heavyOnly","source_url":"https://example.test","effective_date":"2026-10-25"}')$$,
  '22023',null,'a new official spot needs a source name');
select ok(admin_upsert_spot(null,'{"scooter_allowed":true,"heavy_allowed":true,"kind":"official","name":"新官方點","lat":25.06,"lng":121.58,"city":"臺北市","space_type":"heavyOnly","source_name":"臺北市政府","source_url":"https://example.test","effective_date":"2026-10-25"}')->>'source_id' like 'official:%',
  'an admin creates an official spot');
select is(admin_upsert_spot(null,'{"scooter_allowed":true,"heavy_allowed":true,"kind":"community","name":"管理者新增點","lat":25.061,"lng":121.581,"city":"臺北市","space_type":"freeMotorcycle"}')->>'status',
  'pending','an admin creates a pending community spot');
reset role;
select is((select user_id from community_spots where name='管理者新增點'),'10000000-0000-4000-8000-000000000005'::uuid,'an admin-created community spot records the admin');
select is((select count(*)::integer from admin_audit_log where action='create_spot'),2,'creations are audited');

-- Promotion: official source required, rider eligibility never carried over.
update fx set at=(select updated_at from community_spots where id=fx.id) where name='community';
with s as (insert into moderation_queue(source_id,reason) values((select id::text from fx where name='community'),'收費資訊：每次 30 元') returning id)
  insert into fx select 'q_open',id,null from s;
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_promote_spot((select id::text from fx where name='community'),'{"scooter_allowed":true,"heavy_allowed":true,"source_url":"https://example.test/lot","effective_date":"2026-10-25"}',(select at from fx where name='community'))$$,
  '22023',null,'promotion needs a source name');
select throws_ok($$select admin_promote_spot((select id::text from fx where name='community'),'{"scooter_allowed":true,"heavy_allowed":true,"source_name":"臺北市政府","source_url":"https://example.test/lot","effective_date":"2026-10-25"}',now()-interval '1 day')$$,
  '40001','spot changed since it was opened','promotion over a newer version is refused');
select throws_ok($$select admin_promote_spot((select id::text from fx where name='community'),
  '{"source_name":"臺北市政府","source_url":"https://example.test/lot","effective_date":"2026-10-25","scooter_allowed":true}',
  (select at from fx where name='community'))$$,'22023',null,'a promotion states both vehicles (#201)');
select ok(admin_promote_spot((select id::text from fx where name='community'),
  '{"source_name":"臺北市政府","source_url":"https://example.test/lot","effective_date":"2026-10-25","scooter_allowed":true,"heavy_not_stated":true}',
  (select at from fx where name='community'),'比對停管處場站資料')->>'source_id' like 'official:%','an admin promotes a community spot');
reset role;
select is((select heavy_allowed from official_heavy_spots where name='點位頁測試社群點（改）'),null::boolean,'the rider''s heavy eligibility does not carry over');
select is((select heavy_not_stated from official_heavy_spots where name='點位頁測試社群點（改）'),true,'the admin says the official data does not state heavy bikes');
select is((select scooter_allowed from official_heavy_spots where name='點位頁測試社群點（改）'),true,'eligibility the admin states is kept');
select is((select fee_note from official_heavy_spots where name='點位頁測試社群點（改）'),'每次 20 元','other fields carry over');
select is((select status from community_spots where id=(select id from fx where name='community')),'hidden','the community row is hidden, not deleted');
select is((select source_id from moderation_queue where id=(select id from fx where name='q_open')),
  'official:'||(select id from official_heavy_spots where name='點位頁測試社群點（改）'),'open reports follow the promoted spot');
select is((select before->>'user_id' from admin_audit_log where action='promote_spot'),'10000000-0000-4000-8000-000000000001','the audit keeps the full community snapshot');
select is((select before->>'heavy_allowed' from admin_audit_log where action='promote_spot'),'true','the snapshot keeps the rider''s values');

select * from finish();
rollback;
