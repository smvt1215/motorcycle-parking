-- 刪除帳號網頁登入前的帳號檢查（#270；202611051000_deletion_precheck.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- ===== 權限 =====
select ok(not has_table_privilege(r,'private.deletion_precheck_attempts','select'),r||' cannot read attempts')
  from (values ('anon'),('authenticated'),('service_role')) v(r);
select ok(not has_function_privilege(r,'public.deletion_precheck_attempt(text)','execute'),r||' cannot record attempts')
  from (values ('public'),('anon'),('authenticated')) v(r);
select ok(not has_function_privilege(r,'public.deletion_precheck_has_account(text,text)','execute'),r||' cannot look up accounts')
  from (values ('public'),('anon'),('authenticated')) v(r);
select ok(has_function_privilege('service_role','public.deletion_precheck_attempt(text)','execute'),'the Edge Function records attempts');
select ok(has_function_privilege('service_role','public.deletion_precheck_has_account(text,text)','execute'),'the Edge Function looks up accounts');
select is((select p.prosecdef and p.proconfig @> array['search_path=""']
  from pg_proc p where p.oid='public.deletion_precheck_has_account(text,text)'::regprocedure),true,
  'the lookup is a security definer with an empty search_path');
select is((select p.prosecdef and p.proconfig @> array['search_path=""']
  from pg_proc p where p.oid='public.deletion_precheck_attempt(text)'::regprocedure),true,
  'the limiter is a security definer with an empty search_path');

-- ===== 帳號查詢 =====
insert into auth.identities(provider_id,user_id,identity_data,provider,created_at,updated_at)
  values('apple-sub-003','10000000-0000-4000-8000-000000000003','{"email":"x@privaterelay.appleid.com"}','apple',now(),now()),
        ('google-sub-003','10000000-0000-4000-8000-000000000003','{"email":"x@example.test"}','google',now(),now());

set local role service_role;
select is(public.deletion_precheck_has_account('apple','apple-sub-003'),true,'an Apple identity has an account');
select is(public.deletion_precheck_has_account('google','google-sub-003'),true,'a Google identity has an account');
select is(public.deletion_precheck_has_account('google','apple-sub-003'),false,'the sub belongs to its own provider');
select is(public.deletion_precheck_has_account('google','nobody'),false,'an unknown sub has no account');
select throws_ok($$select public.deletion_precheck_has_account('email','x@example.test')$$,'22023','request.invalid','only google and apple');
select throws_ok($$select public.deletion_precheck_has_account('google','')$$,'22023','request.invalid','a sub is required');
reset role;
update auth.users set deleted_at=now() where id='10000000-0000-4000-8000-000000000003';
set local role service_role;
select is(public.deletion_precheck_has_account('apple','apple-sub-003'),false,'a deleted account does not count');
reset role;

-- ===== 頻率限制 =====
set local role service_role;
select throws_ok($$select public.deletion_precheck_attempt('short')$$,'22023','request.invalid','a network hash is required');
select public.deletion_precheck_attempt(repeat('a',64)) from generate_series(1,30);
select throws_ok($$select public.deletion_precheck_attempt(repeat('a',64))$$,'P0001','deletion_precheck.rate_limited','30 an hour per network');
select lives_ok($$select public.deletion_precheck_attempt(repeat('b',64))$$,'other networks are not limited');
reset role;
select is((select count(*)::int from private.deletion_precheck_attempts where ip_hash=repeat('a',64)),30,'a refused attempt is not stored');
update private.deletion_precheck_attempts set created_at=created_at-interval '61 minutes' where ip_hash=repeat('a',64);
set local role service_role;
select lives_ok($$select public.deletion_precheck_attempt(repeat('a',64))$$,'the window rolls after an hour');
reset role;
select is((select count(*)::int from private.deletion_precheck_attempts where ip_hash=repeat('a',64)),1,'attempts older than an hour are deleted');

select * from finish();
rollback;
