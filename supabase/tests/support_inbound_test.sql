-- 收信進客服案件（#295 第 2 層；202611020200_support_inbound.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.h(token text) returns text language sql as $$
  select encode(sha256(convert_to(token,'UTF8')),'hex');
$$;
create temporary table got(k text,r jsonb);
grant all on got to public;
-- 一封信：k 當 Message-ID 與 token 的種子。
create function pg_temp.mail(k text,reply text,sender text,body text default '內容',spf text default 'pass',dkim text default 'pass',
  dmarc text default 'pass')
returns jsonb language sql as $$
  insert into got values(k,public.support_inbound(case when reply is null then null else pg_temp.h(reply) end,
    sender,'主旨 '||k,body,spf,dkim,array['a.pdf',''],pg_temp.h('msg-'||k),pg_temp.h('link-'||k),pg_temp.h('reply-'||k),dmarc))
  returning r;
$$;
create function pg_temp.id(k text) returns uuid language sql as $$ select (r->>'id')::uuid from got where got.k=$1 $$;

select ok(has_function_privilege('service_role','public.support_inbound(text,text,text,text,text,text,text[],text,text,text,text)','execute'),'the Edge Function files mail');
select ok(not has_function_privilege('authenticated','public.support_inbound(text,text,text,text,text,text,text[],text,text,text,text)','execute'),'riders cannot');
select ok(not has_function_privilege('anon','public.support_inbound(text,text,text,text,text,text,text[],text,text,text,text)','execute'),'nor anon');
select ok(not has_table_privilege('service_role','private.support_inbound_keys','select'),'the keys are internal');

set local role service_role;
-- ===== support@：新案件 =====
select is(pg_temp.mail('new',null,' Writer@Example.TEST ')->>'result','created','support@ opens a case');
reset role;
select is((select kind||'|'||source||'|'||contact_email||'|'||subject||'|'||message||'|'||suspicious||'|'||array_to_string(mail_attachments,',')
  from private.support_requests where id=pg_temp.id('new')),
  'general|email|writer@example.test|主旨 new|內容|false|a.pdf','a general question from email; attachments only by name');
select is((select count(*)::int from private.support_case_tokens where request_id=pg_temp.id('new')),2,'with a link and a reply token for the receipt');
set local role service_role;
select is(public.support_inbound(null,'writer@example.test','x','y','pass','pass','{}',pg_temp.h('msg-new'),pg_temp.h('l2'),pg_temp.h('r2')),
  '{"result":"duplicate"}','the same message once only');
select is(pg_temp.mail('spoof',null,'other@example.test','x','fail','none')->>'suspicious','true','SPF or DKIM not passing is suspicious');
select is(pg_temp.mail('soft',null,'other2@example.test','x','pass','fail')->>'suspicious','true','either one');
select is(pg_temp.mail('align',null,'other4@example.test','x','pass','pass','fail')->>'suspicious','true',
  'SPF and DKIM pass for another domain than From: DMARC fails');
select is(pg_temp.mail('empty',null,'other3@example.test','  ')->>'result','created','an empty text is kept');
reset role;
select is((select message from private.support_requests where id=pg_temp.id('empty')),'（沒有純文字內容）','marked');
set local role service_role;
select throws_ok($$select public.support_inbound(null,'not-an-email','s','b','pass','pass','{}',repeat('a',64),repeat('b',64),repeat('c',64))$$,
  '22023','request.invalid','a sender address is required');

-- ===== reply+<token>@：接回同一案件 =====
select is(pg_temp.mail('r1','reply-new','writer@example.test','補充')->>'result','appended','a reply lands on its case');
select is((select r->>'id' from got where k='r1'),pg_temp.id('new')::text,'the same case');
reset role;
select is((select channel||'|'||direction||'|'||from_email||'|'||body from private.support_messages where request_id=pg_temp.id('new')),
  'email|in|writer@example.test|補充','stored with the sender');
set local role service_role;
select is(pg_temp.mail('r2','reply-new','attacker@evil.test')->>'result','created','another sender opens a new case');
select is((select r->>'related_to' from got where k='r2'),null,'not linked to the case it tried');
select is(pg_temp.mail('r3','reply-unknown','writer@example.test')->>'result','created','an unknown token opens a new case');
reset role;

-- 結案後 30 天內：重新開啟；超過：新案件指向舊案。
update private.support_requests set status='done',resolved_at=now()-interval '3 days' where id=pg_temp.id('new');
set local role service_role;
select is(pg_temp.mail('r4','reply-new','writer@example.test')->>'reopened','true','reopened within 30 days');
reset role;
select is((select status from private.support_requests where id=pg_temp.id('new')),'open','open again');
update private.support_requests set status='done',resolved_at=now()-interval '31 days' where id=pg_temp.id('new');
set local role service_role;
select is(pg_temp.mail('r5','reply-new','Writer@Example.test')->>'result','created','after 30 days a new case');
select is((select r->>'related_to' from got where k='r5'),pg_temp.id('new')::text,'pointing to the old one');
reset role;

-- ===== 次數上限 =====
set local role service_role;
-- writer 今天已開 new、r3、r5 三筆：第四筆不登錄。
select is(pg_temp.mail('lim',null,'writer@example.test'),'{"result":"rate_limited"}','three a day per sender');
reset role;
select is((select count(*)::int from private.support_requests where contact_email='writer@example.test'),3,'nothing filed');
set local role service_role;
select pg_temp.mail('c'||n,'reply-r5','writer@example.test') from generate_series(1,10) n;
select is(pg_temp.mail('c11','reply-r5','writer@example.test'),'{"result":"rate_limited"}','ten replies a day per case');
reset role;

-- ===== 保存期 =====
update private.support_inbound_keys set created_at=now()-interval '31 days' where key_hash=decode(pg_temp.h('msg-new'),'hex');
select ok(public.support_requests_prune()>=0,'prune runs');
select ok(not exists(select 1 from private.support_inbound_keys where key_hash=decode(pg_temp.h('msg-new'),'hex')),'keys go after 30 days');

select * from finish();
rollback;
