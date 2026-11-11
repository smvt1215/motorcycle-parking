-- 有處理中內容檢舉的點不能升級成官方點；已搬到官方點的內容檢舉可以讀、可以結案
-- （#326 第 3 項；202611111600_promote_content_reports.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.flag(n integer,spot text,target text,ip text) returns jsonb language sql as $$
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(ip,64),
  jsonb_build_object('action','flag','source_id',spot,'reason','內容不當','field','inappropriate',
    'proposed',jsonb_build_object('target',target),'note','x'));
$$;
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '' end,true);
$$;
create function pg_temp.ver(p text) returns timestamptz language sql stable as $$
select updated_at from public.community_spots where id=p::uuid;
$$;
create function pg_temp.promote(p text) returns jsonb language sql as $$
select public.admin_promote_spot(p,
  '{"source_name":"臺北市政府","source_url":"https://example.test/p","effective_date":"2026-10-31","scooter_allowed":true,"heavy_allowed":false}',
  pg_temp.ver(p));
$$;
grant execute on function pg_temp.ver(text),pg_temp.promote(text) to authenticated;

update auth.users set created_at=now()-interval '30 days' where id in (pg_temp.uid(2),pg_temp.uid(3),pg_temp.uid(6));
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note,entrance_note,parking_guide,special_rules)
values('7d000000-0000-4000-8000-000000000001',pg_temp.uid(1),'原本的點名',23.611,120.611,'雲林縣','freeMotorcycle',true,false,'pending','備註原文','入口原文','停哪裡原文','規則原文'),
  ('7d000000-0000-4000-8000-000000000002',pg_temp.uid(1),'第二點',23.612,120.612,'雲林縣','freeMotorcycle',true,false,'pending','二備註','','',''),
  ('7d000000-0000-4000-8000-000000000003',pg_temp.uid(1),'第三點',23.613,120.613,'雲林縣','freeMotorcycle',true,false,'pending','三備註','','',''),
  ('7d000000-0000-4000-8000-000000000004',pg_temp.uid(1),'第四點',23.614,120.614,'雲林縣','freeMotorcycle',true,false,'pending','四備註','','','');
create temporary table ids(k text primary key,id text);
grant select on ids to authenticated;
delete from rate_limit_events;

-- ===== 遮蔽中（held）的點不能升級 =====
select pg_temp.flag(2,'7d000000-0000-4000-8000-000000000001','impersonation','a');
insert into ids select 'held',id::text from moderation_queue where reporter_id=pg_temp.uid(2) and field='inappropriate';
select is((select held from moderation_queue where id=(select id::uuid from ids where k='held')),true,'the report hides at once');
select is((select name from community_spots where id='7d000000-0000-4000-8000-000000000001'),'名稱審核中','the row holds the placeholder');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select pg_temp.promote('7d000000-0000-4000-8000-000000000001')$$,
  '55000','open content reports block promotion','a held spot is not promoted');
reset role;
select is((select status from community_spots where id='7d000000-0000-4000-8000-000000000001'),'pending','the spot stays as it was');
select is((select count(*)::integer from official_heavy_spots where name in ('名稱審核中','原本的點名')),0,'no official copy');
select is((select source_id from moderation_queue where id=(select id::uuid from ids where k='held')),'7d000000-0000-4000-8000-000000000001',
  'the report stays on the community spot');

-- ===== 沒有觸發遮蔽（held=false）也不能升級 =====
select pg_temp.flag(3,'7d000000-0000-4000-8000-000000000002','other','b');
select is((select held from moderation_queue where reporter_id=pg_temp.uid(3) and source_id='7d000000-0000-4000-8000-000000000002'),false,
  'other does not hide');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select pg_temp.promote('7d000000-0000-4000-8000-000000000002')$$,
  '55000','open content reports block promotion','an open report that hides nothing still blocks');
reset role;

-- ===== 結案後可以升級，官方點拿到原文 =====
select pg_temp.act('admin');
set local role authenticated;
select is((admin_v1.resolve_content_report((select id from ids where k='held'),'restore',
  pg_temp.ver('7d000000-0000-4000-8000-000000000001'),null,'abuse','檢舉不成立'))->>'status','rejected','the report is rejected');
create temporary table promoted as select pg_temp.promote('7d000000-0000-4000-8000-000000000001') as r;
select is((select r->>'name'||'|'||(r->>'note')||'|'||(r->>'entrance_note')||'|'||(r->>'parking_guide')||'|'||(r->>'special_rules') from promoted),
  '原本的點名|備註原文|入口原文|停哪裡原文|規則原文','the official spot gets the original');
reset role;
select is((select status from community_spots where id='7d000000-0000-4000-8000-000000000001'),'hidden','the community row is hidden');

-- ===== 之前已搬到官方點的內容檢舉（舊版升級留下的 'official:<id>'） =====
-- 第三點：遮蔽中的 text 檢舉；第四點：沒有遮蔽的 other 檢舉。照舊版 admin_promote_spot
-- 的做法把 source_id 改成官方點。
select pg_temp.flag(2,'7d000000-0000-4000-8000-000000000003','text','c');
select pg_temp.flag(6,'7d000000-0000-4000-8000-000000000003','text','d');
select pg_temp.flag(3,'7d000000-0000-4000-8000-000000000004','other','e');
insert into ids select 'legacy_held',(array_agg(id::text order by created_at))[1] from moderation_queue
  where source_id='7d000000-0000-4000-8000-000000000003' and field='inappropriate';
insert into ids select 'legacy_open',id::text from moderation_queue where source_id='7d000000-0000-4000-8000-000000000004' and field='inappropriate';
select is((select count(*)::integer from moderation_queue where source_id='7d000000-0000-4000-8000-000000000003' and held),2,'both text reports hide');
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date)
  values('舊升級的官方點',23.613,120.613,'雲林縣','https://example.test/o','臺北市政府','2026-10-31') returning id)
insert into ids select 'official3','official:'||id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date)
  values('舊升級的官方點四',23.614,120.614,'雲林縣','https://example.test/o','臺北市政府','2026-10-31') returning id)
insert into ids select 'official4','official:'||id from s;
update moderation_queue set source_id=(select id from ids where k='official3')
  where source_id='7d000000-0000-4000-8000-000000000003' and status='pending';
update moderation_queue set source_id=(select id from ids where k='official4')
  where source_id='7d000000-0000-4000-8000-000000000004' and status='pending';

select pg_temp.act('admin');
set local role authenticated;
create temporary table detail as select admin_v1.content_report((select id from ids where k='legacy_held')) as d;
select is((select d->>'spot_id' from detail),(select id from ids where k='official3'),'a report on an official spot is read');
select is((select (d->>'spot_deleted')::boolean from detail),true,'its spot is not a community spot');
select is((select d->'current'->>'name' from detail),null,'so current has no content');
select is((select d->'content_held' from detail),'[]'::jsonb,'and nothing held');
select is((select jsonb_array_length(d->'reports') from detail),2,'the group is still read');
select ok(admin_v1.content_report((select id from ids where k='legacy_open')) ? 'snapshot','an open one is read too');

select throws_ok(format('select admin_v1.resolve_content_report(%L,''edit'',now(),''{"note":"改"}'')',(select id from ids where k='legacy_open')),
  'PT404','content_report.spot_not_found','an official spot is not edited here');
create temporary table res as select admin_v1.resolve_content_report((select id from ids where k='legacy_open'),'restore',now(),null,'wrong','') as r;
select is((select r->>'status'||'|'||(r->>'resolved_count') from res),'rejected|1','an open report on an official spot can be closed');
select is((select r->'spot' from res),jsonb_build_object('id',(select id from ids where k='official4')),'spot is only its id');

-- 排程動作（report_*）經 resolve_content_report：試跑不丟錯，到期後執行。
-- timed_cases 的 version：點位不在社群表時是 null。
reset role;
select is((select version from private.timed_case_rows() where id=(select id from ids where k='legacy_held')),null,
  'the case has no spot version');
set local role authenticated;
create temporary table sched as select admin_v1.schedule_case_action((select id from ids where k='legacy_held'),'report_keep','{"note":"移除"}',null) as j;
select ok((select j ? 'action_id' from sched),'a report_keep on an official spot is scheduled');
reset role;
update private.case_actions set run_at=now()-interval '1 second' where id=(select (j->>'action_id')::uuid from sched);
select is((select public.run_due_case_actions()->'done'),'1'::jsonb,'and runs when due');
select is((select string_agg(status,',') from moderation_queue where source_id=(select id from ids where k='official3')),
  'accepted,accepted','closing the whole group');
-- 刪除時要有處理中的遮蔽檢舉可結案：再搬一筆過去。
select pg_temp.flag(3,'7d000000-0000-4000-8000-000000000003','spot_name','g');
select is((select held from moderation_queue where reporter_id=pg_temp.uid(3) and source_id='7d000000-0000-4000-8000-000000000003'),true,
  'a report on the hidden row still hides');
update moderation_queue set source_id=(select id from ids where k='official3')
  where source_id='7d000000-0000-4000-8000-000000000003' and status='pending';

-- 刪除官方點：自動結案遮蔽中的檢舉，不再整筆回滾。
select pg_temp.act('admin');
set local role authenticated;
select lives_ok(format('select admin_set_spot_hidden(%L,true)',(select id from ids where k='official3')),
  'an official spot with a held report is deleted');
reset role;
select ok((select deleted_at is not null from official_heavy_spots where 'official:'||id=(select id from ids where k='official3')),'it is deleted');
select is((select status||'|'||resolution_note from moderation_queue where source_id=(select id from ids where k='official3')
  and reporter_id=pg_temp.uid(3)),'rejected|點位已刪除','its open report is closed');

-- 舊審核頁結案（直接更新）也不丟錯。
select pg_temp.flag(2,'7d000000-0000-4000-8000-000000000002','text','f');
update moderation_queue set source_id=(select id from ids where k='official4')
  where source_id='7d000000-0000-4000-8000-000000000002' and reporter_id=pg_temp.uid(2) and held;
select lives_ok($$update moderation_queue set status='accepted',resolved_at=now()
  where source_id=(select id from ids where k='official4') and resolved_at is null$$,'any close of a held report on an official spot works');

select * from finish();
rollback;
