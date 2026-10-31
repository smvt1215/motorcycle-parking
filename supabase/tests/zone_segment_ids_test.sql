-- Stable zone and segment ids, street segments and zone suggestions
-- (202610310010_zone_segment_ids.sql, #188).
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
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
create temporary table v(at timestamptz);
grant all on v to authenticated;

-- ===== 觸發器：新增時產生 id =====
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,parking_zones)
  values('10000000-0000-4000-8000-000000000001','分區 id 測試',25.061,121.581,'臺北市','offStreet',
    '[{"name":"B1","area":"motorcycle","access":"scooterOnly"},{"name":"B2","access":"heavyOnly"},{"id":"mine","name":"B3"}]')
  returning id)
  insert into fx select 'lot',id from s;
select ok((select entries_have_ids(parking_zones) from community_spots where id=(select id from fx where name='lot')),
  'every zone gets an id on insert');
select is((select parking_zones->2->>'id' from community_spots where id=(select id from fx where name='lot')),'mine',
  'an id the writer sends is kept');
select ok((select parking_zones->0->>'id' ~ '^[a-z0-9_-]{1,32}$' from community_spots where id=(select id from fx where name='lot')),
  'a new id fits zone.id_pattern');
select isnt((select parking_zones->0->>'id' from community_spots where id=(select id from fx where name='lot')),
  (select parking_zones->1->>'id' from community_spots where id=(select id from fx where name='lot')),'new ids differ');
select is((select jsonb_array_length(parking_segments) from community_spots where id=(select id from fx where name='lot')),0,
  'segments default to an empty list');

create temporary table ids as select parking_zones->0->>'id' b1,parking_zones->1->>'id' b2
  from community_spots where id=(select id from fx where name='lot');

-- ===== 修改時保留 =====
-- A writer that sends ids back renames freely.
update community_spots set parking_zones=jsonb_set(parking_zones,'{0,name}','"B1 機車區"')
  where id=(select id from fx where name='lot');
select is((select parking_zones->0->>'id' from community_spots where id=(select id from fx where name='lot')),(select b1 from ids),
  'a rename that sends the id keeps it');
-- An old writer that drops every id keeps them by name (and area).
update community_spots set parking_zones='[{"name":"B2","access":"heavyOnly"},{"name":"B1 機車區","area":"motorcycle","access":"scooterOnly"},{"name":"B3"},{"name":"B4"}]'
  where id=(select id from fx where name='lot');
select is((select parking_zones->0->>'id' from community_spots where id=(select id from fx where name='lot')),(select b2 from ids),
  'an id-less zone takes the id of the old zone with its name');
select is((select parking_zones->1->>'id' from community_spots where id=(select id from fx where name='lot')),(select b1 from ids),
  'reordering keeps ids');
select is((select parking_zones->2->>'id' from community_spots where id=(select id from fx where name='lot')),'mine',
  'a writer-chosen id is kept by name too');
select ok((select parking_zones->3->>'id' not in ((select b1 from ids),(select b2 from ids),'mine')
  from community_spots where id=(select id from fx where name='lot')),'a new zone gets a new id');
-- Two zones of the same name: neither is the old one.
update community_spots set parking_zones='[{"name":"B2","access":"heavyOnly"},{"name":"B2","access":"heavyOnly"}]'
  where id=(select id from fx where name='lot');
select ok((select parking_zones->0->>'id'<>parking_zones->1->>'id' from community_spots where id=(select id from fx where name='lot')),
  'duplicate names still get distinct ids');

-- ===== 檢查 =====
select throws_ok($$update community_spots set parking_zones='[{"id":"a","name":"B1"},{"id":"a","name":"B2"}]'
  where id=(select id from fx where name='lot')$$,'23514',null,'duplicate ids are refused');
select throws_ok($$update community_spots set parking_zones='[{"id":"B1","name":"B1"}]'
  where id=(select id from fx where name='lot')$$,'23514',null,'an id outside the pattern is refused');
select throws_ok($$update community_spots set parking_zones='[{"name":"B1","evidence_url":"http://x.tw/a.jpg"}]'
  where id=(select id from fx where name='lot')$$,'23514',null,'a zone evidence_url must be https');
select lives_ok($$update community_spots set parking_zones='[{"name":"B1","evidence_url":"https://x.tw/a.jpg"}]'
  where id=(select id from fx where name='lot')$$,'an https zone evidence_url is kept');

-- ===== 路段 =====
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,condition,parking_segments)
  values('10000000-0000-4000-8000-000000000001','南京東路三段路邊機車格',25.052,121.543,'臺北市','paidMotorcycle',
    '{"bay":"motorcycle","use":"usual","charge":"toll"}',
    '[{"name":"北側一般機車格","side":"north","range":"建國北路口至松江路口","total":18,
       "condition":{"bay":"motorcycle","use":"usual"}},
      {"name":"南側汽機車共用格","side":"south","condition":{"bay":"car","use":"share","share":"car_motorcycle"}}]')
  returning id)
  insert into fx select 'street',id from s;
select ok((select entries_have_ids(parking_segments) from community_spots where id=(select id from fx where name='street')),
  'every segment gets an id');
select is((select condition_bay_kind(parking_segments->1->'condition') from community_spots where id=(select id from fx where name='street')),
  'car_motorcycle','a segment''s condition reads as its bay kind');
select throws_ok($$update community_spots set parking_segments='[{"name":"北側","condition":{"bay":"motorcycle","allow":{"scooter":true}}}]'
  where id=(select id from fx where name='street')$$,'23514',null,'a segment condition takes no allow');
select throws_ok($$update community_spots set parking_segments='[{"name":" "}]'
  where id=(select id from fx where name='street')$$,'23514',null,'a segment needs a name');
create temporary table sids as select parking_segments->0->>'id' n,parking_segments->1->>'id' s
  from community_spots where id=(select id from fx where name='street');
grant select on sids to authenticated;
update community_spots set parking_segments='[{"name":"南側汽機車共用格","side":"south"},{"name":"北側一般機車格","side":"north","total":20}]'
  where id=(select id from fx where name='street');
select is((select parking_segments->1->>'id' from community_spots where id=(select id from fx where name='street')),(select n from sids),
  'an id-less segment takes the id of the old one with its name and side');

-- The public viewport and the anon grant carry segments.
set local role anon;
select is((select jsonb_array_length(parking_segments) from public_spots where id=(select id from fx where name='street')),2,
  'public_spots carries the segments');
reset role;

-- ===== 管理站寫入 =====
set local role authenticated;
select pg_temp.act('admin');
insert into v select updated_at from community_spots where id=(select id from fx where name='street');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='street'),
  jsonb_build_object('parking_segments',jsonb_build_array(
    jsonb_build_object('id',(select n from sids),'name','北側','side','north','evidence_url','https://x.tw/n.jpg'))),
  (select at from v),'')$$,'admins write segments');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='street'),
  '{"parking_segments":[{"name":"北側","fee":{}}]}',(select updated_at from community_spots where id=(select id from fx where name='street')),'')$$,
  '22023','invalid parking_segments','an invalid segment list is named');
reset role;
select is((select parking_segments->0->>'id' from community_spots where id=(select id from fx where name='street')),(select n from sids),
  'the admin edit keeps the segment id');

-- ===== 新增停車點帶路段 =====
create temporary table made as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","device_id":"00000000-0000-4000-8000-000000000009","spot":{"name":"新路段","lat":25.071,"lng":121.591,
    "city":"臺北市","space_type":"freeMotorcycle","condition":{"bay":"motorcycle","use":"usual","charge":"free"},
    "parking_segments":[{"name":"東側","side":"east","condition":{"bay":"motorcycle"}}]}}')->>'id')::uuid id;
select is((select parking_segments->0->>'name' from community_spots where id=(select id from made)),'東側',
  'a new spot keeps its segments');
select ok((select entries_have_ids(parking_segments) from community_spots where id=(select id from made)),'with ids');
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","device_id":"00000000-0000-4000-8000-000000000009","spot":{"name":"附依據","lat":25.081,"lng":121.601,
    "city":"臺北市","space_type":"freeMotorcycle","condition":{"bay":"motorcycle","use":"usual","charge":"free"},
    "parking_segments":[{"name":"東側","condition":{"bay":"motorcycle","basis":{"source_url":"https://x.tw"}}}]}}')$$,
  '22023','a report cannot set a condition basis','a rider cannot set a segment basis');

-- ===== entries_patch() =====
select is(entries_patch('[{"id":"a","name":"A","guide":"x"},{"id":"b","name":"B"}]','[{"id":"a","guide":null,"area":"car"}]'),
  '[{"id":"a","name":"A","area":"car"},{"id":"b","name":"B"}]'::jsonb,'a patch changes the named entry; null clears a key');
select is(entries_patch('[{"id":"a","name":"A"},{"id":"b","name":"B"}]','[{"id":"a","removed":true},{"name":"C","guide":null}]'),
  '[{"id":"b","name":"B"},{"name":"C"}]'::jsonb,'removed takes an entry out; one without an id is added');
select is(entries_patch('[{"id":"a","name":"A"}]','[{"id":"z","name":"Z"}]'),null,'an unknown id is refused');
select is(entries_patch('[{"id":"a","name":"A"}]','[{"id":"a","removed":true,"name":"A"}]'),null,'a removal carries nothing else');
select is(entries_patch('[{"id":"a","name":"A"}]','[{"name":"A","removed":true}]'),null,'a new entry cannot be removed');
select is(entries_patch('[]','{"id":"a"}'),null,'a patch is a list');
select ok(not entries_patch_conflict('[{"id":"a","name":"A"},{"id":"b","name":"B"}]','[{"id":"a","name":"A"},{"id":"b","name":"B2"}]',
  '[{"id":"a","guide":"x"},{"name":"C"}]'),'another entry''s change is no conflict');
select ok(entries_patch_conflict('[{"id":"a","name":"A"}]','[{"id":"a","name":"A2"}]','[{"id":"a","guide":"x"}]'),
  'a change to the named entry is');
select ok(entries_patch_conflict('[{"id":"a","name":"A"}]','[]','[{"id":"a","removed":true}]'),'so is its removal');

-- ===== 修改建議改分區（admin_resolve_report） =====
update community_spots set parking_zones='[{"id":"b1","name":"B1","access":"scooterOnly"},{"id":"b2","name":"B2","access":"heavyOnly"}]'
  where id=(select id from fx where name='lot');
insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='lot'),'10000000-0000-4000-8000-000000000002','修改分區','note',
    '{"parking_zones":[{"id":"b1","guide":"走右側坡道"},{"id":"b2","removed":true},{"name":"B3","access":"scooterHeavy"}]}');
insert into fx select 'report',id from moderation_queue where reason='修改分區';
select ok((select base_spot ? 'parking_zones' from moderation_queue where id=(select id from fx where name='report')),
  'the snapshot keeps the zones a report changes');
insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='lot'),'10000000-0000-4000-8000-000000000001','改名','name','{"name":"x"}');
select ok(not (select base_spot ? 'parking_zones' from moderation_queue where reason='改名'),'and only those');
-- Another zone changes meanwhile: no conflict.
update community_spots set parking_zones=jsonb_set(parking_zones,'{1,guide}','"重機走左側"')
  where id=(select id from fx where name='lot');
set local role authenticated;
select pg_temp.act('admin');
select throws_ok($$select admin_resolve_report((select id from fx where name='report'),'accepted',
  '{"parking_zones":[{"id":"b9","guide":"x"}]}')$$,'22023','parking_zones names an entry the spot does not have',
  'a patch naming no current zone is refused');
reset role;
-- B2 changed since the report, and the patch removes it: a conflict.
set local role authenticated;
select pg_temp.act('admin');
select throws_ok($$select admin_resolve_report((select id from fx where name='report'),'accepted',
  (select jsonb_build_object('parking_zones',proposed->'parking_zones') from moderation_queue where id=(select id from fx where name='report')))$$,
  '40001',null,'a change to a zone the patch names is a conflict');
select lives_ok($$select admin_resolve_report((select id from fx where name='report'),'accepted',
  '{"parking_zones":[{"id":"b1","guide":"走右側坡道"},{"name":"B3","access":"scooterHeavy"}]}')$$,
  'patching only the unchanged zone applies');
reset role;
select is((select jsonb_array_length(parking_zones) from community_spots where id=(select id from fx where name='lot')),3,
  'B1 changed, B2 kept, B3 added');
select is((select parking_zones->0->>'guide' from community_spots where id=(select id from fx where name='lot')),'走右側坡道',
  'the patched zone');
select is((select parking_zones->0->>'id' from community_spots where id=(select id from fx where name='lot')),'b1','keeps its id');
select ok((select parking_zones->2 ? 'id' from community_spots where id=(select id from fx where name='lot')),'the new zone has an id');

-- ===== 匯入比較不看 id =====
select is(zones_without_plans('[{"id":"b1","name":"B1","fee_plan":"p1"}]'),'[{"name":"B1"}]'::jsonb,
  'imports compare zones without ids or plan references');

select * from finish();
rollback;
