-- 內容不當檢舉（#280 第 2 層；202611021100_content_reports.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.flag(n integer,spot text,target text,note text default '',ip text default 'r') returns jsonb language sql as $$
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(ip,64),
  jsonb_build_object('action','flag','source_id',spot,'reason','內容不當','field','inappropriate',
    'proposed',jsonb_build_object('target',target),'note',note,'evidence_url','https://example.test/x'));
$$;

update auth.users set raw_user_meta_data='{"display_name":"阿明"}' where id=pg_temp.uid(1);
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note,entrance_note)
values('79000000-0000-4000-8000-000000000001',pg_temp.uid(1),'被檢舉的點',23.801,120.801,'雲林縣','freeMotorcycle',true,false,'pending','備註原文','入口原文'),
  ('79000000-0000-4000-8000-000000000002',pg_temp.uid(1),'隱藏的點',23.802,120.802,'雲林縣','freeMotorcycle',true,false,'hidden','','');
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,source,source_name)
values('79000000-0000-4000-8000-000000000003',pg_temp.uid(5),'匯入的點',23.803,120.803,'雲林縣','freeMotorcycle',true,false,'pending','import','社群回報整理');
delete from rate_limit_events;

-- ===== 成功、快照、只留 target =====
select is(pg_temp.flag(2,'79000000-0000-4000-8000-000000000001','rider_name','名字裡有辱罵字眼。')->'accepted','true'::jsonb,
  'a report is accepted');
create temporary table first_report as select id from moderation_queue
  where source_id='79000000-0000-4000-8000-000000000001' and reporter_id=pg_temp.uid(2) and field='inappropriate';
select is((select count(*)::int from first_report),1,'one report is stored');
grant select on first_report to service_role;
select is((select proposed from moderation_queue where id=(select id from first_report)),'{"target":"rider_name"}'::jsonb,
  'proposed keeps only the target');
select is((select base_spot->>'contributor_name'||'|'||(base_spot->>'name')||'|'||(base_spot->>'note')||'|'||(base_spot->>'entrance_note')
  from moderation_queue where id=(select id from first_report)),'阿明|被檢舉的點|備註原文|入口原文',
  'the server keeps the name, texts and contributor as they were');
select is((select evidence_url from moderation_queue where id=(select id from first_report)),null,'no client link is kept');
select is((select reporter_id from moderation_queue where id=(select id from first_report)),pg_temp.uid(2),'the reporter is recorded');
select ok(exists(select 1 from private.report_notices where queue_id=(select id from first_report) and sent_at is null),
  'a notice waits for report-mail');

-- ===== 去重 =====
select throws_ok($$select pg_temp.flag(2,'79000000-0000-4000-8000-000000000001','text')$$,'P0409','duplicate report',
  'one open report per rider and spot, whatever the target');
select lives_ok($$select pg_temp.flag(3,'79000000-0000-4000-8000-000000000001','rider_name','名字裡有辱罵字眼。','s')$$,
  'another rider with the same summary is not swallowed');
select is((select count(*)::int from moderation_queue where source_id='79000000-0000-4000-8000-000000000001' and field='inappropriate'),2,
  'both reports are open');
update moderation_queue set resolved_at=now(),status='rejected',resolution_kind='abuse' where id=(select id from first_report);
select lives_ok($$select pg_temp.flag(2,'79000000-0000-4000-8000-000000000001','spot_name')$$,'after a decision the rider may report again');
select is((select count(*)::int from rate_limit_events where user_id=pg_temp.uid(2)),2,'a duplicate does not use the daily quota');

-- ===== 誰、哪個點可以檢舉 =====
select throws_ok($$select pg_temp.flag(1,'79000000-0000-4000-8000-000000000001','text')$$,'42501','cannot report own spot',
  'nobody reports their own spot');
select throws_ok($$select pg_temp.flag(2,'official:79000000-0000-4000-8000-000000000001','text')$$,'22023',
  'only community spots can be reported','official spots cannot be reported');
select throws_ok($$select pg_temp.flag(2,'79000000-0000-4000-8000-000000000002','text')$$,'22023','spot not found',
  'a spot riders cannot see cannot be reported');
select throws_ok($$select pg_temp.flag(2,gen_random_uuid()::text,'text')$$,'22023','spot not found','nor an unknown one');
select lives_ok($$select pg_temp.flag(2,'79000000-0000-4000-8000-000000000003','spot_name')$$,'an imported spot can be reported');
select throws_ok($$select pg_temp.flag(4,'79000000-0000-4000-8000-000000000003','text')$$,'42501','Google or Apple sign-in required',
  'anonymous accounts cannot report');

-- 匿名化的點（投稿者已刪帳號）可以檢舉。
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('79000000-0000-4000-8000-000000000004',null,'匿名化的點',23.804,120.804,'雲林縣','freeMotorcycle',true,false,'pending');
select lives_ok($$select pg_temp.flag(6,'79000000-0000-4000-8000-000000000004','text')$$,'an anonymized spot can be reported');

-- ===== target 與附註（伺服器自己也檢查） =====
select throws_ok($$select pg_temp.flag(7,'79000000-0000-4000-8000-000000000003','photo')$$,'22023','invalid report target','an unknown target');
select throws_ok($$select public.apply_report(pg_temp.uid(7),repeat('t',64),repeat('t',64),
  '{"action":"flag","source_id":"79000000-0000-4000-8000-000000000003","reason":"x","field":"inappropriate"}')$$,
  '22023','invalid report target','no target');
select throws_ok($$select public.apply_report(pg_temp.uid(7),repeat('t',64),repeat('t',64),
  '{"action":"flag","source_id":"79000000-0000-4000-8000-000000000003","reason":"x","field":"inappropriate","proposed":{"target":"text","name":"改名"}}')$$,
  '22023','invalid report target','a target beside a value to apply');
select throws_ok($$select pg_temp.flag(7,'79000000-0000-4000-8000-000000000003','other','   ')$$,'22023','other needs a note','other needs a note');
select throws_ok(format('select pg_temp.flag(7,%L,%L,%L)','79000000-0000-4000-8000-000000000003','other',E'\n\u3000 '),'22023','other needs a note',
  'line breaks and full-width spaces are blank too');
select throws_ok($$select public.apply_report(pg_temp.uid(7),repeat('t',64),repeat('t',64),
  '{"action":"flag","source_id":"79000000-0000-4000-8000-000000000003","reason":"x","field":"inappropriate","proposed":{}}')$$,
  '22023','invalid report target','an empty proposed');
select throws_ok($$select public.apply_report(pg_temp.uid(7),repeat('t',64),repeat('t',64),
  '{"action":"flag","source_id":"79000000-0000-4000-8000-000000000003","reason":"x","field":"inappropriate","proposed":{"target":null}}')$$,
  '22023','invalid report target','a null target');
select lives_ok($$select pg_temp.flag(7,'79000000-0000-4000-8000-000000000003','other','在推銷東西')$$,'other with a note');

-- 其他回報不受影響：相同摘要的一般建議仍以 (source_id,reason) 去重。
select lives_ok($$select public.apply_report(pg_temp.uid(2),repeat('u',64),repeat('u',64),
  '{"action":"flag","source_id":"79000000-0000-4000-8000-000000000003","reason":"名稱錯了","field":"name","proposed":{"name":"新名稱"}}')$$,
  'an ordinary suggestion still works');
select lives_ok($$select public.apply_report(pg_temp.uid(3),repeat('v',64),repeat('v',64),
  '{"action":"flag","source_id":"79000000-0000-4000-8000-000000000003","reason":"名稱錯了","field":"name","proposed":{"name":"新名稱"}}')$$,
  'and its duplicate is still swallowed quietly');
select is((select count(*)::int from moderation_queue where source_id='79000000-0000-4000-8000-000000000003' and reason='名稱錯了'),1,
  'as before');

-- ===== 通知 =====
set local role service_role;
select ok((select count(*) from public.report_mail_pending(200))>=5,'report-mail reads the pending ids');
select lives_ok(format('select public.report_mail_sent(%L)',(select id from first_report)),'and marks one sent');
select ok(not exists(select 1 from public.report_mail_pending(200) p where p.id=(select id from first_report)),'a sent notice is not read again');
reset role;
select ok(not has_function_privilege('authenticated','public.report_mail_pending(integer)','execute')
  and not has_function_privilege('anon','public.report_mail_sent(uuid)','execute')
  and not has_function_privilege('authenticated','public.report_mail_tick()','execute'),'riders cannot read or mark notices');
select is(public.report_mail_tick(),null,'without the vault secret the tick does nothing');
select is((select schedule from cron.job where jobname='report-mail'),'*/5 * * * *','report-mail runs every 5 minutes');

select * from finish();
rollback;
