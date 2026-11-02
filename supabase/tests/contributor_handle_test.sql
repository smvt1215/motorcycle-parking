-- 公開代號 contributor_handle 與 is_own（#280 第 1 層；202611021000_contributor_handle.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who uuid) returns void language sql as $$
select set_config('request.jwt.claims',case when who is null then ''
  else format('{"sub":"%s","role":"authenticated","aal":"aal1","app_metadata":{"role":"user"}}',who) end,true);
$$;
create function pg_temp.handle(p uuid) returns text language sql as $$
  select contributor_handle from public.public_spots where id=p
$$;
create function pg_temp.own(p uuid) returns boolean language sql as $$
  select is_own from public.public_spots where id=p
$$;
grant execute on function pg_temp.handle(uuid),pg_temp.own(uuid) to anon,authenticated;

-- 1 公開名稱、2 從沒有名稱、6 名稱像 email、7 另一個公開名稱。
update auth.users set raw_user_meta_data='{"display_name":"阿明"}' where id='10000000-0000-4000-8000-000000000001';
update auth.users set raw_user_meta_data='{}' where id='10000000-0000-4000-8000-000000000002';
update auth.users set raw_user_meta_data='{"display_name":"ming@example.test"}' where id='10000000-0000-4000-8000-000000000006';
update auth.users set raw_user_meta_data='{"display_name":"阿哲"}' where id='10000000-0000-4000-8000-000000000007';

insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('78000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','代號一',23.701,120.701,'雲林縣','freeMotorcycle',true,false,'pending'),
  ('78000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','代號二',23.702,120.702,'雲林縣','freeMotorcycle',true,false,'pending'),
  ('78000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000002','無名',23.703,120.703,'雲林縣','freeMotorcycle',true,false,'pending'),
  ('78000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000006','像信箱',23.704,120.704,'雲林縣','freeMotorcycle',true,false,'pending'),
  ('78000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000007','另一位',23.705,120.705,'雲林縣','freeMotorcycle',true,false,'pending'),
  ('78000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000005','管理員新增',23.706,120.706,'雲林縣','freeMotorcycle',true,false,'pending');
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,source,source_name)
values('78000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000001','匯入',23.707,120.707,'雲林縣','freeMotorcycle',true,false,'pending','import','社群回報整理');

-- ===== 代號 =====
set local role anon;
select pg_temp.act(null);
select matches(pg_temp.handle('78000000-0000-4000-8000-000000000001'),'^[0-9a-f]{32}$','a public name gives a 128-bit hex handle');
select is(pg_temp.handle('78000000-0000-4000-8000-000000000002'),pg_temp.handle('78000000-0000-4000-8000-000000000001'),
  'every rider spot of one account has the same handle');
select isnt(pg_temp.handle('78000000-0000-4000-8000-000000000005'),pg_temp.handle('78000000-0000-4000-8000-000000000001'),
  'accounts have different handles');
select ok(position(replace('10000000-0000-4000-8000-000000000001','-','') in pg_temp.handle('78000000-0000-4000-8000-000000000001'))=0
  and pg_temp.handle('78000000-0000-4000-8000-000000000001')<>md5('10000000-0000-4000-8000-000000000001'),
  'the handle is not the uid nor a plain hash of it');
select is(pg_temp.handle('78000000-0000-4000-8000-000000000003'),null,'an account that never showed a name has none');
select is(pg_temp.handle('78000000-0000-4000-8000-000000000004'),null,'an email-like name is not a public name');
select is(pg_temp.handle('78000000-0000-4000-8000-000000000006'),null,'a spot an admin added has none');
select is(pg_temp.handle('78000000-0000-4000-8000-000000000007'),null,'an import has none, even from a named account');
select is(pg_temp.own('78000000-0000-4000-8000-000000000001'),false,'signed out, nothing is own');
create temporary table first_handle as select pg_temp.handle('78000000-0000-4000-8000-000000000001') as h;
reset role;

-- 拿過就一直保留：改名、空白、像 email、被管理員清除。
update auth.users set raw_user_meta_data='{"display_name":"新名字"}' where id='10000000-0000-4000-8000-000000000001';
select is(pg_temp.handle('78000000-0000-4000-8000-000000000001'),(select h from first_handle),'renaming keeps the handle');
update auth.users set raw_user_meta_data='{}' where id='10000000-0000-4000-8000-000000000001';
select is((select contributor_name from community_spots where id='78000000-0000-4000-8000-000000000001'),'','the name is now empty');
select is(pg_temp.handle('78000000-0000-4000-8000-000000000001'),(select h from first_handle),'an emptied name keeps the handle');
update auth.users set raw_user_meta_data='{"display_name":"a@b.test"}' where id='10000000-0000-4000-8000-000000000001';
select is(pg_temp.handle('78000000-0000-4000-8000-000000000001'),(select h from first_handle),'an email-like name keeps the handle');
insert into contributor_name_clears(spot_id,cleared_by) values('78000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000005');
update community_spots set note='清除後' where id='78000000-0000-4000-8000-000000000002';
select is(pg_temp.handle('78000000-0000-4000-8000-000000000002'),(select h from first_handle),'a name an admin cleared keeps the handle');

-- 像 email 的人改成正常名稱 → 從此有代號。
update auth.users set raw_user_meta_data='{"display_name":"小英"}' where id='10000000-0000-4000-8000-000000000006';
select matches(pg_temp.handle('78000000-0000-4000-8000-000000000004'),'^[0-9a-f]{32}$','a later public name starts the handle');

-- 看不到的點（hidden）只在 RLS 下不出現；函式直接呼叫也不回代號。
update community_spots set status='hidden' where id='78000000-0000-4000-8000-000000000005';
set local role anon;
select is(public.spot_contributor_handle('78000000-0000-4000-8000-000000000005'),null,'a hidden spot gives no handle, even called directly');
select is(public.spot_contributor_handle(gen_random_uuid()),null,'an unknown spot gives none');
reset role;

-- 名稱只在被隱藏的點上公開過，不算公開。
update auth.users set raw_user_meta_data='{"display_name":"只在隱藏點"}' where id='10000000-0000-4000-8000-000000000003';
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('78000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000003','隱藏',23.708,120.708,'雲林縣','freeMotorcycle',true,false,'hidden');
select ok(not exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000003'),
  'a name shown only on a hidden spot was never public');

-- ===== is_own =====
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000001');
select is(pg_temp.own('78000000-0000-4000-8000-000000000001'),true,'the reporter sees the spot as own');
select is(pg_temp.own('78000000-0000-4000-8000-000000000003'),false,'someone else''s spot is not own');
select is(public.spot_is_own('78000000-0000-4000-8000-000000000005'),false,'a hidden spot is never own through the function');
select pg_temp.act('10000000-0000-4000-8000-000000000002');
select is(pg_temp.own('78000000-0000-4000-8000-000000000003'),true,'own follows the signed-in account');
select is(pg_temp.own('78000000-0000-4000-8000-000000000001'),false,'and only its own spots');
reset role;

-- ===== API =====
set local role anon;
select pg_temp.act(null);
select ok((select bool_and(e ? 'contributor_handle' and e ? 'is_own')
  from jsonb_array_elements(api_v1.spots_in_viewport(23.70,120.70,23.71,120.71)->'spots') e),
  'spots_in_viewport serves both fields on community spots');
select is((select e->>'contributor_handle' from jsonb_array_elements(api_v1.spots_in_viewport(23.70,120.70,23.71,120.71)->'spots') e
  where e->>'id'='78000000-0000-4000-8000-000000000001'),(select h from first_handle),'the handle is the one public_spots gives');
reset role;
insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,effective_date)
values('代號官方點',23.709,120.709,'雲林縣','offStreet','https://example.test/h','雲林縣政府',current_date);
set local role anon;
select is((select e->'contributor_handle' from jsonb_array_elements(api_v1.spots_in_viewport(23.70,120.70,23.71,120.71)->'spots') e
  where e->>'name'='代號官方點'),'null'::jsonb,'official spots carry a null handle');
select is((select e->'is_own' from jsonb_array_elements(api_v1.spots_in_viewport(23.70,120.70,23.71,120.71)->'spots') e
  where e->>'name'='代號官方點'),'false'::jsonb,'and are never own');
select is((select count(*)::int from viewport_spots_v3(23.70,120.70,23.71,120.71) v where v.contributor_handle is not null),
  (select count(*)::int from public_spots p where p.lat between 23.70 and 23.71 and p.lng between 120.70 and 120.71 and p.contributor_handle is not null),
  'viewport_spots_v3 (what the App reads) carries the handle');
select lives_ok($$select count(*) from viewport_spots(23.70,120.70,23.71,120.71)$$,'the legacy viewport still reads');
select lives_ok($$select count(*) from viewport_spots_v2(23.70,120.70,23.71,120.71)$$,'and its v2');
-- 私有的密鑰、名單與計算函式，API 角色都碰不到。
select throws_ok($$select * from private.contributor_handle_key$$,'42501',null,'anon cannot read the key');
select throws_ok($$select private.contributor_handle('10000000-0000-4000-8000-000000000001')$$,'42501',null,'anon cannot derive a handle from a uid');
reset role;
set local role authenticated;
select throws_ok($$select * from private.contributor_handle_holders$$,'42501',null,'authenticated cannot list who has a handle');
reset role;
select ok(not has_function_privilege('service_role','private.contributor_handle(uuid)','execute'),'service_role cannot derive handles either');

-- ===== 刪除帳號：不再有代號、不能串連 =====
delete from auth.users where id='10000000-0000-4000-8000-000000000001';
select is(pg_temp.handle('78000000-0000-4000-8000-000000000001'),null,'a deleted account''s spot has no handle');
select ok(not exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000001'),
  'nothing records that the deleted account had one');
select ok(not exists(select 1 from moderation_queue q where q.base_spot ? 'contributor_handle')
  and not exists(select 1 from admin_audit_log a where a.before ? 'contributor_handle' or a.after ? 'contributor_handle'),
  'no snapshot keeps a handle');

select * from finish();
rollback;
