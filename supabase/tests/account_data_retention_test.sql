-- 帳號相關資料定期清除（#267；202611012100_account_data_retention.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- ===== 排程與權限 =====
select is((select schedule from cron.job where jobname='account-data-retention'),'29 20 * * *',
  'runs daily at 04:29 Taiwan time');
select is((select command from cron.job where jobname='account-data-retention'),'select public.account_data_retention()',
  'and calls the retention job');
select ok(not has_function_privilege(r,'public.'||f,'execute'),r||' cannot call '||f)
from (values ('usage_events_prune()'),('anonymized_hashes_clear()'),('admin_audit_deidentify(integer)'),
  ('account_data_retention()'),('admin_audit_log_guard()'),('retained_hashes_guard()')) fn(f)
cross join (values ('anon'),('authenticated')) ro(r);
select ok(not has_function_privilege(r,'private.'||f,'execute'),r||' cannot call private.'||f)
from (values ('retention_usage_events()'),('retention_anonymized_hashes()'),('retention_audit_log()'),
  ('audit_personal_keys()'),('audit_redact(jsonb)'),('audit_redact_target(text,text)'))
  fn(f)
cross join (values ('anon'),('authenticated'),('service_role')) ro(r);

-- ===== 1. 使用紀錄 30 天 =====
delete from rate_limit_events;
delete from geocode_events;
insert into rate_limit_events(user_id,ip_hash,created_at) values
  ('10000000-0000-4000-8000-000000000001',repeat('a',64),now()-interval '31 days'),
  ('10000000-0000-4000-8000-000000000001',repeat('a',64),now()-interval '29 days'),
  ('10000000-0000-4000-8000-000000000002',repeat('b',64),now());
insert into geocode_events(user_id,created_at) values
  ('10000000-0000-4000-8000-000000000001',now()-interval '30 days 1 minute'),
  ('10000000-0000-4000-8000-000000000001',now()-interval '1 day');
select is(usage_events_prune(),'{"rate_limit_events":1,"geocode_events":1}'::jsonb,
  'deletes only usage records older than 30 days');
select is((select array_agg(created_at>now()-interval '30 days' order by created_at) from rate_limit_events),
  array[true,true],'the 30-day window the admin stats read stays whole');
select is((select count(*)::int from geocode_events),1,'a recent search stays');
select is(usage_events_prune(),'{"rate_limit_events":0,"geocode_events":0}'::jsonb,'running it again deletes nothing');

-- ===== 2. 刪帳號後的雜湊 180 天 =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type,anonymized_at) values
  ('77000000-0000-4000-8000-000000000001',null,'刪帳號 181 天',25.081,121.601,'臺北市','offStreet',now()-interval '181 days'),
  ('77000000-0000-4000-8000-000000000002',null,'刪帳號 179 天',25.082,121.602,'臺北市','offStreet',now()-interval '179 days'),
  ('77000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000006','帳號還在',25.083,121.603,'臺北市','offStreet',null);
insert into report_identities values
  ('77000000-0000-4000-8000-000000000001',repeat('1',64),repeat('1',64)),
  ('77000000-0000-4000-8000-000000000002',repeat('2',64),repeat('2',64)),
  ('77000000-0000-4000-8000-000000000003',repeat('3',64),repeat('3',64));
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash,created_at,anonymized_at) values
  ('77000000-0000-4000-8000-000000000003',null,'still_there',true,1,repeat('4',64),repeat('4',64),now()-interval '300 days',now()-interval '181 days'),
  ('77000000-0000-4000-8000-000000000003',null,'still_there',true,1,repeat('5',64),repeat('5',64),now()-interval '300 days',now()-interval '200 days'),
  ('77000000-0000-4000-8000-000000000003',null,'gone',false,0.25,repeat('6',64),repeat('6',64),now()-interval '300 days',now()-interval '179 days'),
  ('77000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000002','still_there',true,1,repeat('7',64),repeat('7',64),now()-interval '400 days',null);
insert into rider_sightings(user_id,spot_id,kind,level,vehicle,ip_hash,device_hash,anonymized_at) values
  (null,'77000000-0000-4000-8000-000000000003','level',1,'scooter',repeat('8',64),repeat('8',64),now()-interval '181 days'),
  ('10000000-0000-4000-8000-000000000002','77000000-0000-4000-8000-000000000003','level',1,'scooter',repeat('9',64),repeat('9',64),null);
create temporary table votes_before on commit drop as
  select id,to_jsonb(v)-'ip_hash'-'device_hash' as row from spot_votes v where spot_id='77000000-0000-4000-8000-000000000003';
create temporary table history_before on commit drop as select count(*) as n from spot_rider_events;

select is(anonymized_hashes_clear(),'{"spot_votes":2,"report_identities":1,"rider_sightings":1}'::jsonb,
  'clears the hashes of accounts deleted more than 180 days ago');
select is((select array_agg(coalesce(left(ip_hash,1),'-')||coalesce(left(device_hash,1),'-') order by ip_hash nulls first) from spot_votes
    where spot_id='77000000-0000-4000-8000-000000000003'),
  array['--','--','66','77'],'votes: past 180 days cleared to null; 179 days and live accounts untouched');
select is((select array_agg(spot_id::text||':'||coalesce(left(ip_hash,1),'-')||coalesce(left(device_hash,1),'-') order by spot_id) from report_identities
    where spot_id::text like '77000000-%'),
  array['77000000-0000-4000-8000-000000000001:--','77000000-0000-4000-8000-000000000002:22','77000000-0000-4000-8000-000000000003:33'],
  'reported spots: only the one whose reporter left more than 180 days ago');
select is((select array_agg(coalesce(left(ip_hash,1),'-')||coalesce(left(device_hash,1),'-') order by ip_hash nulls first) from rider_sightings
    where spot_id='77000000-0000-4000-8000-000000000003'),
  array['--','99'],'sightings: only the anonymized one past 180 days');
select is((select count(*)::int from spot_votes v join votes_before b on b.id=v.id
    where to_jsonb(v)-'ip_hash'-'device_hash'<>b.row),0,'every other vote column stays as it was');
select is((select count(*) from spot_rider_events),(select n from history_before),'clearing writes no vote history');
select is(anonymized_hashes_clear(),'{"spot_votes":0,"report_identities":0,"rider_sightings":0}'::jsonb,
  'running it again changes nothing');
select is(current_setting('app.hash_clear',true),'','the clearing flag is reset afterwards');

-- 新寫入不能沒有雜湊：只有清除排程能設成 null。
select throws_ok($$insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
    values('77000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000007','still_there',true,1,null,null)$$,
  '23502','trusted identity hashes are required','a new vote must carry its hashes');
select throws_ok($$insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash,anonymized_at)
    values('77000000-0000-4000-8000-000000000001',null,'still_there',true,1,null,null,now()-interval '1 year')$$,
  '23502','trusted identity hashes are required','even one posing as an anonymized vote');
select throws_ok($$insert into report_identities values('77000000-0000-4000-8000-000000000001',null,null)$$,
  '23502',null,'a new reported spot must carry its hashes');
select throws_ok($$insert into rider_sightings(user_id,spot_id,kind,level,vehicle,ip_hash,device_hash)
    values('10000000-0000-4000-8000-000000000002','77000000-0000-4000-8000-000000000003','level',1,'scooter',null,null)$$,
  '23502','trusted identity hashes are required','a new sighting must carry its hashes');
select throws_ok($$update spot_votes set ip_hash=null,device_hash=null where user_id='10000000-0000-4000-8000-000000000002'
    and spot_id='77000000-0000-4000-8000-000000000003'$$,
  '23502','trusted identity hashes are required','an update cannot clear the hashes outside the job');
select set_config('app.hash_clear','on',true);
select throws_ok($$update spot_votes set ip_hash=null,device_hash=null where user_id='10000000-0000-4000-8000-000000000002'
    and spot_id='77000000-0000-4000-8000-000000000003'$$,
  '23514',null,'even with the flag, a live account''s vote keeps its hashes');
select throws_ok($$update spot_votes set ip_hash=null where ip_hash=repeat('6',64)$$,
  '23514',null,'and both hashes go together');
select set_config('app.hash_clear','',true);
select throws_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',null,null,
    '{"action":"vote","spot_id":"77000000-0000-4000-8000-000000000003","vote":"still_there"}')$$,
  '22023','missing trusted identity','the report path refuses a missing identity');
select ok(not has_table_privilege('authenticated','public.spot_votes','insert')
  and not has_table_privilege('authenticated','public.report_identities','insert')
  and not has_table_privilege('authenticated','public.spot_votes','update'),'riders cannot write votes directly');

-- 計票：清除過的票不算任何網路，也不會被併成同一個網路。
insert into community_spots(id,user_id,name,lat,lng,city,space_type) values
  ('77000000-0000-4000-8000-000000000010',null,'確認數',25.091,121.611,'臺北市','offStreet'),
  ('77000000-0000-4000-8000-000000000011',null,'負向分數',25.092,121.612,'臺北市','offStreet');
insert into report_identities values
  ('77000000-0000-4000-8000-000000000010',repeat('e',64),repeat('e',64)),
  ('77000000-0000-4000-8000-000000000011',repeat('e',64),repeat('e',64));
update community_spots set status='confirmed' where id='77000000-0000-4000-8000-000000000011';
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash,created_at,anonymized_at)
select s,null,v,true,1,repeat(h,64),repeat(h,64),now()-interval '300 days',now()-interval '200 days'
from (values ('77000000-0000-4000-8000-000000000010'::uuid,'still_there','a'),('77000000-0000-4000-8000-000000000010','still_there','b'),
  ('77000000-0000-4000-8000-000000000011','gone','a'),('77000000-0000-4000-8000-000000000011','gone','b'),
  ('77000000-0000-4000-8000-000000000011','gone','c'),('77000000-0000-4000-8000-000000000011','gone','d')) x(s,v,h);
select is((anonymized_hashes_clear()->>'spot_votes')::int,6,'six old votes on the two spots cleared');
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('1',64),repeat('1',64),
  '{"action":"vote","spot_id":"77000000-0000-4000-8000-000000000010","vote":"still_there"}')$$,'a live confirmation');
select is((select status from community_spots where id='77000000-0000-4000-8000-000000000010'),'pending',
  'two cleared confirmations and one live one: the cleared ones count as no network');
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('2',64),repeat('2',64),
  '{"action":"vote","spot_id":"77000000-0000-4000-8000-000000000010","vote":"still_there"}')$$,'a second live confirmation');
select is((select status from community_spots where id='77000000-0000-4000-8000-000000000010'),'confirmed',
  'two live networks still confirm next to cleared votes');
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000001',repeat('1',64),repeat('1',64),
  '{"action":"vote","spot_id":"77000000-0000-4000-8000-000000000011","vote":"gone"}')$$,'a live "gone"');
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('2',64),repeat('2',64),
  '{"action":"vote","spot_id":"77000000-0000-4000-8000-000000000011","vote":"gone"}')$$,'a second live "gone"');
select ok(not exists(select 1 from moderation_queue where source_id='77000000-0000-4000-8000-000000000011'
    and reason='加權負向回報達門檻'),
  'four cleared "gone" votes add nothing: two live ones stay below the threshold of 3 (merged they would reach it)');
select lives_ok($$select public.apply_report('10000000-0000-4000-8000-000000000006',repeat('3',64),repeat('3',64),
  '{"action":"vote","spot_id":"77000000-0000-4000-8000-000000000011","vote":"gone"}')$$,'a third live "gone"');
select ok(exists(select 1 from moderation_queue where source_id='77000000-0000-4000-8000-000000000011'
    and reason='加權負向回報達門檻'),'three live networks still reach it');

-- ===== 3. 稽核 2 年去識別化 =====
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at) values
  ('10000000-0000-4000-8000-000000000003','ban_user','auth.users','10000000-0000-4000-8000-000000000002',
    '{"banned_until":null}','{"banned_until":"2024-01-01T00:00:00+00:00","duration":"7d"}','洗版',now()-interval '3 years'),
  ('10000000-0000-4000-8000-000000000003','resolve_report','moderation_queue','78000000-0000-4000-8000-000000000001',
    jsonb_build_object('report',jsonb_build_object('id','78000000-0000-4000-8000-000000000001','reporter_id','10000000-0000-4000-8000-000000000002',
        'note','名稱錯了','resolved_by','10000000-0000-4000-8000-000000000003'),
      'spot',jsonb_build_object('name','某停車場','contributor_name','小明','deleted_by',null)),
    jsonb_build_object('status','accepted','spot',jsonb_build_object('name','某停車場','contributor_name','')),
    '',now()-interval '2 years 1 day'),
  ('10000000-0000-4000-8000-000000000003','promote_spot','community_spots','77000000-0000-4000-8000-000000000003',
    jsonb_build_object('id','77000000-0000-4000-8000-000000000003','user_id','10000000-0000-4000-8000-000000000006',
      'parking_zones',jsonb_build_array(jsonb_build_object('name','A 區','email','x@example.test'))),
    jsonb_build_object('official',jsonb_build_object('id','79000000-0000-4000-8000-000000000001')),'',now()-interval '30 months'),
  ('10000000-0000-4000-8000-000000000003','upsert_city_rule','city_rules','臺北市:scooter',
    '{"fee_note":"a"}','{"fee_note":"b"}','',now()-interval '3 years'),
  ('10000000-0000-4000-8000-000000000003','ban_user','auth.users','10000000-0000-4000-8000-000000000002',
    '{"banned_until":null}','{"banned_until":"2026-01-01T00:00:00+00:00"}','',now()-interval '23 months');
create temporary table audit_before on commit drop as select * from admin_audit_log;
create temporary table due on commit drop as
  select id from admin_audit_log where created_at<now()-interval '2 years' and deidentified_at is null;
create temporary table recent on commit drop as
  select id from admin_audit_log where action='ban_user' and created_at>now()-interval '2 years';

-- 例外只放行去識別化本身。
select throws_ok($$update admin_audit_log set note='x'$$,'42501','audit log entries cannot be changed',
  'other edits are still refused');
select throws_ok($$delete from admin_audit_log$$,'42501','audit log entries cannot be changed','entries still cannot be deleted');
select throws_ok($$truncate admin_audit_log$$,'42501','audit log entries cannot be changed','nor truncated');
select throws_ok($$update admin_audit_log set target_id='deidentified',deidentified_at=now()
    where action='ban_user' and created_at<now()-interval '2 years'$$,
  '42501','audit log entries cannot be changed','the exact de-identification without the job''s flag is refused');
set local role service_role;
select throws_ok($$update public.admin_audit_log set target_id='deidentified',deidentified_at=now()
    where action='ban_user' and created_at<now()-interval '2 years'$$,
  '42501',null,'so is the service role');
reset role;
select set_config('app.audit_deidentify','on',true);
select throws_ok($$update admin_audit_log set target_id='deidentified',note='',deidentified_at=now()
    where action='ban_user' and created_at<now()-interval '2 years'$$,
  '42501','audit log entries cannot be changed','with the flag, changing anything else is refused');
select throws_ok($$update admin_audit_log set target_id='deidentified',deidentified_at=now()
    where id in (select id from recent)$$,
  '42501','audit log entries cannot be changed','with the flag, an entry younger than 2 years is refused');
select throws_ok($$update admin_audit_log set target_id='10000000-0000-4000-8000-000000000005',deidentified_at=now()
    where action='ban_user' and created_at<now()-interval '2 years'$$,
  '42501','audit log entries cannot be changed','with the flag, any value but the de-identified one is refused');
select set_config('app.audit_deidentify','',true);

select is(admin_audit_deidentify(),(select count(*)::int from due),'de-identifies every entry older than 2 years');
select is((select target_id from admin_audit_log where action='ban_user' and created_at<now()-interval '2 years'),
  'deidentified','a user target loses its uid');
select is((select actor::text||'|'||after::text||'|'||note from admin_audit_log where action='ban_user' and created_at<now()-interval '2 years'),
  '10000000-0000-4000-8000-000000000003|{"duration": "7d", "banned_until": "2024-01-01T00:00:00+00:00"}|洗版',
  'the admin, what happened and the note stay');
select is((select before from admin_audit_log where action='resolve_report' and target_id='78000000-0000-4000-8000-000000000001'),
  jsonb_build_object('report',jsonb_build_object('id','78000000-0000-4000-8000-000000000001','note','名稱錯了',
      'resolved_by','10000000-0000-4000-8000-000000000003'),
    'spot',jsonb_build_object('name','某停車場','contributor_name','（已去識別化）','deleted_by',null)),
  'a report snapshot loses its reporter; a contributor name is replaced; the deciding admin stays');
select is((select after from admin_audit_log where action='resolve_report' and target_id='78000000-0000-4000-8000-000000000001'),
  '{"status":"accepted","spot":{"name":"某停車場","contributor_name":""}}'::jsonb,'an empty name stays empty');
select is((select before from admin_audit_log where action='promote_spot' and target_id='77000000-0000-4000-8000-000000000003'),
  '{"id":"77000000-0000-4000-8000-000000000003","parking_zones":[{"name":"A 區"}]}'::jsonb,
  'personal keys go at any depth; a spot''s own target id stays');
select is((select count(*)::int from admin_audit_log a join audit_before b on b.id=a.id
    where a.action='upsert_city_rule' and (to_jsonb(a)-'deidentified_at')=(to_jsonb(b)-'deidentified_at')
      and a.deidentified_at is not null),1,'an entry without personal data is only marked');
select is((select count(*)::int from admin_audit_log a join audit_before b on b.id=a.id
    where a.id in (select id from recent) and to_jsonb(a)=to_jsonb(b)),1,'an entry younger than 2 years is untouched');
select is((select count(*)::int from admin_audit_log a join audit_before b on b.id=a.id
    where a.id not in (select id from due) and to_jsonb(a)<>to_jsonb(b)),0,'nothing else changed');
select is((select actor::text||'|'||target_table||'|'||(after->>'entries')||'|'||(after->>'changed')
    from admin_audit_log where action='deidentify_audit_log'),
  '00000000-0000-0000-0000-0000000000de|admin_audit_log|'||(select count(*) from due)||'|3',
  'the de-identification is itself audited, counting the entries it changed');
select set_config('app.audit_deidentify','on',true);
select throws_ok($$update admin_audit_log set deidentified_at=now() where id in (select id from due)$$,
  '42501','audit log entries cannot be changed','a de-identified entry cannot be changed again');
select set_config('app.audit_deidentify','',true);
select is(admin_audit_deidentify(),0,'running it again changes nothing');
select is((select count(*)::int from admin_audit_log where action='deidentify_audit_log'),1,'and audits nothing');

-- ===== 4. 每日排程 =====
select is((select array_agg(k order by k) from jsonb_object_keys(account_data_retention()) k),
  array['anonymized_hashes','audit_log','support_requests','usage_events'],'the daily job runs every step');

select * from finish();
rollback;
