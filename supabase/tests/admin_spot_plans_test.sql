-- Admin spot form fee plans and zones (202610270090_admin_spot_plans.sql):
-- reading every column, writing zones and plans, and applying a fee to a
-- shared plan from the review page.
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

-- A lot whose B1 and B2 share the 機車計時 plan.
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,parking_zones)
  values('10000000-0000-4000-8000-000000000001','規則表單測試',25.051,121.571,'臺北市','offStreet',
    '[{"name":"B1","area":"motorcycle","access":"scooterHeavy","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
      {"name":"B2","area":"motorcycle","access":"scooterHeavy","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}}]')
  returning id)
  insert into fx select 'lot',id from s;
update community_spots set fee=parking_zones->0->'fee',fee_note=fee_note_of(parking_zones->0->'fee'),
    fee_source_text='機車每小時10元' where id=(select id from fx where name='lot');

-- ===== 讀取 =====
-- #201: fixtures written before eligibility was required state both
-- vehicles (官方未標示 where they left one out), without touching updated_at.
alter table community_spots disable trigger user;
alter table official_heavy_spots disable trigger user;
update community_spots set scooter_not_stated=scooter_allowed is null,heavy_not_stated=heavy_allowed is null
  where scooter_allowed is null or heavy_allowed is null;
update official_heavy_spots set scooter_not_stated=scooter_allowed is null,heavy_not_stated=heavy_allowed is null
  where scooter_allowed is null or heavy_allowed is null;
alter table community_spots enable trigger user;
alter table official_heavy_spots enable trigger user;
set local role authenticated;
select pg_temp.act('user');
select throws_ok($$select admin_spot_rows(array[(select id::text from fx where name='lot')])$$,'42501',null,
  'only admins read every column');
select pg_temp.act('admin');
select is(jsonb_array_length(admin_spot_rows(array[(select id::text from fx where name='lot'),'official:00000000-0000-4000-8000-000000000000','x'])),
  1,'unknown ids are skipped');
select is((admin_spot_rows(array[(select id::text from fx where name='lot')])->0->'fee_plans'->0->>'name'),'機車計時',
  'the plans and their names');
select is((admin_spot_rows(array[(select id::text from fx where name='lot')])->0->>'fee_source_text'),'機車每小時10元',
  'the source text');
select is((admin_spot_rows(array[(select id::text from fx where name='lot')])->0->>'source_id'),(select id::text from fx where name='lot'),
  'with its source id');
select ok(not (admin_spot_rows(array[(select id::text from fx where name='lot')])->0 ? 'user_id'),'never the reporter');
select throws_ok($$select fee_source_text from community_spots limit 1$$,'42501',null,'the column itself stays ungranted');

-- ===== 寫入：改名、加規則、分區改選 =====
create temporary table v(at timestamptz);
grant all on v to authenticated;
insert into v select updated_at from community_spots where id=(select id from fx where name='lot');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),
  jsonb_build_object(
    'fee_plans','[{"id":"p1","name":"機車平日","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
                  {"id":"p2","name":"機車計次","fee":{"scooter":{"mode":"per_visit","amount":20}}}]'::jsonb,
    'parking_zones','[{"name":"B1","area":"motorcycle","access":"scooterHeavy","fee_plan":"p1","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}},
                      {"name":"B2","area":"motorcycle","access":"scooterOnly","fee_plan":"p2","fee":{"scooter":{"mode":"free"}},
                       "condition":{"bay":"motorcycle","use":"usual","charge":"toll","allow":{"scooter":true,"heavy":false}}}]'::jsonb),
  (select at from v),'規則')$$,'renames a plan, adds one and moves a zone to it');
reset role;
select is((select fee_plans->0->>'name' from community_spots where id=(select id from fx where name='lot')),'機車平日','the new name');
select is((select parking_zones->1->'fee' from community_spots where id=(select id from fx where name='lot')),
  '{"scooter":{"mode":"per_visit","amount":20}}'::jsonb,'the zone carries its new plan''s fee');
select is((select parking_zones->1->>'access' from community_spots where id=(select id from fx where name='lot')),'scooterOnly',
  'with its condition and access');

-- A plan still in use cannot go.
set local role authenticated;
delete from v; insert into v select updated_at from community_spots where id=(select id from fx where name='lot');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),
  '{"fee_plans":[{"id":"p1","name":"機車平日","fee":{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}}]}',
  (select at from v),'')$$,'23503','fee plan in use','removing a plan a zone uses is refused');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='lot'),
  '{"parking_zones":[{"name":"B1","access":"heavyOnly","condition":{"bay":"motorcycle","allow":{"scooter":true,"heavy":false}}}]}',
  (select at from v),'')$$,'22023','invalid parking_zones','a zone whose access is not its condition''s is named');

-- ===== 新增 =====
select is((admin_upsert_spot(null,'{"scooter_allowed":true,"heavy_allowed":true,"kind":"community","name":"新場站","lat":25.052,"lng":121.572,"city":"臺北市","space_type":"offStreet",
    "fee_plans":[{"id":"p1","name":"重機計時","fee":{"heavy":{"mode":"hourly","amount":20,"per_minutes":60}}}],
    "parking_zones":[{"name":"重機區","area":"heavy","access":"heavyOnly","fee_plan":"p1","fee":{"heavy":{"mode":"hourly","amount":20,"per_minutes":60}},
      "condition":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}}}]}')->'fee_plans'->0->>'name'),
  '重機計時','a new lot keeps its plans');

-- ===== 審核：共用規則 =====
reset role;
update community_spots set fee=parking_zones->0->'fee',fee_plan='p1',fee_note=fee_note_of(parking_zones->0->'fee')
  where id=(select id from fx where name='lot');
-- A copy of B1 as B2's place; it gets an id of its own (#188).
update community_spots set parking_zones=jsonb_set(parking_zones,'{1}',(parking_zones->0)-'id')
  where id=(select id from fx where name='lot');
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed,base_spot)
  values((select id::text from fx where name='lot'),'10000000-0000-4000-8000-000000000002','費率','fee_note',
    '{"fee":{"scooter":{"mode":"per_visit","amount":30}}}',
    (select to_jsonb(c)-'location'-'fee_plans'-'fee_plan' from community_spots c where c.id=(select id from fx where name='lot')))
  returning id)
  insert into fx select 'only_here',id from s;
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='lot'),'10000000-0000-4000-8000-000000000002','費率改規則','fee_note',
    '{"fee":{"scooter":{"mode":"per_visit","amount":25}}}') returning id)
  insert into fx select 'everywhere',id from s;
create temporary table pl as select fee_plans from community_spots where id=(select id from fx where name='lot');
grant select on pl to authenticated;
set local role authenticated;
select pg_temp.act('admin');
-- Only the spot's own use: a new plan of its own, the zones keep theirs.
select lives_ok($$select admin_resolve_report((select id from fx where name='only_here'),'accepted',
  jsonb_build_object('fee','{"scooter":{"mode":"per_visit","amount":30}}'::jsonb,
    'fee_note',fee_note_of('{"scooter":{"mode":"per_visit","amount":30}}'),
    'fee_plan','p3',
    'fee_plans',(select fee_plans||'[{"id":"p3","name":"全場計次","fee":{"scooter":{"mode":"per_visit","amount":30}}}]'::jsonb
      from pl),
    'fee_plans_seen',(select jsonb_build_object('plans',fee_plans) from pl)))$$,
  'plans the page saw, and a fee as sent: no conflict');
reset role;
select is((select fee_plan||'|'||(parking_zones->0->>'fee_plan')||'|'||(parking_zones->1->>'fee_plan') from community_spots
  where id=(select id from fx where name='lot')),'p3|p1|p1','the whole fee moved to its own plan');
select is((select fee_plans->2->>'name' from community_spots where id=(select id from fx where name='lot')),'全場計次','under the admin''s name');
-- The plan for everyone: every use follows. Built on plans that have
-- changed since, it is a conflict until the admin forces it.
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from fx where name='everywhere'),'accepted',
  jsonb_build_object('fee_plans',(select fee_plans from pl),'fee_plans_seen',(select jsonb_build_object('plans',fee_plans) from pl)))$$,
  '40001','spot changed since the report','plans changed since the page loaded them');
select lives_ok($$select admin_resolve_report((select id from fx where name='everywhere'),'accepted',
  jsonb_build_object('fee_plans',(select jsonb_set(fee_plans,'{0,fee}','{"scooter":{"mode":"per_visit","amount":25}}')
      ||'[{"id":"p3","name":"全場計次","fee":{"scooter":{"mode":"per_visit","amount":30}}}]'::jsonb from pl)),
  '',true)$$,'editing the shared plan, forced once the admin has seen the newer fee');
reset role;
select is((select jsonb_agg(z->'fee'->'scooter'->>'amount' order by n) from community_spots c,
    jsonb_array_elements(c.parking_zones) with ordinality x(z,n) where c.id=(select id from fx where name='lot')),
  '["25","25"]'::jsonb,'both zones follow');

select * from finish();
rollback;
