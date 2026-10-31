begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(12);

-- 202610270040_community_source_url_https.sql: community_spots.source_url is
-- empty or https, the same limit official_heavy_spots has, and it is
-- validated for every row, not only new ones.
select ok((select convalidated from pg_constraint where conrelid='public.community_spots'::regclass
  and conname='community_spots_source_url_check'),'the source_url check is validated');
create function pg_temp.community(p_url text) returns text language sql as $$
  select format($i$insert into community_spots(user_id,name,lat,lng,city,space_type,source_url)
    values('10000000-0000-4000-8000-000000000001','[測試] 來源網址',25,121.5,'臺北市','paidMotorcycle',%L)$i$,p_url);
$$;
select lives_ok(pg_temp.community(''),'an empty source is allowed');
select lives_ok(pg_temp.community('https://www.gov.taipei/'),'an https source is allowed');
select lives_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','[測試] 預設來源',25,121.5,'臺北市','paidMotorcycle')$$,
  'the default stays empty');
select throws_ok(pg_temp.community('javascript:alert(1)'),'23514',null,'javascript: sources rejected');
select throws_ok(pg_temp.community('data:text/html,<script>alert(1)</script>'),'23514',null,'data: sources rejected');
select throws_ok(pg_temp.community('intent://scan/#Intent;scheme=zxing;end'),'23514',null,'intent: sources rejected');
select throws_ok(pg_temp.community('http://www.gov.taipei/'),'23514',null,'plain http sources rejected');
select throws_ok(pg_temp.community(' https://www.gov.taipei/'),'23514',null,'the scheme must come first');
select throws_ok($$update community_spots set source_url='javascript:alert(1)' where name='[測試] 來源網址'$$,'23514',null,
  'updates are held to the same check');

-- Riders cannot set the link at all: apply_report ignores it on create and
-- update (validate.ts refuses it before the RPC runs).
create temporary table target as
select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('s',64),repeat('s',64),
  '{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"[測試] 回報帶來源","lat":24.8,"lng":121.2,"city":"桃園市","space_type":"paidMotorcycle","source_url":"javascript:alert(1)"}}'
)->>'id')::uuid as id;
select is((select source_url from community_spots where id=(select id from target)),'','a report cannot store a source link');
select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('s',64),repeat('s',64),
  jsonb_build_object('action','update','spot_id',(select id from target),'spot',jsonb_build_object('name','[測試] 更新帶來源','source_url','javascript:alert(1)')));
select is((select source_url from community_spots where id=(select id from target)),'','an update cannot store a source link either');
select * from finish();
rollback;
