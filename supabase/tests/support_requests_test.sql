-- 客服表單（#269；202611012000_support_requests.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
  select set_config('request.jwt.claims', case who
    when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
    else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
  end, true);
$$;

-- ===== 權限 =====
select ok(not has_table_privilege('authenticated','private.support_requests','select'),'riders cannot read support requests');
select ok(not has_table_privilege('service_role','private.support_requests','select'),'only the functions touch the table');
select ok(not has_function_privilege('anon','public.support_request_submit(text,text,text,text,text,text,text,text,text,text)','execute'),'anon cannot submit directly');
select ok(not has_function_privilege('authenticated','public.support_request_submit(text,text,text,text,text,text,text,text,text,text)','execute'),'riders cannot submit directly');
select ok(has_function_privilege('service_role','public.support_request_submit(text,text,text,text,text,text,text,text,text,text)','execute'),'the Edge Function submits');
select ok(not has_function_privilege('authenticated','public.support_requests_prune()','execute'),'riders cannot prune');

-- ===== 送出與頻率限制 =====
create temporary table sent(id uuid);
grant all on sent to public;
set local role service_role;
insert into sent select (public.support_request_submit('account_deletion','  Rider@Example.TEST ','  Rider@Example.TEST ','Google 登入','帳號被停權，想刪除',repeat('a',64),repeat('0',64))->>'id')::uuid;
reset role;
select is((select contact_email||'|'||account_hint||'|'||status from private.support_requests where id=(select id from sent)),
  'rider@example.test|Google 登入|exception','stored (no account: an exception), email lower-cased and trimmed');
set local role service_role;
select throws_ok($$select public.support_request_submit('other','a@b.test','a@b.test','','',repeat('a',64),repeat('0',64))$$,'22023','request.invalid','unknown kind');
select throws_ok($$select public.support_request_submit('account_deletion','not-an-email','not-an-email','','',repeat('a',64),repeat('0',64))$$,'22023','request.invalid','bad email');
select throws_ok($$select public.support_request_submit('account_deletion','a@b.test','a@b.test','',repeat('長',1001),repeat('a',64),repeat('0',64))$$,'22023','request.invalid','message too long');
select throws_ok($$select public.support_request_submit('account_deletion','a@b.test','a@b.test','','','short',repeat('0',64))$$,'22023','request.invalid','network hash required');
select public.support_request_submit('account_deletion','rider@example.test','rider@example.test','','',repeat('b',64),repeat('0',64));
select public.support_request_submit('account_deletion','rider@example.test','rider@example.test','','',repeat('c',64),repeat('0',64));
select throws_ok($$select public.support_request_submit('account_deletion','rider@example.test','rider@example.test','','',repeat('d',64),repeat('0',64))$$,
  'P0001','support.rate_limited','three a day per email');
select public.support_request_submit('account_deletion','n'||g||'@example.test','n'||g||'@example.test','','',repeat('e',64),repeat('0',64)) from generate_series(1,5) g;
select throws_ok($$select public.support_request_submit('account_deletion','other@example.test','other@example.test','','',repeat('e',64),repeat('0',64))$$,
  'P0001','support.rate_limited','five a day per network');
reset role;
update private.support_requests set created_at=created_at-interval '1 day' where ip_hash=repeat('e',64);
set local role service_role;
select lives_ok($$select public.support_request_submit('account_deletion','other@example.test','other@example.test','','',repeat('e',64),repeat('0',64))$$,
  'the limit restarts the next Taiwan day');
select public.support_request_notified((select id from sent));
reset role;
select ok((select notified_at is not null from private.support_requests where id=(select id from sent)),'notification recorded');

-- ===== 管理站 =====
set local role authenticated;
select pg_temp.act('user');
select throws_ok($$select admin_v1.support_requests()$$,'PT403','auth.aal2_required','riders cannot list');
select throws_ok(format('select admin_v1.resolve_support_request(%L,''done'')',(select id from sent)),'PT403','auth.aal2_required','riders cannot resolve');
select pg_temp.act('admin');
-- 這裡的 email 都對不到帳號：系統記成例外（#285；對帳號與確認連結見
-- support_deletion_verify_test.sql）。
select is((select jsonb_array_length(admin_v1.support_requests())),0,'none waits for confirmation');
select is((select jsonb_array_length(admin_v1.support_requests('exception',p_limit=>200))),9,'lists the exceptions');
reset role;
update private.support_requests set created_at=now()+interval '1 minute' where id=(select id from sent);
set local role authenticated;
select is((select admin_v1.support_requests('all',p_limit=>1)->0->>'contact_email'),'rider@example.test','newest first, with the email to reply to');
select is((select admin_v1.support_requests('all',p_limit=>1)->0->>'exception'),'no_account','with the reason');
select throws_ok($$select admin_v1.support_requests('weird')$$,'PT400','request.invalid','unknown status');
select throws_ok($$select admin_v1.support_requests(null)$$,'PT400','request.invalid','null is not a status');
select is((select jsonb_array_length(admin_v1.support_requests('all',p_limit=>200))),9,'all lists every status');
select ok(not exists(select 1 from pg_proc where proname='request_account_deletion_for'),'administrators no longer ask for deletion');

-- 結案：只對待確認的申請。
select throws_ok(format('select admin_v1.resolve_support_request(%L,''done'')',(select id from sent)),
  'PT409','support.already_resolved','an exception is already closed');
reset role;
update private.support_requests set status='open',exception=null,resolved_at=null where id=(select id from sent);
set local role authenticated;
select pg_temp.act('admin');
select is((select admin_v1.resolve_support_request((select id from sent),'done','已回覆')->>'status'),'done','resolved');
select throws_ok(format('select admin_v1.resolve_support_request(%L,''rejected'')',(select id from sent)),
  'PT409','support.already_resolved','resolved once');
select throws_ok(format('select admin_v1.resolve_support_request(%L,''open'')',(select id from sent)),'PT400','request.invalid','only done or rejected');
select throws_ok($$select admin_v1.resolve_support_request(gen_random_uuid(),'done')$$,'PT404','support.not_found','unknown request');
reset role;
select is((select after->>'status' from admin_audit_log where action='resolve_support_request' order by id desc limit 1),'done','resolution audited');

-- ===== 保留期 =====
update private.support_requests set resolved_at=now()-interval '181 days',created_at=now()-interval '200 days' where id=(select id from sent);
select is(public.support_requests_prune(),1,'resolved requests go after 180 days');
select is((select count(*)::int from private.support_requests)>0,true,'recent requests stay');
-- 202611012100 起由 account-data-retention 每日呼叫（#267）。
select ok(not exists(select 1 from cron.job where jobname='support-requests-prune'),'no separate job any more');
select ok((select command from cron.job where jobname='account-data-retention')='select public.account_data_retention()'
  and position('support_requests_prune()' in pg_get_functiondef('public.account_data_retention()'::regprocedure))>0,
  'pruned daily by the retention job');

select * from finish();
rollback;
