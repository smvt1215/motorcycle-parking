begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'admin_aal1' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;

create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date)
  values('隱藏測試官方點',25.041,121.561,'臺北市','https://example.test/notice',current_date) returning id) insert into fx select 'official',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','隱藏測試社群點',25.042,121.562,'臺北市','paidMotorcycle') returning id) insert into fx select 'spot',id from s;
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values('official:'||(select id from fx where name='official'),'10000000-0000-4000-8000-000000000002','點位已不存在：格位已撤除','點位已不存在','{"hidden":true}') returning id) insert into fx select 'q_gone',id from s;

select is((select hidden from official_heavy_spots where id=(select id from fx where name='official')),false,'official spots start visible');

-- Riders cannot hide official data; only an admin with a second factor.
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select admin_set_spot_hidden('official:'||(select id from fx where name='official'),true)$$,'42501',null,'admin without a second factor cannot hide');
reset role;
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_set_spot_hidden('official:'||(select id from fx where name='official'),true)$$,'42501',null,'ordinary user cannot hide');
reset role;
select ok(not has_function_privilege('anon','public.admin_set_spot_hidden(text,boolean,text)','EXECUTE'),'anon cannot call the hide RPC');

-- Accepting a gone report hides the official spot at once.
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from fx where name='q_gone'),'accepted','{"hidden":true}','現場確認撤除')->'spot'->>'hidden','true','accepting hides the official spot');
select is((select count(*)::integer from official_heavy_spots where id=(select id from fx where name='official')),1,'admin still reads the hidden official spot');
reset role;

set local role anon;
select is((select count(*)::integer from official_heavy_spots where id=(select id from fx where name='official')),0,'the public no longer reads it');
select is((select count(*)::integer from official_viewport_spots(25.0,121.5,25.1,121.6) where id='official:'||(select id from fx where name='official')),0,'the map no longer lists it');
select is((select count(*)::integer from official_viewport_spots_v2(25.0,121.5,25.1,121.6) where id='official:'||(select id from fx where name='official')),0,'the new map query no longer lists it');
reset role;
select pg_temp.act('user');
set local role authenticated;
select is((select count(*)::integer from official_heavy_spots where id=(select id from fx where name='official')),0,'signed-in riders no longer read it');
reset role;

-- Restoring later brings it back and is audited.
select pg_temp.act('admin');
set local role authenticated;
select is(admin_set_spot_hidden('official:'||(select id from fx where name='official'),false,'公告恢復')->>'hidden','false','admin restores the official spot');
select throws_ok($$select admin_set_spot_hidden('official:not-a-uuid',false)$$,'22023',null,'malformed ids are refused');
select throws_ok($$select admin_set_spot_hidden('official:00000000-0000-4000-8000-000000000000',false)$$,'22023','spot not found','unknown spots are refused');
reset role;
set local role anon;
select is((select count(*)::integer from official_viewport_spots(25.0,121.5,25.1,121.6) where id='official:'||(select id from fx where name='official')),1,'the restored spot is back on the map');
reset role;
select is((select note from admin_audit_log where action='restore_spot' and target_id=(select id::text from fx where name='official')),'公告恢復','restoring is audited with its note');

-- Community spots go through the same RPC; restoring clears the votes that hid them.
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
values((select id from fx where name='spot'),'10000000-0000-4000-8000-000000000002','gone',true,1,repeat('m',64),repeat('m',64));
select pg_temp.act('admin');
set local role authenticated;
select is(admin_set_spot_hidden((select id::text from fx where name='spot'),true)->>'status','hidden','admin hides a community spot');
select is(admin_set_spot_hidden((select id::text from fx where name='spot'),false)->>'status','pending','a restored community spot is pending again');
reset role;
select is((select count(*)::integer from spot_votes where spot_id=(select id from fx where name='spot') and vote='gone'),0,'restoring clears the gone votes');
select is((select count(*)::integer from admin_audit_log where action='hide_spot'),1,'hiding is audited');

-- Version conflicts: a suggestion records the spot it was made against.
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,fee_note)
  values('10000000-0000-4000-8000-000000000001','衝突測試點',25.043,121.563,'臺北市','paidMotorcycle','每小時 20 元') returning id) insert into fx select 'conflict_spot',id from s;
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('c',64),repeat('c',64),
  jsonb_build_object('action','flag','source_id',(select id::text from fx where name='conflict_spot'),
    'reason','收費資訊：每次 10 元','field','收費資訊','proposed',jsonb_build_object('fee_note','每次 10 元')));
insert into fx select 'q_conflict',id from moderation_queue where reason='收費資訊：每次 10 元';
select is((select base_updated_at from moderation_queue where id=(select id from fx where name='q_conflict')),
  (select updated_at from community_spots where id=(select id from fx where name='conflict_spot')),'a flag records the spot version');
select is((select base_spot->>'fee_note' from moderation_queue where id=(select id from fx where name='q_conflict')),'每小時 20 元','a flag records the values the rider saw');
select ok((select not (base_spot ? 'user_id') from moderation_queue where id=(select id from fx where name='q_conflict')),'the snapshot omits contributor ids');
-- Someone edits the spot after the suggestion (the test runs in one transaction, so move the clock by hand).
update community_spots set fee_note='每小時 25 元',updated_at=updated_at+interval '1 minute' where id=(select id from fx where name='conflict_spot');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from fx where name='q_conflict'),'accepted','{"fee_note":"每次 10 元"}')$$,
  '40001','spot changed since the report','accepting over a newer spot version is refused');
select is((select status from moderation_queue where id=(select id from fx where name='q_conflict')),'pending','a conflict leaves the report pending');
select is((select fee_note from community_spots where id=(select id from fx where name='conflict_spot')),'每小時 25 元','a conflict leaves the spot unchanged');
select is(admin_resolve_report((select id from fx where name='q_conflict'),'rejected')->>'status','rejected','a conflicting report can still be rejected');
reset role;

-- Forcing after review is allowed and audited.
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('d',64),repeat('d',64),
  jsonb_build_object('action','flag','source_id',(select id::text from fx where name='conflict_spot'),
    'reason','收費資訊：每次 15 元','field','收費資訊','proposed',jsonb_build_object('fee_note','每次 15 元')));
insert into fx select 'q_force',id from moderation_queue where reason='收費資訊：每次 15 元';
update community_spots set fee_note='每小時 30 元',updated_at=updated_at+interval '1 minute' where id=(select id from fx where name='conflict_spot');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from fx where name='q_force'),'accepted','{"fee_note":"每次 15 元"}','已重新比對現場',true)->'spot'->>'fee_note','每次 15 元','admin may force after reviewing');
reset role;
select is((select after->>'forced' from admin_audit_log where target_id=(select id::text from fx where name='q_force')),'true','a forced resolution is marked in the audit log');

-- Changes to fields the suggestion leaves alone are not conflicts.
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('f',64),repeat('f',64),
  jsonb_build_object('action','flag','source_id',(select id::text from fx where name='conflict_spot'),
    'reason','格位類型：建議「重機專用格」','field','space_type','proposed',jsonb_build_object('space_type','heavyOnly')));
update community_spots set status='confirmed',last_confirmed_at=now(),note='入口在巷內',updated_at=updated_at+interval '1 minute'
  where id=(select id from fx where name='conflict_spot');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from moderation_queue where reason='格位類型：建議「重機專用格」' and status='pending'),'accepted','{"space_type":"heavyOnly"}')->>'status','accepted','votes and unrelated edits do not block a suggestion');
reset role;

-- Same version: accepted normally, not marked forced.
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('e',64),repeat('e',64),
  jsonb_build_object('action','flag','source_id',(select id::text from fx where name='conflict_spot'),'reason','停車點名稱：衝突測試新名'));
insert into fx select 'q_legacy_flag',id from moderation_queue where reason='停車點名稱：衝突測試新名';
select ok((select base_updated_at is not null from moderation_queue where id=(select id from fx where name='q_legacy_flag')),'a flag from an older app gets the version at queue time');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from fx where name='q_legacy_flag'),'accepted','{"name":"衝突測試新名"}')->>'status','accepted','an unchanged spot is accepted normally');
reset role;
select is((select after->>'forced' from admin_audit_log where target_id=(select id::text from fx where name='q_legacy_flag')),'false','a normal resolution is not marked forced');

-- Reports queued before versions existed are never treated as conflicts.
insert into moderation_queue(source_id,reason) values((select id::text from fx where name='conflict_spot'),'備註：舊資料');
update moderation_queue set base_updated_at=null,base_spot=null where reason='備註：舊資料';
update community_spots set updated_at=updated_at+interval '1 minute' where id=(select id from fx where name='conflict_spot');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from moderation_queue where reason='備註：舊資料'),'accepted','{"note":"舊資料"}')->>'status','accepted','reports without a recorded version are reviewable');
reset role;

-- A location suggestion moves the spot; the geography follows the columns.
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','位置測試點',25.044,121.564,'臺北市','paidMotorcycle') returning id) insert into fx select 'moved_spot',id from s;
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('g',64),repeat('g',64),
  jsonb_build_object('action','flag','source_id',(select id::text from fx where name='moved_spot'),
    'reason','停車點位置：建議移到 25.044100, 121.564000','field','location','proposed',jsonb_build_object('lat',25.0441,'lng',121.564)));
insert into fx select 'q_location',id from moderation_queue where reason like '停車點位置：%';
select is((select field from moderation_queue where id=(select id from fx where name='q_location')),'location','a location suggestion keeps its field key');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from fx where name='q_location'),'accepted',
  (select proposed from moderation_queue where id=(select id from fx where name='q_location')))->>'status','accepted','an admin applies the suggested position');
reset role;
select is((select (lat,lng)::text from community_spots where id=(select id from fx where name='moved_spot')),'(25.0441,121.564)','the spot moves to the suggested coordinates');
select ok((select extensions.st_dwithin(location,extensions.st_setsrid(extensions.st_makepoint(121.564,25.0441),4326)::extensions.geography,0.5)
  from community_spots where id=(select id from fx where name='moved_spot')),'the spatial index position moves with it');
select * from finish();
rollback;
