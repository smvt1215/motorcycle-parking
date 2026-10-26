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

-- A known starting row, whatever the seed holds.
delete from city_rules_data where city in ('基隆市','連江縣');
insert into city_rules_data(city,vehicle,allowed_space_types,conditional_space_types,fee_note,exceptions,effective_date,source_url,version)
  values('基隆市','heavy','["heavyOnly","car"]','["offStreet"]','請依現場收費公告','路邊機車格未開放大型重機。','2026-01-01','https://example.test/keelung',4);

-- Only an admin with a second factor.
select ok(not has_function_privilege('anon','public.admin_upsert_city_rule(text,text,jsonb,integer,text)','EXECUTE'),'anon cannot publish rules');
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"fee_note":"x"}',4)$$,'42501',null,'an ordinary user cannot publish');
reset role;
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"fee_note":"x"}',4)$$,'42501',null,'an admin without a second factor cannot publish');
reset role;

select pg_temp.act('admin');
set local role authenticated;
-- Input checks.
select throws_ok($$select admin_upsert_city_rule('基隆','heavy','{"fee_note":"x"}',4)$$,'22023','unknown city','city names follow the 22 municipalities');
select throws_ok($$select admin_upsert_city_rule('基隆市','car','{"fee_note":"x"}',4)$$,'22023','unknown vehicle','vehicle is scooter or heavy');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"version":9}',4)$$,'22023',null,'the version is not client input');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"allowed_space_types":["heavyOnly","evMotorcycle"]}',4)$$,'22023','unknown space type','only the original five kinds');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"allowed_space_types":["car"],"conditional_space_types":["car"],"restriction":"signage"}',4)$$,'22023','a space type is listed twice','a kind is open or conditional, not both');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"conditional_space_types":["offStreet","paidMotorcycle"]}',4)$$,'23514','conditional street spaces need a restriction','conditional street spaces need a restriction');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"restriction":"signage"}',4)$$,'22023','a restriction needs a conditional street space','a restriction alone means nothing');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"conditional_space_types":["paidMotorcycle"],"restriction":"time_limited"}',4)$$,'22023','unknown restriction','space-level restrictions are not rule restrictions');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"source_url":"http://example.test"}',4)$$,'22023',null,'sources stay https');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"effective_date":"2026-02-30"}',4)$$,'22023',null,'dates must exist');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"district_space_types":{"freeMotorcycle":[]}}',4)$$,'22023',null,'a district-only kind names a district');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"districts":["仁愛區","仁愛區"]}',4)$$,'22023',null,'districts are listed once');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"exceptions":""}',4)$$,'22023',null,'exceptions are shown to riders and cannot be empty');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"fee_note":"請依現場收費公告"}',4)$$,'22023','rule unchanged','an unchanged rule is not a new version');

-- Optimistic versioning.
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"fee_note":"每次 30 元"}',3)$$,'40001','rule changed since it was opened','a publish over an older version is refused');
select throws_ok($$select admin_upsert_city_rule('基隆市','heavy','{"fee_note":"每次 30 元"}')$$,'40001',null,'an existing rule cannot be created again');
select throws_ok($$select admin_upsert_city_rule('連江縣','heavy','{"fee_note":"x"}',1)$$,'40001',null,'a missing rule has no version to edit');

-- Rules are written only through the RPC; reading stays open to everyone.
select throws_ok($$insert into city_rules_data(city,vehicle,allowed_space_types,fee_note,exceptions,effective_date,source_url,version) values('連江縣','scooter','[]','a','a',current_date,'https://example.test',1)$$,'42501',null,'an admin cannot insert a rule directly');
select throws_ok($$update city_rules_data set version=9 where city='基隆市' and vehicle='heavy'$$,'42501',null,'an admin cannot update a rule directly');
select throws_ok($$delete from city_rules_data where city='基隆市' and vehicle='heavy'$$,'42501',null,'an admin cannot delete a rule directly');
reset role;
select pg_temp.act('user');
set local role authenticated;
select ok((select count(*) from city_rules where city='基隆市')=1,'signed-in riders read rules');
reset role;
set local role anon;
select ok((select count(*) from city_rules where city='基隆市')=1,'anonymous riders read rules');
reset role;
select ok(not has_table_privilege('authenticated','public.city_rules','INSERT,UPDATE,DELETE'),'no client role may write rules');
select pg_temp.act('admin');
set local role authenticated;

-- Publishing bumps the version on the server.
select is((admin_upsert_city_rule('基隆市','heavy',
  '{"conditional_space_types":["offStreet","paidMotorcycle"],"restriction":"pilot_area","district_space_types":{"paidMotorcycle":["仁愛區"]},"can_use_two_spaces":true}',
  4,'依 2026 公告')->>'version')::integer,5,'publishing makes version 5');
reset role;
select is((select version from city_rules where city='基隆市' and vehicle='heavy'),5,'the row carries version 5');
select is((select restriction from city_rules where city='基隆市' and vehicle='heavy'),'pilot_area','the restriction was saved');
select is((select fee_note from city_rules where city='基隆市' and vehicle='heavy'),'請依現場收費公告','absent fields keep their value');
select is((select district_space_types from city_rules where city='基隆市' and vehicle='heavy'),'{"paidMotorcycle":["仁愛區"]}'::jsonb,'district-only kinds were saved');
select is((select count(*)::integer from admin_audit_log where action='upsert_city_rule' and target_id='基隆市:heavy'),1,'one audit entry');
select is((select (before->>'version')::integer from admin_audit_log where action='upsert_city_rule' and target_id='基隆市:heavy'),4,'the audit keeps the full previous row');
select is((select (after->>'version')::integer from admin_audit_log where action='upsert_city_rule' and target_id='基隆市:heavy'),5,'and the published row');
select is((select note from admin_audit_log where action='upsert_city_rule' and target_id='基隆市:heavy'),'依 2026 公告','with the admin note');
select is((select actor from admin_audit_log where action='upsert_city_rule' and target_id='基隆市:heavy'),'10000000-0000-4000-8000-000000000005'::uuid,'and the admin');

-- The replaced version is kept, readable by admins only and never changed.
select is((select (row->>'version')::integer from city_rules_history where city='基隆市' and vehicle='heavy'),4,'history keeps the replaced row');
select is((select version from city_rules_history where city='基隆市' and vehicle='heavy'),4,'under its version');
select is((select row->>'fee_note' from city_rules_history where city='基隆市' and vehicle='heavy'),'請依現場收費公告','with its content');
select is((select replaced_by from city_rules_history where city='基隆市' and vehicle='heavy'),'10000000-0000-4000-8000-000000000005'::uuid,'and who replaced it');
select throws_ok($$update city_rules_history set version=9$$,'42501',null,'history cannot be changed');
select throws_ok($$delete from city_rules_history$$,'42501',null,'history cannot be removed');
select pg_temp.act('admin');
set local role authenticated;
select is((select count(*)::integer from city_rules_history where city='基隆市'),1,'admins read the history');
select throws_ok($$insert into city_rules_history(city,vehicle,version,row,replaced_by) values('基隆市','heavy',9,'{}','10000000-0000-4000-8000-000000000005')$$,'42501',null,'only the RPC writes history');
reset role;
select pg_temp.act('user');
set local role authenticated;
select is((select count(*)::integer from city_rules_history),0,'other users see no history');
reset role;

-- A new rule starts at version 1 with safe defaults.
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_upsert_city_rule('連江縣','heavy','{"allowed_space_types":["heavyOnly"]}')$$,'22023',null,'a new rule names its texts');
select is((admin_upsert_city_rule('連江縣','heavy',
  '{"allowed_space_types":["heavyOnly","car"],"fee_note":"免費","exceptions":"請依現場標誌標線。","effective_date":"2026-11-01","source_url":"https://example.test/matsu"}')->>'version')::integer,
  1,'a new rule is version 1');
reset role;
select is((select conditional_space_types from city_rules where city='連江縣' and vehicle='heavy'),'["offStreet"]'::jsonb,'new rules keep lots out of the street lists');
select is((select before from admin_audit_log where action='upsert_city_rule' and target_id='連江縣:heavy'),null::jsonb,'a new rule has no previous row');
select is((select count(*)::integer from city_rules_history where city='連江縣'),0,'and no history entry');

select * from finish();
rollback;
