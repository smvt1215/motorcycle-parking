begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- The shape: a rate per vehicle, heavy bikes may follow scooters or cars.
select ok(valid_fee('{}'),'an empty fee is unconfirmed for both vehicles');
select ok(valid_fee('{"scooter":{"mode":"hourly","amount":20,"per_minutes":60,"daily_cap":100},"heavy":{"mode":"same_as_car"}}'),
  'hourly scooter rate with a daily cap, heavy bikes at car rates');
select ok(valid_fee('{"scooter":{"mode":"per_visit","amount":30,"max_minutes":360},"heavy":{"mode":"daily","amount":50}}'),
  'per-visit and daily rates');
select ok(valid_fee('{"scooter":{"mode":"free"},"heavy":{"mode":"posted"}}'),'free and posted rates');
select ok(not valid_fee('{"scooter":{"mode":"monthly","amount":300}}'),'unknown mode is refused');
select ok(not valid_fee('{"scooter":{"mode":"same_as_car"}}'),'only heavy bikes follow another vehicle');
select ok(not valid_fee('{"car":{"mode":"free"}}'),'unknown vehicle is refused');
select ok(not valid_fee('{"scooter":{"mode":"hourly","amount":20}}'),'an hourly rate needs its period');
select ok(not valid_fee('{"scooter":{"mode":"hourly","amount":"20","per_minutes":60}}'),'amounts are numbers, not strings');
select ok(not valid_fee('{"scooter":{"mode":"daily","amount":20.5}}'),'amounts are whole yuan');
select ok(not valid_fee('{"scooter":{"mode":"daily","amount":10001}}'),'amounts stay in range');
select ok(not valid_fee('{"scooter":{"mode":"hourly","amount":20,"per_minutes":0}}'),'periods are at least a minute');
select ok(not valid_fee('{"scooter":{"mode":"free","amount":0}}'),'keys a mode does not use are refused');
select ok(not valid_fee('{"scooter":"free"}'),'a rate is an object');
select ok(not valid_fee('[]'),'a fee is an object');

select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,fee)
  values('10000000-0000-4000-8000-000000000001','費率測試',25.04,121.56,'臺北市','paidMotorcycle','{"scooter":{"mode":"weekly"}}')$$,
  '23514',null,'the table refuses an unknown mode');
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date,fee)
  values('費率測試官方點',25.04,121.56,'臺北市','https://example.test/notice',current_date,'{"heavy":{"mode":"free","x":1}}')$$,
  '23514',null,'official spots refuse an unknown key');

-- Reports carry the fee into the new spot.
create temporary table target as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"name":"費率點","lat":25.05,"lng":121.57,"city":"臺北市","space_type":"paidMotorcycle","fee_note":"每小時 20 元","fee":{"scooter":{"mode":"hourly","amount":20,"per_minutes":60}}}}')->>'id')::uuid as id;
select is((select fee->'scooter'->>'amount' from community_spots where id=(select id from target)),'20','create stores the fee');
select is((select fee_note from community_spots where id=(select id from target)),'每小時 20 元','and the text beside it');

-- Admins apply a suggested fee like any other field.
with s as (insert into moderation_queue(source_id,reason,field,proposed)
  values((select id::text from target),'收費資訊：每日 30 元','fee_note',
    '{"fee":{"scooter":{"mode":"daily","amount":30},"heavy":{"mode":"same_as_scooter"}},"fee_note":"每日 30 元（大型重機比照機車費率）"}') returning id)
select id into temporary table report from s;
grant select on target,report to authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select is(public.admin_resolve_report((select id from report),'accepted',
    (select proposed from moderation_queue where id=(select id from report)))->'spot'->'fee'->'heavy'->>'mode',
  'same_as_scooter','admin applies the suggested fee');
select is((select fee_note from community_spots where id=(select id from target)),'每日 30 元（大型重機比照機車費率）',
  'the fee text changes with it');
-- Promoting the spot to an official one keeps the fee beside its text.
select is(public.admin_promote_spot((select id::text from target),
    '{"source_name":"臺北市政府","source_url":"https://example.test/lot","effective_date":"2026-10-25"}',
    (select updated_at from community_spots where id=(select id from target)))->'fee',
  '{"scooter":{"mode":"daily","amount":30},"heavy":{"mode":"same_as_scooter"}}'::jsonb,
  'promotion keeps the structured fee');
reset role;
select set_config('request.jwt.claims','',true);
set local role anon;
select lives_ok($$select fee from community_spots limit 1$$,'fee is granted to the public like the other spot columns');
select throws_ok($$select user_id from community_spots limit 1$$,'42501',null,'contributor ids stay private');
reset role;

select * from finish();
rollback;
