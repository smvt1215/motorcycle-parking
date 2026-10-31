-- Fee plans (202610270023_fee_plans.sql, design §2.6). The plan contract
-- itself runs in parking_contract_test.sql from the shared cases; this
-- covers the write-time sync, the checks, the readers and import.
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select is(fee_plan_name('{"scooter":{"mode":"hourly","amount":10,"per_minutes":60},"heavy":{"mode":"same_as_scooter"}}'),
  '機車重機計時','a name from the vehicles and the shared mode');
select is(fee_plan_name('{"car":{"mode":"by_time","periods":[{"days":"all","rate":{"mode":"free"}}]}}'),'汽車時段','by_time');
select is(fee_plan_name('{"scooter":{"mode":"free"},"heavy":{"mode":"daily","amount":30}}'),'機車重機混合','modes that differ');

-- A lot reported by a rider: the zones' fees become plans, the same fee one plan.
create temporary table lot as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"name":"計費規則測試","lat":25.09,"lng":121.61,"city":"臺北市","space_type":"offStreet",
    "parking_zones":[
      {"name":"B1","access":"scooterHeavy","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
      {"name":"B2","access":"scooterHeavy","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
      {"name":"B3","access":"heavyCar","fee":{"car":{"mode":"hourly","amount":40,"per_minutes":60},"heavy":{"mode":"same_as_car"}}}]}}')->>'id')::uuid as id;
grant select on lot to anon,authenticated;
select is((select fee_plans from community_spots where id=(select id from lot)),
  '[{"id":"p1","name":"機車計時","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
    {"id":"p2","name":"重機汽車計時","fee":{"car":{"mode":"hourly","amount":40,"per_minutes":60},"heavy":{"mode":"same_as_car"}}}]'::jsonb,
  'zones at one price share one plan');
select is((select jsonb_agg(z->>'fee_plan' order by n) from community_spots c,jsonb_array_elements(c.parking_zones) with ordinality x(z,n)
  where c.id=(select id from lot)),'["p1","p1","p2"]'::jsonb,'each zone refers to its plan');
select is((select parking_zones->2->'fee' from community_spots where id=(select id from lot)),
  '{"car":{"mode":"hourly","amount":40,"per_minutes":60},"heavy":{"mode":"same_as_car"}}'::jsonb,'and keeps the plan''s fee as its own');

-- Builds that read only fee see the rates as before, in every viewport.
set local role anon;
select is((select parking_zones->0->'fee'->'scooter'->>'amount' from viewport_spots_v2(25.08,121.60,25.10,121.62) where id=(select id from lot)),
  '10','v2 returns each zone''s fee');
select is((select parking_zones->2->'fee'->'car'->>'amount' from viewport_spots(25.08,121.60,25.10,121.62) where id=(select id from lot)),
  '40','the original viewport too');
select is((select parking_zones->1->'fee'->'scooter'->>'amount' from viewport_spots_v3(25.08,121.60,25.10,121.62) where id=(select id from lot)),
  '10','and v3');
reset role;

-- A plan edited in place (an admin later, C6): every zone that refers to it follows.
update community_spots set fee_plans=jsonb_set(fee_plans,'{0,fee}','{"scooter":{"mode":"hourly","amount":15,"per_minutes":60}}')
  where id=(select id from lot);
select is((select jsonb_agg(z->'fee'->'scooter'->>'amount' order by n) from community_spots c,jsonb_array_elements(c.parking_zones) with ordinality x(z,n)
  where c.id=(select id from lot) and z->>'fee_plan'='p1'),'["15","15"]'::jsonb,'zones follow their plan');

-- A writer that knows nothing of plans changes one zone's fee: that zone
-- gets its own plan; the others keep theirs.
update community_spots set parking_zones=jsonb_set(parking_zones,'{0,fee}','{"scooter":{"mode":"free"}}')
  where id=(select id from lot);
select is((select parking_zones->0->>'fee_plan'||'|'||(parking_zones->1->>'fee_plan') from community_spots where id=(select id from lot)),
  'p3|p1','a changed zone fee gets a plan of its own');
select is((select jsonb_array_length(fee_plans) from community_spots where id=(select id from lot)),3,'the shared plan stays');

-- Files and older writers send zones without references: the plans are
-- found again by fee, and plans nobody refers to any more are dropped.
update community_spots set parking_zones=zones_without_plans(parking_zones)
  where id=(select id from lot);
select is((select parking_zones->0->>'fee_plan'||'|'||(parking_zones->2->>'fee_plan') from community_spots where id=(select id from lot)),
  'p3|p2','the same fee finds the same plan');
update community_spots set parking_zones='[{"name":"B1","access":"scooterHeavy","fee":{"scooter":{"mode":"free"}}}]'
  where id=(select id from lot);
select is((select fee_plans from community_spots where id=(select id from lot)),
  '[{"id":"p3","name":"機車免費","fee":{"scooter":{"mode":"free"}}}]'::jsonb,'plans left behind are dropped');

-- A street spot refers to its plan from the top level.
create temporary table street as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"路邊規則測試","lat":25.091,"lng":121.611,"city":"臺北市","space_type":"paidMotorcycle",
    "fee":{"heavy":{"mode":"per_visit","amount":40}},"fee_note":"大型重機每次 40 元（隔日是否另計未確認）"}}')->>'id')::uuid as id;
select is((select fee_plan||'|'||(fee_plans->0->>'name')||'|'||(fee->'heavy'->>'amount') from community_spots where id=(select id from street)),
  'p1|重機計次|40','a street spot''s fee becomes its plan');
update community_spots set fee='{"heavy":{"mode":"per_visit","amount":50}}',fee_note='大型重機每次 50 元（隔日是否另計未確認）'
  where id=(select id from street);
select is((select fee_plan||'|'||(fee_plans::text) from community_spots where id=(select id from street)),
  'p1|[{"id": "p1", "fee": {"heavy": {"mode": "per_visit", "amount": 50}}, "name": "重機計次"}]','a changed fee replaces the plan nobody else uses');
update community_spots set fee=null,fee_note='請依現場公告' where id=(select id from street);
select is((select coalesce(fee_plan,'-')||'|'||coalesce(fee_plans::text,'-') from community_spots where id=(select id from street)),
  '-|-','a cleared fee drops its plan');

-- The checks: a reference to a missing plan, or a copy that differs.
select throws_ok($$update community_spots set fee_plan='p9' where id=(select id from street)$$,'23514',null,
  'a reference to a missing plan is refused');
select throws_ok($$update community_spots set fee_plans='[{"id":"p1","name":"","fee":{"scooter":{"mode":"free"}}}]',fee_plan='p1'
  where id=(select id from street)$$,'23514',null,'a plan without a name is refused');
select throws_ok($$update community_spots set fee_plans=(select jsonb_agg(jsonb_build_object('id','p'||i,'name','規則'||i,
    'fee',jsonb_build_object('scooter',jsonb_build_object('mode','daily','amount',i)))) from generate_series(1,13) i)
  where id=(select id from street)$$,'23514',null,'at most 12 plans');
select ok(not valid_fee_plans('[{"id":"p1","name":"機車免費","fee":{"scooter":{"mode":"free"}}}]','p1','{"scooter":{"mode":"daily","amount":5}}','[]'),
  'a copy that differs from its plan is refused');

-- Promotion copies the zones (with their references) but not the plans;
-- the references are found again by fee.
insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date,parking_zones)
values('規則官方點',25.09,121.61,'臺北市','offStreet','https://example.test/plans','臺北市政府',current_date,
  '[{"name":"機車區","fee_plan":"p7","fee":{"heavy":{"mode":"free"}}}]');
select is((select (parking_zones->0->>'fee_plan')||'|'||(fee_plans->0->>'id') from official_heavy_spots where name='規則官方點'),
  'p1|p1','a reference to a plan the row lacks is taken in by its fee');
-- A zone reference without a fee is a cleared fee (decision 51): the
-- reference goes, whether or not the plan exists.
insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date,parking_zones)
values('規則官方點二',25.09,121.61,'臺北市','offStreet','https://example.test/plans','臺北市政府',current_date,
  '[{"name":"機車區","fee_plan":"p7"}]');
select is((select zones_without_plans(parking_zones)||jsonb_build_array(fee_plans) from official_heavy_spots where name='規則官方點二'),
  '[{"name":"機車區"},null]'::jsonb,'a zone reference without a fee is dropped, not refused');
-- A top-level reference to a missing plan beside no fee is still refused.
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date,fee_plan)
  values('規則官方點三',25.09,121.61,'臺北市','paidMotorcycle','https://example.test/plans','臺北市政府',current_date,'p7')$$,
  '23514',null,'a spot reference without a plan or a fee is refused');

-- Import compares zones as files write them, without references.
insert into official_heavy_spots(id,name,lat,lng,city,district,space_type,fee_note,note,source_url,source_name,source_id,effective_date,
    parking_zones)
  values('23000000-0000-4000-8000-000000000001','規則匯入點',25.04,121.51,'臺北市','中正區','offStreet','請依現場公告','',
    'https://data.example.test/p','臺北市政府','P1','2026-10-17','[{"name":"機車區","fee":{"heavy":{"mode":"free"}}}]');
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select ok(not exists(select 1 from jsonb_array_elements(admin_import_preview(jsonb_build_array(jsonb_build_object(
    'id','official:23000000-0000-4000-8000-000000000001','source','official','name','規則匯入點',
    'lat',25.04,'lng',121.51,'city','臺北市','district','中正區','space_type','offStreet','fee_note','請依現場公告',
    'source_url','https://data.example.test/p','source_name','臺北市政府','source_id','P1',
    'parking_zones',jsonb_build_array(jsonb_build_object('name','機車區','fee',jsonb_build_object('heavy',jsonb_build_object('mode','free'))))
  )))->0->'changes') c where c->>'field'='parking_zones'),'a re-imported zone is no change');
reset role;

-- Choosing another plan for a zone copies that plan's fee, even though the
-- zone still carries the old plan's copy.
update community_spots set fee_plans='[{"id":"p1","name":"機車免費","fee":{"scooter":{"mode":"free"}}},
    {"id":"p2","name":"機車計次","fee":{"scooter":{"mode":"per_visit","amount":20}}}]',
  parking_zones='[{"name":"B1","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}}]'
  where id=(select id from lot);
update community_spots set parking_zones=jsonb_set(parking_zones,'{0,fee_plan}','"p2"') where id=(select id from lot);
select is((select (parking_zones->0)-'id' from community_spots where id=(select id from lot)),
  '{"name":"B1","fee_plan":"p2","fee":{"scooter":{"mode":"per_visit","amount":20}}}'::jsonb,'a zone switched to another plan takes its fee');

-- Editing a street spot's plan keeps its fee_note the fee's sentence.
update community_spots set fee='{"heavy":{"mode":"per_visit","amount":40}}',fee_note='大型重機每次 40 元（隔日是否另計未確認）'
  where id=(select id from street);
update community_spots set fee_plans=jsonb_set(fee_plans,'{0,fee}','{"heavy":{"mode":"free"}}') where id=(select id from street);
select is((select fee_note||'|'||(fee->'heavy'->>'mode') from community_spots where id=(select id from street)),
  '大型重機免費|free','an edited plan rewrites the sentence beside its copy');

-- A promoted spot's zones stay the administrator's for the next import.
create temporary table promoted(id text);
grant select,insert on promoted to authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
insert into promoted select admin_promote_spot((select id::text from lot),
  '{"source_name":"臺北市政府","source_url":"https://example.test/promoted","effective_date":"2026-10-25"}',
  (select updated_at from community_spots where id=(select id from lot)))->>'id';
select is((select c->'admin'->>'action' from jsonb_array_elements(admin_import_preview(jsonb_build_array(jsonb_build_object(
    'id','official:'||(select id from promoted),'source','official','name','計費規則測試',
    'lat',25.09,'lng',121.61,'city','臺北市','space_type','offStreet',
    'source_url','https://example.test/promoted','source_name','臺北市政府','source_id','X',
    'parking_zones',jsonb_build_array(jsonb_build_object('name','別的分區'))
  )))->0->'changes') c where c->>'field'='parking_zones'),'promote_spot',
  'promoted zones with plan references are still the administrator''s');
reset role;

-- ===== #155 第 1–3 項（決定 51，202610270080_fee_plans_edges.sql） =====

-- 1. A zone that keeps fee_plan but loses its fee (no key, JSON null, {})
-- drops the reference; a plan nobody else uses goes with it.
update community_spots set fee_plans='[{"id":"p1","name":"機車免費","fee":{"scooter":{"mode":"free"}}},
    {"id":"p2","name":"機車計次","fee":{"scooter":{"mode":"per_visit","amount":20}}}]',
  parking_zones='[{"name":"B1","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}},
    {"name":"B2","fee_plan":"p2","fee":{"scooter":{"mode":"per_visit","amount":20}}},
    {"name":"B3","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}}]'
  where id=(select id from lot);
update community_spots set parking_zones=jsonb_set(parking_zones,'{0}',(parking_zones->0)-'fee') where id=(select id from lot);
select is((select ((parking_zones->0)-'id')||jsonb_build_object('plans',jsonb_array_length(fee_plans)) from community_spots where id=(select id from lot)),
  '{"name":"B1","plans":2}'::jsonb,'a zone without a fee key drops its reference; the shared plan stays');
update community_spots set parking_zones=jsonb_set(parking_zones,'{2,fee}','null') where id=(select id from lot);
select is((select ((parking_zones->2)-'id')||jsonb_build_object('plans',fee_plans) from community_spots where id=(select id from lot)),
  '{"name":"B3","plans":[{"id":"p2","name":"機車計次","fee":{"scooter":{"mode":"per_visit","amount":20}}}]}'::jsonb,
  'a zone fee of JSON null is not filled back: both keys go, and the plan nobody uses too');
update community_spots set parking_zones=jsonb_set(parking_zones,'{1,fee}','{}') where id=(select id from lot);
select is((select ((parking_zones->1)-'id')||jsonb_build_object('plans',fee_plans) from community_spots where id=(select id from lot)),
  '{"name":"B2","fee":{},"plans":null}'::jsonb,'a zone fee of {} clears it the same way');

-- 2. Zones are matched by name and area, not by place.
create temporary table two_zones as select
  '[{"id":"p1","name":"機車免費","fee":{"scooter":{"mode":"free"}}},
    {"id":"p2","name":"機車計次","fee":{"scooter":{"mode":"per_visit","amount":20}}}]'::jsonb as plans,
  '[{"name":"A","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}},
    {"name":"B","fee_plan":"p2","fee":{"scooter":{"mode":"per_visit","amount":20}}}]'::jsonb as zones;
update community_spots set fee_plans=(select plans from two_zones),parking_zones=(select zones from two_zones) where id=(select id from lot);
-- An older writer deletes A and raises B's fee in one write.
update community_spots set parking_zones=jsonb_build_array(
    jsonb_set(parking_zones->1,'{fee}','{"scooter":{"mode":"per_visit","amount":30}}'))
  where id=(select id from lot);
select is((select (parking_zones->0->'fee'->'scooter'->>'amount')||'|'||(parking_zones->0->>'fee_plan'=fee_plans->0->>'id')::text
    ||'|'||jsonb_array_length(fee_plans) from community_spots where id=(select id from lot)),
  '30|true|1','deleting a zone and editing another keeps the edit');
update community_spots set fee_plans=(select plans from two_zones),parking_zones=(select zones from two_zones) where id=(select id from lot);
-- Zones reordered in the write that edits B.
update community_spots set parking_zones=jsonb_build_array(
    jsonb_set(parking_zones->1,'{fee}','{"scooter":{"mode":"per_visit","amount":30}}'),parking_zones->0)
  where id=(select id from lot);
select is((select (parking_zones->0->>'name')||':'||(parking_zones->0->'fee'->'scooter'->>'amount')
    ||'|'||(parking_zones->1->>'name')||':'||(parking_zones->1->>'fee_plan')||':'||(parking_zones->1->'fee'->'scooter'->>'mode')
  from community_spots where id=(select id from lot)),'B:30|A:p1:free','reordering zones while editing one keeps the edit');
-- Choosing another plan is still read by name: B switched to p1 with p2's copy takes p1's fee.
update community_spots set fee_plans=(select plans from two_zones),parking_zones=(select zones from two_zones) where id=(select id from lot);
update community_spots set parking_zones=jsonb_build_array(jsonb_set(parking_zones->1,'{fee_plan}','"p1"'),parking_zones->0)
  where id=(select id from lot);
select is((select (parking_zones->0)-'id' from community_spots where id=(select id from lot)),
  '{"name":"B","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}}'::jsonb,'a zone that switches plan while moving takes the plan''s fee');
-- Area is part of the match: the same name in another area is a new zone,
-- whose reference is a choice of plan.
update community_spots set fee_plans=(select plans from two_zones),
  parking_zones='[{"name":"機車區","area":"motorcycle","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}}]' where id=(select id from lot);
update community_spots set parking_zones='[{"name":"機車區","area":"heavy","fee_plan":"p1","fee":{"scooter":{"mode":"per_visit","amount":30}}}]'
  where id=(select id from lot);
select is((select parking_zones->0->'fee' from community_spots where id=(select id from lot)),
  '{"scooter":{"mode":"free"}}'::jsonb,'a zone with no stored match is new: its reference copies the plan');
-- The same name and area pair up in order.
update community_spots set fee_plans=(select plans from two_zones),
  parking_zones='[{"name":"B","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}},
    {"name":"B","fee_plan":"p2","fee":{"scooter":{"mode":"per_visit","amount":20}}}]' where id=(select id from lot);
update community_spots set parking_zones=jsonb_set(parking_zones,'{1,fee}','{"scooter":{"mode":"per_visit","amount":30}}')
  where id=(select id from lot);
select is((select (parking_zones->0->'fee'->'scooter'->>'mode')||'|'||(parking_zones->1->'fee'->'scooter'->>'amount')
  from community_spots where id=(select id from lot)),'free|30','zones of one name and area pair up in order');

-- 3. Removing a plan still referred to in the write that changes the plans is refused.
update community_spots set fee_plans=(select plans from two_zones),parking_zones=(select zones from two_zones) where id=(select id from lot);
select throws_ok($$update community_spots set fee_plans=fee_plans-1 where id=(select id from lot)$$,'23503','fee plan in use',
  'removing a plan a zone still uses is refused');
create temporary table caught(detail jsonb);
do $$ begin
  update community_spots set fee_plans=fee_plans-1 where id=(select id from lot);
exception when foreign_key_violation then
  declare d text; begin get stacked diagnostics d=pg_exception_detail; insert into caught values(d::jsonb); end;
end $$;
select is((select detail from caught),'{"plans":[{"id":"p2","name":"機車計次","zones":1,"spot":false}]}'::jsonb,
  'the detail names the plan and how many zones use it');
select is((select fee_plans->1->>'name' from community_spots where id=(select id from lot)),'機車計次','and the plan is not rebuilt');
select lives_ok($$update community_spots set fee_plans=fee_plans-1,parking_zones=jsonb_set(parking_zones,'{1,fee_plan}','"p1"')
  where id=(select id from lot)$$,'a plan can go once its zones point elsewhere in the same write');
select is((select parking_zones->1->'fee' from community_spots where id=(select id from lot)),
  '{"scooter":{"mode":"free"}}'::jsonb,'and those zones take their new plan''s fee');
update community_spots set fee_plans=(select plans from two_zones),parking_zones=(select zones from two_zones) where id=(select id from lot);
select lives_ok($$update community_spots set fee_plans=fee_plans-1,parking_zones=jsonb_set(parking_zones,'{1,fee}','null')
  where id=(select id from lot)$$,'or once the zones that used it clear their fee');
select lives_ok($$update community_spots set fee_plans=jsonb_set(fee_plans,'{0,name}','"平日免費"') where id=(select id from lot)$$,
  'renaming a plan in use is no removal');
select is((select fee_plans->0->>'name' from community_spots where id=(select id from lot)),'平日免費','the administrator''s name stays');
select throws_ok($$update community_spots set fee_plans=null where id=(select id from street)$$,'23503','fee plan in use',
  'removing the plan a street spot refers to is refused');

-- Riders never read or write plans directly.
select ok(not has_column_privilege('anon','public.community_spots','fee_plans','select'),'anon cannot read plans');
select ok(not has_function_privilege('anon','public.fee_plans_sync(jsonb,jsonb)','execute'),'the sync is not public');

select * from finish();
rollback;
