begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- A lot reported with its type, access, entrance, guide and zones.
create temporary table lot as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"細節停車場","lat":25.06,"lng":121.58,"city":"臺北市","space_type":"offStreet",
    "facility_type":"underground","parking_access":"scooterHeavy","entrance_note":" 入口在松仁路側 ","parking_guide":"B2 機車區靠電梯",
    "parking_zones":[{"name":"B2 機車區","access":"scooterHeavy","guide":"靠電梯"}]}}')->>'id')::uuid as id;
select is((select facility_type from community_spots where id=(select id from lot)),'underground','facility type stored');
select is((select parking_access from community_spots where id=(select id from lot)),'scooterHeavy','vehicle access stored');
select is((select entrance_note from community_spots where id=(select id from lot)),'入口在松仁路側','entrance stored and trimmed');
select is((select parking_guide from community_spots where id=(select id from lot)),'B2 機車區靠電梯','guide stored');
select is((select parking_zones->0->>'name' from community_spots where id=(select id from lot)),'B2 機車區','zones stored');

-- A bay reported without lot details keeps the column defaults.
create temporary table bay as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"細節機車格","lat":25.07,"lng":121.59,"city":"臺北市","space_type":"paidMotorcycle"}}')->>'id')::uuid as id;
select is((select facility_type from community_spots where id=(select id from bay)),null,'no facility type for a bay');
select is((select entrance_note||'|'||parking_guide from community_spots where id=(select id from bay)),'|','empty entrance and guide');
select is((select parking_zones from community_spots where id=(select id from bay)),'[]'::jsonb,'no zones');

-- The table still refuses values outside its lists.
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',64),
  '{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"錯誤型式","lat":25.08,"lng":121.60,"city":"臺北市","space_type":"offStreet","facility_type":"tower"}}')$$,
  '23514',null,'unknown facility type refused by the table');

select * from finish();
rollback;
