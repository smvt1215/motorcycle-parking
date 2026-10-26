begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- City rules that end (C4, 202610270030_parking_decision.sql, design §3.2).
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;
create function pg_temp.taipei_today() returns date language sql as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

delete from city_rules_data where city in ('基隆市','連江縣','新竹市');
insert into city_rules_data(city,vehicle,allowed_space_types,conditional_space_types,districts,
    district_space_types,fee_note,exceptions,effective_date,source_url,version,restriction,expires_on)
  values
  -- Ended yesterday: open paid bays, free bays in one district.
  ('基隆市','heavy','["heavyOnly","car","paidMotorcycle"]','["offStreet"]','[]',
   '{"freeMotorcycle":["仁愛區"]}','請依現場收費公告','試辦開放收費機車格。',
   pg_temp.taipei_today()-30,'https://example.test/keelung',3,null,pg_temp.taipei_today()-1),
  -- Ends today in Taiwan: already expired.
  ('連江縣','heavy','["heavyOnly","car"]','["offStreet","paidMotorcycle"]','[]','{}',
   '請依現場收費公告','限標示車格。',pg_temp.taipei_today()-30,'https://example.test/lienchiang',2,
   'signage',pg_temp.taipei_today()),
  -- Ends tomorrow: still in force, served as stored.
  ('新竹市','heavy','["heavyOnly","car","paidMotorcycle"]','["offStreet"]','[]','{}',
   '請依現場收費公告','試辦開放收費機車格。',pg_temp.taipei_today()-30,'https://example.test/hsinchu',7,
   null,pg_temp.taipei_today()+1);

-- The legacy view: expired rows projected, the others as stored.
select is((select allowed_space_types from city_rules where city='基隆市' and vehicle='heavy'),'[]'::jsonb,
  'an expired rule opens nothing for older builds');
select is((select conditional_space_types from city_rules where city='基隆市' and vehicle='heavy'),
  '["car","freeMotorcycle","heavyOnly","offStreet","paidMotorcycle"]'::jsonb,
  'what it opened, in all lists, becomes conditional');
select is((select restriction from city_rules where city='基隆市' and vehicle='heavy'),'unverified',
  'with the unverified restriction, which older builds read as 待確認');
select is((select district_space_types from city_rules where city='基隆市' and vehicle='heavy'),'{}'::jsonb,
  'and no district-only kinds');
select is((select exceptions from city_rules where city='基隆市' and vehicle='heavy'),
  '此地區的規則已過期，請以現場標誌標線為準','the reason older builds show');
select is((select version from city_rules where city='基隆市' and vehicle='heavy'),3,
  'the version is kept, so it still replaces the bundled rule');
select is((select restriction from city_rules where city='連江縣' and vehicle='heavy'),'unverified',
  'a rule ending today in Taiwan is already expired');
select is((select to_jsonb(v) from city_rules v where city='新竹市' and vehicle='heavy'),
  (select to_jsonb(t) from city_rules_data t where city='新竹市' and vehicle='heavy'),
  'a rule still in force is served exactly as stored');
select is((select count(*)::integer from city_rules),(select count(*)::integer from city_rules_data),
  'every row is served, expired or not');
select ok(not exists(select 1 from city_rules v join city_rules_data t using(city,vehicle)
    where t.expires_on is null and to_jsonb(v)<>to_jsonb(t)),
  'rules without an end date are untouched');

-- Riders read the view and city_rules_v2(), never the table.
set local role anon;
select throws_ok($$select count(*) from city_rules_data$$,'42501',null,'anon cannot read city_rules_data');
select ok((select count(*) from city_rules where city='基隆市')=1,'anon reads the legacy view');
select is((select allowed_space_types from city_rules_v2() where city='基隆市' and vehicle='heavy'),
  '["heavyOnly","car","paidMotorcycle"]'::jsonb,'city_rules_v2() returns the stored row');
select is((select expires_on from city_rules_v2() where city='基隆市' and vehicle='heavy'),
  pg_temp.taipei_today()-1,'with its end date');
select ok((select restriction is null from city_rules_v2() where city='基隆市' and vehicle='heavy'),
  'and without the projection');
reset role;
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select count(*) from city_rules_data$$,'42501',null,'signed-in riders cannot read city_rules_data');
select throws_ok($$update city_rules set version=9 where city='基隆市'$$,'55000',null,'nor write the view');
select ok((select count(*) from city_rules_v2())>0,'but call city_rules_v2()');
reset role;
select ok(not has_table_privilege('authenticated','public.city_rules_data','SELECT,INSERT,UPDATE,DELETE'),
  'no client grant on city_rules_data');
select ok(not has_table_privilege('anon','public.city_rules','INSERT,UPDATE,DELETE'),'the view is read-only');

-- The end date follows the start.
select throws_ok($$update city_rules_data set expires_on=effective_date where city='新竹市'$$,'23514',null,
  'a rule cannot end the day it starts');

-- Rule edits still bump the rules data version through the renamed table.
select is((select count(*)::integer from pg_trigger where tgrelid='public.city_rules_data'::regclass
  and tgname='city_rules_data_version'),1,'the data_versions trigger moved with the table');

-- Admins publish end dates through admin_upsert_city_rule().
select pg_temp.act('admin');
set local role authenticated;
select is((admin_upsert_city_rule('新竹市','heavy',
  jsonb_build_object('expires_on',(pg_temp.taipei_today()+60)::text),7,'延長試辦')->>'expires_on')::date,
  pg_temp.taipei_today()+60,'an admin sets the end date');
select is((admin_upsert_city_rule('新竹市','heavy','{"fee_note":"每次 40 元"}',8,'')->>'expires_on')::date,
  pg_temp.taipei_today()+60,'a publish without it keeps the end date');
select ok((admin_upsert_city_rule('新竹市','heavy','{"expires_on":null}',9,'改為長期')->'expires_on')='null'::jsonb,
  'null clears it');
select throws_ok($$select admin_upsert_city_rule('新竹市','heavy',
  jsonb_build_object('expires_on',(pg_temp.taipei_today()-30)::text),10,'')$$,'22023',
  'expires on must be after the effective date','the end date must follow the start');
select throws_ok($$select admin_upsert_city_rule('新竹市','heavy','{"expires_on":"2026-02-30"}',10,'')$$,'22023',
  'expires on must be YYYY-MM-DD','an impossible date is refused');
select throws_ok($$select admin_upsert_city_rule('新竹市','heavy','{"expires_on":5}',10,'')$$,'22023',
  'expires on must be YYYY-MM-DD','a number is refused');
reset role;
select is((select (row->>'expires_on')::date from city_rules_history where city='新竹市' and vehicle='heavy' and version=8),
  pg_temp.taipei_today()+60,'history keeps the replaced end date');

-- rule_verdict() is covered by rule_verdict_test.sql; it reads plain JSON.
select is(rule_verdict((select jsonb_agg(to_jsonb(r)) from city_rules_v2() r where city='基隆市' and vehicle='heavy'),
  'paidMotorcycle','',now()),'{"verdict":"expired","restriction":null}'::jsonb,
  'an expired stored rule reads as expired');

select * from finish();
rollback;
