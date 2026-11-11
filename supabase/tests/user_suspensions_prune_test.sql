-- 過期超過 90 天的停權列定期清除（#338；202611111500_prune_expired_suspensions.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('30000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid
$$;
create function pg_temp.new_user(n int) returns void language sql as $$
  insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
  values(pg_temp.u(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'prune'||n||'@example.test',now(),now(),false,'{"provider":"google"}','{}');
$$;
create function pg_temp.susp(n int,until timestamptz) returns void language sql as $$
  insert into private.user_suspensions(user_id,until,reason,created_by)
  values(pg_temp.u(n),until,'測試用原因','00000000-0000-0000-0000-000000000000');
$$;
create function pg_temp.has(n int) returns boolean language sql as $$
  select exists(select 1 from private.user_suspensions s where s.user_id=pg_temp.u(n))
$$;

-- ===== 權限 =====
select ok(not has_function_privilege(r,'public.user_suspensions_prune()','execute'),r||' cannot run the prune')
from unnest(array['anon','authenticated','service_role']) r;
select ok(not has_function_privilege(r,'private.retention_expired_suspensions()','execute'),r||' cannot read the period')
from unnest(array['anon','authenticated','service_role']) r;
select is(private.retention_expired_suspensions(),interval '90 days','the period is 90 days');

-- ===== 清除條件 =====
select pg_temp.new_user(n) from generate_series(1,6) n;
delete from private.user_suspensions;
select pg_temp.susp(1,now()-interval '91 days');  -- 超過 90 天：刪
select pg_temp.susp(2,now()-interval '89 days');  -- 未滿 90 天：留
select pg_temp.susp(3,null);                      -- 無限期：留
select pg_temp.susp(4,now()+interval '1 day');    -- 尚未到期：留
select pg_temp.susp(5,now()-interval '1 second'); -- 剛過期：留
select pg_temp.susp(6,now()-interval '10 years'); -- 很久以前：刪

select is(public.user_suspensions_prune(),2,'two rows are older than 90 days');
select ok(not pg_temp.has(1),'expired over 90 days is gone');
select ok(not pg_temp.has(6),'expired long ago is gone');
select ok(pg_temp.has(2),'expired under 90 days stays');
select ok(pg_temp.has(3),'an indefinite suspension stays');
select ok(pg_temp.has(4),'an active suspension stays');
select ok(pg_temp.has(5),'just expired stays');
select is(public.user_suspensions_prune(),0,'running it again deletes nothing');

-- ===== 稽核與刪帳號延續 =====
-- 查證紀錄在 admin_audit_log，清除不動它也不另寫一筆。
select pg_temp.new_user(7); select pg_temp.susp(7,now()-interval '100 days');
insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
values('00000000-0000-0000-0000-000000000000','ban_user','auth.users',pg_temp.u(7)::text,'{}','{}','測試');
select is((select count(*)::int from public.admin_audit_log where action='ban_user' and target_id=pg_temp.u(7)::text),1,'ban audit exists');
select public.user_suspensions_prune();
select is((select count(*)::int from public.admin_audit_log where action='ban_user' and target_id=pg_temp.u(7)::text),1,'the prune keeps the audit entry');
select is((select count(*)::int from public.admin_audit_log where target_id=pg_temp.u(7)::text),1,'and writes none of its own');

-- 刪帳號後的延續雜湊是另一張表，這次的清除不碰：180 天內的列留著。
delete from private.suspension_carryover;
insert into private.suspension_carryover(identity_hash,until,expires_at) values
  (decode(repeat('aa',32),'hex'),null,now()+interval '120 days'),
  (decode(repeat('bb',32),'hex'),now()-interval '100 days',now()-interval '100 days'+interval '0');
select is(public.user_suspensions_prune(),0,'no more suspension rows to prune');
select is((select count(*)::int from private.suspension_carryover),2,'the carryover table is untouched by the prune');
select is(((select public.account_data_retention())->>'suspension_carryover')::int,1,'its own prune still deletes only its expired rows');
select is((select count(*)::int from private.suspension_carryover),1,'the unexpired indefinite carryover remains');

-- ===== 每日排程 =====
select pg_temp.new_user(8); select pg_temp.susp(8,now()-interval '91 days');
select is(((select public.account_data_retention())->>'user_suspensions')::int,1,'the daily job prunes expired suspensions');
select ok(not pg_temp.has(8),'the row is gone');
select is((select command from cron.job where jobname='account-data-retention'),'select public.account_data_retention()',
  'on the existing schedule');

select * from finish();
rollback;
