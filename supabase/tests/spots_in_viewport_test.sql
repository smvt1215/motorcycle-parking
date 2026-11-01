-- api_v1.spots_in_viewport()（#195 P2；202611011820_api_v1_spots_in_viewport.sql）：
-- 官方點與社群點合併，欄位與篩選沿用既有的兩支 viewport 函式，不帶判斷結果。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date)
values('合併測試官方點',23.501,120.401,'嘉義縣','offStreet','https://example.test/v','嘉義縣政府',current_date);

set local role anon;
select is((select jsonb_array_length(api_v1.spots_in_viewport(25.0,121.4,25.2,121.7)->'spots')),
  (select least((select count(*) from viewport_spots_v3(25.0,121.4,25.2,121.7)), 500)::int
     + least((select count(*) from official_viewport_spots_v3(25.0,121.4,25.2,121.7)), 500)::int),
  'every spot of both layers is served once');
select is((select e->>'source' from jsonb_array_elements(api_v1.spots_in_viewport(23.49,120.39,23.51,120.41)->'spots') e
  where e->>'name' = '合併測試官方點'), 'official', 'official spots say so');
select ok((select bool_and(e->>'id' like 'official:%') from jsonb_array_elements(api_v1.spots_in_viewport(23.49,120.39,23.51,120.41)->'spots') e
  where e->>'source' = 'official'), 'official ids keep their official: prefix (viewport_availability reads them)');
select ok(not exists (select 1 from jsonb_array_elements(api_v1.spots_in_viewport(25.0,121.4,25.2,121.7)->'spots') e
  where e ? 'verdict' or e ? 'decision'), 'no verdict is served: the App decides locally');
select is((select api_v1.spots_in_viewport(23.49,120.39,23.51,120.41)->'truncated'), 'false'::jsonb, 'a small box is not truncated');
select is((select api_v1.spots_in_viewport(23.49,120.39,23.51,120.41)->'official_unavailable'), 'false'::jsonb,
  'the official layer read fine');
select is((select api_v1.spots_in_viewport(25.0,121.0,26.5,122.5)->'spots'), '[]'::jsonb,
  'a box the viewport functions refuse serves nothing, as they do');
reset role;

-- A failing official layer drops only that layer and says so.
revoke select on official_heavy_spots from anon;
set local role anon;
select is((select api_v1.spots_in_viewport(25.0,121.4,25.2,121.7)->'official_unavailable'), 'true'::jsonb,
  'an official failure is reported');
select is((select jsonb_array_length(api_v1.spots_in_viewport(25.0,121.4,25.2,121.7)->'spots')),
  least((select count(*) from viewport_spots_v3(25.0,121.4,25.2,121.7)), 500)::int,
  'community spots are still served');
reset role;

select * from finish();
rollback;
