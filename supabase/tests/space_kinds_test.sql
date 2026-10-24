begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(4);
insert into community_spots(user_id,name,lat,lng,city,space_type,status) values
('10000000-0000-4000-8000-000000000001','[測試] 電動機車格',25.00,121.50,'臺北市','evMotorcycle','pending'),
('10000000-0000-4000-8000-000000000001','[測試] 收費機車格',25.001,121.501,'臺北市','paidMotorcycle','pending');
insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,effective_date) values
('[測試] 官方身障機車格',25.002,121.502,'臺北市','disabledMotorcycle','https://www.example.gov.tw/x',current_date-1);
set local role anon;
-- Installed builds parse every row; one unknown kind fails their whole map.
select is((select count(*)::integer from viewport_spots(24.999,121.499,25.01,121.51) where name like '[測試]%'),1,
  'the original RPC keeps to the five kinds older builds can parse');
select is((select count(*)::integer from viewport_spots_v2(24.999,121.499,25.01,121.51) where name like '[測試]%'),2,
  'the v2 RPC returns every kind');
select is((select count(*)::integer from official_viewport_spots(24.999,121.499,25.01,121.51) where name like '[測試]%'),0,
  'the original official RPC keeps to the original kinds');
select is((select count(*)::integer from official_viewport_spots_v2(24.999,121.499,25.01,121.51) where name like '[測試]%'),1,
  'the v2 official RPC returns every kind');
select * from finish();
rollback;
