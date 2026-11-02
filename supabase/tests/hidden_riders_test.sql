-- 隱藏清單與依 id 批次讀點位（#280；202611021200_hidden_riders.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'a' then '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","is_anonymous":false}'
  when 'b' then '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","is_anonymous":false}'
  when 'anon_user' then '{"sub":"10000000-0000-4000-8000-000000000004","role":"authenticated","is_anonymous":true}'
  else '' end,true);
$$;
create function pg_temp.h(n int) returns text language sql immutable as $$ select lpad(to_hex(n),32,'0') $$;
create function pg_temp.item(n int,at text,name text default '阿明',spot text default '某點') returns jsonb language sql immutable as $$
  select jsonb_build_object('handle',pg_temp.h(n),'name_at_hide',name,'spot_name_at_hide',spot,'hidden_at',at)
$$;
grant execute on function pg_temp.h(int),pg_temp.item(int,text,text,text) to anon,authenticated;

-- ===== 隱藏清單 =====
set local role authenticated;
select pg_temp.act('a');
select is(api_v1.hidden_riders_list(),'{"items":[],"limit":500}'::jsonb,'an empty list to start');
select is(jsonb_array_length(api_v1.hidden_riders_merge(jsonb_build_array(
    pg_temp.item(1,'2026-10-30T10:00:00+08:00'),pg_temp.item(2,'2026-10-31T10:00:00Z','','')))->'items'),2,'merge adds the list');
-- 同一代號保留較早的時間與當時的名稱；較晚的不覆蓋。
select is((select e->>'name_at_hide' from jsonb_array_elements(api_v1.hidden_riders_merge(jsonb_build_array(
    pg_temp.item(1,'2026-10-29T10:00:00+08:00','舊名','舊點'),pg_temp.item(2,'2026-11-01T00:00:00Z','新名','新點')))->'items') e
  where e->>'handle'=pg_temp.h(1)),'舊名','an earlier hide keeps its own name');
select is((select (e->>'hidden_at')::timestamptz from jsonb_array_elements(api_v1.hidden_riders_list()->'items') e where e->>'handle'=pg_temp.h(1)),
  '2026-10-29T10:00:00+08:00'::timestamptz,'and its time');
select is((select e->>'name_at_hide'||'|'||(e->>'hidden_at')::timestamptz from jsonb_array_elements(api_v1.hidden_riders_list()->'items') e where e->>'handle'=pg_temp.h(2)),
  '|'||'2026-10-31T10:00:00Z'::timestamptz,'a later hide does not overwrite');
select is(jsonb_array_length(api_v1.hidden_riders_merge(jsonb_build_array(
    pg_temp.item(3,'2026-11-01T00:00:00Z','後','後'),pg_temp.item(3,'2026-10-01T00:00:00Z','先','先')))->'items'),3,'a handle twice in one batch is one row');
select is((select e->>'name_at_hide' from jsonb_array_elements(api_v1.hidden_riders_list()->'items') e where e->>'handle'=pg_temp.h(3)),'先',
  'the earliest of the batch wins');
select is(jsonb_array_length(api_v1.hidden_riders_merge('[]')->'items'),3,'an empty merge returns the list');

-- 只有本人。
select pg_temp.act('b');
select is(api_v1.hidden_riders_list()->'items','[]'::jsonb,'someone else sees only their own list');
select is(jsonb_array_length(api_v1.hidden_riders_remove(pg_temp.h(1))->'items'),0,'and cannot remove another''s entries');
select pg_temp.act('a');
select is(jsonb_array_length(api_v1.hidden_riders_list()->'items'),3,'the owner''s list is untouched');
select is(jsonb_array_length(api_v1.hidden_riders_remove(pg_temp.h(1))->'items'),2,'remove takes one handle out');
select is(jsonb_array_length(api_v1.hidden_riders_remove(pg_temp.h(99))->'items'),2,'removing an unknown handle is fine');

-- 不合法的內容。
select throws_ok($$select api_v1.hidden_riders_merge('{}')$$,'PT400','request.invalid','items is an array');
select throws_ok($$select api_v1.hidden_riders_merge('[{"handle":"ABC","hidden_at":"2026-10-01T00:00:00Z"}]')$$,'PT400','request.invalid','a handle is 32 lowercase hex');
select throws_ok($$select api_v1.hidden_riders_merge(jsonb_build_array(pg_temp.item(5,'2026-10-01T00:00:00Z')||'{"user_id":"x"}'))$$,
  'PT400','request.invalid','no other keys');
select throws_ok($$select api_v1.hidden_riders_merge(jsonb_build_array(pg_temp.item(5,'2026-10-01T00:00:00Z',repeat('名',41))))$$,
  'PT400','request.invalid','names are bounded');
select throws_ok($$select api_v1.hidden_riders_merge(jsonb_build_array(pg_temp.item(5,'昨天')))$$,'PT400','request.invalid','hidden_at is a time');
select throws_ok($$select api_v1.hidden_riders_merge(jsonb_build_array(pg_temp.item(5,'2099-01-01T00:00:00Z')))$$,
  'PT400','request.invalid','not in the future');
select throws_ok($$select api_v1.hidden_riders_remove('nope')$$,'PT400','request.invalid','remove checks the handle');

-- 上限 500：超過時整批不寫入。
select is(jsonb_array_length(api_v1.hidden_riders_merge((select jsonb_agg(pg_temp.item(1000+n,'2026-10-01T00:00:00Z')) from generate_series(1,498) n))->'items'),500,
  'up to 500');
select throws_ok($$select api_v1.hidden_riders_merge(jsonb_build_array(pg_temp.item(5,'2026-10-01T00:00:00Z')))$$,
  'PT400','hidden_riders.too_many','one more is refused');
select is(jsonb_array_length(api_v1.hidden_riders_list()->'items'),500,'and nothing of that batch was kept');
select is(jsonb_array_length(api_v1.hidden_riders_merge(jsonb_build_array(pg_temp.item(2,'2026-01-02T00:00:00Z')))->'items'),500,
  'a handle already listed still merges at the limit');
select throws_ok($$select api_v1.hidden_riders_merge((select jsonb_agg(pg_temp.item(n,'2026-10-01T00:00:00Z')) from generate_series(1,501) n))$$,
  'PT400','request.invalid','a batch over the limit is refused outright');

-- 登入。
select pg_temp.act('anon_user');
select throws_ok($$select api_v1.hidden_riders_list()$$,'PT401','auth.sign_in_required','anonymous sign-in has no list');
reset role;
set local role anon;
select pg_temp.act('');
select throws_ok($$select api_v1.hidden_riders_list()$$,'42501',null,'signed out cannot call it');
select throws_ok($$select * from private.hidden_riders$$,'42501',null,'nor read the table');
reset role;
set local role authenticated;
select pg_temp.act('a');
select throws_ok($$select * from private.hidden_riders$$,'42501',null,'the App never reads the table itself');
reset role;

-- 刪除帳號：一併刪除。
delete from auth.users where id='10000000-0000-4000-8000-000000000001';
select is((select count(*)::int from private.hidden_riders where user_id='10000000-0000-4000-8000-000000000001'),0,
  'deleting the account deletes its list');

-- ===== spots_by_ids =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('7a000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','收藏一',23.901,120.901,'雲林縣','freeMotorcycle',true,false,'pending'),
  ('7a000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','收藏隱藏',23.902,120.902,'雲林縣','freeMotorcycle',true,false,'hidden');
insert into official_heavy_spots(id,name,lat,lng,city,space_type,source_url,source_name,effective_date)
values('7a000000-0000-4000-8000-000000000003','收藏官方',23.903,120.903,'雲林縣','offStreet','https://example.test/f','雲林縣政府',current_date),
  ('7a000000-0000-4000-8000-000000000004','未生效官方',23.904,120.904,'雲林縣','offStreet','https://example.test/g','雲林縣政府',current_date+1);
set local role anon;
select pg_temp.act('');
create temporary table byids as select api_v1.spots_by_ids(array['7a000000-0000-4000-8000-000000000001','7a000000-0000-4000-8000-000000000002',
  'official:7a000000-0000-4000-8000-000000000003','official:7a000000-0000-4000-8000-000000000004','tdx:Taipei:1','nope',
  '7a000000-0000-4000-8000-000000000001']) as r;
select is((select string_agg(e->>'name',',' order by n) from byids,jsonb_array_elements(r->'spots') with ordinality x(e,n)),'收藏官方,收藏一',
  'visible spots come back once, official first; hidden, not yet effective and unknown ids do not');
select is((select e->>'id' from byids,jsonb_array_elements(r->'spots') e where e->>'name'='收藏官方'),
  'official:7a000000-0000-4000-8000-000000000003','official ids keep their prefix');
select is((select array_agg(k order by k) from byids,jsonb_array_elements(r->'spots') e,jsonb_object_keys(e) k where e->>'name'='收藏官方'),
  (select array_agg(k order by k) from jsonb_array_elements(api_v1.spots_in_viewport(23.90,120.90,23.91,120.91)->'spots') e,jsonb_object_keys(e) k
    where e->>'name'='收藏官方'),'an official row has the viewport''s keys');
select is((select e from byids,jsonb_array_elements(r->'spots') e where e->>'name'='收藏一'),
  (select e from jsonb_array_elements(api_v1.spots_in_viewport(23.90,120.90,23.91,120.91)->'spots') e where e->>'name'='收藏一'),
  'a community row is the viewport''s row');
select ok((select (e ? 'contributor_handle') and (e ? 'is_own') from byids,jsonb_array_elements(r->'spots') e where e->>'name'='收藏一'),
  'with the handle and is_own');
select is(api_v1.spots_by_ids('{}'),'{"spots":[]}'::jsonb,'no ids, no spots');
select is(api_v1.spots_by_ids(null),'{"spots":[]}'::jsonb,'null is none');
select throws_ok($$select api_v1.spots_by_ids((select array_agg(gen_random_uuid()::text) from generate_series(1,201)))$$,
  'PT400','request.too_many_ids','at most 200 ids');
reset role;
set local role authenticated;
select pg_temp.act('b');
select is((select (e->>'is_own')::boolean from jsonb_array_elements(api_v1.spots_by_ids(array['7a000000-0000-4000-8000-000000000001'])->'spots') e),
  true,'is_own follows the caller');
reset role;

select * from finish();
rollback;
