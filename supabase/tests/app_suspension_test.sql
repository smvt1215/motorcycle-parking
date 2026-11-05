-- App 層級停權（#331；202611052000_app_level_suspension.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- ===== 放行清單 =====
-- api_v1 裡會寫入（volatile）但停權時仍放行的函式：帳號管理，只影響自己
-- （使用者確認 PM_ANS #331：hidden_riders 同步、刪除與取消刪除放行）。其餘每支寫入函式都必須在開頭呼叫
-- private.require_not_suspended()；新增寫入函式時沒有呼叫、也沒有列在這裡，
-- 下面的測試就會失敗。改決定時只要改這一行。
create function pg_temp.suspension_allowed() returns text[] language sql immutable as $$
  select array['request_account_deletion','cancel_account_deletion','hidden_riders_merge','hidden_riders_remove']
$$;

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'suspended' then '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","is_anonymous":false,"aal":"aal1","amr":[{"method":"oauth","timestamp":'||extract(epoch from now())::bigint||'}]}'
  when 'free' then '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","is_anonymous":false}'
  else '' end,true);
$$;

-- Rider 0001 is suspended for 7 days; 0002 is not.
select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban','7d','洗版');

-- ===== 表與函式的權限 =====
select ok((select relrowsecurity from pg_class where oid='private.user_suspensions'::regclass),'row level security is on');
select ok(not has_table_privilege(r,'private.user_suspensions',p),r||' cannot '||p||' suspensions')
from unnest(array['anon','authenticated','service_role']) r,unnest(array['select','insert','update','delete']) p;
select ok(not has_function_privilege(r,f,'execute'),r||' cannot call '||f)
from unnest(array['anon','authenticated']) r,
  unnest(array['public.is_suspended(uuid)','public.suspension_status(uuid)','public.admin_set_user_suspension(uuid,uuid,text,text,text)']) f;
select ok(has_function_privilege('service_role',f,'execute'),'the Edge Functions call '||f)
from unnest(array['public.is_suspended(uuid)','public.suspension_status(uuid)','public.admin_set_user_suspension(uuid,uuid,text,text,text)']) f;
select ok(p.prosecdef and p.proconfig @> array['search_path=""'],p.oid::regprocedure::text||' is a security definer with an empty search path')
from pg_proc p where p.oid in ('public.is_suspended(uuid)'::regprocedure,'public.suspension_status(uuid)'::regprocedure,
  'api_v1.my_account_status()'::regprocedure,'public.admin_set_user_suspension(uuid,uuid,text,text,text)'::regprocedure);
select ok(not has_function_privilege('anon','api_v1.my_account_status()','execute'),'anon cannot read an account status');
select ok(not has_function_privilege('service_role','api_v1.my_account_status()','execute'),'my_account_status is for signed-in callers only');

-- ===== 狀態 =====
select ok(is_suspended('10000000-0000-4000-8000-000000000001'),'0001 is suspended');
select ok(not is_suspended('10000000-0000-4000-8000-000000000002'),'0002 is not');
select is(suspension_status('10000000-0000-4000-8000-000000000002'),'{"suspended":false,"until":null}'::jsonb,'not suspended: until is null');
update private.user_suspensions set until=now()-interval '1 second' where user_id='10000000-0000-4000-8000-000000000001';
select ok(not is_suspended('10000000-0000-4000-8000-000000000001'),'an ended suspension does not count');
update private.user_suspensions set until=null where user_id='10000000-0000-4000-8000-000000000001';
select is(suspension_status('10000000-0000-4000-8000-000000000001'),'{"suspended":true,"until":null}'::jsonb,'indefinite: until is null');
update private.user_suspensions set until=now()+interval '7 days' where user_id='10000000-0000-4000-8000-000000000001';

set local role authenticated;
select pg_temp.act('suspended');
select is(api_v1.my_account_status(),jsonb_build_object('suspended',true,'suspended_until',now()+interval '7 days'),
  'my_account_status gives the end of the suspension');
select pg_temp.act('free');
select is(api_v1.my_account_status(),'{"suspended":false,"suspended_until":null}'::jsonb,'and nothing for an account in good standing');
select pg_temp.act('');
select throws_ok($$select api_v1.my_account_status()$$,'PT401','auth.sign_in_required','a sign-in is required');
reset role;

-- ===== 每支 api_v1 寫入函式都要擋 =====
select ok(exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='api_v1' and p.proname=a and p.provolatile='v'),
  a||' on the allowed list is a write function of api_v1')
from unnest(pg_temp.suspension_allowed()) a;

create temporary table writes on commit drop as
select p.oid::regprocedure::text as fn,
  format('select %s(%s)',p.oid::regproc,
    coalesce((select string_agg('null::'||format_type(t,null),',' order by o) from unnest(p.proargtypes) with ordinality x(t,o)),'')) as call
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='api_v1' and p.provolatile='v' and p.prokind='f'
  and p.proname<>all(pg_temp.suspension_allowed());
grant select on writes to authenticated;

set local role authenticated;
select pg_temp.act('suspended');
-- Called with null arguments: the check comes before any argument check.
select throws_ok(w.call,'PT403','account.suspended',w.fn||' refuses a suspended account') from writes w;
reset role;
select pass('api_v1 has '||(select count(*) from writes)||' write functions outside the allowed list, each checked above');

-- 其他 schema 能被 anon／authenticated 呼叫的寫入函式只能是管理員函式
-- （管理員不能被停權）；不然要加檢查並移到 api_v1。
select is(array(select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname not in ('api_v1','admin_v1','pg_catalog','information_schema','extensions','graphql','graphql_public',
        'auth','storage','realtime','vault','cron','net','pgsodium','pgsodium_masks','supabase_functions','pgbouncer','pg_toast')
      and n.nspname not like 'pg\_temp%' and p.provolatile='v' and p.prokind='f' and p.prorettype<>'trigger'::regtype
      and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute'))
      and p.proname not like 'admin\_%'),
  array[]::text[],'every other write a client can call is an admin function');

-- ===== 放行：帳號管理 =====
set local role authenticated;
select pg_temp.act('suspended');
select lives_ok($$select api_v1.hidden_riders_merge('[]')$$,'a suspended account still manages its hidden riders');
select lives_ok($$select api_v1.hidden_riders_remove(lpad('1',32,'0'))$$,'and removes one');
select is(api_v1.account_deletion_status()->>'status','none','reads its deletion status');
select is(api_v1.request_account_deletion('app')->>'status','pending','requests deletion');
select is(api_v1.cancel_account_deletion()->>'status','none','and cancels it');
reset role;

-- ===== 寫入的防線 =====
set local role service_role;
select throws_ok($$select apply_report('10000000-0000-4000-8000-000000000001',repeat('a',64),repeat('b',64),
    '{"action":"flag","source_id":"x","reason":"名稱：測試"}')$$,
  'PT403','account.suspended','apply_report refuses a suspended account, whatever the action');
reset role;
select throws_ok($$insert into rate_limit_events(user_id,ip_hash) values('10000000-0000-4000-8000-000000000001',repeat('a',64))$$,
  'PT403','account.suspended','no report can be counted for it');
select lives_ok($$insert into rate_limit_events(user_id,ip_hash) values('10000000-0000-4000-8000-000000000002',repeat('a',64))$$,
  'other accounts report as before');
create function pg_temp.err_detail(q text) returns jsonb language plpgsql as $$
declare d text;
begin
  execute q;
  return null;
exception when others then
  get stacked diagnostics d=pg_exception_detail;
  return d::jsonb;
end $$;
select ok((pg_temp.err_detail($$insert into rate_limit_events(user_id,ip_hash) values('10000000-0000-4000-8000-000000000001',repeat('a',64))$$)->>'until')::timestamptz
  =now()+interval '7 days','the error detail carries until');

-- ===== 名稱與頭像 =====
update auth.users set raw_user_meta_data='{"display_name":"舊名","profile_avatar_url":"https://x/a.jpg","full_name":"甲"}'
  where id='10000000-0000-4000-8000-000000000002';
select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','ban','30d','不當名稱');
update auth.users set raw_user_meta_data='{"display_name":"新名","profile_avatar_url":"","full_name":"乙"}'
  where id='10000000-0000-4000-8000-000000000002';
select is((select raw_user_meta_data from auth.users where id='10000000-0000-4000-8000-000000000002'),
  '{"display_name":"舊名","profile_avatar_url":"https://x/a.jpg","full_name":"乙"}'::jsonb,
  'a suspended account keeps its name and avatar; other keys update');
update auth.users set raw_user_meta_data=raw_user_meta_data-'display_name'-'profile_avatar_url'
  where id='10000000-0000-4000-8000-000000000002';
select is((select raw_user_meta_data->>'display_name' from auth.users where id='10000000-0000-4000-8000-000000000002'),'舊名',
  'removing the name is no change either');
update auth.users set raw_user_meta_data='{"display_name":"新的"}' where id='10000000-0000-4000-8000-000000000001';
select is((select raw_user_meta_data from auth.users where id='10000000-0000-4000-8000-000000000001'),'{}'::jsonb,
  'a name it never had is not added');
select is((select raw_user_meta_data->>'profile_avatar_url' from auth.users where id='10000000-0000-4000-8000-000000000002'),'https://x/a.jpg',
  'nor is removing the avatar');
-- 頭像檔案：停權中不能上傳也不能刪除。
insert into storage.objects(bucket_id,name,owner_id) values
  ('motopark-avatars','10000000-0000-4000-8000-000000000002/'||'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg','10000000-0000-4000-8000-000000000002');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","is_anonymous":false}',true);
select throws_ok($$insert into storage.objects(bucket_id,name,owner_id) values('motopark-avatars',
    '10000000-0000-4000-8000-000000000002/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg','10000000-0000-4000-8000-000000000002')$$,
  '42501',null,'a suspended account cannot upload an avatar');
select set_config('storage.allow_delete_query','true',true);
delete from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000002/%';
reset role;
select is((select count(*)::int from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000002/%'),1,
  'nor delete its avatar file');
select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','unban',null,'解除');
update auth.users set raw_user_meta_data='{"display_name":"新名"}' where id='10000000-0000-4000-8000-000000000002';
select is((select raw_user_meta_data->>'display_name' from auth.users where id='10000000-0000-4000-8000-000000000002'),'新名',
  'after the suspension the name changes again');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","is_anonymous":false}',true);
select lives_ok($$insert into storage.objects(bucket_id,name,owner_id) values('motopark-avatars',
    '10000000-0000-4000-8000-000000000002/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','10000000-0000-4000-8000-000000000002')$$,
  'and an avatar uploads again');
delete from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000002/%';
reset role;
select is((select count(*)::int from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000002/%'),0,
  'and its avatar files can be deleted again');
select ok(not has_function_privilege('anon','public.caller_suspended()','execute'),'anon cannot call caller_suspended');
select ok(exists(select 1 from pg_trigger where tgname='suspended_profile_freeze' and tgrelid='auth.users'::regclass
  and tgtype&2=2),'the freeze runs before the update, ahead of the name triggers');

-- ===== 帳號刪除 =====
select is((select confdeltype from pg_constraint where conrelid='private.user_suspensions'::regclass and contype='f'),'c',
  'a suspension goes with the deleted account; its audit entries stay (#267)');
select ok(not exists(select 1 from pg_trigger where tgrelid='auth.users'::regclass and tgname='rider_sightings_unban'),
  'Auth banned_until no longer drives the sighting suspension');

select * from finish();
rollback;
