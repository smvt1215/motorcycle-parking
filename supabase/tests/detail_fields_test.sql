begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(10);
insert into community_spots(user_id,name,lat,lng,city,space_type,status,facility_type,parking_access,address,road_segment,
  entrance_note,parking_guide,special_rules,photo_urls,parking_zones) values
('10000000-0000-4000-8000-000000000001','[測試] 詳情停車場',25.00,121.50,'臺北市','offStreet','pending','underground','scooterHeavy',
  '臺北市大安區測試路1號','測試路（北側）','機車道入口','B2 重機區','限停指定格位','["https://example.gov.tw/a.jpg"]',
  '[{"name":"機車區","access":"scooterHeavy","fee_note":"20 元／次"}]'),
('10000000-0000-4000-8000-000000000001','[測試] 舊資料',25.001,121.501,'臺北市','paidMotorcycle','pending',null,null,'','','','','','[]','[]');
set local role anon;
select is((select facility_type||'|'||parking_access||'|'||address||'|'||road_segment from viewport_spots(24.999,121.499,25.01,121.51) where name='[測試] 詳情停車場'),
  'underground|scooterHeavy|臺北市大安區測試路1號|測試路（北側）','viewport returns type, access, address and road segment');
select is((select entrance_note||'|'||parking_guide||'|'||special_rules from viewport_spots(24.999,121.499,25.01,121.51) where name='[測試] 詳情停車場'),
  '機車道入口|B2 重機區|限停指定格位','viewport returns entrance, guide and special rules');
select is((select (photo_urls->>0)||'|'||(parking_zones->0->>'fee_note') from viewport_spots(24.999,121.499,25.01,121.51) where name='[測試] 詳情停車場'),
  'https://example.gov.tw/a.jpg|20 元／次','viewport returns photos and zones');
select is((select facility_type is null and photo_urls='[]'::jsonb from public_spots where name='[測試] 舊資料'),true,'rows without details keep empty defaults');
select throws_ok($$select user_id from community_spots limit 1$$,'42501',null,'contributor ids stay private');
reset role;
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,photo_urls) values('10000000-0000-4000-8000-000000000001','x',25,121.5,'臺北市','offStreet','["http://example.gov.tw/a.jpg"]')$$,
  '23514',null,'photo links must be https');
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,parking_access) values('10000000-0000-4000-8000-000000000001','x',25,121.5,'臺北市','offStreet','anything')$$,
  '23514',null,'unknown access rejected');
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,photo_urls) values('10000000-0000-4000-8000-000000000001','x',25,121.5,'臺北市','offStreet','["https://a","https://b","https://c","https://d","https://e","https://f","https://g","https://h","https://i","https://j","https://k"]')$$,
  '23514',null,'at most ten photos');
insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date,parking_access,road_segment,license_note,photo_urls) values
('[測試] 官方詳情',24.80,120.97,'新竹市','https://data.gov.tw/dataset/67771',current_date-1,'heavyOnly','府後街（東側）','政府資料開放授權條款第 1 版','["https://example.gov.tw/b.jpg"]');
set local role anon;
select is((select parking_access||'|'||road_segment||'|'||license_note||'|'||(photo_urls->>0) from official_viewport_spots(24.79,120.96,24.81,120.98) where name='[測試] 官方詳情'),
  'heavyOnly|府後街（東側）|政府資料開放授權條款第 1 版|https://example.gov.tw/b.jpg','official viewport returns the same detail fields');
reset role;
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date,photo_urls) values('x',25,121.5,'臺北市','https://a.gov.tw',current_date,'"https://a"')$$,
  '23514',null,'official photos must be a list');
select * from finish();
rollback;
