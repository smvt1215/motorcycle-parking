-- 停權延續到同一登入身分的新帳號（#331，202611090200_suspension_carryover.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('20000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid
$$;
create function pg_temp.new_user(n int,app_meta jsonb default '{"provider":"google"}') returns void language sql as $$
  insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
  values(pg_temp.u(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'carry'||n||'@example.test',now(),now(),false,app_meta,'{}');
$$;
create function pg_temp.link(n int,provider text,sub text) returns void language sql as $$
  insert into auth.identities(provider_id,user_id,identity_data,provider,created_at,updated_at)
  values(sub,pg_temp.u(n),jsonb_build_object('sub',sub),provider,now(),now());
$$;
create function pg_temp.ban(n int,duration text) returns void language sql as $$
  select public.admin_set_user_suspension('10000000-0000-4000-8000-000000000005',pg_temp.u(n),'ban',duration,'測試用原因');
$$;
create function pg_temp.hash(provider text,sub text) returns bytea language sql as $$
  select private.suspension_carryover_hash(provider,sub)
$$;
create function pg_temp.rows(provider text,sub text) returns bigint language sql as $$
  select count(*) from private.suspension_carryover c where c.identity_hash=pg_temp.hash(provider,sub)
$$;
create function pg_temp.drop_user(n int) returns void language sql as $$
  delete from auth.users where id=pg_temp.u(n);
$$;

delete from private.suspension_carryover;

-- ===== 權限 =====
select ok((select relrowsecurity from pg_class where oid=t::regclass),t||' has row level security')
from unnest(array['private.suspension_carryover','private.suspension_carryover_key']) t;
select ok(not has_table_privilege(r,t,p),r||' cannot '||p||' '||t)
from unnest(array['anon','authenticated','service_role']) r,
  unnest(array['private.suspension_carryover','private.suspension_carryover_key']) t,
  unnest(array['select','insert','update','delete']) p;
select ok(not has_function_privilege(r,f,'execute'),r||' cannot call '||f)
from unnest(array['anon','authenticated','service_role']) r,
  unnest(array['public.suspension_carryover_capture()','public.suspension_carryover_restore()',
    'public.suspension_carryover_prune()','private.suspension_carryover_hash(text,text)',
    'private.retention_suspension_carryover()','private.suspension_set(uuid,uuid,text,text,boolean,timestamptz)']) f;
select ok(p.prosecdef and p.proconfig @> array['search_path=""'],p.oid::regprocedure::text||' is a security definer with an empty search path')
from pg_proc p where p.oid in ('public.suspension_carryover_capture()'::regprocedure,
  'public.suspension_carryover_restore()'::regprocedure,'public.suspension_carryover_prune()'::regprocedure,
  'private.suspension_carryover_hash(text,text)'::regprocedure);
select ok(exists(select 1 from pg_trigger t where t.tgrelid='auth.users'::regclass and t.tgname='suspension_carryover_capture'
    and t.tgenabled='O' and (t.tgtype & 2)<>0 and (t.tgtype & 8)<>0),'capture runs before delete on auth.users');
select ok(exists(select 1 from pg_trigger t where t.tgrelid='auth.identities'::regclass and t.tgname='suspension_carryover_restore'
    and t.tgenabled='O' and (t.tgtype & 2)=0 and (t.tgtype & 4)<>0),'restore runs after insert on auth.identities');
-- Only the hash, its dates: nothing that names a person.
select is((select array_agg(a.attname::text order by a.attnum) from pg_attribute a
    where a.attrelid='private.suspension_carryover'::regclass and a.attnum>0 and not a.attisdropped),
  array['identity_hash','until','expires_at','created_at'],'the table has no user, email, sub or reason column');

-- ===== HMAC =====
select isnt(pg_temp.hash('google','same-sub'),pg_temp.hash('apple','same-sub'),'the provider is part of the hash');
select isnt(pg_temp.hash('google','x'),pg_temp.hash('googlex',''),'the provider and the sub cannot run together');
select is(octet_length(pg_temp.hash('google','x')),32,'a whole SHA-256');
select ok((select c.key<>k.key from private.suspension_carryover_key c,private.contributor_handle_key k),
  'its key is not the contributor handle key');

-- ===== 不寫入 =====
select pg_temp.new_user(1); select pg_temp.link(1,'google','sub-free');
select pg_temp.drop_user(1);
select is(pg_temp.rows('google','sub-free'),0::bigint,'no suspension: nothing is kept');

select pg_temp.new_user(2); select pg_temp.link(2,'google','sub-ended');
select pg_temp.ban(2,'7d');
update private.user_suspensions set until=now()-interval '1 second' where user_id=pg_temp.u(2);
select pg_temp.drop_user(2);
select is(pg_temp.rows('google','sub-ended'),0::bigint,'an ended suspension: nothing is kept');

-- ===== 有到期日 =====
select pg_temp.new_user(3); select pg_temp.link(3,'google','sub-dated');
select pg_temp.ban(3,'7d');
create temporary table dated as select until from private.user_suspensions where user_id=pg_temp.u(3);
select pg_temp.drop_user(3);
select ok(not exists(select 1 from auth.users where id=pg_temp.u(3)),'the account is really deleted');
select ok(not exists(select 1 from private.user_suspensions where user_id=pg_temp.u(3)),'and its suspension cascades');
select is((select c.until from private.suspension_carryover c where c.identity_hash=pg_temp.hash('google','sub-dated')),
  (select until from dated),'the end date is kept');
select is((select c.expires_at from private.suspension_carryover c where c.identity_hash=pg_temp.hash('google','sub-dated')),
  (select until from dated),'and the row expires with the suspension');
-- The raw sub is in no row, as text or inside the hash.
select ok(not exists(select 1 from private.suspension_carryover c
    where position(convert_to('sub-dated','UTF8') in c.identity_hash)>0 or to_jsonb(c)::text like '%sub-dated%'),
  'the row does not contain the sub');

-- 其他身分不受影響。
select pg_temp.new_user(4); select pg_temp.link(4,'google','sub-other');
select ok(not is_suspended(pg_temp.u(4)),'another identity is not suspended');
select is(pg_temp.rows('google','sub-dated'),1::bigint,'and leaves the row alone');
-- 同一個 sub、不同供應商是不同身分。
select pg_temp.new_user(5); select pg_temp.link(5,'apple','sub-dated');
select ok(not is_suspended(pg_temp.u(5)),'the same sub at another provider is another identity');

select pg_temp.new_user(6); select pg_temp.link(6,'google','sub-dated');
select is((select until from private.user_suspensions where user_id=pg_temp.u(6)),(select until from dated),
  'the same identity gets the suspension back, same end date');
select is(pg_temp.rows('google','sub-dated'),0::bigint,'the row is deleted once used');
select is((select count(*) from admin_audit_log a where a.target_id=pg_temp.u(6)::text and a.action='ban_user'
    and a.actor=private.suspension_system_actor() and a.after->>'duration'='until'),1::bigint,'and it is audited as the system');
select is((select reason from private.user_suspensions where user_id=pg_temp.u(6)),'同一登入身分重新建立帳號，恢復刪除前的停權（#331）',
  'the old reason is not carried, only a fixed note');

-- ===== 無限期 =====
select pg_temp.new_user(7); select pg_temp.link(7,'apple','sub-forever');
select pg_temp.ban(7,'indefinite');
select pg_temp.drop_user(7);
select is((select c.until from private.suspension_carryover c where c.identity_hash=pg_temp.hash('apple','sub-forever')),null,
  'indefinite stays indefinite');
select is((select c.expires_at from private.suspension_carryover c where c.identity_hash=pg_temp.hash('apple','sub-forever')),
  now()+interval '180 days','and is kept for 180 days');
select pg_temp.new_user(8); select pg_temp.link(8,'apple','sub-forever');
select ok(is_suspended(pg_temp.u(8)),'the new account is suspended');
select is((select until from private.user_suspensions where user_id=pg_temp.u(8)),null,'indefinitely');
select is(pg_temp.rows('apple','sub-forever'),0::bigint,'the row is deleted once used');

-- 恢復後再刪除：重新寫入，180 天重新起算。
select pg_temp.drop_user(8);
select is(pg_temp.rows('apple','sub-forever'),1::bigint,'deleting again keeps the identity again');
select pg_temp.new_user(9); select pg_temp.link(9,'google','sub-relink');
insert into private.suspension_carryover(identity_hash,expires_at) values(pg_temp.hash('google','sub-relink'),now()+interval '1 day');
-- The row that was left behind (a failed restore) is overwritten.
select pg_temp.ban(9,'indefinite');
select pg_temp.drop_user(9);
select is((select c.expires_at from private.suspension_carryover c where c.identity_hash=pg_temp.hash('google','sub-relink')),
  now()+interval '180 days','the 180 days start over');

-- ===== 多個身分 =====
select pg_temp.new_user(10);
select pg_temp.link(10,'google','sub-g'); select pg_temp.link(10,'apple','sub-a'); select pg_temp.link(10,'email','sub-e');
select pg_temp.ban(10,'30d');
select pg_temp.drop_user(10);
select is(pg_temp.rows('google','sub-g'),1::bigint,'Google is kept');
select is(pg_temp.rows('apple','sub-a'),1::bigint,'Apple is kept');
select is(pg_temp.rows('email','sub-e'),0::bigint,'other providers are not');

select pg_temp.new_user(11); select pg_temp.link(11,'google','sub-g');
select ok(is_suspended(pg_temp.u(11)),'back through Google');
select is(pg_temp.rows('apple','sub-a'),1::bigint,'the Apple row stays for a separate account');
-- A longer suspension given since is not shortened when Apple is linked.
select admin_set_user_suspension('10000000-0000-4000-8000-000000000005',pg_temp.u(11),'ban','indefinite','管理員加重');
select pg_temp.link(11,'apple','sub-a');
select is((select until from private.user_suspensions where user_id=pg_temp.u(11)),null,'linking Apple does not shorten it');
select is(pg_temp.rows('apple','sub-a'),0::bigint,'and uses the row');

select pg_temp.new_user(12);
select pg_temp.link(12,'google','sub-g2'); select pg_temp.link(12,'apple','sub-a2');
select pg_temp.ban(12,'7d');
select pg_temp.drop_user(12);
select pg_temp.new_user(13); select pg_temp.link(13,'apple','sub-a2');
select pg_temp.new_user(14); select pg_temp.link(14,'google','sub-g2');
select ok(is_suspended(pg_temp.u(13)) and is_suspended(pg_temp.u(14)),'each identity carries it to its own new account');

-- ===== 到期 =====
select pg_temp.new_user(15); select pg_temp.link(15,'google','sub-late');
select pg_temp.ban(15,'indefinite');
select pg_temp.drop_user(15);
update private.suspension_carryover set expires_at=now()-interval '1 second'
  where identity_hash=pg_temp.hash('google','sub-late');
select pg_temp.new_user(16); select pg_temp.link(16,'google','sub-late');
select ok(not is_suspended(pg_temp.u(16)),'an expired row restores nothing');
select is(pg_temp.rows('google','sub-late'),1::bigint,'and waits for the prune');

insert into private.suspension_carryover(identity_hash,expires_at)
  values(pg_temp.hash('google','sub-alive'),now()+interval '1 minute');
select is(((select public.account_data_retention())->>'suspension_carryover')::int,1,'the daily retention job prunes expired rows');
select is(pg_temp.rows('google','sub-late'),0::bigint,'the expired row is gone');
select is(pg_temp.rows('google','sub-alive'),1::bigint,'a live one stays');
select is((select command from cron.job where jobname='account-data-retention'),'select public.account_data_retention()',
  'on the existing schedule');

-- ===== 出錯不擋登入 =====
-- A natural failure: administrators cannot be suspended.
insert into private.suspension_carryover(identity_hash,expires_at) values(pg_temp.hash('google','sub-admin'),now()+interval '1 day');
select pg_temp.new_user(17,'{"provider":"google","role":"admin"}');
select lives_ok($$select pg_temp.link(17,'google','sub-admin')$$,'a failing restore does not fail the sign-in');
select is((select count(*) from auth.identities where provider_id='sub-admin'),1::bigint,'the identity is there');
select is(pg_temp.rows('google','sub-admin'),1::bigint,'the row is kept: the delete is rolled back with the failure');
select ok(not is_suspended(pg_temp.u(17)),'and nothing is half done');

-- An unexpected one: the table itself is gone.
savepoint broken;
drop table private.suspension_carryover;
select pg_temp.new_user(18);
select lives_ok($$select pg_temp.link(18,'google','sub-broken')$$,'a broken carryover does not fail the sign-in');
rollback to savepoint broken;

-- ===== suspension_set 的 until =====
select pg_temp.new_user(19);
select throws_ok($$select private.suspension_set(private.suspension_system_actor(),pg_temp.u(19),'until','x')$$,
  '22023',null,'until needs a date');
select throws_ok($$select private.suspension_set(private.suspension_system_actor(),pg_temp.u(19),'until','x',false,now()-interval '1 second')$$,
  '22023',null,'in the future');
select throws_ok($$select private.suspension_set(private.suspension_system_actor(),pg_temp.u(19),'7d','x',false,now()+interval '1 day')$$,
  '22023',null,'and only until takes one');
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000005',pg_temp.u(19),'ban','until','x')$$,
  '22023',null,'administrators cannot pick until');

select * from finish();
rollback;
