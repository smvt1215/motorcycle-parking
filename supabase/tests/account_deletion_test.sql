-- 刪除帳號（#215；202611011900_account_deletion.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- 騎士 1 要刪帳號；騎士 2、6 是其他人；4 是匿名登入。
create function pg_temp.act(p_user text,p_signed_in_ago interval default interval '1 minute',p_anonymous boolean default false)
returns void language sql as $$
  select set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated',
    'is_anonymous',p_anonymous,
    'amr',jsonb_build_array(jsonb_build_object('method','oauth',
      'timestamp',extract(epoch from now()-p_signed_in_ago)::bigint)))::text,true);
$$;

-- ===== 1. 外鍵 =====
select is(
  (select string_agg(c.conrelid::regclass::text||'.'||a.attname||'='||c.confdeltype::text,','
    order by c.conrelid::regclass::text||'.'||a.attname)
   from pg_constraint c join pg_attribute a on a.attrelid=c.conrelid and a.attnum=any(c.conkey)
   where c.contype='f' and c.confrelid='auth.users'::regclass and c.connamespace='public'::regnamespace),
  'community_spots.user_id=n,favorites.user_id=c,geocode_events.user_id=c,moderation_queue.reporter_id=n,'
  'rate_limit_events.user_id=c,rider_sighting_scores.user_id=c,rider_sightings.user_id=n,'
  'spot_rider_events.actor=n,spot_votes.user_id=n',
  'every reference to an account is set null (kept anonymous) or cascades (personal data)');
select ok(not exists(select 1 from pg_constraint c
    where c.contype='f' and c.confrelid='auth.users'::regclass and c.confdeltype in ('a','r')),
  'nothing restricts deleting an account');

-- ===== 2. 資料 =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type)
values('76000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','要刪帳號的點',25.081,121.601,'臺北市','offStreet'),
  ('76000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000006','別人的點',25.082,121.602,'臺北市','offStreet');
update auth.users set raw_user_meta_data='{"display_name":"要刪的人"}' where id='10000000-0000-4000-8000-000000000001';
select is((select contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),'要刪的人','the point shows its reporter''s name');
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
values('76000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','still_there',true,1,repeat('a',64),repeat('a',64)),
  ('76000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','still_there',true,1,repeat('b',64),repeat('b',64));
insert into moderation_queue(source_id,reporter_id,reason,field)
values('76000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','名稱錯了','name');
insert into rider_sightings(user_id,spot_id,kind,level,vehicle,ip_hash,device_hash)
values('10000000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000002','level',1,'scooter',repeat('a',64),repeat('a',64));
insert into rider_sighting_scores(user_id,agree) values('10000000-0000-4000-8000-000000000001',3);
insert into favorites(user_id,spot_id,spot) values('10000000-0000-4000-8000-000000000001','fav-del','{"id":"fav-del"}');
insert into rate_limit_events(user_id,ip_hash) values('10000000-0000-4000-8000-000000000001',repeat('a',64));

-- ===== 3. 申請、查詢、取消 =====
select ok(not has_function_privilege('anon','api_v1.request_account_deletion(text)','execute'),'anon cannot request a deletion');
select ok(not has_function_privilege('anon','api_v1.cancel_account_deletion()','execute'),'anon cannot cancel');
select ok(not has_function_privilege('anon','api_v1.account_deletion_status()','execute'),'anon cannot read the status');
select ok(not has_function_privilege('authenticated','public.account_deletion_claim(integer)','execute'),'riders cannot run the executor');
select ok(not has_function_privilege('authenticated','public.account_deletion_finish(uuid,text,jsonb)','execute'),'riders cannot write the audit');
select ok(has_function_privilege('service_role','public.account_deletion_claim(integer)','execute'),'the executor can claim');
select ok(not has_table_privilege('authenticated','private.account_deletion_requests','select'),'requests are private');
select ok(not has_table_privilege('service_role','private.account_deletion_audit','select'),'the audit is private');

set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000004',p_anonymous=>true);
select throws_ok($$select api_v1.request_account_deletion()$$,'PT401','auth.sign_in_required','an anonymous sign-in cannot request');
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select throws_ok($$select api_v1.account_deletion_status()$$,'PT401','auth.sign_in_required','no account, no status');

select pg_temp.act('10000000-0000-4000-8000-000000000001');
select is(api_v1.account_deletion_status(),'{"status":"none","requested_at":null,"scheduled_at":null,"cancelled_at":null,"cancelled_by_sign_in":null}'::jsonb,'no request yet');
select pg_temp.act('10000000-0000-4000-8000-000000000001',interval '11 minutes');
select throws_ok($$select api_v1.request_account_deletion()$$,'PT401','auth.recent_sign_in_required','a sign-in older than 10 minutes must sign in again');
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api_v1.request_account_deletion()$$,'PT401','auth.recent_sign_in_required','a token without amr is not a recent sign-in');
select pg_temp.act('10000000-0000-4000-8000-000000000001');
select throws_ok($$select api_v1.request_account_deletion('mail')$$,'PT400','request.invalid','only app or web');
select is((select api_v1.request_account_deletion()->>'status'),'pending','a fresh sign-in can request');
reset role;
select is((select contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),'',
  'the name stops showing as soon as deletion is requested');
update auth.users set raw_user_meta_data='{"display_name":"改名也不顯示"}' where id='10000000-0000-4000-8000-000000000001';
select is((select contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),'',
  'renaming during the cooling-off period shows nothing either');
update auth.users set raw_user_meta_data='{"display_name":"要刪的人"}' where id='10000000-0000-4000-8000-000000000001';
set local role authenticated;
select is((select (api_v1.account_deletion_status()->>'scheduled_at')::timestamptz-(api_v1.account_deletion_status()->>'requested_at')::timestamptz),
  interval '7 days','deletion is due 7 days after the request');
select pg_temp.act('10000000-0000-4000-8000-000000000001',interval '1 day');
select is(api_v1.request_account_deletion(),api_v1.account_deletion_status(),'asking again keeps the first request and needs no new sign-in');
select pg_temp.act('10000000-0000-4000-8000-000000000002');
select is((select api_v1.account_deletion_status()->>'status'),'none','another rider has no request');
select pg_temp.act('10000000-0000-4000-8000-000000000001',interval '2 days');
select is((select api_v1.cancel_account_deletion()->>'status'),'none','cancelling within the cooling-off period');
select is((select api_v1.account_deletion_status()->>'cancelled_by_sign_in'),'false','the status says it was cancelled, not by signing in');
select ok((select api_v1.account_deletion_status()->>'cancelled_at') is not null,'and when');
select is((select api_v1.cancel_account_deletion()->>'status'),'none','cancelling without a request succeeds');
reset role;
select is((select contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),'要刪的人',
  'cancelling shows the name again');

-- 管理員不能自助刪除。
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000005');
select throws_ok($$select api_v1.request_account_deletion()$$,'PT403','account.admin_cannot_self_delete',
  'an admin must lose the role first');
reset role;

-- 冷靜期內的新登入自動取消；申請前的 session、換 token 都不算。
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000001');
select api_v1.request_account_deletion();
reset role;
select is((select api_v1_cancelled from (select (private.account_deletion_state('10000000-0000-4000-8000-000000000001')->>'cancelled_at') is null as api_v1_cancelled) x),
  true,'a new request clears the last cancellation');
insert into auth.sessions(id,user_id,created_at,updated_at) values(gen_random_uuid(),'10000000-0000-4000-8000-000000000001',now(),now());
select is((select count(*)::int from private.account_deletion_requests),1,'a session as old as the request does not cancel it');
update private.account_deletion_requests set requested_at=now()-interval '1 day',scheduled_at=now()+interval '6 days';
update auth.sessions set refreshed_at=now() where user_id='10000000-0000-4000-8000-000000000001';
select is((select count(*)::int from private.account_deletion_requests),1,'refreshing a session does not cancel it');
insert into auth.sessions(id,user_id,created_at,updated_at) values(gen_random_uuid(),'10000000-0000-4000-8000-000000000001',now(),now());
select is((select count(*)::int from private.account_deletion_requests),0,'signing in again cancels the request');
select is((select private.account_deletion_state('10000000-0000-4000-8000-000000000001')->>'cancelled_by_sign_in'),'true',
  'the status says signing in cancelled it');
select is((select contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),'要刪的人',
  'and the name shows again');
delete from private.account_deletion_cancellations;
delete from auth.sessions where user_id='10000000-0000-4000-8000-000000000001';
select is((select string_agg(event||'/'||source,',' order by id) from private.account_deletion_audit),
  'requested/app,cancelled/app,requested/app,cancelled/app','requests and cancellations are audited');
select is((select count(distinct request_id)::int from private.account_deletion_audit),2,'each request has its own id');
select is((select count(*)::int from private.account_deletion_audit group by request_id limit 1),2,'a request''s events share its id');
select ok(not exists(select 1 from information_schema.columns
    where table_schema='private' and table_name='account_deletion_audit' and column_name ~ '(user|name|email)'),
  'the audit stores no account, name or email');
select throws_ok($$delete from private.account_deletion_audit$$,'42501',null,'the audit cannot be changed');

-- ===== 4. 到期執行 =====
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000001');
select api_v1.request_account_deletion('web');
reset role;
set local role service_role;
select is((select count(*)::int from public.account_deletion_claim()),0,'nothing is due during the cooling-off period');
reset role;
update private.account_deletion_requests set requested_at=now()-interval '8 days',scheduled_at=now()-interval '1 day';
set local role service_role;
create temporary table claimed as select * from public.account_deletion_claim();
select is((select count(*)::int from claimed),1,'a due request is claimed');
select is((select count(*)::int from public.account_deletion_claim()),0,'a claimed request is not claimed twice');
reset role;
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000001');
select throws_ok($$select api_v1.cancel_account_deletion()$$,'PT409','account.deletion_in_progress','cannot cancel while it is being deleted');
reset role;
set local role service_role;
select is(public.account_deletion_prepare((select request_id from claimed)),
  jsonb_build_object('spots',(select count(*) from community_spots where user_id='10000000-0000-4000-8000-000000000001'),
    'votes',1,'reports',1,'reports_pending',1,'sightings',1,'favorites',1),'counts before deletion');
select is(public.account_deletion_prepare(gen_random_uuid()),null,'an unknown request has nothing to prepare');
select throws_ok(format('select public.account_deletion_finish(%L,''web'',''{}'')',(select request_id from claimed)),
  '55000','account still exists','cannot record a deletion before the account is gone');
reset role;

-- What auth.admin.deleteUser does in the database.
delete from auth.users where id='10000000-0000-4000-8000-000000000001';

select is((select user_id::text||'|'||contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),null,
  'the point stays, without its reporter');
select is((select contributor_name from community_spots where id='76000000-0000-4000-8000-000000000001'),'','its public name is cleared');
select is((select count(*)::int from spot_votes where spot_id='76000000-0000-4000-8000-000000000002' and user_id is null),1,'the vote stays, anonymous');
select is((select count(*)::int from spot_votes where spot_id='76000000-0000-4000-8000-000000000001'),1,'votes by others on the point stay');
select is((select reporter_id::text||'|'||status from moderation_queue where reason='名稱錯了'),null,'the pending report stays, anonymous');
select is((select status||'|'||(anonymized_at is not null) from moderation_queue where reason='名稱錯了'),'pending|true','and is still pending review');
select is((select count(*)::int from rider_sightings where spot_id='76000000-0000-4000-8000-000000000002' and user_id is null),1,'the sighting stays, anonymous');
select is((select string_agg(x,',' order by x) from (
    select 'spot' x from community_spots where id='76000000-0000-4000-8000-000000000001' and anonymized_at=now()
    union all select 'vote' from spot_votes where spot_id='76000000-0000-4000-8000-000000000002' and user_id is null and anonymized_at=now()
    union all select 'report' from moderation_queue where reason='名稱錯了' and anonymized_at=now()
    union all select 'sighting' from rider_sightings where spot_id='76000000-0000-4000-8000-000000000002' and user_id is null and anonymized_at=now()) a),
  'report,sighting,spot,vote','each kept row records when it became anonymous (#267 counts its retention from then)');
select is((select count(*)::int from spot_votes where spot_id='76000000-0000-4000-8000-000000000001' and anonymized_at is not null),0,
  'other riders'' rows are not marked');
select is((select count(*)::int from rider_sighting_scores where user_id='10000000-0000-4000-8000-000000000001'),0,'the score is deleted');
select is((select count(*)::int from favorites where user_id='10000000-0000-4000-8000-000000000001'),0,'favorites are deleted');
select is((select count(*)::int from rate_limit_events where user_id='10000000-0000-4000-8000-000000000001'),0,'rate-limit events are deleted');
select is((select count(*)::int from private.account_deletion_requests),0,'the request goes with the account');

set local role service_role;
select lives_ok(format('select public.account_deletion_finish(%L,''web'',''{"spots":1,"avatars":0}'')',(select request_id from claimed)),
  'the deletion is recorded');
reset role;
select is((select event||'/'||source||'/'||(counts->>'spots') from private.account_deletion_audit order by id desc limit 1),
  'executed/web/1','executed with its counts');

-- 匿名點位仍可被投票（apply_report 以找到點位判斷）。
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000006',repeat('c',64),repeat('c',64),
  '{"action":"vote","spot_id":"76000000-0000-4000-8000-000000000001","vote":"still_there"}')$$,
  'riders can still vote on an anonymous point');
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000006',repeat('c',64),repeat('c',64),
  '{"action":"vote","spot_id":"76000000-0000-4000-8000-0000000000ff","vote":"still_there"}')$$,
  '22023','spot not found','an unknown point is still not found');
-- 兩位已刪帳號的人在同一點的票都留下。
delete from auth.users where id='10000000-0000-4000-8000-000000000002';
select is((select count(*)::int from spot_votes where spot_id='76000000-0000-4000-8000-000000000001' and user_id is null),1,
  'a second deleted voter''s vote stays too');
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
values('76000000-0000-4000-8000-000000000001',null,'gone',true,1,repeat('d',64),repeat('d',64));
select is((select count(*)::int from spot_votes where spot_id='76000000-0000-4000-8000-000000000001' and user_id is null),2,
  'anonymous votes do not collide');
select throws_ok($$insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
  values('76000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000006','gone',true,1,repeat('e',64),repeat('e',64))$$,
  '23505',null,'one vote per rider per point still holds');

-- 統計：匿名化的回報不算投票自動建立。
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}',true);
select is((select auto_reports from public.admin_review_baseline(1) limit 1),
  (select count(*)::int from moderation_queue q where q.reporter_id is null and q.anonymized_at is null
    and date_trunc('month',q.created_at at time zone 'Asia/Taipei')=date_trunc('month',now() at time zone 'Asia/Taipei')),
  'reports of deleted accounts are not counted as automatic');

-- 失敗會放開領取並留紀錄。
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000006');
select api_v1.request_account_deletion();
reset role;
update private.account_deletion_requests set requested_at=now()-interval '8 days',scheduled_at=now()-interval '1 day';
set local role service_role;
create temporary table claimed2 as select * from public.account_deletion_claim(5);
reset role;
update auth.users set raw_app_meta_data='{"role":"admin","provider":"google"}' where id='10000000-0000-4000-8000-000000000006';
set local role service_role;
select throws_ok(format('select public.account_deletion_prepare(%L)',(select request_id from claimed2)),
  '42501','account.admin_cannot_self_delete','an account made admin during the cooling-off period is not deleted');
select public.account_deletion_fail((select request_id from claimed2),'storage_failed');
reset role;
select is((select attempts||'|'||last_error||'|'||(claimed_at is not null) from private.account_deletion_requests),'1|storage_failed|true',
  'a failure is recorded and stays claimed for this run');
select is((select count(*)::int from public.account_deletion_claim(5)),0,'the same run does not retry it');
select is((select event||'/'||error from private.account_deletion_audit order by id desc limit 1),'failed/storage_failed','the failure is audited');

-- 持續失敗的申請不會擋住其他到期申請。
reset role;
set local role authenticated;
select pg_temp.act('10000000-0000-4000-8000-000000000003');
select api_v1.request_account_deletion();
reset role;
update private.account_deletion_requests set requested_at=now()-interval '8 days',scheduled_at=now()-interval '12 hours'
  where user_id='10000000-0000-4000-8000-000000000003';
-- 下一天：上一次的領取已過期。
update private.account_deletion_requests set claimed_at=now()-interval '1 day'
  where user_id='10000000-0000-4000-8000-000000000006';
set local role service_role;
select is((select user_id from public.account_deletion_claim(1)),'10000000-0000-4000-8000-000000000003'::uuid,
  'a request not yet tried goes before one that keeps failing, though due later');
reset role;

-- 排程：每天一次；vault 沒設定時不呼叫。
select is((select schedule from cron.job where jobname='account-deletion'),'41 19 * * *','runs daily at 03:41 Taiwan time');
select is(public.account_deletion_tick(),null,'does nothing without its vault secrets');

select * from finish();
rollback;
