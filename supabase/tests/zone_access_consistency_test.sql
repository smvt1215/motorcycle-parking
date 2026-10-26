begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- 202610270020_zone_access_consistency.sql (decision 32): a zone with a
-- condition carries an allow naming both vehicles and the access it writes
-- back; a zone without a condition is unchecked. The case-by-case rule is
-- in parking_contract_test.sql (zone_rows); these check the table checks.

create function pg_temp.lot(p_name text,p_zones jsonb) returns uuid language sql as $$
  insert into community_spots(user_id,name,lat,lng,city,space_type,facility_type,status,parking_zones)
  values('10000000-0000-4000-8000-000000000001',p_name,25.25,121.45,'臺北市','offStreet','underground','confirmed',p_zones)
  returning id;
$$;
create function pg_temp.official(p_name text,p_zones jsonb) returns uuid language sql as $$
  insert into official_heavy_spots(name,lat,lng,city,space_type,facility_type,source_url,effective_date,heavy_allowed,parking_zones)
  values(p_name,25.25,121.45,'臺北市','offStreet','underground','https://example.test/o',current_date,true,p_zones)
  returning id;
$$;

-- ===== Consistent: stored =====
select lives_ok($$select pg_temp.lot('試辦場站','[
  {"name":"機車區","area":"motorcycle","access":"scooterHeavy",
   "condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"toll","allow":{"scooter":true,"heavy":true}}},
  {"name":"汽車區","area":"car","access":"heavyCar",
   "condition":{"bay":"car","use":"usual","charge":"toll","allow":{"scooter":false,"heavy":true}}}]')$$,
  'the §2.4 zones, each with its allow and the access it writes back');
select lives_ok($$select pg_temp.lot('普機與重機專區','[
  {"name":"B1","access":"scooterOnly","condition":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}}},
  {"name":"B2","access":"heavyOnly","condition":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}}},
  {"name":"B3","access":"noMotorcycle","condition":{"allow":{"scooter":false,"heavy":false}}}]')$$,
  'scooterOnly, heavyOnly and noMotorcycle zones');
select lives_ok($$select pg_temp.official('官方場站','[
  {"name":"汽車區","access":"heavyCar","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]')$$,
  'the official table takes a consistent zone');

-- ===== No condition: unchanged =====
select lives_ok($$select pg_temp.lot('舊分區','[{"name":"B1","access":"scooterHeavy","guide":"B1"},{"name":"B2"}]')$$,
  'zones without a condition keep any access or none');
select lives_ok($$select pg_temp.lot('混合','[
  {"name":"B1","access":"scooterOnly"},
  {"name":"B2","access":"heavyCar","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]')$$,
  'a zone without a condition beside one with');

-- ===== Missing allow: refused =====
select throws_ok($$select pg_temp.lot('x1','[{"name":"機車區","access":"scooterHeavy",
  "condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"toll"}}]')$$,
  '23514',null,'a zone condition without allow');
select throws_ok($$select pg_temp.lot('x2','[{"name":"B1","access":"scooterOnly",
  "condition":{"bay":"motorcycle","use":"usual","allow":{"scooter":true}}}]')$$,
  '23514',null,'an allow naming one vehicle');
select throws_ok($$select pg_temp.official('x3','[{"name":"機車區","access":"scooterHeavy",
  "condition":{"bay":"motorcycle","use":"share","share":"scooter_heavy"}}]')$$,
  '23514',null,'the official table refuses it too');

-- ===== Inconsistent: refused =====
select throws_ok($$select pg_temp.lot('x4','[{"name":"B1","access":"scooterHeavy",
  "condition":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}}}]')$$,
  '23514',null,'an access other than the one allow writes back');
select throws_ok($$select pg_temp.lot('x5','[{"name":"B2","access":"heavyCar",
  "condition":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}}}]')$$,
  '23514',null,'an access other than the one the bay writes back');
select throws_ok($$select pg_temp.lot('x6','[{"name":"B1",
  "condition":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}}}]')$$,
  '23514',null,'a zone condition without its access');
select throws_ok($$select pg_temp.lot('x7','[{"name":"B1","access":"heavyOnly",
  "condition":{"bay":"motorcycle","use":"usual","allow":{"scooter":false,"heavy":true}}}]')$$,
  '23514',null,'a condition that writes back no access');
select throws_ok($$select pg_temp.official('x8','[{"name":"B1","access":"scooterOnly",
  "condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]')$$,
  '23514',null,'the official table refuses an inconsistent zone');

-- ===== Updates and reports go through the same check =====
select throws_ok($$update community_spots set parking_zones=jsonb_set(parking_zones,'{0,access}','"scooterOnly"')
  where name='試辦場站'$$,
  '23514',null,'an update cannot make a stored zone inconsistent');
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"回報場站","lat":25.273,"lng":121.473,"city":"臺北市","space_type":"offStreet",
    "parking_zones":[{"name":"B1","access":"scooterOnly","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]}}')$$,
  '23514',null,'a new spot report with an inconsistent zone');
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"回報場站","lat":25.273,"lng":121.473,"city":"臺北市","space_type":"offStreet",
    "parking_zones":[{"name":"B1","access":"heavyCar","condition":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}}}]}}')$$,
  'a new spot report with a consistent zone');

select * from finish();
rollback;
