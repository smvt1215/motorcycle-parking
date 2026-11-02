-- 我的地圖照抄文字清除（#275；202611020100_strip_mymaps_copied_text.sql）：
-- 清除後觸發器恢復、暫存表不留下、沒有點位再以來源地圖署名。逐列的新值由
-- tool/test_mymaps_strip_sql.py 與 staging 備份的本機演練驗證。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select is((select tgenabled::text from pg_trigger where tgname='community_spots_flags_from_entries'), 'O',
  'the community eligibility trigger is enabled again');
select is((select tgenabled::text from pg_trigger where tgname='official_heavy_spots_flags_from_entries'), 'O',
  'the official eligibility trigger is enabled again');
select is((select count(*)::int from pg_class where relname='strip_text' and relpersistence='t'), 0,
  'the value table is dropped');
select is((select count(*)::int from public.community_spots where license_note like '%Alan%'), 0,
  'no community spot names the source map');
select is((select count(*)::int from public.official_heavy_spots where license_note like '%Alan%'), 0,
  'no official spot names the source map');
select is((select count(*)::int from public.community_spots where source_url like '%google.com/maps/d/%'), 0,
  'no community spot links the source map');

-- A spot updated afterwards still follows its bays (the trigger is back).
insert into auth.users(id,instance_id,aud,role,email) values
  ('10000000-0000-4000-8000-0000000000a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a1@example.test');
insert into public.community_spots(id,user_id,source,name,lat,lng,city,district,space_type,fee_note,status,parking_zones)
values('20000000-0000-4000-8000-0000000000a1','10000000-0000-4000-8000-0000000000a1','import','測試停車場',25.0,121.5,
  '臺北市','中正區','offStreet','請依現場公告','pending','[{"name":"機車區","access":"scooterHeavy"}]');
update public.community_spots set note='車道較窄' where id='20000000-0000-4000-8000-0000000000a1';
select is((select scooter_allowed from public.community_spots where id='20000000-0000-4000-8000-0000000000a1'), true,
  'eligibility still follows the zones');

select * from finish();
rollback;
