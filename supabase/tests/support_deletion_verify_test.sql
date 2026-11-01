-- 客服表單刪除帳號的身分確認（#285；202611012200_support_deletion_verify.sql）。
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
-- Edge Function 傳來的雜湊：token 的 SHA-256 十六進位。
create function pg_temp.h(token text) returns text language sql as $$
  select encode(sha256(convert_to(token,'UTF8')),'hex');
$$;
create function pg_temp.u(suffix text) returns uuid language sql as $$
  select ('10000000-0000-4000-8000-'||suffix)::uuid $$;

-- ===== 權限 =====
select ok(has_function_privilege('service_role','public.support_request_link(uuid,text,text)','execute'),'the Edge Function opens links');
select ok(not has_function_privilege('anon','public.support_request_link(uuid,text,text)','execute'),'anon cannot open links directly');
select ok(not has_function_privilege('authenticated','public.support_request_link(uuid,text,text)','execute'),'riders cannot open links directly');
select ok(not has_function_privilege('authenticated','public.support_deletion_notices(int)','execute'),'riders cannot read notices');
select ok(has_function_privilege('service_role','public.support_deletion_notices(int)','execute'),'the mailer reads notices');
select ok(not has_function_privilege('authenticated','public.support_deletion_notified(uuid)','execute'),'riders cannot mark notices');
select ok(not has_function_privilege('authenticated','public.support_mail_tick()','execute'),'riders cannot call the mailer');
select ok(not has_function_privilege('service_role','private.support_login_account(text)','execute'),'the matcher is internal');
select ok(exists(select 1 from cron.job where jobname='support-mail' and command='select public.support_mail_tick()'),'unsent notices retried on a schedule');
select ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='admin_v1' and p.proname='request_account_deletion_for'),'administrators no longer ask for deletion');

-- 帳號 3 的 Apple 隱藏的電子郵件；帳號 7 的身分用帳號 6 的 email（對到兩個帳號）。
insert into auth.identities(provider_id,user_id,identity_data,provider,created_at,updated_at)
  values('apple-003','10000000-0000-4000-8000-000000000003','{"email":"Abc123@PrivateRelay.AppleID.com"}','apple',now(),now()),
        ('google-dup','10000000-0000-4000-8000-000000000007','{"email":"Fixture5@example.test"}','google',now(),now());
insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data)
  select pg_temp.u('0000000000a'||n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'extra'||n||'@example.test',now()-interval '30 days',now(),false,'{"provider":"google","role":"user"}','{}'
  from generate_series(1,8) n;
-- 送出前就已在冷靜期（帳號 1）、正在刪除（帳號 7）。
insert into private.account_deletion_requests(user_id,source,scheduled_at)
  values('10000000-0000-4000-8000-000000000001','app',now()+interval '5 days');
insert into private.account_deletion_requests(user_id,source,requested_at,scheduled_at,claimed_at)
  values('10000000-0000-4000-8000-000000000007','app',now()-interval '8 days',now()-interval '1 day',now());
-- 帳號 2 有一個連線，確認後要登出。
insert into auth.sessions(id,user_id,created_at,updated_at) values(gen_random_uuid(),'10000000-0000-4000-8000-000000000002',now(),now());

-- ===== 送出：只認登入 email =====
create temporary table sent(k text,r jsonb);
grant all on sent to public;
create function pg_temp.submit(k text,login text,contact text default null) returns void language sql as $$
  insert into sent values(k,public.support_request_submit('account_deletion',coalesce(contact,k||'@contact.test'),login,'','',
    pg_temp.h('ip-'||k),pg_temp.h('tok-'||k)));
$$;
set local role service_role;
select pg_temp.submit('login',' Fixture1@Example.TEST ','attacker@evil.test');
select pg_temp.submit('relay','abc123@privaterelay.appleid.com');
select pg_temp.submit('none','nobody@example.test','attacker@evil.test');
select pg_temp.submit('twice','fixture5@example.test');
select pg_temp.submit('admin','fixture4@example.test');
select pg_temp.submit('pend','fixture0@example.test');
select pg_temp.submit('progress','fixture6@example.test');
select pg_temp.submit('gone','extra1@example.test');
select pg_temp.submit('again1','extra2@example.test');
select pg_temp.submit('adminlater','extra3@example.test');
select pg_temp.submit('denied','extra4@example.test');
select pg_temp.submit('later','extra5@example.test');
select pg_temp.submit('expired','extra6@example.test');
select pg_temp.submit('resolved','extra7@example.test');
select throws_ok($$select public.support_request_submit('account_deletion','a@b.test','x@example.test','','',repeat('a',64),'short')$$,
  '22023','request.invalid','a token hash is required');
select throws_ok($$select public.support_request_submit('account_deletion','a@b.test','','','',repeat('a',64),repeat('0',64))$$,
  '22023','request.invalid','a login email is required');
reset role;
create function pg_temp.id(k text) returns uuid language sql as $$ select (r->>'id')::uuid from sent where sent.k=$1 $$;
create function pg_temp.row(k text) returns private.support_requests language sql as $$
  select s from private.support_requests s where s.id=pg_temp.id($1) $$;
create function pg_temp.mail(k text) returns text language sql as $$ select coalesce(r->>'mail','-') from sent where sent.k=$1 $$;

select is(pg_temp.mail('login'),'confirm','the login email (any case) gets the link');
select is((pg_temp.row('login')).matched_user,'10000000-0000-4000-8000-000000000002'::uuid,'matched to that account');
select is((pg_temp.row('login')).login_email||'|'||(pg_temp.row('login')).contact_email,'fixture1@example.test|attacker@evil.test',
  'login and contact emails kept apart');
select is((pg_temp.row('login')).confirm_token_hash,decode(pg_temp.h('tok-login'),'hex'),'only the hash is stored');
select ok((pg_temp.row('login')).confirm_expires_at between now()+interval '23 hours 59 minutes' and now()+interval '24 hours','valid for 24 hours');
select is((pg_temp.row('login')).status,'open','waiting for the owner');
select is((pg_temp.row('relay')).matched_user,'10000000-0000-4000-8000-000000000003'::uuid,'an identity email (Apple hidden email) matches');
select is((select string_agg(k||':'||(pg_temp.row(k)).status||':'||coalesce((pg_temp.row(k)).exception,'-')||':'||pg_temp.mail(k),',' order by k)
    from unnest(array['admin','none','pend','progress','twice']) k),
  'admin:exception:admin_account:-,none:exception:no_account:-,pend:exception:deletion_pending:status,'
  ||'progress:exception:deletion_in_progress:-,twice:exception:no_account:-',
  'exceptions are recorded, no link; only the owner of an account in the cooling-off period hears its state');
select ok((select r->>'scheduled_at' is not null from sent where k='pend'),'the state mail has the deletion time');
select ok((select bool_and(confirm_token_hash is null) from private.support_requests where status='exception'),'no token for an exception');
select is((select count(distinct (select array_agg(x order by x) from jsonb_object_keys(r) x))::int from sent),1,
  'the same answer shape for every case');
select is((select count(*)::int from private.account_deletion_requests),2,'sending creates no deletion');

-- ===== 確認連結：打開不改狀態 =====
create function pg_temp.link(k text,token text,action text) returns jsonb language sql as $$
  select public.support_request_link(pg_temp.id(k),pg_temp.h(token),action) $$;
set local role service_role;
select is(pg_temp.link('login','wrong','view'),'{"result":"invalid"}','a wrong token is refused');
select is(public.support_request_link(gen_random_uuid(),pg_temp.h('tok-login'),'view'),'{"result":"invalid"}','an unknown request is refused');
select is(pg_temp.link('none','tok-none','confirm'),'{"result":"invalid"}','an exception has no token');
select is(public.support_request_link(pg_temp.id('login'),'nothex','confirm'),'{"result":"invalid"}','a malformed hash is refused');
select is(pg_temp.link('relay','tok-login','confirm'),'{"result":"invalid"}','a token only works for its request');
select throws_ok(format('select public.support_request_link(%L,%L,''delete'')',pg_temp.id('login'),pg_temp.h('tok-login')),
  '22023','request.invalid','unknown action');
select is((select r->>'result'||'|'||(r->>'contact_email') from (select pg_temp.link('login','tok-login','view') r) x),
  'pending|attacker@evil.test','opening the link shows the request');
select is(pg_temp.link('login','tok-login','view')->>'result','pending','as often as a mail scanner likes');
reset role;
select ok((pg_temp.row('login')).confirmed_at is null and (pg_temp.row('login')).confirm_token_hash is not null
  and not exists(select 1 from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000002'),
  'viewing and failed attempts change nothing');

-- 「是我」：系統直接建立刪除申請，與 App 相同。
create temporary table confirmed(k text,r jsonb);
grant all on confirmed to public;
set local role service_role;
insert into confirmed values('login',pg_temp.link('login','tok-login','confirm'));
select is((select r->>'result' from confirmed),'deletion_requested','the button asks for the deletion');
select is(pg_temp.link('login','tok-login','confirm'),'{"result":"invalid"}','once only');
select is(pg_temp.link('login','tok-login','view'),'{"result":"invalid"}','then the link is gone');
reset role;
select is((select source||'|'||(scheduled_at-requested_at)::text from private.account_deletion_requests
  where user_id='10000000-0000-4000-8000-000000000002'),'support|7 days','from support, with the 7-day cooling-off period');
select is((select scheduled_at from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000002'),
  (select (r->>'scheduled_at')::timestamptz from confirmed),'the page is told when');
select is((select count(*)::int from auth.sessions where user_id='10000000-0000-4000-8000-000000000002'),0,'signed out everywhere');
select is((select count(*)::int from private.account_deletion_audit a join private.account_deletion_requests r using(request_id)
  where r.user_id='10000000-0000-4000-8000-000000000002' and a.event='requested' and a.source='support'),1,'audited');
select ok((pg_temp.row('login')).status='done' and (pg_temp.row('login')).confirmed_at is not null
  and (pg_temp.row('login')).deletion_request_id is not null and (pg_temp.row('login')).confirm_token_hash is null,
  'the request is done and linked');

update private.support_requests set confirm_expires_at=now()-interval '1 second' where id=pg_temp.id('expired');
-- 送出後才進入冷靜期、刪除、變成管理員：確認時記成例外，不建立申請。
insert into private.account_deletion_requests(user_id,source,scheduled_at) values(pg_temp.u('0000000000a5'),'app',now()+interval '6 days');
update auth.users set deleted_at=now() where id=pg_temp.u('0000000000a1');
update auth.users set raw_app_meta_data='{"provider":"google","role":"admin"}' where id=pg_temp.u('0000000000a3');
set local role service_role;
select is(pg_temp.link('expired','tok-expired','confirm'),'{"result":"invalid"}','an expired token is refused');
select is(pg_temp.link('later','tok-later','view')->>'result','account_deletion_pending','opening shows the cooling-off period');
select ok((pg_temp.link('later','tok-later','confirm')->>'scheduled_at') is not null,'confirming then tells when');
select is(pg_temp.link('gone','tok-gone','confirm')->>'result','account_deleting','a deleted account');
select is(pg_temp.link('adminlater','tok-adminlater','confirm')->>'result','unavailable','an admin account');
select is(pg_temp.link('denied','tok-denied','deny')->>'result','denied','"not me" voids the request');
select is(pg_temp.link('denied','tok-denied','view'),'{"result":"invalid"}','and its link');
select is(pg_temp.link('relay','tok-relay','confirm')->>'result','deletion_requested','an Apple account is deleted all the same');
reset role;
select is((select string_agg(k||':'||(pg_temp.row(k)).status||':'||coalesce((pg_temp.row(k)).exception,'-'),',' order by k)
    from unnest(array['adminlater','denied','expired','gone','later']) k),
  'adminlater:exception:admin_account,denied:voided:-,expired:open:-,gone:exception:account_deleted,later:exception:deletion_pending',
  'each outcome recorded');
select ok(not exists(select 1 from private.account_deletion_requests where user_id in
  (pg_temp.u('0000000000a3'),pg_temp.u('0000000000a4'),pg_temp.u('0000000000a6'))),'no deletion for them');
select is((select source from private.account_deletion_requests where user_id=pg_temp.u('0000000000a5')),'app','the earlier request stays');

-- 客服結案一筆還沒確認的申請：連結顯示已結案。
set local role authenticated;
select pg_temp.act('admin');
select is(admin_v1.resolve_support_request(pg_temp.id('resolved'),'rejected','重複申請')->>'status','rejected','resolved by support');
reset role;
set local role service_role;
select is(pg_temp.link('resolved','tok-resolved','confirm')->>'result','resolved','a resolved request cannot be confirmed');
reset role;
select ok(not exists(select 1 from private.account_deletion_requests where user_id=pg_temp.u('0000000000a7')),'and creates nothing');

-- 重送：舊連結作廢，算進每個登入 email 每日 3 筆。
set local role service_role;
select pg_temp.submit('again2','EXTRA2@example.test');
select is(pg_temp.link('again1','tok-again1','view'),'{"result":"invalid"}','sending again voids the old link');
select is(pg_temp.link('again2','tok-again2','view')->>'result','pending','the new one works');
select pg_temp.submit('again3','extra2@example.test');
select throws_ok(format('select public.support_request_submit(''account_deletion'',''z@contact.test'',''extra2@example.test'','''','''',%L,%L)',
  pg_temp.h('ip-again4'),pg_temp.h('tok-again4')),'P0001','support.rate_limited','sending again counts toward three a day per login email');
reset role;
select is((select string_agg((pg_temp.row(k)).status,',' order by k) from unnest(array['again1','again2','again3']) k),
  'voided,voided,open','each newer one supersedes the last');
select ok((pg_temp.row('again1')).superseded_by=pg_temp.id('again2') and (pg_temp.row('again2')).superseded_by=pg_temp.id('again3')
  and (pg_temp.row('again1')).resolved_at is not null,'the event is recorded: which request replaced it, and when');

-- 聯絡 email：每日 3 筆之外，30 天內 10 筆。
do $$ begin
  for n in 1..10 loop
    perform pg_temp.submit('spam'||n,'nobody'||n||'@example.test','spam@contact.test');
    update private.support_requests set created_at=created_at-interval '1 day' where contact_email='spam@contact.test';
  end loop;
end $$;
select throws_ok(format('select public.support_request_submit(''account_deletion'',''spam@contact.test'',''nobody11@example.test'','''','''',%L,%L)',
  pg_temp.h('ip-spam11'),pg_temp.h('tok-spam11')),'P0001','support.rate_limited','ten receipts in 30 days per contact email');
update private.support_requests set created_at=created_at-interval '21 days' where contact_email='spam@contact.test';
select lives_ok(format('select public.support_request_submit(''account_deletion'',''spam@contact.test'',''nobody11@example.test'','''','''',%L,%L)',
  pg_temp.h('ip-spam11'),pg_temp.h('tok-spam11')),'after 30 days the count restarts');

-- ===== 管理站：唯讀紀錄與例外 =====
set local role authenticated;
select pg_temp.act('user');
select throws_ok($$select admin_v1.support_requests('exception')$$,'PT403','auth.aal2_required','riders cannot list');
select pg_temp.act('admin');
select is((select x->>'account_matched'||'|'||coalesce(x->>'matched_user','-')||'|'||(x->>'exception')||'|'||(x->>'login_email')
  from jsonb_array_elements(admin_v1.support_requests('all',200)) x where x->>'id'=pg_temp.id('none')::text),
  'false|-|no_account|nobody@example.test','an unmatched request, with the reason');
select ok((select x->>'matched_user'='10000000-0000-4000-8000-000000000002' and x->>'email_confirmed_at' is not null
    and x->>'deletion_requested'='true' and x->>'status'='done' and x->>'exception' is null
  from jsonb_array_elements(admin_v1.support_requests('done',200)) x where x->>'id'=pg_temp.id('login')::text),
  'a confirmed request and its deletion');
select is((select jsonb_array_length(admin_v1.support_requests('exception',200))),8+11,'the exceptions have their own list (8 above, 11 contact-limit ones)');
select is((select jsonb_array_length(admin_v1.support_requests('voided',200))),3,'and the voided ones');
reset role;

-- ===== 建立後的通知：只寄到登入 email =====
select is(public.support_mail_tick(),null,'without vault secrets the tick does nothing');
create temporary table notices as select * from public.support_deletion_notices(50);
select is((select string_agg(email||'|'||apple::text,',' order by email) from notices),
  'abc123@privaterelay.appleid.com|true,fixture1@example.test|false','to the login emails, never the contact email');
select ok((select n.scheduled_at=r.scheduled_at from notices n join private.account_deletion_requests r
  on r.user_id='10000000-0000-4000-8000-000000000002' where n.id=pg_temp.id('login')),'with the deletion time');
-- 寄出前存取消連結的雜湊，到預計刪除時間為止。
set local role service_role;
select is(public.support_cancel_token(pg_temp.id('login'),pg_temp.h('cancel-login')),true,'the cancel link is stored before sending');
select is(public.support_cancel_token(pg_temp.id('relay'),pg_temp.h('cancel-relay')),true,'for each notice');
select is(public.support_cancel_token(pg_temp.id('none'),pg_temp.h('cancel-none')),false,'not without a deletion');
reset role;
select is((pg_temp.row('login')).cancel_expires_at,(select scheduled_at from private.account_deletion_requests
  where user_id='10000000-0000-4000-8000-000000000002'),'valid through the cooling-off period');
set local role service_role;
select public.support_deletion_notified(pg_temp.id('login'));
select is(public.support_cancel_token(pg_temp.id('login'),pg_temp.h('other')),false,'not replaced once sent');
select is((select count(*)::int from public.support_deletion_notices(50)),1,'sent once');
reset role;
select ok((pg_temp.row('login')).deletion_notified_at is not null,'the send is recorded');
-- 冷靜期內取消後不再寄。
delete from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000003';
select is((select count(*)::int from public.support_deletion_notices(50)),0,'a cancelled deletion is not notified');

-- ===== 取消刪除連結 =====
create function pg_temp.cancel(k text,token text,action text) returns jsonb language sql as $$
  select public.support_cancel_link(pg_temp.id(k),pg_temp.h(token),action) $$;
set local role service_role;
select is(pg_temp.cancel('login','wrong','cancel'),'{"result":"invalid"}','a wrong token is refused');
select is(pg_temp.cancel('login','tok-login','cancel'),'{"result":"invalid"}','the confirmation token is not a cancel token');
select throws_ok(format('select public.support_cancel_link(%L,%L,''delete'')',pg_temp.id('login'),pg_temp.h('cancel-login')),
  '22023','request.invalid','unknown action');
select is(pg_temp.cancel('login','cancel-login','view')->>'result','pending','opening shows the cooling-off period');
select ok((pg_temp.cancel('login','cancel-login','view')->>'scheduled_at') is not null,'with the deletion time, and changes nothing');
reset role;
update private.account_deletion_requests set claimed_at=now() where user_id='10000000-0000-4000-8000-000000000002';
set local role service_role;
select is(pg_temp.cancel('login','cancel-login','cancel')->>'result','account_deleting','too late once the deletion runs');
reset role;
update private.account_deletion_requests set claimed_at=null where user_id='10000000-0000-4000-8000-000000000002';
update private.support_requests set cancel_expires_at=now()-interval '1 second' where id=pg_temp.id('login');
set local role service_role;
select is(pg_temp.cancel('login','cancel-login','cancel'),'{"result":"invalid"}','an expired cancel link is refused');
reset role;
update private.support_requests set cancel_expires_at=now()+interval '1 day' where id=pg_temp.id('login');
select ok(exists(select 1 from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000002'),
  'nothing cancelled yet');
set local role service_role;
select is(pg_temp.cancel('login','cancel-login','cancel')->>'result','cancelled','the button cancels');
select is(pg_temp.cancel('login','cancel-login','cancel'),'{"result":"invalid"}','once only');
select is(pg_temp.cancel('relay','cancel-relay','view')->>'result','not_pending','a deletion already cancelled in the App');
select is(pg_temp.cancel('relay','cancel-relay','view'),'{"result":"invalid"}','then that link is gone');
reset role;
select ok(not exists(select 1 from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000002'),
  'the deletion is cancelled');
select is((select string_agg(a.event||':'||a.source,',' order by a.id) from private.account_deletion_audit a
  where a.request_id=(pg_temp.row('login')).deletion_request_id),'requested:support,cancelled:support_link','audited as support_link');
select ok((pg_temp.row('login')).cancelled_at is not null and (pg_temp.row('login')).cancel_token_hash is null,'recorded on the request');

-- ===== 保留期：每種終止狀態都有結束時間，滿 180 天清除 =====
select is(public.support_requests_prune(),0,'nothing is old yet');
select is((pg_temp.row('expired')).status,'expired','the daily run marks an expired link');
select ok((pg_temp.row('expired')).resolved_at<now() and (pg_temp.row('expired')).confirm_token_hash is null,
  'ended when the link expired');
select is((select string_agg(distinct status,',' order by status) from private.support_requests where status<>'open'),
  'done,exception,expired,rejected,voided','every final state is here');
select ok(not exists(select 1 from private.support_requests where status<>'open' and resolved_at is null),
  'and each has an end time');
create temporary table ended as select id from private.support_requests where status<>'open';
update private.support_requests set resolved_at=resolved_at-interval '181 days' where id in (select id from ended);
select is(public.support_requests_prune(),(select count(*)::int from ended),'all of them go 180 days after they ended');
select ok((pg_temp.row('again3')).id is not null,'a request still waiting stays');

select * from finish();
rollback;
