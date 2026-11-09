-- 管理站「待處理」清單與計數（202611090700_admin_timed_cases.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}' end,true);
$$;
create function pg_temp.flag(n integer,spot text,target text,ip text) returns jsonb language sql as $$
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(ip,64),
  jsonb_build_object('action','flag','source_id',spot,'reason','內容不當','field','inappropriate',
    'proposed',jsonb_build_object('target',target),'note','x'));
$$;

-- ===== 權限 =====
select ok(not has_function_privilege('anon','admin_v1.timed_cases(text,text,jsonb,integer)','execute'),'anon cannot list');
select ok(not has_function_privilege('anon','admin_v1.timed_case_counts()','execute'),'nor count');
select ok(has_function_privilege('authenticated','admin_v1.timed_cases(text,text,jsonb,integer)','execute'),'admins list through PostgREST');
select ok(not has_function_privilege('authenticated','private.timed_case_rows(timestamptz)','execute'),'the rows are internal');
select pg_temp.act('user');
select throws_ok('select admin_v1.timed_cases()','PT403','auth.aal2_required','a rider cannot list');
select throws_ok('select admin_v1.timed_case_counts()','PT403','auth.aal2_required','nor count');

-- ===== 分格：台灣時間的今天 =====
select is(private.timed_bucket('2026-11-09 00:00+08','2026-11-08 10:00+08'),'today','due at the end of today');
select is(private.timed_bucket('2026-11-09 00:00+08','2026-11-08 23:59+08'),'today','until midnight in Taiwan');
select is(private.timed_bucket('2026-11-09 00:00+08','2026-11-09 00:00+08'),'overdue','past due at the deadline');
select is(private.timed_bucket('2026-11-10 00:00+08','2026-11-08 10:00+08'),'later','due tomorrow is later');
select is(private.timed_bucket('2026-11-09 00:00+08','2026-11-07 17:00Z'),'today','counted in Taiwan time (01:00+08 on the 8th)');

-- ===== 資料 =====
reset role;
delete from private.support_requests;
delete from public.moderation_queue where field='inappropriate';
delete from rate_limit_events;
insert into private.support_requests(id,kind,contact_email,ip_hash,created_at) values
  ('5a000000-0000-4000-8000-00000000000a','general','a@example.test',repeat('a',64),now()-interval '30 days'),
  ('5a000000-0000-4000-8000-00000000000b','general','b@example.test',repeat('b',64),now()),
  ('5a000000-0000-4000-8000-00000000000c','complaint','c@example.test',repeat('c',64),now()),
  ('5a000000-0000-4000-8000-00000000000d','account_deletion','d@example.test',repeat('d',64),now()),
  ('5a000000-0000-4000-8000-00000000000e','general','e@example.test',repeat('e',64),now());
-- 結案的不列。
insert into private.support_requests(kind,contact_email,ip_hash,status,resolved_at)
  values('general','z@example.test',repeat('z',64),'done',now());
-- b：最後一則是我們的回覆（等對方）；c：回覆寄送失敗、不再重試。
insert into private.support_messages(request_id,direction,channel,body,to_email,delivery_status,attempts,created_at) values
  ('5a000000-0000-4000-8000-00000000000b','out','admin','回覆','b@example.test','sent',1,now()),
  ('5a000000-0000-4000-8000-00000000000c','out','admin','回覆','c@example.test','failed',5,now());

update auth.users set created_at=now()-interval '30 days' where id in (pg_temp.uid(2),pg_temp.uid(3),pg_temp.uid(6));
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note)
values('7c000000-0000-4000-8000-000000000001',pg_temp.uid(1),'檢舉的點',23.611,120.611,'雲林縣','freeMotorcycle',true,false,'pending','備註原文'),
  ('7c000000-0000-4000-8000-000000000002',pg_temp.uid(1),'其他原因的點',23.612,120.612,'雲林縣','freeMotorcycle',true,false,'pending','');
select pg_temp.flag(2,'7c000000-0000-4000-8000-000000000001','text','p');
select pg_temp.flag(3,'7c000000-0000-4000-8000-000000000001','text','q');
select pg_temp.flag(6,'7c000000-0000-4000-8000-000000000002','other','s');
create temporary table first_text as select id::text id from moderation_queue
  where field='inappropriate' and source_id='7c000000-0000-4000-8000-000000000001' order by created_at,id limit 1;
grant select on first_text to authenticated;

-- ===== 每一列 =====
select is((select count(*)::integer from private.timed_case_rows()),7,'five open cases and two report groups');
select is((select state||'|'||bucket||'|'||rank from private.timed_case_rows() where id='5a000000-0000-4000-8000-00000000000a'),
  'awaiting_admin|overdue|1','no reply yet, past due');
select is((select state||'|'||bucket||'|'||rank from private.timed_case_rows() where id='5a000000-0000-4000-8000-00000000000b'),
  'awaiting_user|waiting|3','our reply last: waiting');
select is((select state||'|'||rank from private.timed_case_rows() where id='5a000000-0000-4000-8000-00000000000c'),
  'send_failed|0','a reply that failed for good goes on top');
select is((select state||'|'||bucket from private.timed_case_rows() where id='5a000000-0000-4000-8000-00000000000d'),
  'system|waiting','a deletion request is the system''s');
select is((select due_at from private.timed_case_rows() where id='5a000000-0000-4000-8000-00000000000e'),
  (select private.support_due_at(created_at) from private.support_requests where id='5a000000-0000-4000-8000-00000000000e'),
  'the support due date (#301)');
select is((select r.state||'|'||r.report_count||'|'||array_to_string(r.hidden_parts,',') from private.timed_case_rows() r
  where r.type='report' and r.kind='text'),'held|2|text','two reports of the same text are one row, hidden');
select is((select id from private.timed_case_rows() where type='report' and kind='text'),(select id from first_text),
  'its id is the earliest report');
select is((select version from private.timed_case_rows() where type='report' and kind='text'),
  (select updated_at from community_spots where id='7c000000-0000-4000-8000-000000000001'),'the spot''s updated_at is the version');
select is((select state||'|'||cardinality(hidden_parts) from private.timed_case_rows() where type='report' and kind='other'),
  'open|0','an other report hides nothing');
select is((select due_at from private.timed_case_rows() where type='report' and kind='other'),
  (select private.support_due_at(created_at) from moderation_queue where field='inappropriate' and proposed->>'target'='other'),
  'reports have five workdays too');
select ok((select bool_and(version>=s.created_at) from private.timed_case_rows() r join private.support_requests s on s.id::text=r.id),
  'a case version is never before it was sent');

-- ===== 清單 =====
select pg_temp.act('admin');
select is((select jsonb_array_length(admin_v1.timed_cases()->'items')),5,'all leaves out waiting');
select is((select admin_v1.timed_cases()->'items'->0->>'id'),'5a000000-0000-4000-8000-00000000000c','the failed reply first');
select is((select admin_v1.timed_cases()->'items'->1->>'id'),'5a000000-0000-4000-8000-00000000000a','then the overdue case');
select is((select admin_v1.timed_cases()->'next_cursor'),'null'::jsonb,'one page');
select is((select array_agg(x->>'id' order by x->>'id') from jsonb_array_elements(admin_v1.timed_cases(p_bucket=>'waiting')->'items') x),
  array['5a000000-0000-4000-8000-00000000000b','5a000000-0000-4000-8000-00000000000d'],'waiting lists the other two');
select is((select jsonb_array_length(admin_v1.timed_cases(p_kind=>'report')->'items')),2,'reports only');
select is((select admin_v1.timed_cases(p_kind=>'report:other')->'items'->0->>'state'),'open','one target');
select is((select jsonb_array_length(admin_v1.timed_cases(p_kind=>'support:general')->'items')),2,'one support kind (waiting left out)');
select is((select admin_v1.timed_cases(p_kind=>'report:other')->'items'->0->'hidden_parts'),'[]'::jsonb,'hidden_parts is an array');
select is((select admin_v1.timed_cases(p_kind=>'support:complaint')->'items'->0->'hidden_parts'),'null'::jsonb,'null for a case');
select ok(not exists(select 1 from jsonb_array_elements(admin_v1.timed_cases()->'items') x
  where x ?| array['message','subject','contact_email','note','body']),'no rider text, no email');

-- 分頁：每頁 2 筆，三頁不重複、不漏。
create temporary table pages(n integer,r jsonb);
insert into pages values(1,admin_v1.timed_cases(p_limit=>2));
insert into pages values(2,admin_v1.timed_cases(p_limit=>2,p_cursor=>(select r->'next_cursor' from pages where n=1)));
insert into pages values(3,admin_v1.timed_cases(p_limit=>2,p_cursor=>(select r->'next_cursor' from pages where n=2)));
select is((select jsonb_array_length(r->'items') from pages where n=1),2,'a page of 2');
select is((select r->'next_cursor'->>'id' from pages where n=1),(select r->'items'->1->>'id' from pages where n=1),
  'the cursor is the last row');
select is((select jsonb_array_length(r->'items') from pages where n=3),1,'the last page has the rest');
select is((select r->'next_cursor' from pages where n=3),'null'::jsonb,'and no cursor');
select is((select array_agg(x.j->>'id' order by p.n,x.o) from pages p,jsonb_array_elements(p.r->'items') with ordinality x(j,o)),
  (select array_agg(x.j->>'id' order by x.o) from jsonb_array_elements(admin_v1.timed_cases()->'items') with ordinality x(j,o)),
  'the pages are the whole list in order');

select throws_ok($$select admin_v1.timed_cases(p_kind=>'support:nope')$$,'PT400','request.invalid','an unknown kind');
select throws_ok($$select admin_v1.timed_cases(p_bucket=>'soon')$$,'PT400','request.invalid','an unknown bucket');
select throws_ok($$select admin_v1.timed_cases(p_limit=>0)$$,'PT400','request.invalid','a limit of at least 1');
select throws_ok($$select admin_v1.timed_cases(p_cursor=>'{"rank":1}')$$,'PT400','request.invalid','a cursor has all three keys');
select throws_ok($$select admin_v1.timed_cases(p_cursor=>'{"rank":1,"due_at":"soon","id":"x"}')$$,'PT400','request.invalid','and a real time');

-- ===== 計數 =====
select is((select admin_v1.timed_case_counts()-'as_of'-'by_kind'),
  '{"all":5,"overdue":1,"today":0,"later":4,"waiting":2,"send_failed":1}'::jsonb,'all = overdue + today + later; waiting apart');
select is((select admin_v1.timed_case_counts()->'by_kind'),
  '{"support":3,"report":2,"support:general":2,"support:complaint":1,"report:text":1,"report:other":1}'::jsonb,
  'by kind, actionable rows only');
select is((select (admin_v1.timed_case_counts()->>'all')::integer),(select jsonb_array_length(admin_v1.timed_cases()->'items')),
  'the count matches the list');

-- 結案後就不列。
reset role;
update private.support_requests set status='done',resolved_at=now() where id='5a000000-0000-4000-8000-00000000000a';
select pg_temp.act('admin');
select is((select (admin_v1.timed_case_counts()->>'overdue')::integer),0,'a resolved case leaves the list');

select * from finish();
rollback;
