begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(6);
insert into community_spots(user_id,name,lat,lng,city,space_type,status) values
('10000000-0000-4000-8000-000000000001','[測試] 視窗A',25.00,121.50,'臺北市','paidMotorcycle','pending'),
('10000000-0000-4000-8000-000000000001','[測試] 視窗B',25.005,121.505,'新北市','paidMotorcycle','confirmed'),
('10000000-0000-4000-8000-000000000001','[測試] 隱藏',25.006,121.506,'臺北市','paidMotorcycle','hidden');
set local role anon;
select is((select count(*)::integer from viewport_spots(24.999,121.499,25.01,121.51)),2,'viewport crosses cities and preserves RLS');
select is((select count(*)::integer from viewport_spots(25.002,121.503,25.01,121.51)),1,'exact bounding box excludes outside point');
select is((select count(*)::integer from viewport_spots(24.14,120.66,24.16,120.68)),0,'moving away excludes Taipei points');
select is((select count(*)::integer from viewport_spots(20,118,27,123)),0,'broad queries rejected');
select is((select count(*)::integer from viewport_spots(25.1,121.6,25.0,121.5)),0,'reversed bounds rejected');
select is((select count(*)::integer from viewport_spots('NaN'::float8,121.5,25.1,121.6)),0,'nonfinite bounds rejected');
select * from finish();
rollback;
