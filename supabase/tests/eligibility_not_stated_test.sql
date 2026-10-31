-- 停放資格「官方未標示」與不可留空（202610310200_eligibility_not_stated.sql, #201).
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;
create function pg_temp.report(body jsonb) returns jsonb language sql as $$
select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('e',64),repeat('e',64),body);
$$;
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;

-- ===== 契約 =====
select ok(valid_condition('{"allow":{"scooter":true,"heavy":"not_stated"}}',true),'a zone allow may say not_stated');
select ok(not valid_condition('{"allow":{"scooter":"maybe","heavy":true}}',true),'no other string');
select ok(zone_condition_consistent('{"name":"B1","condition":{"allow":{"scooter":"not_stated","heavy":false}}}'),
  'a zone that says not_stated carries no access');
select ok(not zone_condition_consistent('{"name":"B1","access":"scooterOnly","condition":{"allow":{"scooter":true,"heavy":"not_stated"}}}'),
  'nor may it');
select ok(eligibility_values_ok('{"scooter_allowed":true,"heavy_not_stated":true}'),'true and not_stated are values');
select ok(not eligibility_values_ok('{"scooter_allowed":null}'),'null alone clears a vehicle');
select ok(not eligibility_values_ok('{"scooter_allowed":true,"scooter_not_stated":true}'),'a boolean beside not_stated');
select ok(not eligibility_values_ok('{"heavy_not_stated":false}'),'not_stated false without a boolean');
select ok(eligibility_values_ok('{"name":"x"}'),'a write without vehicles');
select ok(not eligibility_stated('{"scooter_allowed":true}'),'one vehicle is not both');

-- ===== 欄位與觸發器 =====
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date,scooter_allowed,heavy_not_stated)
  values('資格測試官方點',25.071,121.571,'臺北市','offStreet','https://example.test/a','臺北市政府',current_date,true,true) returning id)
  insert into fx select 'official',id from s;
select is((select heavy_allowed from official_heavy_spots where id=(select id from fx where name='official')),null::boolean,
  'not_stated keeps the boolean null');
update official_heavy_spots set heavy_allowed=false where id=(select id from fx where name='official');
select is((select heavy_not_stated from official_heavy_spots where id=(select id from fx where name='official')),false,
  'a boolean clears not_stated');
alter table official_heavy_spots disable trigger official_heavy_spots_eligibility;
select throws_ok($$update official_heavy_spots set heavy_allowed=true,heavy_not_stated=true where id=(select id from fx where name='official')$$,
  '23514',null,'the table never holds not_stated beside a boolean');
alter table official_heavy_spots enable trigger official_heavy_spots_eligibility;
update official_heavy_spots set scooter_not_stated=true where id=(select id from fx where name='official');
select is((select scooter_allowed from official_heavy_spots where id=(select id from fx where name='official')),null::boolean,
  'newly marking not_stated clears the boolean');
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date)
  values('舊資料官方點',25.072,121.572,'臺北市','offStreet','https://example.test/b','臺北市政府',current_date) returning id)
  insert into fx select 'old',id from s;

-- ===== 讀取 =====
select ok((select scooter_not_stated from official_viewport_spots_v3(25.06,121.56,25.08,121.58) where name='資格測試官方點'),
  'the official viewport carries not_stated');
select has_column('public','public_spots','heavy_not_stated','public_spots carries not_stated');

-- ===== 管理站寫入 =====
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_upsert_spot(null,'{"kind":"official","name":"新官方點","lat":25.073,"lng":121.573,"city":"臺北市","space_type":"offStreet","source_name":"臺北市政府","source_url":"https://example.test/c","effective_date":"2026-10-31","scooter_allowed":true}')$$,
  '22023','state both vehicles: true, false or not_stated','a new official spot states both vehicles');
select ok(admin_upsert_spot(null,'{"kind":"official","name":"新官方點","lat":25.073,"lng":121.573,"city":"臺北市","space_type":"offStreet","source_name":"臺北市政府","source_url":"https://example.test/c","effective_date":"2026-10-31","scooter_allowed":true,"heavy_not_stated":true}')->>'heavy_not_stated'='true',
  'or says 官方未標示');
select throws_ok($$select admin_upsert_spot('official:'||(select id from fx where name='old'),'{"note":"現場確認"}',
  (select updated_at from official_heavy_spots where id=(select id from fx where name='old')))$$,
  '22023','state both vehicles: true, false or not_stated','editing old data fills both vehicles in');
select lives_ok($$select admin_upsert_spot('official:'||(select id from fx where name='old'),'{"closure":null}',
  (select updated_at from official_heavy_spots where id=(select id from fx where name='old')))$$,
  'the closure alone is no edit of the data');
select lives_ok($$select admin_upsert_spot('official:'||(select id from fx where name='old'),'{"note":"現場確認","scooter_allowed":false,"heavy_not_stated":true}',
  (select updated_at from official_heavy_spots where id=(select id from fx where name='old')))$$,
  'once filled in, the edit goes through');
reset role;

-- ===== 騎士新增 =====
select throws_ok($$select pg_temp.report('{"action":"create","spot":{"name":"沒填資格","lat":25.074,"lng":121.574,"city":"臺北市","space_type":"freeMotorcycle","scooter_allowed":true}}')$$,
  '22023','a new spot states both vehicles','a rider states both vehicles');
select throws_ok($$select pg_temp.report('{"action":"create","spot":{"name":"路邊未標示","lat":25.074,"lng":121.574,"city":"臺北市","space_type":"freeMotorcycle","scooter_allowed":true,"heavy_not_stated":true}}')$$,
  '22023','a new spot states both vehicles','a street spot is true or false');
select throws_ok($$select pg_temp.report('{"action":"create","spot":{"name":"分區沒填","lat":25.075,"lng":121.575,"city":"臺北市","space_type":"offStreet","scooter_allowed":true,"heavy_not_stated":true,"parking_zones":[{"name":"B1"}]}}')$$,
  '22023','a new spot states both vehicles','every zone it adds states both');
create temporary table made as select (pg_temp.report('{"action":"create","spot":{"name":"新停車場","lat":25.075,"lng":121.575,"city":"臺北市","space_type":"offStreet","scooter_allowed":true,"heavy_not_stated":true,"parking_zones":[{"name":"B1","access":"scooterOnly"},{"name":"B2","condition":{"allow":{"scooter":"not_stated","heavy":"not_stated"}}}]}}')->>'id')::uuid id;
select is((select heavy_not_stated from community_spots where id=(select id from made)),true,'a lot may say 官方未標示');
select is((select parking_zones->1->'condition'->'allow'->>'heavy' from community_spots where id=(select id from made)),'not_stated',
  'so may its zones');

-- ===== 修改建議：只有改到的分區必填 =====
update community_spots set parking_zones='[{"id":"a","name":"A","access":"scooterOnly"},{"id":"b","name":"B"}]'
  where id=(select id from made);
insert into moderation_queue(source_id,reporter_id,reason,field,proposed) values
  ((select id::text from made),'10000000-0000-4000-8000-000000000001','改 A 的說明','zones','{"parking_zones":[{"id":"a","guide":"從 B1 進"}]}'),
  ((select id::text from made),'10000000-0000-4000-8000-000000000001','改 B 的說明','zones','{"parking_zones":[{"id":"b","guide":"從 B2 進"}]}');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_resolve_report((select id from moderation_queue where reason='改 A 的說明'),'accepted',
  (select jsonb_build_object('parking_zones',proposed->'parking_zones') from moderation_queue where reason='改 A 的說明'))$$,
  'a zone already stated takes the change; the old zone beside it stays as it is');
select throws_ok($$select admin_resolve_report((select id from moderation_queue where reason='改 B 的說明'),'accepted',
  (select jsonb_build_object('parking_zones',proposed->'parking_zones') from moderation_queue where reason='改 B 的說明'))$$,
  '22023','a zone this patch changes needs both vehicles stated','a zone the patch changes must be filled in');
select lives_ok($$select admin_resolve_report((select id from moderation_queue where reason='改 B 的說明'),'accepted',
  '{"parking_zones":[{"id":"b","guide":"從 B2 進","access":"heavyOnly"}]}')$$,'with both vehicles it goes through');
reset role;

-- A suggestion for one of a vehicle's two fields conflicts with a later
-- change of the other.
update community_spots set heavy_allowed=false,heavy_not_stated=false where id=(select id from made);
insert into moderation_queue(source_id,reporter_id,reason,field,proposed) values
  ((select id::text from made),'10000000-0000-4000-8000-000000000001','重機官方未標示','eligibility','{"heavy_not_stated":true}');
update community_spots set heavy_allowed=true where id=(select id from made);
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from moderation_queue where reason='重機官方未標示'),'accepted',
  '{"heavy_not_stated":true}')$$,'40001',null,
  'a later change of the flag conflicts with a not_stated suggestion');
reset role;

-- ===== 匯入：官方資料沒寫＝官方未標示 =====
select is((admin_import_row('{"name":"x","heavy_allowed":true}',true)->>'scooter_not_stated'),'true','an official file leaving scooters out');
select is((admin_import_row('{"name":"x","heavy_allowed":true}',true)->>'heavy_not_stated'),'false','one it states');
select is((admin_import_row('{"name":"x"}',false)->>'scooter_not_stated'),'false','a community file stays unconfirmed');

-- An admin's vehicle and its not_stated are kept or replaced together.
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date,scooter_allowed,heavy_not_stated)
  values('匯入配對測試點',25.079,121.579,'臺北市','offStreet','https://example.test/i','臺北市政府',current_date,false,true) returning id)
  insert into fx select 'paired',id from s;
create temporary table file as select jsonb_build_array(jsonb_build_object(
  'id','official:'||(select id from fx where name='paired'),'source','official','name','匯入配對測試點','lat',25.079,'lng',121.579,
  'city','臺北市','space_type','offStreet','source_url','https://example.test/i','source_name','臺北市政府','scooter_allowed',false)) spots;
grant select on file to authenticated;
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_upsert_spot('official:'||(select id from fx where name='paired'),'{"heavy_allowed":true}',
  (select updated_at from official_heavy_spots where id=(select id from fx where name='paired')))$$,'an admin states heavy bikes');
reset role;
create temporary table plan as select * from admin_import_plan((select spots from file));
grant select on plan to authenticated;
select is((select status from plan),'conflict','a file leaving heavy bikes out conflicts with the admin''s value');
select is((select count(*)::integer from plan,jsonb_array_elements(changes) c
  where c->>'field' in ('heavy_allowed','heavy_not_stated') and jsonb_typeof(c->'admin')='object'),2,
  'both of the vehicle''s fields are the admin''s');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_import_apply((select spots from file),
  jsonb_build_object('official:'||(select id from fx where name='paired'),
    jsonb_build_object('base_updated_at',(select base_updated_at from plan))),current_date)$$,'the import keeps the admin''s fields');
reset role;
select ok((select heavy_allowed and not heavy_not_stated from official_heavy_spots where id=(select id from fx where name='paired')),
  'the admin''s heavy value stands');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_import_apply((select spots from file),
  jsonb_build_object('official:'||(select id from fx where name='paired'),
    jsonb_build_object('base_updated_at',(select updated_at from official_heavy_spots where id=(select id from fx where name='paired')),
      'overwrite',jsonb_build_array('heavy_allowed'))),current_date)$$,'overwriting one field');
reset role;
select ok((select heavy_allowed is null and heavy_not_stated from official_heavy_spots where id=(select id from fx where name='paired')),
  'replaces the vehicle''s two fields together');

select * from finish();
rollback;
