begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Display metadata is untrusted text, not a role. Never fall back to email.
update auth.users set raw_app_meta_data='{"role":"user","provider":"google"}',
  raw_user_meta_data='{"display_name":"  小\n哲\t🛵  ","full_name":"舊姓名","role":"admin"}'
  where id='10000000-0000-4000-8000-000000000001';
update auth.users set raw_app_meta_data='{"role":"user","provider":"google"}',
  raw_user_meta_data='{"display_name":42,"full_name":"  王小明  "}'
  where id='10000000-0000-4000-8000-000000000002';
update auth.users set raw_app_meta_data='{"role":"user"}',
  raw_user_meta_data=jsonb_build_object('name',repeat('車',60))
  where id='10000000-0000-4000-8000-000000000003';
update auth.users set raw_user_meta_data='{}',email='private-contributor@example.test'
  where id='10000000-0000-4000-8000-000000000004';
update auth.users set raw_app_meta_data='{"role":"admin","provider":"google"}',
  raw_user_meta_data='{"display_name":"私人管理員姓名"}'
  where id='10000000-0000-4000-8000-000000000005';

insert into community_spots(id,user_id,name,lat,lng,city,space_type,contributor_name,contributor_role)
values('75000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','回報者一',25.091,121.611,'臺北市','offStreet','偽造姓名','admin'),
  ('75000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','回報者二',25.092,121.612,'臺北市','offStreet','','admin'),
  ('75000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','回報者三',25.093,121.613,'臺北市','offStreet','','rider'),
  ('75000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000004','無姓名',25.094,121.614,'臺北市','offStreet','','rider'),
  ('75000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000005','管理員新增',25.095,121.615,'臺北市','offStreet','偽造姓名','rider');
insert into community_spots(id,user_id,name,lat,lng,city,space_type,source,source_name,contributor_name,contributor_role)
values('75000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000001','授權匯入',25.096,121.616,'臺北市','offStreet','import','社群回報整理','偽造姓名','rider');

select is((select contributor_name from community_spots where id='75000000-0000-4000-8000-000000000001'),'小 哲 🛵','custom name is trimmed to a single line');
select is((select contributor_role from community_spots where id='75000000-0000-4000-8000-000000000001'),'rider','user metadata and supplied row fields cannot claim admin');
select is((select contributor_name from community_spots where id='75000000-0000-4000-8000-000000000002'),'王小明','wrong metadata type falls back to provider full name');
select is((select char_length(contributor_name) from community_spots where id='75000000-0000-4000-8000-000000000003'),40,'names are bounded by Unicode characters');
select is((select contributor_name from community_spots where id='75000000-0000-4000-8000-000000000004'),'','missing names never fall back to email');
select is((select contributor_role||'|'||contributor_name from community_spots where id='75000000-0000-4000-8000-000000000005'),'admin|','trusted admin identity needs no public personal name');
select is((select contributor_role||'|'||contributor_name||'|'||source_name from community_spots where id='75000000-0000-4000-8000-000000000006'),'import||社群回報整理','imports preserve source credits and expose no owner name');

update community_spots set name='修改停車資訊',contributor_name='改寫作者',contributor_role='admin'
  where id='75000000-0000-4000-8000-000000000001';
select is((select contributor_name||'|'||contributor_role from community_spots where id='75000000-0000-4000-8000-000000000001'),'小 哲 🛵|rider','edits cannot rewrite the public name or the role');
update auth.users set raw_user_meta_data='{"display_name":"新名稱","full_name":"舊姓名"}' where id='10000000-0000-4000-8000-000000000001';
select is((select string_agg(contributor_name,',' order by id) from community_spots where id in('75000000-0000-4000-8000-000000000001','75000000-0000-4000-8000-000000000006')),'新名稱,',
  'renaming the account updates its reported points, imports stay unnamed');
update auth.users set raw_user_meta_data='{"full_name":"王小明"}' where id='10000000-0000-4000-8000-000000000002';
update auth.users set raw_user_meta_data='{"display_name":"自訂暱稱","full_name":"王小明"}' where id='10000000-0000-4000-8000-000000000002';
select is((select contributor_name from community_spots where id='75000000-0000-4000-8000-000000000002'),'自訂暱稱','a name set in the app takes precedence over the provider name');
update auth.users set raw_app_meta_data='{"role":"admin"}' where id='10000000-0000-4000-8000-000000000002';
update community_spots set note='角色變更後編輯' where id='75000000-0000-4000-8000-000000000002';
select is((select contributor_role from community_spots where id='75000000-0000-4000-8000-000000000002'),'rider','the role is fixed when the point is created');
create temporary table attribution_report as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"name":"新回報使用新姓名","lat":25.098,"lng":121.618,"city":"臺北市","space_type":"offStreet","contributor_name":"假管理員","contributor_role":"admin"}}')->>'id')::uuid as id;
select is((select contributor_name||'|'||contributor_role from community_spots where id=(select id from attribution_report)),'新名稱|rider','create RPC uses the server-side account name and ignores client claims');

update auth.users set deleted_at=now() where id='10000000-0000-4000-8000-000000000003';
select is((select contributor_name||'|'||contributor_role from community_spots where id='75000000-0000-4000-8000-000000000003'),'|rider','a deleted account no longer shows its name');

-- Moderation: only an administrator with a second factor clears a name, audited.
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}',true);
set local role authenticated;
select throws_ok($$select public.admin_clear_contributor_name('75000000-0000-4000-8000-000000000001','冒犯字眼')$$,'42501',null,'riders cannot clear names');
reset role;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select throws_ok($$select public.admin_clear_contributor_name('75000000-0000-4000-8000-000000000001','冒犯字眼')$$,'42501',null,'clearing a name needs a second factor');
reset role;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select throws_ok($$select public.admin_clear_contributor_name('75000000-0000-4000-8000-0000000000ff','')$$,'22023',null,'missing points are rejected');
select is(public.admin_clear_contributor_name('75000000-0000-4000-8000-000000000001','  冒犯字眼  ')->>'contributor_name','','administrators clear a public name');
select is(public.admin_upsert_spot(null,'{"kind":"community","name":"管理站新增","lat":25.099,"lng":121.619,"city":"臺北市","space_type":"freeMotorcycle"}')->>'contributor_role',
  'admin','admin create RPC works with the private contributor trigger');
reset role;
select set_config('request.jwt.claims','',true);
select is((select actor::text||'|'||(before->>'contributor_name')||'|'||(after->>'contributor_name')||'|'||note from admin_audit_log
  where action='clear_contributor_name' and target_id='75000000-0000-4000-8000-000000000001'),
  '10000000-0000-4000-8000-000000000005|新名稱||冒犯字眼','clearing is audited with the removed name');
update auth.users set raw_user_meta_data='{"display_name":"再改名"}' where id='10000000-0000-4000-8000-000000000001';
select is((select contributor_name from community_spots where id='75000000-0000-4000-8000-000000000001')||'|'||
  (select contributor_name from community_spots where id=(select id from attribution_report)),'|再改名',
  'a cleared name stays cleared after renaming, other points follow the account');

insert into official_heavy_spots(id,name,lat,lng,city,source_url,source_name,effective_date,fee)
values('75000000-0000-4000-8000-000000000007','官方回報者測試',25.097,121.617,'臺北市','https://example.test/attribution','臺北市政府',current_date,'{"heavy":{"mode":"free"}}');

set local role anon;
select is((select contributor_role from viewport_spots_v2(25.09,121.61,25.10,121.62) where id='75000000-0000-4000-8000-000000000001'),'rider','v2 community viewport exposes only public attribution');
select is((select contributor_name from viewport_spots(25.09,121.61,25.10,121.62) where id='75000000-0000-4000-8000-000000000002'),'自訂暱稱','legacy viewport preserves attribution compatibility');
select is((select contributor_role||'|'||contributor_name||'|'||source_name||'|'||(fee->'heavy'->>'mode') from official_viewport_spots_v2(25.09,121.61,25.10,121.62)
  where id='official:75000000-0000-4000-8000-000000000007'),'admin||臺北市政府|free','official v2 keeps government source and structured fee');
select is((select contributor_role from official_viewport_spots(25.09,121.61,25.10,121.62)
  where id='official:75000000-0000-4000-8000-000000000007'),'admin','legacy official viewport also has attribution');
select throws_ok($$select user_id from public_spots$$,'42703',null,'public view has no contributor account ids');
select throws_ok($$select user_id from community_spots$$,'42501',null,'raw contributor account ids stay private');
select throws_ok($$select email from auth.users$$,'42501',null,'auth emails remain private');
select ok(not has_function_privilege('anon','public.spot_contributor_name(uuid,uuid,text)','EXECUTE'),'anonymous callers cannot look up arbitrary account names');
select ok(not has_function_privilege('authenticated','public.spot_contributor_name(uuid,uuid,text)','EXECUTE'),'signed-in callers cannot look up arbitrary account names');
select ok(not has_function_privilege('authenticated','public.spot_contributor_role(uuid,text)','EXECUTE'),'signed-in callers cannot probe account roles');
select ok(not has_function_privilege('anon','public.admin_clear_contributor_name(uuid,text)','EXECUTE'),'anonymous callers cannot moderate names');
select throws_ok($$select spot_id from contributor_name_clears$$,'42501',null,'moderation records stay private');
reset role;

select * from finish();
rollback;
