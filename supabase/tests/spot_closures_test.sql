-- Temporary closures and the admin map's limit (202610270091_spot_closures.sql).
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
create temporary table d(today date);
insert into d select (now() at time zone 'Asia/Taipei')::date;
grant select on d to authenticated,anon;

-- ===== 形狀 =====
select ok(valid_closure(null),'none');
select ok(valid_closure('{"reason":"works","since":"2026-10-26"}'),'works without a date');
select ok(valid_closure('{"reason":"closed","since":"2026-10-26","until":"2026-11-30","basis":"車友回報"}'),'a closure with a date');
select ok(not valid_closure('{"reason":"gone","since":"2026-10-26"}'),'only works or closed');
select ok(not valid_closure('{"reason":"works"}'),'since is required');
select is(valid_closure('{"since":"2026-10-27"}'),false,'a reason is required: false, never NULL');
select is(valid_closure('{"reason":null,"since":"2026-10-27"}'),false,'a null reason too');
select ok(not valid_closure('{"reason":"works","since":"2026-02-30"}'),'a real date');
select ok(not valid_closure('{"reason":"works","since":"2026-10-26","until":"2026-10-25"}'),'until is not before since');
select ok(not valid_closure('{"reason":"works","since":"2026-10-26","note":"x"}'),'no other keys');
select ok(not valid_closure(jsonb_build_object('reason','works','since','2026-10-26','basis',repeat('字',201))),'basis at most 200');

-- ===== 到期 =====
select is(closure_state(jsonb_build_object('reason','works','since',(select today from d)-7)),'active',
  'without a date: 7 days after since it still holds');
select is(closure_state(jsonb_build_object('reason','works','since',(select today from d)-8)),'expired','and the day after it ends');
select is(closure_state(jsonb_build_object('reason','closed','since',(select today from d)-30,'until',(select today from d))),'active',
  'the until day itself still holds');
select is(closure_state(jsonb_build_object('reason','closed','since',(select today from d)-30,'until',(select today from d)-1)),'expired',
  'past until it is over');
select is(closure_state(null),null,'no closure, no state');

-- ===== 讀取 =====
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,closure)
  values('10000000-0000-4000-8000-000000000001','封閉測試點',25.061,121.581,'臺北市','paidMotorcycle',
    jsonb_build_object('reason','works','since',(select today from d)-1,'until',(select today from d)+30,'basis','車友回報'))
  returning id)
  insert into fx select 'spot',id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_name,source_url,effective_date,closure)
  values('官方封閉測試',25.062,121.582,'臺北市','heavyOnly','臺北市政府','https://example.test/n','2026-01-01',
    jsonb_build_object('reason','closed','since',(select today from d)-20))
  returning id)
  insert into fx select 'official',id from s;
set local role anon;
select is((select closure_state from viewport_spots_v3(25.05,121.57,25.07,121.59) where id=(select id from fx where name='spot')),
  'active','the app reads the server''s judgement');
select is((select closure->>'reason' from viewport_spots_v3(25.05,121.57,25.07,121.59) where id=(select id from fx where name='spot')),
  'works','and the closure');
select is((select closure_state from official_viewport_spots_v3(25.05,121.57,25.07,121.59) where id='official:'||(select id from fx where name='official')),
  'expired','official spots too');
select is((select count(*)::integer from viewport_spots_v2(25.05,121.57,25.07,121.59) where id=(select id from fx where name='spot')),
  1,'older builds still list it');
reset role;

-- ===== 管理站與審核 =====
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='spot'),'10000000-0000-4000-8000-000000000002','已經可以停','reopened','{"closure":null}')
  returning id)
  insert into fx select 'reopened',id from s;
create temporary table v(at timestamptz);
grant all on v to authenticated;
insert into v select updated_at from community_spots where id=(select id from fx where name='spot');
set local role authenticated;
select pg_temp.act('admin');
select is(admin_spot_rows(array[(select id::text from fx where name='spot')])->0->>'closure_state','active',
  'the admin form reads the same judgement');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='spot'),'{"closure":{"reason":"works"}}',(select at from v),'')$$,
  '22023','invalid closure','a broken closure is named');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='spot'),
  jsonb_build_object('closure',jsonb_build_object('reason','closed','since',(select today from d)-1,'until',(select today from d)+60)),
  (select at from v),'延長')$$,'the admin extends it');
select lives_ok($$select admin_resolve_report((select id from fx where name='reopened'),'accepted','{"closure":null}','',true)$$,
  'a rider''s 已經可以停 clears it (forced: the admin extended it since)');
reset role;
select is((select closure from community_spots where id=(select id from fx where name='spot')),null,'and the spot stays');

-- ===== 改為官方點 =====
reset role;
update community_spots set closure=jsonb_build_object('reason','works','since',(select today from d))
  where id=(select id from fx where name='spot');
delete from v; insert into v select updated_at from community_spots where id=(select id from fx where name='spot');
set local role authenticated;
select pg_temp.act('admin');
create temporary table promoted(j jsonb);
grant all on promoted to authenticated;
insert into promoted select admin_promote_spot((select id::text from fx where name='spot'),
  '{"scooter_allowed":true,"heavy_allowed":true,"source_name":"臺北市政府","source_url":"https://example.test/n","effective_date":"2026-01-01"}',(select at from v),'');
reset role;
select is((select j->'closure'->>'reason' from promoted),'works','a promoted spot keeps its closure');

-- ===== 地圖上限（#133） =====
insert into community_spots(user_id,name,lat,lng,city,space_type)
  select '10000000-0000-4000-8000-000000000001','上限測試'||n,24.50+n*0.00001,120.50,'臺中市','paidMotorcycle'
  from generate_series(1,620) n;
insert into official_heavy_spots(name,lat,lng,city,space_type,source_name,source_url,effective_date)
  select '上限官方'||n,24.50+n*0.00001,120.501,'臺中市','heavyOnly','臺中市政府','https://example.test/n','2026-01-01'
  from generate_series(1,620) n;
set local role authenticated;
select pg_temp.act('admin');
create temporary table m as select admin_viewport_spots_v2(24.49,120.49,24.52,120.52,true,true,true) j;
reset role;
select is((select jsonb_array_length(j->'rows') from m),1000,'at most 1,000 rows in all');
select is((select j->'counts'->'community' from m),'{"shown":500,"total":620}'::jsonb,'each layer at most 500, with its count');
select is((select j->'counts'->'official' from m),'{"shown":500,"total":620}'::jsonb,'official too');
select is((select j->'counts'->'hidden'->>'shown' from m),'0','the rest is left out');
select ok((select (j->>'truncated')::boolean from m),'and says so');
set local role authenticated;
select pg_temp.act('user');
select throws_ok($$select admin_viewport_spots_v2(24.49,120.49,24.52,120.52)$$,'42501',null,'admins only');

select * from finish();
rollback;
