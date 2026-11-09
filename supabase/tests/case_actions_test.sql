-- 管理站的排程動作（202611090800_case_actions.sql）。
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
-- 案件 'a'、'b'…的 id。
create function pg_temp.c(k text) returns text language sql immutable as $$
select '5b000000-0000-4000-8000-00000000000'||k;
$$;
create function pg_temp.ver(k text) returns timestamptz language sql stable as $$
select (private.case_current('support',pg_temp.c(k))).version;
$$;
create function pg_temp.reply(k text,body text) returns jsonb language sql as $$
select admin_v1.schedule_case_action(pg_temp.c(k),'reply',jsonb_build_object('body',body),pg_temp.ver(k));
$$;
-- 讓動作到期。
create function pg_temp.due(p_id text) returns void language sql as $$
update private.case_actions set run_at=now()-interval '1 second' where id=p_id::uuid;
$$;
create function pg_temp.st(p_id text) returns text language sql stable as $$
select status from private.case_actions where id=p_id::uuid;
$$;
create temporary table r(k text primary key,j jsonb);
create function pg_temp.keep(k text,j jsonb) returns void language sql as $$
insert into r values(k,j) on conflict (k) do update set j=excluded.j;
$$;
create function pg_temp.aid(k text) returns text language sql stable as $$
select j->>'action_id' from r where r.k=$1;
$$;

-- ===== 權限與排程 =====
select ok(not has_function_privilege('anon','admin_v1.schedule_case_action(text,text,jsonb,timestamptz)','execute'),'anon cannot schedule');
select ok(has_function_privilege('authenticated','admin_v1.schedule_case_action(text,text,jsonb,timestamptz)','execute'),'admins schedule through PostgREST');
select ok(not has_function_privilege('authenticated','public.run_due_case_actions(integer)','execute'),'clients cannot run the queue');
select ok(not has_function_privilege('anon','public.run_due_case_actions(integer)','execute'),'nor anon');
select ok(has_function_privilege('service_role','public.run_due_case_actions(integer)','execute'),'the Edge Function can');
select ok(not has_function_privilege('service_role','private.run_due_case_actions(integer)','execute'),'the rules stay private');
select ok(not has_table_privilege('authenticated','private.case_actions','select'),'the queue is private');
select ok(not has_table_privilege('service_role','private.case_actions','select'),'even for the service role');
select is((select schedule||'|'||command from cron.job where jobname='case-actions'),
  '* * * * *|select private.run_due_case_actions()','pg_cron every minute only calls the function');
select ok(exists(select 1 from cron.job where jobname='case-actions-prune'),'finished rows are pruned');
select is(private.case_action_delay(false),interval '5 seconds','5 seconds');
select is(private.case_action_delay(true),interval '10 seconds','10 for irreversible');
select is(private.case_action_tick(now()),null,'without vault secrets the tick does nothing');

-- ===== 資料 =====
delete from private.support_requests;
delete from public.moderation_queue where field='inappropriate';
delete from rate_limit_events;
delete from private.case_actions;
insert into private.support_requests(id,kind,contact_email,ip_hash) values
  (pg_temp.c('a')::uuid,'general','a@example.test',repeat('a',64)),
  (pg_temp.c('b')::uuid,'general','b@example.test',repeat('b',64)),
  (pg_temp.c('c')::uuid,'general','c@example.test',repeat('c',64)),
  (pg_temp.c('d')::uuid,'account_deletion','d@example.test',repeat('d',64)),
  (pg_temp.c('e')::uuid,'general','e@example.test',repeat('e',64)),
  (pg_temp.c('f')::uuid,'general','f@example.test',repeat('f',64));
update auth.users set created_at=now()-interval '30 days' where id in (pg_temp.uid(2),pg_temp.uid(3),pg_temp.uid(6));
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note) values
  ('7e000000-0000-4000-8000-000000000001',pg_temp.uid(1),'檢舉文字的點',23.621,120.621,'雲林縣','freeMotorcycle',true,false,'pending','備註原文'),
  ('7e000000-0000-4000-8000-000000000002',pg_temp.uid(1),'其他原因的點',23.622,120.622,'雲林縣','freeMotorcycle',true,false,'pending','');
select pg_temp.flag(2,'7e000000-0000-4000-8000-000000000001','text','p');
select pg_temp.flag(3,'7e000000-0000-4000-8000-000000000002','other','q');
create temporary table reports as
  select proposed->>'target' k,id::text id from moderation_queue where field='inappropriate';
create function pg_temp.spot_ver(p_spot text) returns timestamptz language sql stable as $$
select updated_at from community_spots where id=p_spot::uuid;
$$;

select pg_temp.act('user');
select throws_ok($$select pg_temp.reply('a','x')$$,'PT403','auth.aal2_required','a rider cannot schedule');
select pg_temp.act('admin');

-- 排程：一般 5 秒。
select pg_temp.keep('a1',pg_temp.reply('a','第一則'));
select is(((select j from r where k='a1')->>'run_at')::timestamptz,now()+interval '5 seconds','a reply waits 5 seconds');
select is((select j from r where k='a1')->'irreversible','false'::jsonb,'mail is not irreversible');
select is((select j from r where k='a1')->'duplicate','false'::jsonb,'a new action');
select is(pg_temp.st(pg_temp.aid('a1')),'scheduled','scheduled');
select is((select count(*)::integer from private.support_messages where request_id=pg_temp.c('a')::uuid),0,
  'the dry run wrote nothing');
select is((select count(*)::integer from admin_audit_log where action='reply_support_request' and target_id=pg_temp.c('a')),0,
  'nor audited anything');
select is((select auth.uid()),pg_temp.uid(5),'the dry run gave back the caller''s claims');

-- 不到時間不執行。
select is((select public.run_due_case_actions()->'claimed'),'0'::jsonb,'nothing is due yet');
select is(pg_temp.st(pg_temp.aid('a1')),'scheduled','still scheduled');

-- 去重。
select pg_temp.keep('a1b',pg_temp.reply('a','第一則'));
select is(pg_temp.aid('a1b'),pg_temp.aid('a1'),'the same action sent twice is one row');
select is((select j from r where k='a1b')->'duplicate','true'::jsonb,'and says so');
select is((select count(*)::integer from private.case_actions where case_id=pg_temp.c('a')),1,'one row');
select pg_temp.keep('a2',pg_temp.reply('a','第二則'));
select isnt(pg_temp.aid('a2'),pg_temp.aid('a1'),'a different reply is another action');
select is((select dedupe_key from private.case_actions where id=pg_temp.aid('a1')::uuid),
  (select 'support:'||pg_temp.c('a')||':reply:'||extract(epoch from pg_temp.ver('a'))::text||':'||md5('{"body": "第一則"}')),
  'the key is the case, action, version and content');

-- 取消競態：先取消，執行者就不會做。
select is(admin_v1.cancel_case_action(pg_temp.aid('a2')::uuid),'{"cancelled":true}'::jsonb,'cancelled');
select pg_temp.due(pg_temp.aid('a2'));
select is(pg_temp.st(pg_temp.aid('a2')),'cancelled','cancelled');
select is((select payload from private.case_actions where id=pg_temp.aid('a2')::uuid),'{}'::jsonb,'its text is gone');
select is(admin_v1.cancel_case_action(pg_temp.aid('a2')::uuid),'{"cancelled":true}'::jsonb,'cancelling twice is fine');
select pg_temp.keep('a3',pg_temp.reply('a','第二則'));
select isnt(pg_temp.aid('a3'),pg_temp.aid('a2'),'a cancelled action can be sent again');
select lives_ok(format('select admin_v1.cancel_case_action(%L)',pg_temp.aid('a3')),'cancel it again');

-- 取消競態：已開始就來不及。
update private.case_actions set status='running',leased_until=now()+interval '60 seconds' where id=pg_temp.aid('a1')::uuid;
select throws_ok(format('select admin_v1.cancel_case_action(%L)',pg_temp.aid('a1')),'PT409','case_action.started','running cannot be cancelled');
select is((select public.run_due_case_actions()->'claimed'),'0'::jsonb,'a live lease is left alone');
update private.case_actions set status='scheduled',leased_until=null where id=pg_temp.aid('a1')::uuid;
select throws_ok(format('select admin_v1.cancel_case_action(%L)','00000000-0000-4000-8000-000000000000'),'PT404','case_action.not_found','no such action');

-- ===== 執行 =====
select pg_temp.due(pg_temp.aid('a1'));
-- 執行者不是管理員：它只帶自己的身分進來，案件照建立者的權限處理。
select pg_temp.act('user');
select is((select public.run_due_case_actions()-'retried'),'{"claimed":1,"done":1,"stale":0,"failed":0}'::jsonb,'runs what is due');
select ok(not public.is_admin(),'the run gives back the caller''s claims');
select pg_temp.act('admin');
select is(pg_temp.st(pg_temp.aid('a1')),'done','done');
select is((select attempts from private.case_actions where id=pg_temp.aid('a1')::uuid),1,'one attempt');
select is((select leased_until from private.case_actions where id=pg_temp.aid('a1')::uuid),null,'the lease ended');
select is((select payload from private.case_actions where id=pg_temp.aid('a1')::uuid),'{}'::jsonb,'the text lives in the message now');
select ok((select finished_at is not null and started_at is not null from private.case_actions where id=pg_temp.aid('a1')::uuid),'timed');
select is((select count(*)::integer from private.support_messages where request_id=pg_temp.c('a')::uuid and direction='out' and body='第一則' and delivery_status='queued'),
  1,'the reply is queued, once');
select is((select m.id from private.support_messages m where m.request_id=pg_temp.c('a')::uuid),
  (select message_id from private.case_actions where id=pg_temp.aid('a1')::uuid),'and remembered');
select is((select author from private.support_messages where request_id=pg_temp.c('a')::uuid),pg_temp.uid(5),'written as the admin who sent it');
select is((select actor from admin_audit_log where action='reply_support_request' and target_id=pg_temp.c('a')),pg_temp.uid(5),'audited as the admin');
select is((select public.run_due_case_actions()->'claimed'),'0'::jsonb,'a done action is not run twice');
select pg_temp.keep('a1c',admin_v1.schedule_case_action(pg_temp.c('a'),'reply','{"body":"第一則"}',
  (select expected_version from private.case_actions where id=pg_temp.aid('a1')::uuid)));
select is(pg_temp.aid('a1c'),pg_temp.aid('a1'),'a resend after it ran is the same action, not stale');

-- ===== 版本：排程當下 =====
select throws_ok($$select admin_v1.schedule_case_action(pg_temp.c('b'),'reply','{"body":"x"}','2000-01-01T00:00:00Z')$$,
  'PT409','case.stale','an out-of-date version');
do $$
declare d text;
begin
  perform admin_v1.schedule_case_action(pg_temp.c('b'),'reply','{"body":"x"}','2000-01-01T00:00:00Z');
exception when others then
  get stacked diagnostics d=pg_exception_detail;
  perform pg_temp.keep('stale_detail',d::jsonb);
end $$;
select is((select j->>'by' from r where k='stale_detail'),'other_admin','no reply yet: another admin');
select is(((select j->>'version' from r where k='stale_detail')::timestamptz),pg_temp.ver('b'),'with the current version');
select throws_ok($$select admin_v1.schedule_case_action(pg_temp.c('b'),'reply','{"body":""}',pg_temp.ver('b'))$$,
  'PT400','request.invalid','an empty reply fails now, not 5 seconds later');
select throws_ok($$select admin_v1.schedule_case_action(pg_temp.c('d'),'reply','{"body":"x"}',pg_temp.ver('d'))$$,
  'PT409','support.reply_not_allowed','a deletion request cannot be answered');
select throws_ok($$select admin_v1.schedule_case_action(pg_temp.c('b'),'resolve_support','{"status":"nope"}',pg_temp.ver('b'))$$,
  'PT400','request.invalid','a bad status');
select throws_ok($$select admin_v1.schedule_case_action(pg_temp.c('b'),'nope','{}',pg_temp.ver('b'))$$,
  'PT400','request.invalid','an unknown action');
select throws_ok($$select admin_v1.schedule_case_action('x','reply','{}',now())$$,'PT400','request.invalid','a bad case id');
select throws_ok($$select admin_v1.schedule_case_action(pg_temp.c('b'),'reply','[]',pg_temp.ver('b'))$$,'PT400','request.invalid','a payload is an object');
select throws_ok($$select admin_v1.schedule_case_action('5b000000-0000-4000-8000-000000000999','reply','{"body":"x"}',now())$$,
  'PT404','support.not_found','no such case');

-- ===== 版本：執行當下（stale）=====
select pg_temp.keep('b1',pg_temp.reply('b','你的回覆'));
select pg_temp.due(pg_temp.aid('b1'));
-- 使用者在倒數時補充。
insert into private.support_messages(request_id,direction,channel,body)
  values(pg_temp.c('b')::uuid,'in','case_link','我補充');
select is((select public.run_due_case_actions()-'retried'),'{"claimed":1,"done":0,"stale":1,"failed":0}'::jsonb,'stale at run time');
select is(pg_temp.st(pg_temp.aid('b1')),'stale','stale');
select is((select payload->>'body' from private.case_actions where id=pg_temp.aid('b1')::uuid),'你的回覆','the draft is kept');
select is((select count(*)::integer from private.support_messages where request_id=pg_temp.c('b')::uuid and direction='out'),0,'nothing sent');
select is((select dedupe_key from private.case_actions where id=pg_temp.aid('b1')::uuid),null,'can be sent again');
select is((select (x->'pending_action')->>'status' from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('b')),
  'stale','the list shows it');
select is((select x->>'state' from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('b')),
  'awaiting_admin','the case is back to a normal row');
select ok((select (x->>'rank')::integer in (1,2) from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('b')),'at normal rank');
select is((select admin_v1.case_actions(pg_temp.c('b'))->0->'payload'->>'body'),'你的回覆','the detail restores the draft');
select is((select count(*)::integer from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->'pending_action' ? 'payload'),0,'the list carries no text');
do $$
declare d text;
begin
  perform admin_v1.schedule_case_action(pg_temp.c('b'),'reply','{"body":"x"}','2000-01-01T00:00:00Z');
exception when others then
  get stacked diagnostics d=pg_exception_detail;
  perform pg_temp.keep('stale_detail',d::jsonb);
end $$;
select is((select j->>'by' from r where k='stale_detail'),'user_reply','the rider wrote last');

-- 倒數時別人結案。
select pg_temp.keep('c1',pg_temp.reply('c','回覆'));
select pg_temp.due(pg_temp.aid('c1'));
select lives_ok($$select admin_v1.resolve_support_request(pg_temp.c('c')::uuid,'done')$$,'another admin resolves it');
select is((select public.run_due_case_actions()->'stale'),'1'::jsonb,'stale once resolved');
select throws_ok($$select pg_temp.reply('c','再一則')$$,'PT409','support.already_resolved','resolved cases refuse a new action');

-- ===== 失敗 =====
select pg_temp.keep('e2',pg_temp.reply('e','會失敗'));
select pg_temp.due(pg_temp.aid('e2'));
update private.case_actions set payload='{"body":""}' where id=pg_temp.aid('e2')::uuid;
select is((select public.run_due_case_actions()-'retried'),'{"claimed":1,"done":0,"stale":0,"failed":1}'::jsonb,'a failure is recorded');
select is((select status||'|'||error from private.case_actions where id=pg_temp.aid('e2')::uuid),'failed|request.invalid','the stable code');
select is((select x->>'state' from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('e')),
  'send_failed','a failed action is send_failed');
select is((select (x->>'rank')::integer from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('e')),
  0,'on top');
select is((select (admin_v1.timed_case_counts()->>'send_failed')::integer),1,'and counted');

-- 再寄一次：動作本身失敗。
update private.case_actions set payload='{"body":"這次會過"}' where id=pg_temp.aid('e2')::uuid;
select is((select admin_v1.retry_case_action(pg_temp.aid('e2')::uuid)->>'action_id'),pg_temp.aid('e2'),'retried');
select is(pg_temp.st(pg_temp.aid('e2')),'scheduled','back in the queue');
select ok((select run_at<=now() from private.case_actions where id=pg_temp.aid('e2')::uuid),'at once, no second wait');
select throws_ok(format('select admin_v1.retry_case_action(%L)',pg_temp.aid('e2')),'PT409','case_action.not_retryable','only failed ones');
select is((select public.run_due_case_actions()->'done'),'1'::jsonb,'and it runs');
select is(pg_temp.st(pg_temp.aid('e2')),'done','done');

-- 建立者已不是管理員。
select pg_temp.keep('f1',pg_temp.reply('f','回覆'));
select pg_temp.due(pg_temp.aid('f1'));
update auth.users set raw_app_meta_data=jsonb_set(raw_app_meta_data,'{role}','"user"') where id=pg_temp.uid(5);
select is((select public.run_due_case_actions()->'failed'),'1'::jsonb,'a demoted admin''s action does not run');
select is((select error from private.case_actions where id=pg_temp.aid('f1')::uuid),'case_action.actor_not_admin','and says why');
update auth.users set raw_app_meta_data=jsonb_set(raw_app_meta_data,'{role}','"admin"') where id=pg_temp.uid(5);
select is((select count(*)::integer from private.support_messages where request_id=pg_temp.c('f')::uuid and direction='out'),0,'nothing written');

-- 再寄一次：信寄不出去。
select pg_temp.keep('f2',admin_v1.schedule_case_action(pg_temp.c('f'),'reply','{"body":"寄不出去"}',pg_temp.ver('f')));
select pg_temp.due(pg_temp.aid('f2'));
select is((select public.run_due_case_actions()->'done'),'1'::jsonb,'queued');
update private.support_messages set delivery_status='failed',attempts=5,send_error='resend 500' where request_id=pg_temp.c('f')::uuid and direction='out';
select is((select (x->'pending_action')->>'status' from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('f')),
  'failed','a failed mail shows as failed');
select is((select x->>'state' from jsonb_array_elements(admin_v1.timed_cases()->'items') x where x->>'id'=pg_temp.c('f')),
  'send_failed','and on top');
select is((select admin_v1.case_actions(pg_temp.c('f'))->0->>'send_error'),'resend 500','the detail says why');
select is((select admin_v1.case_actions(pg_temp.c('f'))->0->'address_editable'),'false'::jsonb,'no address change yet');
select is((select admin_v1.retry_case_action(pg_temp.aid('f2')::uuid)->>'action_id'),pg_temp.aid('f2'),'sent again');
select is((select delivery_status||'|'||attempts||'|'||coalesce(send_error,'-') from private.support_messages
  where request_id=pg_temp.c('f')::uuid and direction='out'),'queued|0|-','queued, attempts reset');
select is((select count(*)::integer from admin_audit_log where action='retry_case_action' and target_id=pg_temp.c('f')),1,'audited');
select throws_ok(format('select admin_v1.retry_case_action(%L)',pg_temp.aid('f2')),'PT409','case_action.not_retryable','only while failed');
update private.support_messages set delivery_status='failed',attempts=5 where request_id=pg_temp.c('f')::uuid and direction='out';
insert into private.support_messages(request_id,direction,channel,body) values(pg_temp.c('f')::uuid,'in','case_link','又補充');
select throws_ok(format('select admin_v1.retry_case_action(%L)',pg_temp.aid('f2')),'PT409','case.stale','a newer message: look first');
select throws_ok(format('select admin_v1.retry_case_action(%L)',pg_temp.aid('a3')),'PT409','case_action.not_retryable','a cancelled one is not retried');

-- ===== 租約 =====
select pg_temp.keep('l1',admin_v1.schedule_case_action(pg_temp.c('f'),'resolve_support','{"status":"done","note":"好了"}',pg_temp.ver('f')));
select is((select j->'irreversible' from r where k='l1'),'false'::jsonb,'closing a case is a normal action');
-- 上一個執行者領了就掛了。
update private.case_actions set status='running',attempts=1,run_at=now()-interval '2 minutes',leased_until=now()-interval '1 second'
  where id=pg_temp.aid('l1')::uuid;
select throws_ok(format('select admin_v1.cancel_case_action(%L)',pg_temp.aid('l1')),'PT409','case_action.started','still counts as started');
update private.case_actions set leased_until=now()+interval '1 minute' where id=pg_temp.aid('l1')::uuid;
select is((select public.run_due_case_actions()->'claimed'),'0'::jsonb,'not reclaimed before the lease ends');
update private.case_actions set leased_until=now()-interval '1 second',expected_version='2000-01-01T00:00:00Z' where id=pg_temp.aid('l1')::uuid;
select is((select public.run_due_case_actions()->'stale'),'1'::jsonb,'reclaimed, and the version is still checked');
select is((select status from private.support_requests where id=pg_temp.c('f')::uuid),'open','so nothing happened');
update private.case_actions set status='running',attempts=1,run_at=now()-interval '2 minutes',leased_until=now()-interval '1 second',
  expected_version=pg_temp.ver('f'),dedupe_key='lease-test',error=null,finished_at=null where id=pg_temp.aid('l1')::uuid;
select is((select public.run_due_case_actions()->'done'),'1'::jsonb,'reclaimed and run');
select is((select status from private.support_requests where id=pg_temp.c('f')::uuid),'done','the case is closed');
select is((select attempts from private.case_actions where id=pg_temp.aid('l1')::uuid),2,'attempts add up');
update private.case_actions set status='running',attempts=5,leased_until=now()-interval '1 second',error=null,dedupe_key=null,finished_at=null where id=pg_temp.aid('l1')::uuid;
select is((select public.run_due_case_actions()->'failed'),'1'::jsonb,'at most 5 attempts');
select is((select error from private.case_actions where id=pg_temp.aid('l1')::uuid),'case_action.attempts_exhausted','and says why');

-- ===== 倒數暫停與上限 =====
update private.support_requests set status='open',resolved_at=null where id=pg_temp.c('f')::uuid;
select pg_temp.keep('h1',admin_v1.schedule_case_action(pg_temp.c('f'),'reply','{"body":"暫停"}',pg_temp.ver('f')));
select is(((select admin_v1.hold_case_action(pg_temp.aid('h1')::uuid,true))->>'run_at')::timestamptz,now()+interval '60 seconds','hold: 60 seconds');
select is((select admin_v1.hold_case_action(pg_temp.aid('h1')::uuid,true))->'capped','false'::jsonb,'not capped yet');
select is(((select admin_v1.hold_case_action(pg_temp.aid('h1')::uuid,false))->>'run_at')::timestamptz,now()+interval '5 seconds','release: 5 seconds again');
select is(pg_temp.st(pg_temp.aid('h1')),'scheduled','still scheduled');
-- 5 秒＋5 分鐘的累計上限。
update private.case_actions set created_at=now()-interval '5 minutes' where id=pg_temp.aid('h1')::uuid;
select is(((select admin_v1.hold_case_action(pg_temp.aid('h1')::uuid,true))->>'run_at')::timestamptz,now()+interval '5 seconds','capped at 5 minutes in all');
select is((select admin_v1.hold_case_action(pg_temp.aid('h1')::uuid,true))->'capped','true'::jsonb,'and says so');
update private.case_actions set created_at=now()-interval '2 hours' where id=pg_temp.aid('h1')::uuid;
select ok(((select admin_v1.hold_case_action(pg_temp.aid('h1')::uuid,true))->>'run_at')::timestamptz<=now(),'past the cap it runs at once');
select is((select public.run_due_case_actions()->'done'),'1'::jsonb,'so a hold cannot stall it forever');
select throws_ok(format('select admin_v1.hold_case_action(%L,true)',pg_temp.aid('h1')),'PT409','case_action.started','too late to hold');
select throws_ok(format('select admin_v1.hold_case_action(%L,true)',pg_temp.aid('a2')),'PT409','case_action.cancelled','cancelled');
select throws_ok(format('select admin_v1.hold_case_action(%L,null)',pg_temp.aid('a2')),'PT400','request.invalid','hold or release');

-- ===== 檢舉 =====
select pg_temp.keep('t1',admin_v1.schedule_case_action((select id from reports where k='text'),'report_keep','{"note":"移除"}',
  pg_temp.spot_ver('7e000000-0000-4000-8000-000000000001')));
select is((select j->'irreversible' from r where k='t1'),'true'::jsonb,'removing text is irreversible');
select is(((select j from r where k='t1')->>'run_at')::timestamptz,now()+interval '10 seconds','10 seconds');
select is((select (x->>'state') from jsonb_array_elements(admin_v1.timed_cases(p_kind=>'report')->'items') x where x->>'id'=(select id from reports where k='text')),
  'scheduled','the list counts down');
select is((select bucket from private.timed_case_rows() where id=(select id from reports where k='text')),
  (select private.timed_bucket(due_at,now()) from private.timed_case_rows() where id=(select id from reports where k='text')),'in the same bucket');
select is((select (x->'pending_action')->>'id' from jsonb_array_elements(admin_v1.timed_cases(p_kind=>'report')->'items') x where x->>'id'=(select id from reports where k='text')),
  pg_temp.aid('t1'),'with the id to cancel');
select pg_temp.due(pg_temp.aid('t1'));
select is((select public.run_due_case_actions()->'done'),'1'::jsonb,'it runs');
select is((select status from moderation_queue where id=(select id::uuid from reports where k='text')),'accepted','through resolve_content_report');
select is((select resolved_by from moderation_queue where id=(select id::uuid from reports where k='text')),pg_temp.uid(5),'as the admin');

select pg_temp.keep('o1',admin_v1.schedule_case_action((select id from reports where k='other'),'report_keep','{}',
  pg_temp.spot_ver('7e000000-0000-4000-8000-000000000002')));
select is((select j->'irreversible' from r where k='o1'),'false'::jsonb,'keeping an other report changes nothing: 5 seconds');
select is(admin_v1.cancel_case_action(pg_temp.aid('o1')::uuid),'{"cancelled":true}'::jsonb,'cancel');
select pg_temp.keep('o2',admin_v1.schedule_case_action((select id from reports where k='other'),'report_edit','{"patch":{"note":"改"},"note":""}',
  pg_temp.spot_ver('7e000000-0000-4000-8000-000000000002')));
select is((select j->'irreversible' from r where k='o2'),'true'::jsonb,'an edit overwrites: 10 seconds');
select is(admin_v1.cancel_case_action(pg_temp.aid('o2')::uuid),'{"cancelled":true}'::jsonb,'cancel');
select throws_ok(format('select admin_v1.schedule_case_action(%L,''report_edit'',''{}'',%L)',(select id from reports where k='other'),
  pg_temp.spot_ver('7e000000-0000-4000-8000-000000000002')),'PT400','content_report.invalid_patch','checked by the same rules');
select pg_temp.keep('o3',admin_v1.schedule_case_action((select id from reports where k='other'),'report_restore','{"reason":"wrong"}',
  pg_temp.spot_ver('7e000000-0000-4000-8000-000000000002')));
select is((select j->'irreversible' from r where k='o3'),'false'::jsonb,'a rejection is a normal action');
select pg_temp.due(pg_temp.aid('o3'));
-- 點位在倒數時被改。
update community_spots set note='有人改了',updated_at=now()+interval '1 second' where id='7e000000-0000-4000-8000-000000000002';
select is((select public.run_due_case_actions()->'stale'),'1'::jsonb,'the spot changed');
select is((select resolved_at from moderation_queue where id=(select id::uuid from reports where k='other')),null,'the report stays open');

-- ===== 保存 =====
update private.case_actions set finished_at=now()-interval '31 days' where id=pg_temp.aid('a2')::uuid;
select is(private.case_actions_prune(),1,'finished 30 days ago: gone');
select ok(not exists(select 1 from private.case_actions where id=pg_temp.aid('a2')::uuid),'the row is deleted');
select ok(exists(select 1 from private.case_actions where id=pg_temp.aid('a1')::uuid),'newer ones stay');

-- ===== skip locked：另一個連線鎖著的列不領 =====
create extension if not exists dblink with schema extensions;
-- 連到自己的網路位址：127.0.0.1 是 trust，不會要密碼，非 superuser 的 dblink 不准。
select dblink_connect('cx',format('host=%s port=5432 dbname=postgres user=postgres password=postgres',host(inet_server_addr())));
select dblink_exec('cx','set lock_timeout=''2s''');
-- 另一個連線已提交的到期動作，再開交易鎖住（別的執行者正在處理）。
select dblink_exec('cx',$$insert into private.case_actions(id,case_type,case_id,action,payload,actor,run_at,irreversible)
  values('6a000000-0000-4000-8000-000000000001','support','6a000000-0000-4000-8000-0000000000ff','reply','{}',
    '10000000-0000-4000-8000-000000000005',now()-interval '1 minute',false)$$);
select dblink_exec('cx','begin');
select dblink_exec('cx',$$select 1 from private.case_actions where id='6a000000-0000-4000-8000-000000000001' for update$$);
select is((select status from private.case_actions where id='6a000000-0000-4000-8000-000000000001'),'scheduled','the other session''s row is visible');
select is((select public.run_due_case_actions()->'claimed'),'0'::jsonb,'a locked row is skipped, not waited for');
select is((select status from private.case_actions where id='6a000000-0000-4000-8000-000000000001'),'scheduled','and left alone');
select dblink_exec('cx','rollback');
-- 這一列在另一個連線提交過，測試交易回滾不會帶走它。
select dblink_exec('cx',$$delete from private.case_actions where id='6a000000-0000-4000-8000-000000000001'$$);
select dblink_disconnect('cx');

select * from finish();
rollback;
