-- 點位刪除改軟刪除、14 天後永久刪除（202610310300_soft_delete_spots.sql, #200).
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;

with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed)
  values('10000000-0000-4000-8000-000000000001','刪除測試社群點',25.081,121.581,'臺北市','freeMotorcycle',true,false) returning id)
  insert into fx select 'community',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed)
  values('10000000-0000-4000-8000-000000000001','升級測試社群點',25.082,121.582,'臺北市','freeMotorcycle',true,false) returning id)
  insert into fx select 'promote',id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,source_name,source_id,effective_date,scooter_allowed,heavy_allowed)
  values('刪除測試官方點',25.083,121.583,'臺北市','offStreet','https://example.test/a','臺北市政府','TP-9',current_date,true,true) returning id)
  insert into fx select 'official',id from s;
insert into moderation_queue(source_id,reporter_id,reason,field) values
  ((select id::text from fx where name='community'),'10000000-0000-4000-8000-000000000001','名稱有誤','name'),
  ((select 'official:'||id from fx where name='official'),'10000000-0000-4000-8000-000000000001','點位已不存在：封閉','gone');

select has_column('community_spots','deleted_at','community spots record when they were deleted');
select has_column('official_heavy_spots','deleted_by','and who deleted them');
select ok(exists(select 1 from cron.job where jobname='purge-deleted-spots'),'a daily job purges them');

-- ===== 刪除 =====
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_set_spot_hidden((select id::text from fx where name='community'),true,'現場已改汽車格')$$,
  'an admin deletes a community spot');
select throws_ok($$select admin_set_spot_hidden((select id::text from fx where name='community'),true,'')$$,
  '22023','spot already deleted','a deleted spot is not deleted again');
reset role;
select ok((select deleted_at is not null and deleted_by='10000000-0000-4000-8000-000000000005' and status='hidden'
  from community_spots where id=(select id from fx where name='community')),'deleted now, by the admin, and hidden');
select is((select status||'|'||resolution_kind||'|'||resolution_note from moderation_queue where reason='名稱有誤'),
  'rejected|other|點位已刪除','its open report is closed: 點位已刪除');
select is((select count(*)::integer from admin_audit_log where action='delete_spot'
  and target_id=(select id::text from fx where name='community')),1,'deleting is audited');
set local role anon;
select is((select count(*)::integer from public_spots where id=(select id from fx where name='community')),0,
  'riders no longer see it');
reset role;
select is((select count(*)::integer from public_spots where id=(select id from fx where name='community')),0,
  'public_spots leaves it out for every reader');
select ok(sighting_spot_location((select id::text from fx where name='community')) is null,'sightings skip it');

-- ===== 審核採納「點位已不存在」也是刪除 =====
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_resolve_report((select id from moderation_queue where reason='點位已不存在：封閉'),'accepted','{"hidden":true}')$$,
  'a review adopting a gone report deletes the spot');
reset role;
select ok((select deleted_at is not null from official_heavy_spots where id=(select id from fx where name='official')),
  'the official spot is deleted');
select is((select status from moderation_queue where reason='點位已不存在：封閉'),'accepted','the adopted report stays accepted');
select ok(sighting_spot_location((select 'official:'||id from fx where name='official')) is null,'sightings skip it too');

-- ===== 復原 =====
update community_spots set deleted_at=now()-interval '15 days' where id=(select id from fx where name='community');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_set_spot_hidden((select id::text from fx where name='community'),false,'')$$,
  '22023','deleted more than 14 days ago','past 14 days nothing is restored');
reset role;
select throws_ok($$update community_spots set status='pending' where id=(select id from fx where name='community')$$,
  '22023','deleted more than 14 days ago','nor does any other writer');
update community_spots set deleted_at=now()-interval '1 day' where id=(select id from fx where name='community');
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_set_spot_hidden((select id::text from fx where name='community'),false,'誤刪')$$,
  'within 14 days it is restored');
reset role;
select ok((select deleted_at is null and deleted_by is null and status='pending'
  from community_spots where id=(select id from fx where name='community')),'restored as pending');
select is((select status from moderation_queue where reason='名稱有誤'),'rejected','its closed report is not reopened');
select is((select count(*)::integer from admin_audit_log where action='restore_spot'),1,'restoring is audited');
select is((select count(*)::integer from spot_history_entries((select id::text from fx where name='community'))
  where action in ('delete_spot','restore_spot')),2,'the spot''s history lists the deletion and the restore');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_set_spot_hidden((select id::text from fx where name='community'),false,'')$$,
  '22023','only a deleted spot can be restored','a spot that is not deleted is not restored');

-- ===== 升級官方點：社群點隱藏但不刪除 =====
select lives_ok($$select admin_promote_spot((select id::text from fx where name='promote'),
  '{"source_name":"臺北市政府","source_url":"https://example.test/p","effective_date":"2026-10-31","scooter_allowed":true,"heavy_allowed":false}',
  (select updated_at from community_spots where id=(select id from fx where name='promote')))$$,'an admin promotes a spot');
reset role;
select ok((select status='hidden' and deleted_at is null from community_spots where id=(select id from fx where name='promote')),
  'the promoted community row is hidden, not deleted');

-- ===== 14 天後永久刪除 =====
update official_heavy_spots set deleted_at=now()-interval '15 days' where id=(select id from fx where name='official');
-- A report left open by a concurrent review is closed by the purge.
insert into moderation_queue(source_id,reporter_id,reason,field) values
  ((select 'official:'||id from fx where name='official'),'10000000-0000-4000-8000-000000000001','刪除後仍待審','name');
select is(purge_deleted_spots(),1,'the purge deletes what was deleted more than 14 days ago');
select is((select count(*)::integer from official_heavy_spots where id=(select id from fx where name='official')),0,'it is gone');
select is((select status||'|'||resolution_note from moderation_queue where reason='刪除後仍待審'),'rejected|點位已刪除',
  'a report still open on it is closed');
select is((select source_id from purged_official_spots where official_id=(select id from fx where name='official')),'TP-9',
  'its ids are kept for imports');
select is((select actor::text from admin_audit_log where action='purge_spot'),'10000000-0000-4000-8000-000000000005',
  'the purge is audited as the admin who deleted it');
select ok(not has_function_privilege('authenticated','public.purge_deleted_spots()','EXECUTE'),'only the job purges');

-- ===== 匯入跳過，管理員可解除 =====
select is((select status||'|'||reason from admin_import_plan(jsonb_build_array(jsonb_build_object(
    'id','official:'||(select id from fx where name='official'),'source','official','name','刪除測試官方點',
    'lat',25.083,'lng',121.583,'city','臺北市','source_url','https://example.test/a','source_name','臺北市政府')))),
  'invalid|這個官方點已永久刪除，匯入時跳過；要匯回請先在管理站「已刪除」解除','an import skips a purged official spot');
select is((select status from admin_import_plan(jsonb_build_array(jsonb_build_object(
    'id','official:00000000-0000-4000-8000-0000000000aa','source','official','name','同一筆換了 id',
    'lat',25.083,'lng',121.583,'city','臺北市','source_id','TP-9','source_url','https://example.test/a','source_name','臺北市政府')))),
  'invalid','also by its source id');
select is((select status from admin_import_plan(jsonb_build_array(jsonb_build_object(
    'id','official:00000000-0000-4000-8000-0000000000ab','source','official','name','另一個資料集的同編號',
    'lat',25.084,'lng',121.584,'city','臺北市','source_id','TP-9','source_url','https://example.test/other','source_name','新北市政府')))),
  'new','the same id in another dataset is not skipped');
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_release_purged_official((select id from fx where name='official'),'')$$,'42501',null,
  'only admins release one');
select pg_temp.act('admin');
select lives_ok($$select admin_release_purged_official((select id from fx where name='official'),'官方資料已修正')$$,
  'an admin releases it');
reset role;
select is((select status from admin_import_plan(jsonb_build_array(jsonb_build_object(
    'id','official:'||(select id from fx where name='official'),'source','official','name','刪除測試官方點',
    'lat',25.083,'lng',121.583,'city','臺北市','source_url','https://example.test/a','source_name','臺北市政府')))),
  'new','then the import brings it back');
select is((select count(*)::integer from admin_audit_log where action='release_purged_spot'),1,'releasing is audited');

-- ===== 舊資料：先前隱藏的點位視為今天刪除 =====
select ok(exists(select 1 from pg_trigger where tgname='community_spots_soft_delete'),'the trigger is in place');

select * from finish();
rollback;
