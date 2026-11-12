-- 檢舉後立即暫時隱藏（#280 第 3 層；202611021300_content_holds.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.flag(n integer,spot text,target text,ip text default 'r',note text default 'x') returns jsonb language sql as $$
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(ip,64),
  jsonb_build_object('action','flag','source_id',spot,'reason','內容不當','field','inappropriate',
    'proposed',jsonb_build_object('target',target),'note',note));
$$;
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'owner' then '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1","app_metadata":{"role":"user"}}'
  when 'other' then '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1","app_metadata":{"role":"user"}}'
  else '' end,true);
$$;
create function pg_temp.spot(p uuid) returns public_spots language sql as $$ select * from public.public_spots where id=p $$;
grant execute on function pg_temp.spot(uuid) to anon,authenticated;

update auth.users set raw_user_meta_data='{"display_name":"阿明"}' where id=pg_temp.uid(1);
-- 檢舉者帳號都滿 24 小時。
update auth.users set created_at=now()-interval '30 days' where id in (pg_temp.uid(2),pg_temp.uid(3),pg_temp.uid(6),pg_temp.uid(7));
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note,entrance_note,parking_guide,special_rules)
values('7b000000-0000-4000-8000-000000000001',pg_temp.uid(1),'原本的點名',23.601,120.601,'雲林縣','freeMotorcycle',true,false,'pending','備註原文','入口原文','停哪裡原文','規則原文'),
  ('7b000000-0000-4000-8000-000000000002',pg_temp.uid(1),'第二點',23.602,120.602,'雲林縣','freeMotorcycle',true,false,'pending','二備註','','','');
create temporary table ids(k text primary key,id uuid);
grant select on ids to anon,authenticated,service_role;
delete from rate_limit_events;

-- ===== rider_name：只遮車友名稱，代號照回 =====
select pg_temp.flag(2,'7b000000-0000-4000-8000-000000000001','rider_name','a');
insert into ids select 'rider',id from moderation_queue where reporter_id=pg_temp.uid(2) and field='inappropriate';
select is((select held from moderation_queue where id=(select id from ids where k='rider')),true,'the report hides at once');
select is((select content_held from community_spots where id='7b000000-0000-4000-8000-000000000001'),array['rider_name'],'content_held says what');
set local role anon;
select pg_temp.act('');
select is((pg_temp.spot('7b000000-0000-4000-8000-000000000001')).contributor_name,'','others see no rider name');
select matches((pg_temp.spot('7b000000-0000-4000-8000-000000000001')).contributor_handle,'^[0-9a-f]{32}$','the handle is still served');
select is((pg_temp.spot('7b000000-0000-4000-8000-000000000001')).name,'原本的點名','the spot name is not hidden');
select is((pg_temp.spot('7b000000-0000-4000-8000-000000000001')).content_held,array['rider_name'],'content_held is public');
reset role;
select is((select contributor_name from community_spots where id='7b000000-0000-4000-8000-000000000001'),'',
  'the table itself holds no name, so no read path shows it');
select is((select base_spot->>'contributor_name' from moderation_queue where id=(select id from ids where k='rider')),'阿明',
  'the report keeps the name as it was');
set local role authenticated;
select pg_temp.act('owner');
select is((pg_temp.spot('7b000000-0000-4000-8000-000000000001')).contributor_name,'阿明','the contributor sees their own name');
select is((pg_temp.spot('7b000000-0000-4000-8000-000000000001')).content_held,array['rider_name'],'and that it is held');
reset role;

-- ===== impersonation：名稱、點名、文字全遮 =====
select pg_temp.flag(3,'7b000000-0000-4000-8000-000000000001','impersonation','b');
insert into ids select 'imp',id from moderation_queue where reporter_id=pg_temp.uid(3) and field='inappropriate';
select is((select content_held from community_spots where id='7b000000-0000-4000-8000-000000000001'),array['rider_name','spot_name','text'],
  'impersonation hides all three');
select is((select name||'|'||note||'|'||entrance_note||'|'||parking_guide||'|'||special_rules from community_spots where id='7b000000-0000-4000-8000-000000000001'),
  '名稱審核中||||','the name becomes 名稱審核中 and the texts are emptied');
select is((select (lat,space_type,scooter_allowed)::text from community_spots where id='7b000000-0000-4000-8000-000000000001'),
  '(23.601,freeMotorcycle,t)','the parking facts stay');
select is((select jsonb_agg(e) from jsonb_array_elements(public.spot_history('7b000000-0000-4000-8000-000000000001')) e
  where e::text like '%原本的點名%' or e::text like '%備註原文%'),null,'history shows no held text');
set local role authenticated;
select pg_temp.act('owner');
select is((select name||'|'||note||'|'||entrance_note from public_spots where id='7b000000-0000-4000-8000-000000000001'),
  '原本的點名|備註原文|入口原文','the contributor sees the original');
select pg_temp.act('other');
select is((select name||'|'||note from public_spots where id='7b000000-0000-4000-8000-000000000001'),'名稱審核中|','others do not');
select is(public.spot_held_original('7b000000-0000-4000-8000-000000000001'),null,'nor through the function');
reset role;

-- 遮蔽期間投稿者改名：新值收進 holds，點位上維持替代內容。
select set_config('app.owner_update','7b000000-0000-4000-8000-000000000001',true);
update community_spots set name='投稿者新名',note='新備註' where id='7b000000-0000-4000-8000-000000000001';
select is((select name||'|'||note from community_spots where id='7b000000-0000-4000-8000-000000000001'),'名稱審核中|','an edit stays hidden');
select is((select original->>'name' from private.content_holds where spot_id='7b000000-0000-4000-8000-000000000001' and part='spot_name'),
  '投稿者新名','and waits for review');

-- ===== other：不立即隱藏 =====
select pg_temp.flag(2,'7b000000-0000-4000-8000-000000000002','other','c');
select is((select held from moderation_queue where reporter_id=pg_temp.uid(2) and source_id='7b000000-0000-4000-8000-000000000002'),false,
  'other only waits for review');
select is((select content_held from community_spots where id='7b000000-0000-4000-8000-000000000002'),'{}'::text[],'nothing is hidden');

-- ===== 管理員處理 =====
set local role authenticated;
select pg_temp.act('admin');
create temporary table detail as select admin_v1.content_report((select id::text from ids where k='imp')) as d;
select is((select d->>'target' from detail),'impersonation','the detail names the target');
select is((select d->'snapshot'->>'name' from detail),'原本的點名','the snapshot is the original');
select is((select d->'current'->>'name' from detail),'投稿者新名','current is the held value, not the placeholder');
select is((select jsonb_array_length(d->'reports') from detail),1,'one report in the group');
select is((select d->'editable_fields' from detail),'["name","note","entrance_note","parking_guide","special_rules"]'::jsonb,'editable fields');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''restore'',%L)',(select id from ids where k='imp'),'2000-01-01T00:00:00Z'),
  'PT400','content_report.reason_required','a restore needs a reason');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''restore'',%L,null,''abuse'')',(select id from ids where k='imp'),'2000-01-01T00:00:00Z'),
  'PT409','content_report.stale','a stale spot is refused');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''edit'',%L,''{"lat":1}'')',(select id from ids where k='imp'),
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000001')),
  'PT400','content_report.invalid_patch','only the five text fields');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''edit'',%L,''{"name":" "}'')',(select id from ids where k='imp'),
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000001')),
  'PT400','content_report.invalid_patch','no empty strings');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''keep'',%L)',(select id from ids where k='imp'),
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000001')),
  'PT400','content_report.name_required','keeping a hidden spot name needs a new one');

-- 還原 impersonation：名稱與文字放回，但 rider_name 仍被另一筆檢舉遮著。
create temporary table res as select admin_v1.resolve_content_report((select id::text from ids where k='imp'),'restore',
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000001'),null,'abuse','檢舉不成立') as r;
select is((select r->>'status'||'|'||(r->>'resolved_count') from res),'rejected|1','restore rejects the group');
reset role;
select is((select name||'|'||note||'|'||entrance_note from community_spots where id='7b000000-0000-4000-8000-000000000001'),
  '投稿者新名|新備註|入口原文','the held values come back');
select is((select content_held from community_spots where id='7b000000-0000-4000-8000-000000000001'),array['rider_name'],
  'the rider name stays held by the other report');
select is((select contributor_name from community_spots where id='7b000000-0000-4000-8000-000000000001'),'','still no name');
select ok(exists(select 1 from admin_audit_log where action='resolve_content_report' and target_id='7b000000-0000-4000-8000-000000000001'),
  'the decision is audited');

-- 駁回後內容改過（投稿者改了名），再檢舉同樣部分：照常立即隱藏。
select pg_temp.flag(6,'7b000000-0000-4000-8000-000000000001','spot_name','d');
select is((select held||'|'||array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(6)),
  'true|','content changed since the rejection hides again');
update moderation_queue set status='rejected',resolution_kind='duplicate',resolved_at=now() where reporter_id=pg_temp.uid(6);

-- 維持隱藏或移除：rider_name 永久清除。
set local role authenticated;
select pg_temp.act('admin');
select is((admin_v1.resolve_content_report((select id::text from ids where k='rider'),'keep',
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000001'),null,null,'辱罵'))->>'status','accepted','keep accepts');
reset role;
select is((select content_held from community_spots where id='7b000000-0000-4000-8000-000000000001'),'{}'::text[],'nothing is held any more');
select ok(exists(select 1 from contributor_name_clears where spot_id='7b000000-0000-4000-8000-000000000001'),'the name is cleared for good');
select is((select contributor_name from community_spots where id='7b000000-0000-4000-8000-000000000001'),'','so it stays empty');
select matches(public.spot_contributor_handle('7b000000-0000-4000-8000-000000000001'),'^[0-9a-f]{32}$','and the handle stays');

-- edit：改內容後解除。
select pg_temp.flag(7,'7b000000-0000-4000-8000-000000000002','text','e');
insert into ids select 'text',id from moderation_queue where reporter_id=pg_temp.uid(7);
select is((select note from community_spots where id='7b000000-0000-4000-8000-000000000002'),'','text hides at once');
set local role authenticated;
select pg_temp.act('admin');
select is((admin_v1.resolve_content_report((select id::text from ids where k='text'),'edit',
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000002'),'{"note":"改過的備註"}'))->'spot'->>'note',
  '改過的備註','edit returns the spot as changed');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''restore'',now(),null,''abuse'')',(select id from ids where k='text')),
  'PT409','content_report.already_resolved','a resolved report cannot be resolved again');
reset role;
select is((select note||'|'||cardinality(content_held) from community_spots where id='7b000000-0000-4000-8000-000000000002'),'改過的備註|0',
  'the edit is published and nothing is held');

-- 舊審核頁（admin_resolve_report）不能結案內容檢舉（#326 方案 B）：結案會
-- 經 moderation_inappropriate_resolved 把原文放回。
select pg_temp.flag(3,'7b000000-0000-4000-8000-000000000002','text','f');
insert into ids select 'legacy',id from moderation_queue where reporter_id=pg_temp.uid(3)
  and source_id='7b000000-0000-4000-8000-000000000002';
select is((select note from community_spots where id='7b000000-0000-4000-8000-000000000002'),'','hidden again');
set local role authenticated;
select pg_temp.act('admin');
select throws_ok(format('select admin_resolve_report(%L,''accepted'')',(select id from ids where k='legacy')),
  'P0421','content reports are resolved on the pending cases page','the old page cannot close a content report as is');
select throws_ok(format('select admin_resolve_report(%L,''accepted'',''{"note":"舊頁改的備註"}'')',(select id from ids where k='legacy')),
  'P0421','content reports are resolved on the pending cases page','nor apply an edit to it');
select throws_ok(format('select admin_resolve_report(%L,''rejected'',''{}'',''騎士亂報'',false,''abuse'')',(select id from ids where k='legacy')),
  'P0421','content reports are resolved on the pending cases page','nor reject it');
reset role;
select is((select status||'|'||(resolved_at is null)::text from moderation_queue where id=(select id from ids where k='legacy')),
  'pending|true','the report stays open');
select is((select note||'|'||array_to_string(content_held,',') from community_spots where id='7b000000-0000-4000-8000-000000000002'),
  '|text','and the text stays hidden');
select ok(not exists(select 1 from admin_audit_log where action='resolve_report' and target_id=(select id::text from ids where k='legacy')),
  'nothing is audited for the refused attempts');
-- 其他回報照舊由舊審核頁處理。
insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
values('7b000000-0000-4000-8000-000000000002',pg_temp.uid(2),'名稱錯了','name','{"name":"第二點（改）"}');
set local role authenticated;
select pg_temp.act('admin');
select is((admin_resolve_report((select id from moderation_queue where reporter_id=pg_temp.uid(2)
    and source_id='7b000000-0000-4000-8000-000000000002' and field='name'),'accepted','{"name":"第二點（改）"}'))->>'status',
  'accepted','a report that is not a content report still resolves there');
reset role;
select is((select name||'|'||note||'|'||array_to_string(content_held,',') from community_spots where id='7b000000-0000-4000-8000-000000000002'),
  '第二點（改）||text','the edit lands and the held text stays hidden');
-- 被拒絕的內容檢舉仍由案件頁正常結案，原文照常放回。
set local role authenticated;
select pg_temp.act('admin');
select is((admin_v1.resolve_content_report((select id::text from ids where k='legacy'),'restore',
  (select updated_at from community_spots where id='7b000000-0000-4000-8000-000000000002'),null,'abuse'))->>'status',
  'rejected','the pending cases page still resolves it');
reset role;
select is((select note from community_spots where id='7b000000-0000-4000-8000-000000000002'),'改過的備註','restoring puts the text back');
-- 駁回後內容沒變，再檢舉同樣部分：等人工審核。
select pg_temp.flag(6,'7b000000-0000-4000-8000-000000000002','text','k');
select is((select held||'|'||array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(6)
  and source_id='7b000000-0000-4000-8000-000000000002' and proposed->>'target'='text'),
  'false|hold_skipped_reviewed_content','unchanged reviewed content waits for review');

-- 非管理員不能用。
set local role authenticated;
select pg_temp.act('other');
select throws_ok(format('select admin_v1.content_report(%L)',(select id from ids where k='text')),'PT403','auth.aal2_required','riders cannot read reports');
reset role;

-- ===== 重疊的檢舉：keep 移除的文字不會在另一筆還原時回來 =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note,entrance_note)
values('7d000000-0000-4000-8000-000000000001',pg_temp.uid(1),'重疊點',23.401,120.401,'雲林縣','freeMotorcycle',true,false,'pending','不當備註','入口');
delete from rate_limit_events;
select pg_temp.flag(2,'7d000000-0000-4000-8000-000000000001','text','m');
select pg_temp.flag(7,'7d000000-0000-4000-8000-000000000001','impersonation','n');
set local role authenticated;
select pg_temp.act('admin');
select is((admin_v1.resolve_content_report((select id::text from moderation_queue where reporter_id=pg_temp.uid(2) and source_id='7d000000-0000-4000-8000-000000000001'),
  'keep',(select updated_at from community_spots where id='7d000000-0000-4000-8000-000000000001')))->'spot'->>'note','',
  'keep removes the text even while another report still hides it');
select is((admin_v1.resolve_content_report((select id::text from moderation_queue where reporter_id=pg_temp.uid(7) and source_id='7d000000-0000-4000-8000-000000000001'),
  'restore',(select updated_at from community_spots where id='7d000000-0000-4000-8000-000000000001'),null,'wrong'))->>'status','rejected',
  'the other report is rejected');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''edit'',now(),''{"name":"名稱審核中"}'')',
  (select id from moderation_queue where reporter_id=pg_temp.uid(7) and source_id='7d000000-0000-4000-8000-000000000001')),
  'PT400','content_report.invalid_patch','the placeholder is not a name');
reset role;
select is((select note||'|'||entrance_note||'|'||name||'|'||cardinality(content_held) from community_spots where id='7d000000-0000-4000-8000-000000000001'),
  '||重疊點|0','the removed text stays removed, the rest comes back');

-- ===== 刪除點位：遮蔽保留，復原時重新送審 =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note)
values('7d000000-0000-4000-8000-000000000002',pg_temp.uid(1),'會被刪的點',23.402,120.402,'雲林縣','freeMotorcycle',true,false,'pending','不當');
select pg_temp.flag(2,'7d000000-0000-4000-8000-000000000002','text','o');
update community_spots set status='hidden' where id='7d000000-0000-4000-8000-000000000002';
select is((select status||'|'||resolution_note from moderation_queue where reporter_id=pg_temp.uid(2) and source_id='7d000000-0000-4000-8000-000000000002'),
  'rejected|點位已刪除','deleting closes the report');
select is((select note from community_spots where id='7d000000-0000-4000-8000-000000000002'),'','but the text stays hidden');
update community_spots set status='pending' where id='7d000000-0000-4000-8000-000000000002';
select is((select status from moderation_queue where reporter_id=pg_temp.uid(2) and source_id='7d000000-0000-4000-8000-000000000002'),
  'pending','restoring sends it back for review');
select is((select note||'|'||array_to_string(content_held,',') from community_spots where id='7d000000-0000-4000-8000-000000000002'),'|text',
  'and keeps it hidden');

-- ===== reviewed_content 只在這次的部分都被審過時跳過 =====
select pg_temp.flag(6,'7d000000-0000-4000-8000-000000000001','impersonation','p');
select is((select held from moderation_queue where reporter_id=pg_temp.uid(6) and source_id='7d000000-0000-4000-8000-000000000001'),true,
  'a rejected impersonation report covers it; but the text changed since (removed), so it hides');
-- held 不能由寫入者指定。
insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note,held)
values('7d000000-0000-4000-8000-000000000002',pg_temp.uid(3),'x','inappropriate','{"target":"other"}','x',true);
select is((select held from moderation_queue where reporter_id=pg_temp.uid(3) and source_id='7d000000-0000-4000-8000-000000000002'),false,
  'held is the server''s, never the writer''s');

-- ===== 投稿者硬刪除的點：只能結案 =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note)
values('7d000000-0000-4000-8000-000000000003',pg_temp.uid(1),'會被硬刪的點',23.403,120.403,'雲林縣','freeMotorcycle',true,false,'pending','不當');
select pg_temp.flag(7,'7d000000-0000-4000-8000-000000000003','text','q');
delete from community_spots where id='7d000000-0000-4000-8000-000000000003';
set local role authenticated;
select pg_temp.act('admin');
select is((admin_v1.content_report((select id::text from moderation_queue where reporter_id=pg_temp.uid(7) and source_id='7d000000-0000-4000-8000-000000000003')))->'current'->'name',
  'null'::jsonb,'a hard-deleted spot has no current content');
select throws_ok(format('select admin_v1.resolve_content_report(%L,''edit'',now(),''{"note":"x"}'')',
  (select id from moderation_queue where reporter_id=pg_temp.uid(7) and source_id='7d000000-0000-4000-8000-000000000003')),
  'PT404','content_report.spot_not_found','and cannot be edited');
select is((admin_v1.resolve_content_report((select id::text from moderation_queue where reporter_id=pg_temp.uid(7) and source_id='7d000000-0000-4000-8000-000000000003'),
  'keep',now()))->'spot','{"id":"7d000000-0000-4000-8000-000000000003"}'::jsonb,'but can be closed');
reset role;

-- ===== 檢舉雜湊的保留期限 =====
select is((select schedule from cron.job where jobname='content-report-identities-prune'),'47 20 * * *','identities are pruned daily');
update private.content_report_identities set created_at=now()-interval '200 days'
  where queue_id=(select id from moderation_queue where reporter_id=pg_temp.uid(2) and source_id='7d000000-0000-4000-8000-000000000001');
select ok(public.content_report_identities_prune()>=1,'old identities go');

-- ===== 不立即隱藏的規則 =====
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status,note)
select ('7c000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,pg_temp.uid(1),'規則點'||n,23.5+n*0.001,120.5,'雲林縣','freeMotorcycle',true,false,'pending','備註'
from generate_series(1,30) n;
-- 新帳號。
update auth.users set created_at=now()-interval '1 hour' where id=pg_temp.uid(6);
select pg_temp.flag(6,'7c000000-0000-4000-8000-000000000001','text','g');
select is((select array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(6) and source_id='7c000000-0000-4000-8000-000000000001'),
  'hold_skipped_new_account','an account younger than 24 hours does not hide');
update auth.users set created_at=now()-interval '30 days' where id=pg_temp.uid(6);
-- 被駁回太多的檢舉者。
update moderation_queue set status='rejected',resolution_kind='wrong',resolved_at=now() where reporter_id=pg_temp.uid(6) and resolved_at is null;
insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note,status,resolution_kind,resolved_at)
values('7c000000-0000-4000-8000-000000000030',pg_temp.uid(6),'x','inappropriate','{"target":"other"}','x','rejected','abuse',now());
select pg_temp.flag(6,'7c000000-0000-4000-8000-000000000002','text','g');
select is((select array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(6) and source_id='7c000000-0000-4000-8000-000000000002'),
  'hold_skipped_rejected_reporter','a reporter rejected twice in 90 days does not hide');
-- 同網路 24 小時已觸發 3 次。
select pg_temp.flag(2,'7c000000-0000-4000-8000-000000000003','text','h');
select pg_temp.flag(5,'7c000000-0000-4000-8000-000000000004','text','h');
select pg_temp.flag(7,'7c000000-0000-4000-8000-000000000005','text','h');
delete from rate_limit_events;
select pg_temp.flag(2,'7c000000-0000-4000-8000-000000000006','text','h');
select is((select array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(2) and source_id='7c000000-0000-4000-8000-000000000006'),
  'hold_skipped_network_quota','a network that hid 3 times in 24 hours does not hide again');
-- ip_busy（App Check enforce 後，網路當天超過 200 筆）。
delete from rate_limit_events;
insert into rate_limit_events(user_id,ip_hash) select pg_temp.uid(1),repeat('z',64) from generate_series(1,200);
select public.apply_report(pg_temp.uid(7),repeat('z',64),repeat('z',64),
  '{"action":"flag","source_id":"7c000000-0000-4000-8000-000000000009","reason":"x","field":"inappropriate","proposed":{"target":"text"}}',false);
select is((select array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(7) and source_id='7c000000-0000-4000-8000-000000000009'),
  'ip_busy,hold_skipped_ip_busy','a busy network does not hide');
-- 全站保險絲：24 小時內 20 次。
delete from rate_limit_events;
update moderation_queue set held=true,created_at=now() where field='inappropriate' and source_id like '7c000000%' and not held
  and reporter_id<>pg_temp.uid(6);
insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note)
select '7c000000-0000-4000-8000-0000000000'||(10+n),pg_temp.uid(5),'x','inappropriate','{"target":"other"}','x' from generate_series(1,20) n;
update moderation_queue set held=true where reporter_id=pg_temp.uid(5) and source_id like '7c000000%' and proposed->>'target'='other';
select pg_temp.flag(5,'7c000000-0000-4000-8000-000000000007','text','i');
select is((select array_to_string(risk_flags,',') from moderation_queue where reporter_id=pg_temp.uid(5) and source_id='7c000000-0000-4000-8000-000000000007'),
  'hold_skipped_global_fuse','past 20 immediate hides in 24 hours, reports only wait');
select ok(exists(select 1 from private.report_notices where kind='fuse'),'and ops@ is told once');
select pg_temp.flag(7,'7c000000-0000-4000-8000-000000000008','text','j');
select is((select count(*)::int from private.report_notices where kind='fuse'),1,'only once a day');

select * from finish();
rollback;
