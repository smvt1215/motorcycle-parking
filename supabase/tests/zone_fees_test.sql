begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select ok(valid_zone_fees('[]'),'no zones remains valid');
select ok(valid_zone_fees('[{"name":"舊區","fee_note":"免費","car_fee_note":"原文"}]'),'legacy strings stay valid');
select ok(valid_zone_fees('[{"name":"B2","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"same_as_scooter"}}}]'),'zone uses the existing fee contract');
select ok(not valid_zone_fees('[{"name":"B2","fee":{"car":{"mode":"free"}}}]'),'zone cannot introduce car rates');
select ok(not valid_zone_fees('[{"name":"B2","fee":{"heavy":{"mode":"hourly","amount":20}}}]'),'zone hourly rate needs a period');
select ok(not valid_zone_fees('[{"name":"B2","fee":{"heavy":{"mode":"daily","amount":-1}}}]'),'zone amount cannot be negative');
select ok(not valid_zone_fees('[{"name":"B2","fee":{"scooter":{"mode":"same_as_car"}}}]'),'only heavy bikes follow another vehicle');

create temporary table zone_target as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"name":"分區費率測試","lat":25.09,"lng":121.61,"city":"臺北市","space_type":"offStreet",
    "fee":{"heavy":{"mode":"daily","amount":80}},
    "parking_zones":[{"name":"B2","access":"scooterHeavy","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":30}}}]}}')->>'id')::uuid as id;
select is((select parking_zones->0->'fee'->'heavy'->>'amount' from community_spots where id=(select id from zone_target)),'20','create RPC preserves zone fee');
grant select on zone_target to anon,authenticated;

-- A lot: street spots have no zones (202610270010_parking_conditions.sql).
insert into official_heavy_spots(id,name,lat,lng,city,space_type,source_url,effective_date,fee,parking_zones)
values('74000000-0000-4000-8000-000000000001','官方分區費率',25.09,121.61,'臺北市','offStreet','https://example.test/zone-fees',current_date,
  '{"heavy":{"mode":"daily","amount":60}}','[{"name":"機車區","fee":{"heavy":{"mode":"free"}}}]');

set local role anon;
select is((select fee->'heavy'->>'amount' from viewport_spots_v2(25.08,121.60,25.10,121.62) where id=(select id from zone_target)),'80','v2 community viewport returns point fee');
select is((select fee->'heavy'->>'amount' from viewport_spots(25.08,121.60,25.10,121.62) where id=(select id from zone_target)),'80','legacy community viewport returns point fee');
select is((select fee->'heavy'->>'amount' from official_viewport_spots_v2(25.08,121.60,25.10,121.62) where id='official:74000000-0000-4000-8000-000000000001'),'60','v2 official viewport returns point fee');
select is((select fee->'heavy'->>'amount' from official_viewport_spots(25.08,121.60,25.10,121.62) where id='official:74000000-0000-4000-8000-000000000001'),'60','legacy official viewport returns point fee');
select throws_ok($$select user_id from public_spots$$,'42703',null,'public view never exposes contributor ids');
reset role;

select throws_ok($$update community_spots set parking_zones='[{"name":"B2","fee":{"car":{"mode":"free"}}}]'
  where id=(select id from zone_target)$$,'23514',null,'table rejects invalid nested fees');
select throws_ok($$update official_heavy_spots set parking_zones='[{"name":"B2","fee":{"scooter":{"mode":"hourly","amount":20}}}]'
  where id='74000000-0000-4000-8000-000000000001'$$,'23514',null,'official table also validates nested fees');

select * from finish();
rollback;
