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

-- An official spot already imported, one the file adds, and a community one.
insert into official_heavy_spots(id,name,lat,lng,city,district,space_type,fee_note,note,source_url,source_name,source_id,
    effective_date,scooter_allowed,heavy_allowed)
  values('20000000-0000-4000-8000-000000000001','匯入測試停車場',25.04,121.51,'臺北市','中正區','offStreet','機車計次20元;','',
    'https://data.example.test/a','臺北市政府','A1','2026-10-17',true,null);
insert into community_spots(id,user_id,source,name,lat,lng,city,district,space_type,fee_note)
  values('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001','import','匯入測試社群點',
    25.05,121.52,'臺北市','中正區','offStreet','免費（大型重機比照機車費率）');

create temporary table file(spots jsonb);
grant select on file to authenticated;
insert into file values(jsonb_build_array(
  -- Unchanged except its note.
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000001','source','official','name','匯入測試停車場',
    'lat',25.04,'lng',121.51,'city','臺北市','district','中正區','space_type','offStreet','fee_note','機車計次20元;',
    'note','官方資料更新','heavy_allowed',null,'scooter_allowed',true,'source_url','https://data.example.test/a',
    'source_name','臺北市政府','source_id','A1'),
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000002','source','official','name','匯入測試新官方點',
    'lat',25.041,'lng',121.511,'city','臺北市','district','中正區','space_type','offStreet','fee_note','機車免費;',
    'fee',jsonb_build_object('scooter',jsonb_build_object('mode','free')),
    'source_url','https://data.example.test/b','source_name','臺北市政府','source_id','B1'),
  jsonb_build_object('id','20000000-0000-4000-8000-000000000003','source','import','name','匯入測試社群點（改）',
    'lat',25.05,'lng',121.52,'city','臺北市','space_type','offStreet'),
  jsonb_build_object('id','20000000-0000-4000-8000-000000000004','source','import','name','匯入測試新社群點',
    'lat',25.06,'lng',121.53,'city','臺北市','district','中山區','space_type','offStreet','heavy_allowed',true,
    'scooter_allowed',true,'fee_note','免費（大型重機比照機車費率）','parking_zones',jsonb_build_array(jsonb_build_object('name','機車區'))),
  jsonb_build_object('id','not-a-uuid','source','official','name','x'),
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000005','source','import','name','來源不符',
    'lat',25,'lng',121,'city','臺北市'),
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000006','source','official','name','海上',
    'lat',30,'lng',121,'city','臺北市','source_url','https://x.test','source_name','臺北市政府'),
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000007','source','official','name','http 來源',
    'lat',25,'lng',121,'city','臺北市','source_url','http://x.test','source_name','臺北市政府'),
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000008','source','official','name','型別錯誤',
    'lat','north','lng',121,'city','臺北市','source_url','https://x.test','source_name','臺北市政府'),
  jsonb_build_object('id','official:20000000-0000-4000-8000-000000000002','source','official','name','重複')
));
create function pg_temp.plan() returns jsonb language sql as $$
  select jsonb_object_agg(coalesce(p->>'source_id',''),p) from jsonb_array_elements(admin_import_preview((select spots from file))) p
    where p->>'reason'<>'檔案中重複的 id';
$$;

-- Only an admin with a second factor.
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select admin_import_preview('[]')$$,'42501',null,'admin without a second factor cannot preview');
select throws_ok($$select admin_import_apply('[]','{}',current_date)$$,'42501',null,'admin without a second factor cannot import');
select throws_ok($$select * from admin_fee_backlog()$$,'42501',null,'admin without a second factor cannot list fees');
select throws_ok($$select admin_convert_fees('[]')$$,'42501',null,'admin without a second factor cannot convert fees');
reset role;
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_import_preview('[]')$$,'42501',null,'ordinary user cannot preview');
select throws_ok($$select admin_convert_fees('[]')$$,'42501',null,'ordinary user cannot convert fees');
reset role;
select ok(not has_function_privilege('anon','public.admin_import_apply(jsonb,jsonb,date,text)','EXECUTE'),'anon cannot import');
select ok(not has_function_privilege('authenticated','public.admin_import_plan(jsonb)','EXECUTE'),'the plan is internal');

-- The preview sorts every entry and writes nothing.
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_import_preview((select jsonb_agg(x) from generate_series(1,501) x))$$,'22023',null,'at most 500 a call');
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->>'status','update','a changed official spot is an update');
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'changes',
  '[{"field":"note","current":"","incoming":"官方資料更新","admin":null}]'::jsonb,'only the changed field is listed');
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000002'->>'status','new','a new official spot');
select is(pg_temp.plan()->'20000000-0000-4000-8000-000000000003'->>'status','existing','existing community spots are not updated');
select is(pg_temp.plan()->'20000000-0000-4000-8000-000000000004'->>'status','new','a new community spot');
select is(pg_temp.plan()->'not-a-uuid'->>'status','invalid','an entry without a usable id');
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000005'->>'status','invalid','source must match the id');
select matches(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000006'->>'reason','座標','coordinates outside Taiwan');
select matches(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000007'->>'reason','https','official sources stay https');
select matches(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000008'->>'reason','型別','wrong types are reported');
select is((select count(*)::integer from jsonb_array_elements(admin_import_preview((select spots from file))) p
  where p->>'reason'='檔案中重複的 id'),1,'a repeated id is reported');
reset role;
select is((select count(*)::integer from official_heavy_spots where id='20000000-0000-4000-8000-000000000002'),0,'preview wrote nothing');

-- An administrator's edit is never overwritten silently.
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot('official:20000000-0000-4000-8000-000000000001','{"name":"匯入測試停車場（現場名稱）","fee_note":"機車每次 20 元"}',
  (select updated_at from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'),'現場確認')$$,'an admin edits the official spot');
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->>'status','conflict','the import would overwrite that edit');
select is((select jsonb_agg(c->>'field' order by c->>'field') from jsonb_array_elements(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'changes') c
  where jsonb_typeof(c->'admin')='object'),'["fee_note", "name"]','both edited fields are marked');
select is((select c->'admin'->>'action' from jsonb_array_elements(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'changes') c
  where c->>'field'='name'),'update_spot','with the write that set it');

-- Apply keeps the administrator's fields unless told otherwise.
create temporary table choice(value jsonb);
grant all on choice to authenticated;
insert into choice select jsonb_build_object(
  'official:20000000-0000-4000-8000-000000000001',jsonb_build_object('base_updated_at',pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'base_updated_at','overwrite','[]'::jsonb),
  'official:20000000-0000-4000-8000-000000000002',jsonb_build_object('base_updated_at',null),
  '20000000-0000-4000-8000-000000000004',jsonb_build_object('base_updated_at',null),
  '20000000-0000-4000-8000-000000000003',jsonb_build_object('base_updated_at',pg_temp.plan()->'20000000-0000-4000-8000-000000000003'->'base_updated_at'));
select throws_ok($$select admin_import_apply((select spots from file),(select value from choice),current_date,repeat('x',501))$$,'22023',null,'note length is checked');
select is(admin_import_apply((select spots from file),(select value from choice),'2026-10-26','十月匯入')-'skipped',
  '{"inserted":2,"updated":1}'::jsonb,'two new spots and one update');
reset role;
select is((select name||'|'||fee_note||'|'||note from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'),
  '匯入測試停車場（現場名稱）|機車每次 20 元|官方資料更新','edited fields kept, the rest imported');
select is((select after->'import'->'kept' from admin_audit_log where action='import_spot' and target_id='20000000-0000-4000-8000-000000000001'),
  '["name", "fee_note"]'::jsonb,'the audit entry names what was kept');
select is((select effective_date from official_heavy_spots where id='20000000-0000-4000-8000-000000000002'),'2026-10-26'::date,'new official spots take the effective date');
select is((select fee from official_heavy_spots where id='20000000-0000-4000-8000-000000000002'),'{"scooter":{"mode":"free"}}'::jsonb,'with the fee in the file');
select is((select source||'|'||status||'|'||contributor_role||'|'||user_id from community_spots where id='20000000-0000-4000-8000-000000000004'),
  'import|pending|import|10000000-0000-4000-8000-000000000001','new community spots join the earlier imports');
select ok((select heavy_verified_at is null and scooter_verified_at is null from community_spots where id='20000000-0000-4000-8000-000000000004'),
  'an import is not an administrator verifying vehicle access');
select is((select parking_zones from community_spots where id='20000000-0000-4000-8000-000000000004'),'[{"name":"機車區"}]'::jsonb,'detail columns are imported');
select is((select name from community_spots where id='20000000-0000-4000-8000-000000000003'),'匯入測試社群點','existing community spots stay as they are');
select is((select count(*)::integer from admin_audit_log where action='import_spot'),3,'every write is audited');

-- The next preview still marks the kept fields; overwriting clears them.
select pg_temp.act('admin');
set local role authenticated;
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->>'status','conflict','kept edits stay the administrator''s');
select is(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000002'->>'status','unchanged','an imported spot imports unchanged');
-- A version the preview did not show is refused.
select is(admin_import_apply((select spots from file),jsonb_build_object('official:20000000-0000-4000-8000-000000000001',
    jsonb_build_object('base_updated_at','2000-01-01T00:00:00Z','overwrite',jsonb_build_array('name'))),current_date)->'skipped'->0->>'reason',
  '試算後點位已變更，請重新試算','a stale preview is skipped');
select is(admin_import_apply((select spots from file),jsonb_build_object('official:20000000-0000-4000-8000-000000000001',
    jsonb_build_object('base_updated_at',pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'base_updated_at','overwrite',jsonb_build_array('name'))),current_date)->>'updated',
  '1','overwriting a chosen field');
select is((select jsonb_agg(c->>'field') from jsonb_array_elements(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'changes') c),
  '["fee_note"]','the overwritten field matches the file and is no longer listed');
reset role;
select is((select name from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'),'匯入測試停車場','the name came from the file');

-- Imports never touch hidden or effective_date of existing spots.
update official_heavy_spots set hidden=true where id='20000000-0000-4000-8000-000000000002';
update file set spots=jsonb_set(spots,'{1,name}','"匯入測試新官方點（改名）"');
select pg_temp.act('admin');
set local role authenticated;
select ok((pg_temp.plan()->'official:20000000-0000-4000-8000-000000000002'->>'hidden')::boolean,'the preview shows the spot is hidden');
select is(admin_import_apply((select spots from file),jsonb_build_object('official:20000000-0000-4000-8000-000000000002',
    jsonb_build_object('base_updated_at',pg_temp.plan()->'official:20000000-0000-4000-8000-000000000002'->'base_updated_at')),'2030-01-01')->>'updated',
  '1','a hidden spot can be updated');
reset role;
select is((select hidden::text||'|'||effective_date from official_heavy_spots where id='20000000-0000-4000-8000-000000000002'),
  'true|2026-10-26','hidden and effective date stay');

-- Fee conversion: a confirmed fee is written once, for the note it was read from.
select pg_temp.act('admin');
set local role authenticated;
select is((select fee_note from admin_fee_backlog() where source_id='official:20000000-0000-4000-8000-000000000001'),'機車每次 20 元','the backlog lists spots without a fee');
select ok(not exists(select 1 from admin_fee_backlog() where source_id='official:20000000-0000-4000-8000-000000000002'),'spots with a fee are not listed');
select throws_ok($$select admin_convert_fees((select jsonb_agg(x) from generate_series(1,501) x))$$,'22023',null,'at most 500 a call');
select is(admin_convert_fees(jsonb_build_array(
    jsonb_build_object('source_id','official:20000000-0000-4000-8000-000000000001','fee_note','機車每次 20 元',
      'fee',jsonb_build_object('scooter',jsonb_build_object('mode','per_visit','amount',20))),
    jsonb_build_object('source_id','20000000-0000-4000-8000-000000000003','fee_note','舊的說明',
      'fee',jsonb_build_object('scooter',jsonb_build_object('mode','free'))),
    jsonb_build_object('source_id','20000000-0000-4000-8000-000000000004','fee_note','免費（大型重機比照機車費率）',
      'fee',jsonb_build_object('scooter',jsonb_build_object('mode','same_as_scooter'))),
    jsonb_build_object('source_id','official:20000000-0000-4000-8000-000000000002','fee_note','機車免費;',
      'fee',jsonb_build_object('scooter',jsonb_build_object('mode','free'))),
    jsonb_build_object('source_id','nope','fee',jsonb_build_object())
  ),'確認轉換'),
  '{"converted":1,"skipped":[
    {"reason":"費率說明已變更，請重新讀取","source_id":"20000000-0000-4000-8000-000000000003"},
    {"reason":"費率格式不符","source_id":"20000000-0000-4000-8000-000000000004"},
    {"reason":"已有結構化費率","source_id":"official:20000000-0000-4000-8000-000000000002"},
    {"reason":"無法辨識的點位","source_id":"nope"}]}'::jsonb,
  'one written; changed notes, invalid fees and existing fees are skipped');
reset role;
select is((select fee from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'),'{"scooter":{"mode":"per_visit","amount":20}}'::jsonb,'the fee is written');
select is((select fee_note from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'),'機車每次 20 元','the note stays as written');
select is((select after->'fee' from admin_audit_log where action='convert_fee'),'{"scooter":{"mode":"per_visit","amount":20}}'::jsonb,'the conversion is audited');

-- The note stays as written, so the spot form's fee_note check
-- (202610260010) applies only to edits that touch the fee or its text.
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot('official:20000000-0000-4000-8000-000000000001','{"note":"入口在地下一樓"}',
  (select updated_at from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'))$$,
  'other edits of a converted spot still save');
select throws_ok($$select admin_upsert_spot('official:20000000-0000-4000-8000-000000000001','{"fee_note":"機車每次 20 元（舊）"}',
  (select updated_at from official_heavy_spots where id='20000000-0000-4000-8000-000000000001'))$$,
  '22023','fee_note must be the text of fee','changing the text of a converted spot follows its fee');
reset role;

-- A converted fee counts as the administrator's for the next import.
select pg_temp.act('admin');
set local role authenticated;
select is((select c->'admin'->>'action' from jsonb_array_elements(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'changes') c
  where c->>'field'='fee'),'convert_fee','a file fee for a different note conflicts with the conversion');
reset role;
update file set spots=jsonb_set(spots,'{0,fee_note}','"機車每次 20 元"');
select pg_temp.act('admin');
set local role authenticated;
select ok(not exists(select 1 from jsonb_array_elements(pg_temp.plan()->'official:20000000-0000-4000-8000-000000000001'->'changes') c
  where c->>'field' in ('fee','fee_note')),'a file without a fee keeps the stored one for the same note');
reset role;

select * from finish();
rollback;
