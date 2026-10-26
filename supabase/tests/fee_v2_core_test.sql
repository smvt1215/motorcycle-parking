-- Fees v2, core (202610270022_fee_v2_core.sql). The shapes and sentences
-- themselves run in parking_contract_test.sql (generated from the shared
-- cases); this covers the tables, the migration's helpers and the RPCs.
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

-- posted reads as unconfirmed: still a valid fee, dropped from stored ones.
select ok(valid_fee('{"scooter":{"mode":"posted"}}'),'older builds may still send posted');
select is(fee_without_posted('{"scooter":{"mode":"posted"},"heavy":{"mode":"free"}}'),
  '{"heavy":{"mode":"free"}}'::jsonb,'a posted vehicle is dropped');
select is(fee_without_posted('{"scooter":{"mode":"posted"}}'),null,'a fee left with no vehicle is null');
select is(fee_without_posted('{"car":{"mode":"by_time","periods":[{"days":"all","from":"08:00","to":"20:00","rate":{"mode":"posted"}},{"days":"all","from":"20:00","to":"08:00","rate":{"mode":"free"}}]}}'),
  '{"car":{"mode":"by_time","periods":[{"days":"all","from":"20:00","to":"08:00","rate":{"mode":"free"}}]}}'::jsonb,
  'a posted period is dropped');
select is(fee_without_posted('{"car":{"mode":"by_time","periods":[{"days":"all","rate":{"mode":"posted"}}]},"heavy":{"mode":"same_as_car"}}'),
  '{"heavy":{"mode":"same_as_car"}}'::jsonb,'a by_time of posted periods only is dropped');
select is(zones_without_posted('[{"name":"B1","fee":{"heavy":{"mode":"posted"}}},{"name":"B2","fee":{"heavy":{"mode":"posted"},"scooter":{"mode":"free"}}},{"name":"B3"}]'),
  '[{"name":"B1"},{"name":"B2","fee":{"scooter":{"mode":"free"}}},{"name":"B3"}]'::jsonb,'zone fees lose posted rates too');
select ok(not has_function_privilege('anon','public.fee_without_posted(jsonb)','execute'),'the helper is not public');

-- fee_note: free text keeps 200 characters; a fee's own sentence may be longer.
create temporary table longest(fee jsonb);
insert into longest values((select jsonb_build_object('car',jsonb_build_object('mode','by_time','periods',jsonb_agg(
  jsonb_build_object('days',jsonb_build_array(d),'from','23:00','to','22:00','rate',
    jsonb_build_object('mode','per_visit','amount',9999,'max_minutes',1439,
      'extension',jsonb_build_object('amount',9999,'max_times',10,'minutes',1439))) order by n)))
  from unnest(array['mon','tue','wed','thu','fri','sat']) with ordinality u(d,n)));
select cmp_ok(char_length(fee_note_of((select fee from longest))),'>',200,'a six-period sentence runs over 200');
select cmp_ok(char_length(fee_note_of((select fee from longest))),'<=',fee_note_max_length(),'and within the bound');
select lives_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,fee,fee_note)
  values('10000000-0000-4000-8000-000000000001','長費率',25.05,121.57,'臺北市','paidMotorcycle',
    (select fee from longest),fee_note_of((select fee from longest)))$$,'a long fee_note that is its fee''s sentence is stored');
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,fee,fee_note)
  values('10000000-0000-4000-8000-000000000001','長費率',25.05,121.57,'臺北市','paidMotorcycle',
    (select fee from longest),fee_note_of((select fee from longest))||'。')$$,'23514',null,'a long note that is not the sentence is refused');
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,fee_note)
  values('10000000-0000-4000-8000-000000000001','長說明',25.05,121.57,'臺北市','paidMotorcycle',repeat('元',201))$$,
  '23514',null,'free text stays within 200');
select lives_ok($$insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date,fee,fee_note)
  values('長費率官方',25.05,121.57,'臺北市','https://example.test/n','臺北市政府',current_date,
    (select fee from longest),fee_note_of((select fee from longest)))$$,'official spots take the same bound');

-- fee_source_text: written by imports and administrators, never shown to riders.
select is((select fee_source_text from community_spots where name='長費率'),'','it defaults to empty');
select ok(not has_column_privilege('anon','public.community_spots','fee_source_text','select'),
  'riders cannot read it from community spots');
select hasnt_column('public','public_spots','fee_source_text','the public view leaves it out');
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,fee_source_text)
  values('10000000-0000-4000-8000-000000000001','原文',25.05,121.57,'臺北市','paidMotorcycle',repeat('元',2001))$$,
  '23514',null,'it holds at most 2000 characters');
select ok(not 'fee_source_text'=any(admin_spot_fields(false)) and not 'fee_source_text'=any(admin_spot_fields(true)),
  'the spot form shows it read-only');

-- An administrator saves a v2 fee with its sentence.
insert into official_heavy_spots(id,name,lat,lng,city,space_type,fee_note,source_url,source_name,source_id,effective_date,
    fee,fee_source_text)
  values('22000000-0000-4000-8000-000000000001','費率 v2 官方點',25.04,121.51,'臺北市','paidMotorcycle',
    '大型重機每次 40 元（隔日是否另計未確認）','https://data.example.test/v2','臺北市政府','V2','2026-10-17',
    '{"heavy":{"mode":"per_visit","amount":40}}','大型重機每次40元');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_upsert_spot('official:22000000-0000-4000-8000-000000000001',
    '{"fee":{"heavy":{"mode":"per_visit","amount":40,"renew":"midnight"},"car":{"mode":"hourly","amount":40,"per_minutes":60}},
      "fee_note":"大型重機每次 40 元，隔日另計；汽車每小時 40 元"}',
    (select updated_at from official_heavy_spots where id='22000000-0000-4000-8000-000000000001'))->>'fee_note',
  '大型重機每次 40 元，隔日另計；汽車每小時 40 元','renew and the car rate save with their sentence');
select throws_ok($$select admin_upsert_spot('official:22000000-0000-4000-8000-000000000001',
    '{"fee":{"heavy":{"mode":"same_as_car","factor_pct":200},"car":{"mode":"hourly","amount":40,"per_minutes":60}},
      "fee_note":"大型重機比照汽車費率"}',
    (select updated_at from official_heavy_spots where id='22000000-0000-4000-8000-000000000001'))$$,
  '22023','fee_note must be the text of fee','a follow is written as amounts, never 比照 (#140)');

-- A file note that is the stored fee's source text reads as no change.
select ok(not exists(select 1 from jsonb_array_elements(admin_import_preview(jsonb_build_array(jsonb_build_object(
    'id','official:22000000-0000-4000-8000-000000000001','source','official','name','費率 v2 官方點',
    'lat',25.04,'lng',121.51,'city','臺北市','space_type','paidMotorcycle','fee_note','大型重機每次40元',
    'source_url','https://data.example.test/v2','source_name','臺北市政府','source_id','V2')))->0->'changes') c
  where c->>'field' in ('fee','fee_note')),'a re-imported source text keeps the stored fee and its sentence');
reset role;

select * from finish();
rollback;
