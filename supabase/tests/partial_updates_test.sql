begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(7);
create temporary table update_target as
select (public.apply_report(
  '10000000-0000-4000-8000-000000000001',repeat('u',64),repeat('u',64),
  '{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"更新測試","lat":24.8,"lng":121.2,"city":"桃園市","space_type":"paidMotorcycle","fee_note":"每小時 20 元","note":"入口在北側"}}'
)->>'id')::uuid as id;
select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('u',64),repeat('u',64),
  jsonb_build_object('action','update','spot_id',(select id from update_target),'spot',jsonb_build_object('name','只更新名稱')));
select is((select name from community_spots where id=(select id from update_target)),'只更新名稱','partial update changes the name');
select is((select fee_note from community_spots where id=(select id from update_target)),'每小時 20 元','omitted fee details are preserved');
select is((select note from community_spots where id=(select id from update_target)),'入口在北側','omitted location notes are preserved');
select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('u',64),repeat('u',64),
  jsonb_build_object('action','update','spot_id',(select id from update_target),'spot',jsonb_build_object('name','清除備註','fee_note','','note','')));
select is((select fee_note from community_spots where id=(select id from update_target)),'','explicit empty fee details clear the field');
select is((select note from community_spots where id=(select id from update_target)),'','explicit empty location notes clear the field');
select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('u',64),repeat('u',64),
  jsonb_build_object('action','update','spot_id',(select id from update_target),'spot',jsonb_build_object('name','替換備註','fee_note','免費','note','入口在南側')));
select is((select fee_note from community_spots where id=(select id from update_target)),'免費','explicit fee details replace the field');
select is((select note from community_spots where id=(select id from update_target)),'入口在南側','explicit location notes replace the field');
select * from finish();
rollback;
