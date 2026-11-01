-- 客服案件系統（#295；202611020100_support_cases.sql）。
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
create function pg_temp.h(token text) returns text language sql as $$
  select encode(sha256(convert_to(token,'UTF8')),'hex');
$$;

-- ===== 權限 =====
select ok(not has_table_privilege('service_role','private.support_messages','select'),'only the functions touch the messages');
select ok(not has_table_privilege('service_role','private.support_case_tokens','select'),'and the tokens');
select ok(has_function_privilege('service_role','public.support_case_link(uuid,text,text,text)','execute'),'the Edge Function opens case links');
select ok(not has_function_privilege('authenticated','public.support_case_link(uuid,text,text,text)','execute'),'riders cannot directly');
select ok(not has_function_privilege('anon','public.support_case_link(uuid,text,text,text)','execute'),'nor anon');
select ok(has_function_privilege('service_role','public.support_outbound_claim(int)','execute'),'the mailer claims replies');
select ok(not has_function_privilege('authenticated','public.support_outbound_claim(int)','execute'),'riders cannot');
select ok(not has_function_privilege('authenticated','public.support_outbound_tokens(uuid,text,text)','execute'),'nor store tokens');
select ok(not has_function_privilege('authenticated','public.support_outbound_result(uuid,boolean,text,text)','execute'),'nor results');
select ok(not has_function_privilege('service_role','private.support_add_inbound(uuid,text,text,text,text,text,boolean,text[])','execute'),'adding a message is internal');
select ok(not has_function_privilege('anon','admin_v1.reply_support_request(uuid,text)','execute'),'anon cannot reply');
select ok(has_function_privilege('authenticated','admin_v1.support_request(uuid)','execute'),'admins call the detail through PostgREST');

-- ===== 回覆期限：5 個工作天，依 public.holidays =====
-- 2026-11-02（一）送出：11/03–11/06 是 4 個工作天，11/09（一）第 5 個。
select is(private.support_due_at('2026-11-02 10:00+08'),'2026-11-10 00:00+08'::timestamptz,'five workdays, weekends off');
-- 11/04（三）放假、11/07（六）補班。
insert into public.holidays(date,is_off,note) values('2026-11-04',true,'測試假日')
  on conflict(date) do update set is_off=excluded.is_off,note=excluded.note;
select is(private.support_due_at('2026-11-02 10:00+08'),'2026-11-11 00:00+08'::timestamptz,'a holiday is off');
insert into public.holidays(date,is_off,note) values('2026-11-07',false,'補班')
  on conflict(date) do update set is_off=excluded.is_off,note=excluded.note;
select is(private.support_due_at('2026-11-02 10:00+08'),'2026-11-10 00:00+08'::timestamptz,'a make-up Saturday is a workday');
select is(private.support_due_at('2026-11-01 23:30+08'),private.support_due_at('2026-11-01 15:40Z'),'counted in Taiwan time');

-- ===== 送出：一般案件 =====
create temporary table sent(k text,r jsonb);
grant all on sent to public;
set local role service_role;
insert into sent values('g',public.support_request_submit('general',' Asker@Example.TEST ',null,'','停車點的費用不對',
  repeat('1',64),pg_temp.h('link-g'),'費用錯誤',null,pg_temp.h('reply-g')));
insert into sent values('d',public.support_request_submit('data_issue','owner@example.test','','','照片侵權',
  repeat('2',64),pg_temp.h('link-d'),'',null,pg_temp.h('reply-d')));
select throws_ok($$select public.support_request_submit('general','a@b.test','a@b.test','','x',repeat('3',64),repeat('0',64),'',null,repeat('1',64))$$,
  '22023','request.invalid','a general question has no login email');
select throws_ok($$select public.support_request_submit('general','a@b.test',null,'','x',repeat('3',64),repeat('0',64))$$,
  '22023','request.invalid','a general question needs a reply token');
select throws_ok($$select public.support_request_submit('privacy','a@b.test','fixture1@example.test','','x',repeat('3',64),repeat('0',64))$$,
  '22023','request.invalid','a privacy request names the right');
select throws_ok($$select public.support_request_submit('general','a@b.test',null,'','x',repeat('3',64),repeat('0',64),'','access',repeat('1',64))$$,
  '22023','request.invalid','only a privacy request names a right');
select throws_ok($$select public.support_request_submit('general','a@b.test',null,'',repeat('長',4001),repeat('3',64),repeat('0',64),'',null,repeat('1',64))$$,
  '22023','request.invalid','4000 characters at most');
select throws_ok($$select public.support_request_submit('complaint','a@b.test',null,'','x',repeat('3',64),pg_temp.h('link-g'),'',null,repeat('1',64))$$,
  '22023','request.invalid','a token hash is never reused');
reset role;
create function pg_temp.id(k text) returns uuid language sql as $$ select (r->>'id')::uuid from sent where sent.k=$1 $$;
select is((select r->>'mail' from sent where k='g'),'case','a general question gets a receipt with the case link');
select is((select kind||'|'||source||'|'||contact_email||'|'||subject||'|'||status from private.support_requests where id=pg_temp.id('g')),
  'general|web|asker@example.test|費用錯誤|open','stored open, from the form');
select is((select array_agg(kind order by kind) from private.support_case_tokens where request_id=pg_temp.id('g')),
  array['link','reply'],'a link and a reply token, hashed');
select ok((select expires_at between now()+interval '29 days' and now()+interval '31 days' from private.support_case_tokens
  where request_id=pg_temp.id('g') and kind='link'),'the link lasts 30 days');

-- ===== 送出：個資權利請求（比照 #285）=====
set local role service_role;
insert into sent values('p',public.support_request_submit('privacy','contact@example.test',' Fixture1@Example.TEST ','','請給我資料複本',
  repeat('4',64),pg_temp.h('tok-p'),'','copy',null));
insert into sent values('pnone',public.support_request_submit('privacy','contact@example.test','nobody@example.test','','查詢',
  repeat('5',64),pg_temp.h('tok-pnone'),'','access',null));
reset role;
select is((select r->>'mail' from sent where k='p'),'confirm','the login email gets the confirmation link');
select is((select r->>'mail' from sent where k='pnone'),null,'no account: only the receipt');
select is((select status||'|'||exception from private.support_requests where id=pg_temp.id('pnone')),'exception|no_account','recorded as an exception');
set local role service_role;
select is(public.support_request_link(pg_temp.id('p'),pg_temp.h('tok-p'),'view')->>'kind','privacy','the page knows the kind');
select is(public.support_request_link(pg_temp.id('p'),pg_temp.h('tok-p'),'view')->>'result','pending','opening changes nothing');
reset role;

-- ===== 管理站：列表與回覆權限 =====
set local role authenticated;
select pg_temp.act('user');
select throws_ok($$select admin_v1.support_request(gen_random_uuid())$$,'PT403','auth.aal2_required','riders cannot read a case');
select throws_ok($$select admin_v1.reply_support_request(gen_random_uuid(),'hi')$$,'PT403','auth.aal2_required','riders cannot reply');
select pg_temp.act('admin');
select throws_ok(format('select admin_v1.reply_support_request(%L,''稍等'')',pg_temp.id('p')),'PT409','support.reply_not_allowed',
  'a privacy request is answered only after the owner confirms');
select throws_ok($$select admin_v1.support_requests(p_kind=>'weird')$$,'PT400','request.invalid','unknown kind');
select throws_ok($$select admin_v1.support_request(gen_random_uuid())$$,'PT404','support.not_found','unknown case');
select is((select jsonb_array_length(admin_v1.support_requests('open',p_kind=>'general'))),1,'filter by kind');
select is((select x->>'reply_to'||'|'||(x->>'can_reply')||'|'||(x->>'awaiting_admin')||'|'||(x->>'source')
  from jsonb_array_elements(admin_v1.support_requests('open',p_kind=>'general')) x),
  'asker@example.test|true|true|web','replies go to the contact email; it waits for an answer');
select is((select x->>'can_reply' from jsonb_array_elements(admin_v1.support_requests('open',p_kind=>'privacy')) x),'false','not yet');
select ok((select (x->>'due_at')::timestamptz>now() from jsonb_array_elements(admin_v1.support_requests('open',p_kind=>'general')) x),'with a due time');
select is((select admin_v1.support_request(pg_temp.id('g'))->'messages'->0->>'body'),'停車點的費用不對','the original is the first message');
select is((select admin_v1.support_request(pg_temp.id('g'))->'messages'->0->>'channel'),'web','from the form');
reset role;

-- 刪除帳號不回覆（聯絡 email 只收固定回條）。
set local role service_role;
insert into sent values('del',public.support_request_submit('account_deletion','c2@example.test','fixture2@example.test','','',
  repeat('6',64),pg_temp.h('tok-del')));
reset role;
set local role authenticated;
select pg_temp.act('admin');
select throws_ok(format('select admin_v1.reply_support_request(%L,''hi'')',pg_temp.id('del')),'PT409','support.reply_not_allowed',
  'an account deletion is never answered by mail');
select throws_ok(format('select admin_v1.reply_support_request(%L,'' '')',pg_temp.id('g')),'PT400','request.invalid','an empty reply');

-- 回覆：排入寄送，寫稽核。
create temporary table replies(r jsonb);
insert into replies values(admin_v1.reply_support_request(pg_temp.id('g'),'  已更正，謝謝  '));
select is((select r->>'body'||'|'||(r->>'delivery_status')||'|'||(r->>'to_email')||'|'||(r->>'direction') from replies),
  '已更正，謝謝|queued|asker@example.test|out','stored and queued to the case email');
select is((select x->>'awaiting_admin' from jsonb_array_elements(admin_v1.support_requests('open',p_kind=>'general')) x),'false','answered');
select is((select jsonb_array_length(admin_v1.support_requests('open',p_kind=>'general',p_awaiting_admin=>true))),0,'the answered one leaves the queue');
select is((select admin_v1.support_requests('open',p_awaiting_admin=>true)->0->>'id'),pg_temp.id('d')::text,'the unanswered one stays');
reset role;
select is((select action||'|'||target_id||'|'||(after->>'message_id') from public.admin_audit_log where action='reply_support_request'),
  'reply_support_request|'||pg_temp.id('g')||'|'||(select r->>'id' from replies),'audited without the text or email');

-- ===== 寄送 =====
set local role service_role;
create temporary table claimed as select * from public.support_outbound_claim(10);
reset role;
select is((select count(*)::int from claimed),1,'the mailer claims the reply');
select is((select to_email||'|'||kind||'|'||subject from claimed),'asker@example.test|general|費用錯誤','with what the mail needs');
set local role service_role;
select is((select count(*)::int from public.support_outbound_claim(10)),0,'claimed once');
select ok(public.support_outbound_tokens((select id from claimed),pg_temp.h('link-r1'),pg_temp.h('reply-r1')),'tokens stored');
select public.support_outbound_result((select id from claimed),false,null,'resend 500');
reset role;
select is((select delivery_status||'|'||attempts||'|'||send_error from private.support_messages where id=(select id from claimed)),
  'failed|1|resend 500','a failure is kept');
select is((select count(*)::int from private.support_case_tokens where message_id=(select id from claimed)),0,'its tokens are dropped');
update private.support_messages set claimed_at=now()-interval '16 minutes' where id=(select id from claimed);
set local role service_role;
select is((select count(*)::int from public.support_outbound_claim(10)),1,'retried after 15 minutes');
select ok(not public.support_outbound_tokens(gen_random_uuid(),pg_temp.h('x1'),pg_temp.h('x2')),'only for a claimed message');
select ok(public.support_outbound_tokens((select id from claimed),pg_temp.h('link-r2'),pg_temp.h('reply-r2')),'new tokens');
select public.support_outbound_result((select id from claimed),true,'re_123',null);
reset role;
select is((select delivery_status||'|'||attempts||'|'||resend_id from private.support_messages where id=(select id from claimed)),
  'sent|2|re_123','sent, with the Resend id');
select is((select count(*)::int from private.support_case_tokens where message_id=(select id from claimed)),2,'its link and reply token');

-- ===== 案件連結 =====
set local role service_role;
create function pg_temp.link(k text,token text,action text,body text default null) returns jsonb language sql as $$
  select public.support_case_link(pg_temp.id(k),pg_temp.h(token),action,body) $$;
select is(pg_temp.link('g','wrong','view'),'{"result":"invalid"}','a wrong token');
select is(pg_temp.link('d','link-g','view'),'{"result":"invalid"}','a token only opens its case');
select is(pg_temp.link('g','reply-g','view'),'{"result":"invalid"}','a reply token is not a link');
select is(public.support_case_link(pg_temp.id('g'),'nothex','view'),'{"result":"invalid"}','a malformed hash');
select throws_ok(format('select public.support_case_link(%L,%L,''reply'','''')',pg_temp.id('g'),pg_temp.h('link-g')),
  '22023','request.invalid','an empty supplement');
select is((select r->>'result'||'|'||(r->>'can_reply')||'|'||jsonb_array_length(r->'messages')
  from (select pg_temp.link('g','link-r2','view') r) x),'ok|true|2','the reply mail''s link shows the thread');
select is(pg_temp.link('g','link-g','view')->'messages'->1->>'body','已更正，謝謝','with the answer');
select is(pg_temp.link('g','link-g','reply','還有一個問題')->>'result','received','a supplement');
reset role;
select is((select channel||'|'||direction from private.support_messages where request_id=pg_temp.id('g') order by created_at desc limit 1),
  'case_link|in','stored as the rider''s');
set local role authenticated;
select pg_temp.act('admin');
select is((select x->>'awaiting_admin' from jsonb_array_elements(admin_v1.support_requests('open',p_kind=>'general')) x),'true','waits for an answer again');
reset role;
set local role service_role;
select pg_temp.link('g','link-g','reply','補充 '||n) from generate_series(2,5) n;
select is(pg_temp.link('g','link-g','reply','第 6 次')->>'result','rate_limited','five supplements per link');
select is(pg_temp.link('g','link-g','view')->>'can_reply','false','the page says so');
select pg_temp.link('g','link-r2','reply','補充 '||n) from generate_series(6,10) n;
select is(pg_temp.link('g','link-r2','reply','第 11 則')->>'result','rate_limited','ten a day per case');
reset role;
update private.support_case_tokens set expires_at=now()-interval '1 second' where token_hash=decode(pg_temp.h('link-d'),'hex');
set local role service_role;
select is(pg_temp.link('d','link-d','view'),'{"result":"invalid"}','an expired link');
reset role;

-- ===== 結案與重新開啟 =====
set local role authenticated;
select pg_temp.act('admin');
select admin_v1.resolve_support_request(pg_temp.id('g'),'done','');
select throws_ok(format('select admin_v1.reply_support_request(%L,''再補一句'')',pg_temp.id('g')),'PT409','support.already_resolved',
  'a closed case cannot be answered');
reset role;
delete from private.support_messages where request_id=pg_temp.id('g') and direction='in' and created_at>=public.report_day_start();
update private.support_case_tokens set uses=0 where token_hash=decode(pg_temp.h('link-r2'),'hex');
update private.support_requests set created_at=now()-interval '20 days' where id=pg_temp.id('g');
set local role service_role;
select is(pg_temp.link('g','link-r2','reply','結案後的補充')->>'reopened','true','within 30 days a supplement reopens it');
reset role;
select is((select status||'|'||(resolved_at is null)||'|'||(reopened_at is not null) from private.support_requests where id=pg_temp.id('g')),
  'open|true|true','open again');
set local role authenticated;
select pg_temp.act('admin');
select ok((select (x->>'due_at')::timestamptz>now()
  from jsonb_array_elements(admin_v1.support_requests('open',p_kind=>'general')) x),'the due time restarts');
select admin_v1.resolve_support_request(pg_temp.id('g'),'done','');
reset role;
update private.support_requests set resolved_at=now()-interval '31 days' where id=pg_temp.id('g');
set local role service_role;
select is(pg_temp.link('g','link-r2','reply','很久以後')->>'result','closed','closed for over 30 days: not reopened');
select is(pg_temp.link('g','link-r2','view')->>'can_reply','false','the page says so');
reset role;

-- ===== 個資權利請求：確認後回覆到登入 email =====
set local role service_role;
select is(public.support_request_link(pg_temp.id('p'),pg_temp.h('tok-p'),'confirm')->>'result','verified','the owner confirms');
select is(public.support_request_link(pg_temp.id('p'),pg_temp.h('tok-p'),'view'),'{"result":"invalid"}','once only');
reset role;
select is((select status||'|'||(confirmed_at is not null) from private.support_requests where id=pg_temp.id('p')),'open|true','still open for the answer');
set local role authenticated;
select pg_temp.act('admin');
select is((select admin_v1.reply_support_request(pg_temp.id('p'),'附件請見下載說明')->>'to_email'),'fixture1@example.test',
  'the answer goes only to the login email');
reset role;

-- ===== 狀態信的取消刪除連結（App 來源的申請）=====
insert into private.account_deletion_requests(user_id,source,scheduled_at)
  values('10000000-0000-4000-8000-000000000006','app',now()+interval '5 days');
set local role service_role;
insert into sent values('st',public.support_request_submit('account_deletion','c3@example.test','fixture5@example.test','','',
  repeat('7',64),pg_temp.h('tok-st')));
reset role;
select is((select r->>'mail' from sent where k='st'),'status','the owner hears the deletion is pending');
select ok((select cancel_expires_at=(select scheduled_at from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000006')
  and status_request_id is not null from private.support_requests where id=pg_temp.id('st')),'with a cancel link until the deletion time');
set local role service_role;
select is(public.support_cancel_link(pg_temp.id('st'),pg_temp.h('wrong'),'view'),'{"result":"invalid"}','a wrong token');
select is(public.support_cancel_link(pg_temp.id('st'),pg_temp.h('tok-st'),'view')->>'result','pending','opening shows the deletion time');
select is(public.support_request_link(pg_temp.id('st'),pg_temp.h('tok-st'),'confirm'),'{"result":"invalid"}','it is no confirmation link');
select is(public.support_cancel_link(pg_temp.id('st'),pg_temp.h('tok-st'),'cancel')->>'result','cancelled','an App request is cancelled by it');
select is(public.support_cancel_link(pg_temp.id('st'),pg_temp.h('tok-st'),'cancel'),'{"result":"invalid"}','once only');
reset role;
select ok(not exists(select 1 from private.account_deletion_requests where user_id='10000000-0000-4000-8000-000000000006'),'the deletion is gone');

-- ===== 保存期 =====
select is(public.support_requests_prune(),0,'nothing is 180 days old yet');
select ok(exists(select 1 from private.support_requests where id=pg_temp.id('g')),'a case closed 31 days ago stays');
select ok(not exists(select 1 from private.support_case_tokens where token_hash=decode(pg_temp.h('link-d'),'hex')),'expired links are dropped');
update private.support_requests set resolved_at=now()-interval '181 days' where id=pg_temp.id('g');
select is(public.support_requests_prune(),1,'180 days after it ended');
select ok(not exists(select 1 from private.support_requests where id=pg_temp.id('g')),'the case is deleted');
select is((select count(*)::int from private.support_messages where request_id=pg_temp.id('g')),0,'with its messages');
select is((select count(*)::int from private.support_case_tokens where request_id=pg_temp.id('g')),0,'and its tokens');

select * from finish();
rollback;
